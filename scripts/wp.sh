#!/usr/bin/env bash
# Run a WP-CLI command inside a running WP container.
# Usage: scripts/wp.sh <env> [wp-cli args...]
#   env: dev | staging
# Example: scripts/wp.sh dev cache flush
#          scripts/wp.sh staging plugin list

set -euo pipefail

ENV="${1:?Usage: scripts/wp.sh <dev|staging> [wp-cli args...]}"
shift

case "$ENV" in
  dev)     CONTAINER=cms_dev ;;
  staging) CONTAINER=cms_staging ;;
  *) echo "Unknown env: $ENV (expected dev or staging)" >&2; exit 1 ;;
esac

docker exec "$CONTAINER" wp --allow-root --path=/app/web/wp "$@"
