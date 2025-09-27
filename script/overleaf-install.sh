#!/usr/bin/env bash
# Fully automatic Overleaf Community Edition installer/repairer
# - Clones/updates Overleaf Toolkit into $OVERLEAF_DIR
# - Configures required Mongo split (MONGO_IMAGE/MONGO_VERSION)
# - Disables unsupported sibling containers on CE
# - Brings stack up, waits for Mongo, auto-initializes replica set (idempotent)
# - Waits for ShareLaTeX web to come up and prints the URL
#
# Usage:
#   chmod +x overleaf-install.auto.sh
#   ./overleaf-install.auto.sh
#
# Optional environment overrides:
#   OVERLEAF_DIR="$HOME/overleaf-ce" OVERLEAF_PORT=8080 OVERLEAF_LISTEN_IP=127.0.0.1 ./overleaf-install.auto.sh
#
set -euo pipefail

# ---------------------- User-configurable (via env) ----------------------
OVERLEAF_DIR="${OVERLEAF_DIR:-$HOME/overleaf-ce}"
OVERLEAF_PORT="${OVERLEAF_PORT:-8080}"                # Host port for HTTP access
OVERLEAF_LISTEN_IP="${OVERLEAF_LISTEN_IP:-0.0.0.0}" # Bind address (use 0.0.0.0 for LAN access)

# Mongo settings required by newer Toolkit
MONGO_IMAGE="${MONGO_IMAGE:-mongo}"
MONGO_VERSION="${MONGO_VERSION:-6.0}"

# Repo for Overleaf Toolkit
TOOLKIT_REPO_URL="${TOOLKIT_REPO_URL:-https://github.com/overleaf/overleaf-toolkit}"

# --------------------------- Helpers -------------------------------------
log()  { printf "\033[1;36m[+] %s\033[0m\n" "$*"; }
warn() { printf "\033[1;33m[!] %s\033[0m\n" "$*"; }
err()  { printf "\033[1;31m[-] %s\033[0m\n" "$*"; }
die()  { err "$*"; exit 1; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Required command '$1' not found. Please install it and re-run."
}

set_kv() {
  local key="$1" val="$2" file="$3"
  if grep -qE "^${key}=" "$file" 2>/dev/null; then
    sed -i "s|^${key}=.*|${key}=${val}|" "$file"
  else
    printf "%s=%s\n" "$key" "$val" >> "$file"
  fi
}

dc() { ( cd "$OVERLEAF_DIR" && ./bin/docker-compose "$@" ); }
tk() { ( cd "$OVERLEAF_DIR" && ./bin/"$@" ); }

# --------------------------- Steps ---------------------------------------
ensure_prereqs() {
  log "Checking prerequisites…"
  need_cmd git
  need_cmd bash
  need_cmd sed
  need_cmd awk
  need_cmd grep
  need_cmd curl || warn "curl not found (optional; used for health checks)"
}

ensure_docker() {
  if ! command -v docker >/dev/null 2>&1; then
    die "Docker is not installed. Install Docker Engine + docker compose plugin and re-run."
  fi
  if ! docker compose version >/dev/null 2>&1; then
    die "docker compose plugin not found. Please install 'docker-compose-plugin' (Ubuntu: apt install docker-compose-plugin)."
  fi
  # Test Docker daemon
  if ! docker ps >/dev/null 2>&1; then
    die "Docker daemon not running or insufficient permissions. Start Docker or add your user to 'docker' group."
  fi
}

clone_or_update_toolkit() {
  if [ ! -d "$OVERLEAF_DIR" ]; then
    log "Cloning Overleaf Toolkit → $OVERLEAF_DIR"
    git clone --depth=1 "$TOOLKIT_REPO_URL" "$OVERLEAF_DIR"
  else
    log "Updating Overleaf Toolkit in $OVERLEAF_DIR"
    ( cd "$OVERLEAF_DIR" && git pull --ff-only || true )
  fi
}

init_toolkit() {
  log "Initializing Toolkit config…"
  ( cd "$OVERLEAF_DIR" && ./bin/init )
}

configure_overleaf_rc() {
  log "Writing config/overleaf.rc settings…"
  mkdir -p "$OVERLEAF_DIR/config" "$OVERLEAF_DIR/logs"
  local rc="$OVERLEAF_DIR/config/overleaf.rc"
  touch "$rc"

  set_kv PROJECT_NAME               "overleaf"              "$rc"
  set_kv OVERLEAF_LISTEN_IP         "${OVERLEAF_LISTEN_IP}" "$rc"
  set_kv OVERLEAF_PORT              "${OVERLEAF_PORT}"      "$rc"
  set_kv NGINX_ENABLED              "false"                 "$rc"
  set_kv SIBLING_CONTAINERS_ENABLED "false"                 "$rc"
  set_kv REDIS_AOF_PERSISTENCE      "true"                  "$rc"
  set_kv OVERLEAF_LOG_PATH          "logs"                  "$rc"

  # Required since Toolkit split Mongo image/version
  set_kv MONGO_IMAGE                "${MONGO_IMAGE}"        "$rc"
  set_kv MONGO_VERSION              "${MONGO_VERSION}"      "$rc"
}

