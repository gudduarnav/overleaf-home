#!/usr/bin/env bash
# overleaf_start.sh
set -euo pipefail
OVERLEAF_DIR="${OVERLEAF_DIR:-$HOME/overleaf-ce}"
cd "$OVERLEAF_DIR"
./bin/up -d
echo "Overleaf CE started (detached)."

