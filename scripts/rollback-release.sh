#!/usr/bin/env bash
set -euo pipefail

META_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="$META_DIR/.env"

TARGET="${1:?Usage: scripts/rollback-release.sh <target> [release_id]}"
RELEASE_ID="${2:-}"

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

payload="{\"target\":\"${TARGET}\"}"
if [[ -n "$RELEASE_ID" ]]; then
  payload="{\"target\":\"${TARGET}\",\"release_id\":\"${RELEASE_ID}\"}"
fi

response="$(docker exec "$ORCHESTRATOR_CONTAINER" curl -sf \
  -X POST "http://localhost:${ORCHESTRATOR_PORT}/rollback" \
  -H "Authorization: Bearer ${ASTRO_BUILD_TRIGGER_SECRET}" \
  -H "Content-Type: application/json" \
  -d "$payload")"

printf '%s\n' "$response"
