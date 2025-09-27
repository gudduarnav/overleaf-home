#!/usr/bin/env bash
# Fully automatic Overleaf CE + TeX Live full installer
# - Installs Docker + compose
# - Clones Overleaf Toolkit
# - Configures Mongo split (MONGO_IMAGE/MONGO_VERSION)
# - Starts CE, installs TeX Live full, commits tagged image
# - Recreates CE on the TeX-full image
set -euo pipefail

# ---------------------- Config (env-overridable) ----------------------
OVERLEAF_DIR="${OVERLEAF_DIR:-$HOME/overleaf-ce}"
OVERLEAF_PORT="${OVERLEAF_PORT:-8080}"
OVERLEAF_LISTEN_IP="${OVERLEAF_LISTEN_IP:-127.0.0.1}"

# Mongo settings required by newer Toolkit
MONGO_IMAGE="${MONGO_IMAGE:-mongo}"
MONGO_VERSION="${MONGO_VERSION:-6.0}"          # Must start with major + dot

# TeX Live meta-scheme (scheme-full is full install)
TEXLIVE_SCHEME="${TEXLIVE_SCHEME:-scheme-full}"

# Optional admin creation
OVERLEAF_ADMIN_EMAIL="${OVERLEAF_ADMIN_EMAIL:-}"  # e.g., you@example.com

# Sentinels
REENTERED="${REENTERED:-0}"

# ---------------------- Helpers ----------------------
have() { command -v "$1" >/dev/null 2>&1; }

