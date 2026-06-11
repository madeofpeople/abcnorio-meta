#!/usr/bin/env bash
# Trigger an Astro build via the deploy orchestrator.
# Usage: scripts/trigger-build.sh <target> [scope]
#   target: production | preview
#   scope:  full (default) | events | <page-slug>
# Requires ASTRO_BUILD_TRIGGER_SECRET in environment or abcnorio-meta/.env

set -euo pipefail

META_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="$META_DIR/.env"

TARGET="${1:?Usage: scripts/trigger-build.sh <staging|production|preview> [scope]}"
SCOPE="${2:-full}"

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
ORCHESTRATOR_CONTAINER="${ORCHESTRATOR_CONTAINER:-deploy-orchestrator}"

docker exec "$ORCHESTRATOR_CONTAINER" curl -sf \
  -X POST "http://localhost:${ORCHESTRATOR_PORT}/trigger" \
  -H "Authorization: Bearer ${ASTRO_BUILD_TRIGGER_SECRET}" \
  -H "Content-Type: application/json" \
  -d "{\"target\":\"${TARGET}\",\"scope\":\"${SCOPE}\",\"source\":\"manual\"}" \
  | cat
echo
