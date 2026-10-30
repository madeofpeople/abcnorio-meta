#!/usr/bin/env bash
# Sync database between dev and staging environments.
# Usage: scripts/sync-db.sh <direction>
#   direction: dev-to-staging | staging-to-dev
# Runs via the orchestrator's dev-tools endpoint.

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib/orchestrator.sh"

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

orchestrator_init

echo "Note: this command validates data/media sync only. It does not validate frontend deployment state."
run_dev_tool "$ENDPOINT" "$STATUS_KEY" "Sync DB ($DIRECTION, also syncs media uploads)"

echo "Resetting WP runtime cache in ${WP_CONTAINER} (no container restart)..."
docker exec "${WP_CONTAINER}" sh -lc '
  wp --allow-root --path=/app/web/wp cache flush >/dev/null
  wp --allow-root --path=/app/web/wp transient delete --all >/dev/null || true
  curl -sf -X POST http://127.0.0.1:2019/frankenphp/workers/restart >/dev/null
'
echo "Cache reset complete (object cache flushed, transients purge requested, workers refreshed)."
