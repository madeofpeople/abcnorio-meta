#!/usr/bin/env bash
# Copy staging WordPress media uploads to dev (rsync, only changed files).
# Run from anywhere on the host: bash wp/scripts/copy-staging-media-to-dev.sh
#
# Reads STAGING_HOST_ROOT and DEV_HOST_ROOT from abcnorio-meta/.env

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/../../.env"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "ERROR: .env not found at $ENV_FILE" >&2
  exit 1
fi

get_env() { grep -E "^$1=" "$ENV_FILE" | head -1 | cut -d= -f2- | tr -d "'\""; }

STAGING_HOST_ROOT=$(get_env STAGING_HOST_ROOT)
DEV_HOST_ROOT=$(get_env DEV_HOST_ROOT)

STAGING_UPLOADS="${STAGING_HOST_ROOT%/}/bedrock/web/app/uploads/"
DEV_UPLOADS="${DEV_HOST_ROOT%/}/bedrock/web/app/uploads/"

if [[ ! -d "$STAGING_UPLOADS" ]]; then
  echo "ERROR: staging uploads dir not found: $STAGING_UPLOADS" >&2
  exit 1
fi

echo "Rsyncing media: staging → dev..."
rsync -a --delete "$STAGING_UPLOADS" "$DEV_UPLOADS"

echo "Done. Dev media now mirrors staging."