compose_up() {
  log "Bringing Overleaf CE up (detached)…"
  tk up -d
}

wait_for_mongo() {
  log "Waiting for Mongo to accept connections…"
  local deadline=$((SECONDS+180))
  until dc exec -T mongo mongosh --quiet --eval "db.adminCommand({ ping: 1 }).ok" >/dev/null 2>&1; do
    if (( SECONDS > deadline )); then
      die "Mongo did not become ready in time."
    fi
    sleep 2
  done
  log "Mongo is up."
}

init_mongo_replset() {
  log "Ensuring Mongo replica set 'rs0' is initiated…"
  if dc exec -T mongo mongosh --quiet --eval "rs.status().ok" >/dev/null 2>&1; then
    log "Replica set already initiated."
    return
  fi
  if ! dc exec -T mongo mongosh --quiet --eval \
      "rs.initiate({_id:'rs0', members:[{_id:0, host:'mongo:27017'}]})" >/dev/null; then
    err "rs.initiate failed. Mongo logs:"
    dc logs --tail=120 mongo || true
    die "Could not initiate Mongo replica set."
  fi
  # Wait until PRIMARY
  local deadline=$((SECONDS+120))
  until dc exec -T mongo mongosh --quiet --eval "rs.status().members.filter(m=>m.stateStr==='PRIMARY').length" | grep -q "1"; do
    (( SECONDS > deadline )) && die "Replica set did not reach PRIMARY in time."
    sleep 2
  done
  log "Replica set initiated and PRIMARY is up."
}

wait_for_sharelatex() {
  log "Waiting for ShareLaTeX service to become reachable…"
  # Determine mapped host port for service 'sharelatex' port 80
  local mapped
  if ! mapped="$(dc port sharelatex 80/tcp 2>/dev/null)"; then
    warn "Could not resolve mapped ShareLaTeX port via 'docker compose port'. Using OVERLEAF_PORT=${OVERLEAF_PORT}."
    mapped="${OVERLEAF_LISTEN_IP}:${OVERLEAF_PORT}"
  fi
  # mapped may be like "0.0.0.0:8080" or "127.0.0.1:8080"
  local host="${mapped%:*}"; local port="${mapped##*:}"
  # Use localhost for health check if Docker reports 0.0.0.0
  local hc_host="$host"
  if [ "$hc_host" = "0.0.0.0" ]; then hc_host="127.0.0.1"; fi
  local deadline=$((SECONDS+300))
  while true; do
    # Prefer curl if available
    if command -v curl >/dev/null 2>&1; then
      if curl -fsS "http://${hc_host}:${port}/" >/dev/null 2>&1; then
        break
      fi
    else
      # Fallback to bash /dev/tcp
      if (exec 3<>"/dev/tcp/${hc_host}/${port}") >/dev/null 2>&1; then
        exec 3>&-
        break
      fi
    fi
    (( SECONDS > deadline )) && die "ShareLaTeX did not become reachable on http://${host}:${port}/"
    sleep 2
  done
  log "ShareLaTeX is reachable at http://${host}:${port}/"
}

print_summary() {
  echo
  log "✅ Overleaf Community Edition is up."
  echo "    URL:   http://${OVERLEAF_LISTEN_IP}:${OVERLEAF_PORT}/"
  if command -v hostname >/dev/null 2>&1; then
    LAN_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
    if [ -n "$LAN_IP" ]; then
      echo "    LAN:   http://${LAN_IP}:${OVERLEAF_PORT}/ (from other devices)"
    fi
  fi
  echo "    Dir:   $OVERLEAF_DIR"
  echo
  warn "Community Edition does not support isolated sibling compiles (this is normal for CE)."
  echo
  log "Common next steps:"
  echo "  • To see running services:        (cd \"$OVERLEAF_DIR\" && ./bin/docker-compose ps)"
  echo "  • To tail ShareLaTeX logs:        (cd \"$OVERLEAF_DIR\" && ./bin/docker-compose logs -f sharelatex)"
  echo "  • To stop the stack:              (cd \"$OVERLEAF_DIR\" && ./bin/stop)"
}

# --------------------------- Main ----------------------------------------
ensure_prereqs
ensure_docker
clone_or_update_toolkit
init_toolkit
configure_overleaf_rc
compose_up
wait_for_mongo
init_mongo_replset
wait_for_sharelatex
print_summary
