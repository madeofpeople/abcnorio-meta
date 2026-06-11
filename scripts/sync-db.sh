#!/usr/bin/env bash
# Sync database between dev and staging environments.
# Usage: scripts/sync-db.sh <direction>
#   direction: dev-to-staging | staging-to-dev
# Runs via the orchestrator's dev-tools endpoint.

set -euo pipefail

META_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="$META_DIR/.env"

DIRECTION="${1:?Usage: scripts/sync-db.sh <dev-to-staging|staging-to-dev>}"

case "$DIRECTION" in
  dev-to-staging) ENDPOINT="/dev-tools/pull-from-dev" ;;
  staging-to-dev) ENDPOINT="/dev-tools/pull-from-staging" ;;
  *) echo "Unknown direction: $DIRECTION (expected dev-to-staging or staging-to-dev)" >&2; exit 1 ;;
esac

if [[ -z "${ASTRO_BUILD_TRIGGER_SECRET:-}" ]]; then
  if [[ ! -f "$ENV_FILE" ]]; then
    echo "ERROR: Missing required env file: $ENV_FILE" >&2
    exit 1
  fi
  # shellcheck source=/dev/null
  source "$ENV_FILE"
fi

: "${ASTRO_BUILD_TRIGGER_SECRET:?ASTRO_BUILD_TRIGGER_SECRET not set}"

ORCHESTRATOR_PORT="${ORCHESTRATOR_PORT:-4011}"

echo "Syncing DB: $DIRECTION (also syncs media uploads)..."
curl -sf \
  -X POST "http://localhost:${ORCHESTRATOR_PORT}${ENDPOINT}" \
  -H "Authorization: Bearer ${ASTRO_BUILD_TRIGGER_SECRET}" \
  | cat
echo
