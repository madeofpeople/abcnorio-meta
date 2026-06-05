#!/usr/bin/env bash
# Copy media uploads between dev and staging environments.
# Usage: scripts/copy-media.sh <direction>
#   direction: dev-to-staging | staging-to-dev
# Runs via the orchestrator's dev-tools endpoint (no direct container access needed).

set -euo pipefail

DIRECTION="${1:?Usage: scripts/copy-media.sh <dev-to-staging|staging-to-dev>}"

case "$DIRECTION" in
  dev-to-staging) ENDPOINT="/dev-tools/copy-media-to-staging" ;;
  staging-to-dev) ENDPOINT="/dev-tools/copy-media-to-dev" ;;
  *) echo "Unknown direction: $DIRECTION (expected dev-to-staging or staging-to-dev)" >&2; exit 1 ;;
esac

# Load secret from abcnorio-meta/.env if not already set
if [[ -z "${ASTRO_BUILD_TRIGGER_SECRET:-}" ]]; then
  META_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  ENV_FILE="$META_DIR/.env"
  if [[ -f "$ENV_FILE" ]]; then
    ASTRO_BUILD_TRIGGER_SECRET="$(grep '^ASTRO_BUILD_TRIGGER_SECRET=' "$ENV_FILE" | cut -d= -f2- | tr -d "'\"")"
  fi
fi

: "${ASTRO_BUILD_TRIGGER_SECRET:?ASTRO_BUILD_TRIGGER_SECRET not set}"

ORCHESTRATOR_PORT="${ORCHESTRATOR_PORT:-4011}"

curl -sf \
  -X POST "http://localhost:${ORCHESTRATOR_PORT}${ENDPOINT}" \
  -H "Authorization: Bearer ${ASTRO_BUILD_TRIGGER_SECRET}" \
  | cat
echo
