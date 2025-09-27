#!/usr/bin/env bash
# overleaf_stop.sh
set -euo pipefail
OVERLEAF_DIR="${OVERLEAF_DIR:-$HOME/overleaf-ce}"
cd "$OVERLEAF_DIR"
# Stop all services for this instance (mongo, redis, sharelatex, etc.)
./bin/docker-compose stop
echo "Overleaf CE stopped."

