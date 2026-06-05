#!/usr/bin/env bash
# One-off: downscale all upload originals to max 1600px longest side.
# Usage: scripts/downscale-originals.sh <dev|staging>

set -euo pipefail

ENV="${1:?Usage: scripts/downscale-originals.sh <dev|staging>}"

case "$ENV" in
  dev)     CONTAINER=abcwpdev ;;
  staging) CONTAINER=abcwpstaging ;;
  *) echo "Unknown env: $ENV (expected dev or staging)" >&2; exit 1 ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

docker cp "$SCRIPT_DIR/downscale-originals.php" "$CONTAINER":/tmp/downscale-originals.php
docker exec "$CONTAINER" wp --allow-root --path=/app/web/wp eval-file /tmp/downscale-originals.php
docker exec "$CONTAINER" rm /tmp/downscale-originals.php
