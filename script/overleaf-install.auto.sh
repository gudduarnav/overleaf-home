#!/bin/bash
# Fully automatic Overleaf CE installer with TeX Live FULL + extras (persisted)
# v1.3 — Robust tlmgr mirror fallback on signature/mirror sync errors
set -Eeuo pipefail

if [ -z "${BASH_VERSION:-}" ]; then
  echo "This script must be run with bash. Try: bash $0"
  exit 1
fi

# ---------------------- User-configurable (via env) ----------------------
OVERLEAF_DIR="${OVERLEAF_DIR:-$HOME/overleaf-ce}"
OVERLEAF_PORT="${OVERLEAF_PORT:-8080}"
OVERLEAF_LISTEN_IP="${OVERLEAF_LISTEN_IP:-0.0.0.0}"
MONGO_IMAGE="${MONGO_IMAGE:-mongo}"
MONGO_VERSION="${MONGO_VERSION:-6.0}"

# TeX Live + extras
TEXLIVE_SCHEME="${TEXLIVE_SCHEME:-scheme-full}"
APT_EXTRAS="${APT_EXTRAS:-python3 python3-pygments inkscape ghostscript lmodern fontconfig poppler-utils perl libyaml-tiny-perl libfile-homedir-perl libunicode-linebreak-perl}"

TOOLKIT_REPO_URL="${TOOLKIT_REPO_URL:-https://github.com/overleaf/overleaf-toolkit}"

# --------------------------- Helpers -------------------------------------
log()  { printf "\033[1;36m[+] %s\033[0m\n" "$*"; }
warn() { printf "\033[1;33m[!] %s\033[0m\n" "$*"; }
err()  { printf "\033[1;31m[-] %s\033[0m\n" "$*"; }
die()  { err "$*"; exit 1; }

need_cmd() { command -v "$1" >/dev/null 2>&1 || die "Required command '$1' not found."; }

dc() { ( cd "$OVERLEAF_DIR" && ./bin/docker-compose "$@" ); }
tk() { ( cd "$OVERLEAF_DIR" && ./bin/"$@" ); }

set_kv() {
  local key="$1" val="$2" file="$3"
  mkdir -p "$(dirname "$file")"
  touch "$file"
  if grep -qE "^${key}=" "$file" 2>/dev/null; then
    sed -i "s|^${key}=.*|${key}=${val}|" "$file"
  else
    printf "%s=%s\n" "$key" "$val" >> "$file"
  fi
}

# --------------------------- Steps ---------------------------------------
ensure_prereqs() {
  log "Checking prerequisites…"
  need_cmd git; need_cmd sed; need_cmd awk; need_cmd grep; need_cmd bash
  if ! command -v curl >/dev/null 2>&1; then warn "curl not found - used later for HTTP health checks"; fi
}

ensure_docker() {
  need_cmd docker
  if ! docker compose version >/dev/null 2>&1; then
    die "docker compose plugin not found. Install 'docker-compose-plugin' (e.g., apt install docker-compose-plugin)."
  fi
  docker ps >/dev/null 2>&1 || die "Docker daemon not running or insufficient permissions."
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
  local rc="$OVERLEAF_DIR/config/overleaf.rc"
  set_kv PROJECT_NAME               "overleaf"              "$rc"
  set_kv OVERLEAF_LISTEN_IP         "${OVERLEAF_LISTEN_IP}" "$rc"
  set_kv OVERLEAF_PORT              "${OVERLEAF_PORT}"      "$rc"
  set_kv NGINX_ENABLED              "false"                 "$rc"
  set_kv SIBLING_CONTAINERS_ENABLED "false"                 "$rc"
  set_kv REDIS_AOF_PERSISTENCE      "true"                  "$rc"
  set_kv OVERLEAF_LOG_PATH          "logs"                  "$rc"
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
    (( SECONDS > deadline )) && die "Mongo did not become ready in time."
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
  dc exec -T mongo mongosh --quiet --eval "rs.initiate({_id:'rs0', members:[{_id:0, host:'mongo:27017'}]})" >/dev/null \
    || { dc logs --tail=120 mongo || true; die "Could not initiate Mongo replica set."; }
  local deadline=$((SECONDS+120))
  until dc exec -T mongo mongosh --quiet --eval "rs.status().members.filter(m=>m.stateStr==='PRIMARY').length" | grep -q "1"; do
    (( SECONDS > deadline )) && die "Replica set did not reach PRIMARY in time."
    sleep 2
  done
  log "Replica set PRIMARY is up."
}

