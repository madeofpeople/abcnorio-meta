#!/usr/bin/env bash
# Copy staging media and database to dev.
# Copies media first (rsync), then imports DB and rewrites URLs.
# Run from anywhere on the host: bash wp/scripts/copy-staging-db-and-media-to-dev.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=== Step 1/2: Media ==="
bash "$SCRIPT_DIR/copy-staging-media-to-dev.sh"

echo ""
echo "=== Step 2/2: Database ==="
bash "$SCRIPT_DIR/copy-staging-db-to-dev.sh"

echo ""
echo "Done. Dev has staging media and database."
