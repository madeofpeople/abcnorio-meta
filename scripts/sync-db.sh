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
  dev-to-staging)
    ENDPOINT="/dev-tools/pull-from-dev"
    STATUS_KEY="pullDBFromDevToStaging"
    WP_CONTAINER="abcwpstaging"
    ;;
  staging-to-dev)
    ENDPOINT="/dev-tools/pull-from-staging"
    STATUS_KEY="pullFromStagingToDev"
    WP_CONTAINER="abcwpdev"
    ;;
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
echo "Note: this command validates data/media sync only. It does not validate frontend deployment state."
curl -sf \
  -X POST "http://localhost:${ORCHESTRATOR_PORT}${ENDPOINT}" \
  -H "Authorization: Bearer ${ASTRO_BUILD_TRIGGER_SECRET}" \
  | cat
echo

echo "Waiting for dev-tools operation: ${STATUS_KEY}"
deadline=$((SECONDS + 600))

while (( SECONDS < deadline )); do
  status_json="$(curl -sf \
    -H "Authorization: Bearer ${ASTRO_BUILD_TRIGGER_SECRET}" \
    "http://localhost:${ORCHESTRATOR_PORT}/dev-tools/status")"

  op_status="$(printf '%s' "$status_json" | tr -d '\n' | sed -n "s/.*\"${STATUS_KEY}\":{\"status\":\"\([^\"]*\)\".*/\1/p")"

  case "$op_status" in
    done)
      echo "Sync completed (data/media scope only)."
      break
      ;;
    failed)
      echo "Sync failed for ${STATUS_KEY}." >&2
      echo "$status_json" >&2
      exit 1
      ;;
    running|idle|"")
      :
      ;;
    *)
      echo "Unexpected status for ${STATUS_KEY}: ${op_status}" >&2
      echo "$status_json" >&2
      exit 1
      ;;
  esac
done

if (( SECONDS >= deadline )); then
  echo "Timed out waiting for ${STATUS_KEY} to complete." >&2
  exit 1
fi

echo "Resetting WP runtime cache in ${WP_CONTAINER} (no container restart)..."
docker exec "${WP_CONTAINER}" sh -lc '
  wp --allow-root --path=/app/web/wp cache flush >/dev/null
  wp --allow-root --path=/app/web/wp transient delete --all >/dev/null || true
  curl -sf -X POST http://127.0.0.1:2019/frankenphp/workers/restart >/dev/null
'
echo "Cache reset complete (object cache flushed, transients purge requested, workers refreshed)."