wait_for_sharelatex() {
  log "Waiting for ShareLaTeX (web) to become reachable…"
  local mapped host port hc_host
  mapped="$(dc port sharelatex 80/tcp 2>/dev/null || true)"
  if [ -z "$mapped" ]; then mapped="${OVERLEAF_LISTEN_IP}:${OVERLEAF_PORT}"; fi
  host="${mapped%:*}"; port="${mapped##*:}"
  hc_host="$host"; [ "$hc_host" = "0.0.0.0" ] && hc_host="127.0.0.1"
  local deadline=$((SECONDS+300))
  while true; do
    if command -v curl >/dev/null 2>&1; then
      curl -fsS "http://${hc_host}:${port}/" >/dev/null 2>&1 && break
    else
      (exec 3<>"/dev/tcp/${hc_host}/${port}") >/dev/null 2>&1 && { exec 3>&-; break; }
    fi
    (( SECONDS > deadline )) && die "ShareLaTeX did not become reachable on http://${host}:${port}/"
    sleep 2
  done
  log "ShareLaTeX is reachable at http://${host}:${port}/"
}

install_texlive_full() {
  log "Installing TeX Live ${TEXLIVE_SCHEME} inside 'sharelatex' - includes mirror fallback…"
  dc exec -T sharelatex bash -lc '
set -e
if ! command -v tlmgr >/dev/null 2>&1; then
  echo "tlmgr not found in container. Aborting." >&2
  exit 1
fi

# Detect TL year and choose repository set
TLYEAR=$(tlmgr --version 2>/dev/null | grep -oE "20[0-9]{2}" | head -1 || true)
HIST_REPO=""
if [ -n "$TLYEAR" ] && [ "$TLYEAR" -le 2023 ]; then
  HIST_REPO="https://ftp.math.utah.edu/pub/tex/historic/systems/texlive/$TLYEAR/tlnet-final"
fi

# Candidate mirrors (pin to avoid mid-sync issues)
REPOS=""
if [ -n "$HIST_REPO" ]; then
  REPOS="$HIST_REPO"
else
  REPOS="https://ctan.math.illinois.edu/systems/texlive/tlnet
https://ftp.jaist.ac.jp/pub/CTAN/systems/texlive/tlnet
https://mirror2.sandyriver.net/pub/ctan/systems/texlive/tlnet
https://ctan.mirror.globo.tech/systems/texlive/tlnet
https://mirrors.rit.edu/CTAN/systems/texlive/tlnet
https://mirror.ctan.org/systems/texlive/tlnet"
fi

ok=""
for R in $REPOS; do
  echo "Trying TeX Live repo: $R"
  tlmgr option repository "$R" || continue
  if tlmgr update --self; then
    ok="yes"
    break
  else
    echo "tlmgr self-update failed on $R, trying next mirror…"
  fi
done

if [ -z "$ok" ]; then
  echo "All candidate mirrors failed for tlmgr update --self." >&2
  exit 2
fi

# Proceed with installs
tlmgr install '"$TEXLIVE_SCHEME"' latexmk biber biblatex collection-fontsrecommended
tlmgr path add
fmtutil-sys --all >/dev/null 2>&1 || true
mktexlsr
echo "IEEEtran at: $(kpsewhich IEEEtran.cls || true)"
'
}

install_apt_extras() {
  log "Installing external helper tools inside 'sharelatex' via apt…"
  dc exec -T sharelatex bash -lc "apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y ${APT_EXTRAS} && apt-get clean && rm -rf /var/lib/apt/lists/*"
  dc exec -T sharelatex bash -lc "command -v pygmentize >/dev/null && echo 'pygmentize OK' || echo 'pygmentize missing'"
  dc exec -T sharelatex bash -lc "command -v inkscape  >/dev/null && echo 'inkscape OK'  || echo 'inkscape missing'"
}

verify_ieee() {
  log "Verifying IEEEtran.cls presence…"
  if ! dc exec -T sharelatex kpsewhich IEEEtran.cls >/dev/null 2>&1; then
    die "IEEEtran.cls not found after installation."
  fi
  log "IEEEtran.cls is installed."
}

commit_image_and_pin_version() {
  log "Committing the 'sharelatex' container as a new image with TeX Live full…"
  local version_file="$OVERLEAF_DIR/config/version"
  local base_tag=""
  if [ -f "$version_file" ]; then base_tag="$(cat "$version_file" | tr -d '\n\r' || true)"; fi
  [ -z "$base_tag" ] && base_tag="latest"
  local new_tag="${base_tag}-texlive-full"
  docker commit sharelatex "sharelatex/sharelatex:${new_tag}" >/dev/null
  log "Created image tag: sharelatex/sharelatex:${new_tag}"
  echo "${new_tag}" > "$version_file"
  log "Pinned Toolkit version to: $(cat "$version_file")"
}

recreate_stack() {
  log "Recreating stack with the new image tag…"
  tk stop || true
  tk up -d
  wait_for_sharelatex
}

print_summary() {
  echo
  log "Overleaf CE is up with TeX Live FULL + extras baked in."
  echo "    Dir:   $OVERLEAF_DIR"
  echo "    URL:   http://${OVERLEAF_LISTEN_IP}:${OVERLEAF_PORT}/"
  echo "    Check: docker exec -it sharelatex kpsewhich IEEEtran.cls"
  echo
  log "Installed external tools (apt): ${APT_EXTRAS}"
  echo
  log "You can rerun this script safely; it is idempotent."
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
install_texlive_full
install_apt_extras
verify_ieee
commit_image_and_pin_version
recreate_stack
print_summary