apt_install()  { sudo apt-get update -y && sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"; }
dnf_install()  { sudo dnf install -y "$@"; }
yum_install()  { sudo yum install -y "$@"; }

install_pkg() {
  if have apt-get; then apt_install "$@"
  elif have dnf;   then dnf_install "$@"
  elif have yum;   then yum_install "$@"
  else
    echo "[-] Unsupported package manager. Please install: $* and re-run." >&2
    exit 1
  fi
}

ensure_prereqs() {
  for p in git curl; do
    have "$p" || install_pkg "$p"
  done
}

ensure_docker() {
  if ! have docker; then
    echo "[+] Installing Docker Engine via convenience script…"
    curl -fsSL https://get.docker.com | sh
  fi

  # Try starting the daemon if stopped
  if have systemctl && ! (sudo systemctl is-active --quiet docker); then
    sudo systemctl start docker || true
    sudo systemctl enable docker || true
  fi

  # Ensure we can run docker without sudo (Toolkit uses 'docker', not 'sudo docker')
  if ! docker info >/dev/null 2>&1; then
    # If it's a permission issue, add user to docker group and re-exec in that group
    if groups "$USER" | grep -qw docker; then
      echo "[!] Docker running but 'docker info' failed; trying with sudo once to detect cause…"
      sudo docker info >/dev/null 2>&1 || true
    else
      echo "[+] Adding $USER to 'docker' group and re-executing this script in a new group session…"
      sudo usermod -aG docker "$USER"
      if [ "$REENTERED" != "1" ]; then
        # Re-enter with docker group without requiring a logout
        exec env REENTERED=1 newgrp docker <<'EONG'
bash -lc 'exec "$0"'  # will re-run this script with REENTERED=1
EONG
      fi
    fi
  fi

  # Compose plugin
  if ! docker compose version >/dev/null 2>&1; then
    echo "[+] Installing docker compose plugin…"
    if have apt-get; then
      install_pkg docker-compose-plugin
    else
      echo "[-] Compose plugin missing and automatic install not supported on this distro."
      echo "    Please install the Docker Compose plugin for your OS and re-run."
      exit 1
    fi
  fi
}

clone_toolkit() {
  if [ ! -d "$OVERLEAF_DIR" ]; then
    echo "[+] Cloning Overleaf Toolkit → $OVERLEAF_DIR"
    git clone https://github.com/overleaf/toolkit.git "$OVERLEAF_DIR"
  else
    echo "[=] Using existing Toolkit at $OVERLEAF_DIR"
  fi
}

init_toolkit() {
  cd "$OVERLEAF_DIR"
  echo "[+] Initializing Toolkit config"
  ./bin/init
}

# Write or update key=value in a .rc file idempotently
set_kv() {
  local key="$1" val="$2" file="$3"
  if grep -qE "^${key}=" "$file"; then
    sed -i "s|^${key}=.*|${key}=${val}|" "$file"
  else
    printf "%s=%s\n" "$key" "$val" >> "$file"
  fi
}

configure_overleaf_rc() {
  mkdir -p config logs
  local rc=config/overleaf.rc
  touch "$rc"
  set_kv PROJECT_NAME        "overleaf"             "$rc"
  set_kv OVERLEAF_LISTEN_IP  "${OVERLEAF_LISTEN_IP}" "$rc"
  set_kv OVERLEAF_PORT       "${OVERLEAF_PORT}"      "$rc"
  set_kv NGINX_ENABLED       "false"                "$rc"
  set_kv REDIS_AOF_PERSISTENCE "true"               "$rc"
  set_kv OVERLEAF_LOG_PATH   "logs"                 "$rc"

  # Required by new Toolkit releases
  set_kv MONGO_IMAGE         "${MONGO_IMAGE}"       "$rc"
  set_kv MONGO_VERSION       "${MONGO_VERSION}"     "$rc"
}

compose_up() {
  echo "[+] Bringing Overleaf CE up (detached)…"
  ./bin/up -d
}

wait_for_sharelatex() {
  echo "[~] Waiting for 'sharelatex' container to be ready (tlmgr check loop)…"
  local deadline=$((SECONDS+900))  # 15 min timeout just for readiness, not for TeX install
  until ./bin/docker-compose exec -T sharelatex bash -lc "tlmgr --version" >/dev/null 2>&1; do
    if (( SECONDS > deadline )); then
      echo "[-] sharelatex container didn't become ready in time." >&2
      ./bin/docker-compose ps
      exit 1
    fi
    sleep 5
  done
  echo "[+] sharelatex is reachable."
}

install_texlive_full() {
  echo "[+] Installing TeX Live meta-scheme '${TEXLIVE_SCHEME}' inside the container (this is large)…"
  # Set a mirror to avoid prompts; update self; then install scheme and add to PATH
  ./bin/docker-compose exec -T sharelatex bash -lc \
    "tlmgr option repository http://mirror.ctan.org/systems/texlive/tlnet && \
     tlmgr update --self && \
     tlmgr install ${TEXLIVE_SCHEME} && \
     tlmgr path add"
}

commit_new_image_and_switch() {
  local version new_tag cid
  version="$(cat config/version)"
  cid="$(./bin/docker-compose ps -q sharelatex)"
  new_tag="sharelatex/sharelatex:${version}-tlfull"

  echo "[+] Committing running container → ${new_tag}"
  docker commit "$cid" "$new_tag" >/dev/null

  echo "[+] Switching Toolkit to new image tag: ${version}-tlfull"
  echo "${version}-tlfull" > config/version
  ./bin/up -d
}

maybe_create_admin() {
  if [ -n "$OVERLEAF_ADMIN_EMAIL" ]; then
    echo "[+] Creating admin user: ${OVERLEAF_ADMIN_EMAIL}"
    ./bin/docker-compose exec -T sharelatex bash -lc \
      "cd /var/www/sharelatex && grunt user:create-admin --email='${OVERLEAF_ADMIN_EMAIL}'" || {
        echo "[!] Admin creation may have failed; check logs. Continuing…"
      }
  fi
}

print_summary() {
  echo
  echo "✅ Overleaf CE with TeX Live full is running."
  echo "   URL:  http://${OVERLEAF_LISTEN_IP}:${OVERLEAF_PORT}"
  echo "   Dir:  ${OVERLEAF_DIR}"
  if [ -n "$OVERLEAF_ADMIN_EMAIL" ]; then
    echo "   Admin created for: ${OVERLEAF_ADMIN_EMAIL}"
  else
    echo "   (Optional) Create an admin later:"
    echo "     cd ${OVERLEAF_DIR}"
    echo "     ./bin/docker-compose exec sharelatex bash -lc \"cd /var/www/sharelatex && grunt user:create-admin --email='you@example.com'\""
  fi
}

# ---------------------- Main ----------------------
ensure_prereqs
ensure_docker
clone_toolkit
init_toolkit
configure_overleaf_rc
compose_up
wait_for_sharelatex
install_texlive_full
commit_new_image_and_switch
maybe_create_admin
print_summary

