#!/usr/bin/env bash
# overleaf_purge.sh
# WARNING: deletes containers and volumes for this Overleaf instance.
# Optionally deletes the committed TeX-full image tag and the toolkit folder.
set -euo pipefail
OVERLEAF_DIR="${OVERLEAF_DIR:-$HOME/overleaf-ce}"
cd "$OVERLEAF_DIR"

VERSION="$(cat config/version || true)"
IMAGE_TAG=""
if [ -n "${VERSION:-}" ]; then
  IMAGE_TAG="sharelatex/sharelatex:${VERSION}"
fi

echo "This will:"
echo "  • Stop and remove Overleaf CE containers"
echo "  • Remove compose volumes for this instance (Mongo/Redis data)"
echo "  • Remove the committed image tag (${IMAGE_TAG:-<none>}) if present"
echo "  • Optionally delete ${OVERLEAF_DIR}"
read -r -p "Type DELETE to continue: " ANS
[ "$ANS" = "DELETE" ] || { echo "Aborted."; exit 1; }

./bin/docker-compose down -v || true

if [ -n "$IMAGE_TAG" ] && docker image inspect "$IMAGE_TAG" >/dev/null 2>&1; then
  echo "[+] Removing image $IMAGE_TAG"
  docker rmi "$IMAGE_TAG" || true
fi

read -r -p "Also delete the toolkit folder ${OVERLEAF_DIR}? (y/N): " DELDIR
if [[ "${DELDIR:-N}" =~ ^[Yy]$ ]]; then
  cd ..
  rm -rf "$OVERLEAF_DIR"
  echo "[+] Deleted ${OVERLEAF_DIR}"
fi

echo "✅ Purge complete."
