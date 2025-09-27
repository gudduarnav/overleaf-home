#!/bin/sh
# overleaf-uninstall-posix.sh
# POSIX-compatible uninstaller for Overleaf CE.
# - Stops/removes the current Overleaf CE compose stack
# - Removes the committed image tag sharelatex/sharelatex:<version> (if present)
# - Optionally deletes the toolkit folder
#
# Usage:
#   sudo ./overleaf-uninstall-posix.sh         # recommended
#   ./overleaf-uninstall-posix.sh              # may need write perms
#
set -eu

OVERLEAF_DIR="${OVERLEAF_DIR:-$HOME/overleaf-ce}"

if [ ! -d "$OVERLEAF_DIR" ]; then
  echo "Overleaf directory not found: $OVERLEAF_DIR"
  exit 1
fi

cd "$OVERLEAF_DIR"

VERSION=""
if [ -f "config/version" ]; then
  VERSION="$(cat config/version || true)"
fi

IMAGE_TAG=""
if [ -n "$VERSION" ]; then
  IMAGE_TAG="sharelatex/sharelatex:$VERSION"
fi

echo "This will:"
echo "  • Stop and remove Overleaf CE containers"
echo "  • Remove compose volumes for this instance (Mongo/Redis data)"
if [ -n "$IMAGE_TAG" ]; then
  echo "  • Remove the committed image tag ($IMAGE_TAG) if present"
else
  echo "  • Remove the committed image tag (<none>) if present"
fi
echo "  • Optionally delete $OVERLEAF_DIR"
printf "Type DELETE to continue: "
read ANS
if [ "$ANS" != "DELETE" ]; then
  echo "Aborted."
  exit 1
fi

# Bring down the stack (ignore errors if compose wrapper is missing)
if [ -x "./bin/docker-compose" ]; then
  ./bin/docker-compose down -v || true
else
  # Fallback to docker compose if available in PATH
  if command -v docker >/dev/null 2>&1; then
    docker compose down -v || true
  fi
fi

# Remove image tag if present
if [ -n "$IMAGE_TAG" ]; then
  if command -v docker >/dev/null 2>&1; then
    if docker image inspect "$IMAGE_TAG" >/dev/null 2>&1; then
      echo "[+] Removing image $IMAGE_TAG"
      docker rmi "$IMAGE_TAG" || true
    fi
  fi
fi

# Ask about deleting folder
printf "Also delete the toolkit folder %s? (y/N): " "$OVERLEAF_DIR"
read DELDIR
case "$DELDIR" in
  y|Y)
    cd ..
    # try to fix perms if needed
    if command -v chattr >/dev/null 2>&1; then
      chattr -i "$OVERLEAF_DIR" 2>/dev/null || true
      # best-effort remove immutable on contents
      find "$OVERLEAF_DIR" -exec chattr -i {} + 2>/dev/null || true
    fi
    # best-effort make writable
    chmod -R u+rwX "$OVERLEAF_DIR" 2>/dev/null || true
    rm -rf "$OVERLEAF_DIR" || true
    echo "[+] Deleted $OVERLEAF_DIR"
    ;;
  *)
    echo "Skipped deleting $OVERLEAF_DIR"
    ;;
esac

echo "✅ Purge complete."
