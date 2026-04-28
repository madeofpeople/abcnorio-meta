#!/usr/bin/env bash
# Copy staging WordPress database to dev and rewrite URLs.
# Run from anywhere on the host: bash wp/scripts/copy-staging-db-to-dev.sh
#
# Reads STAGING_DB_*, DEV_DB_* from abcnorio-meta/.env
# Uses mariadb container for dump/import (has mysql client).
# Uses wp_dev container for search-replace (WP-CLI handles serialized PHP).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/../../.env"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "ERROR: .env not found at $ENV_FILE" >&2
  exit 1
fi

# Load only the vars we need without polluting the environment.
get_env() { grep -E "^$1=" "$ENV_FILE" | head -1 | cut -d= -f2- | tr -d "'\""; }

STAGING_DB_NAME=$(get_env STAGING_DB_NAME)
STAGING_DB_USER=$(get_env STAGING_DB_USER)
STAGING_DB_PASSWORD=$(get_env STAGING_DB_PASSWORD)
DEV_DB_NAME=$(get_env DEV_DB_NAME)
DEV_DB_USER=$(get_env DEV_DB_USER)
DEV_DB_PASSWORD=$(get_env DEV_DB_PASSWORD)
STAGING_CMS=$(get_env STAGING_CMS)
DEV_CMS=$(get_env DEV_CMS)
STAGING_FRONTEND_URL=$(get_env STAGING_FRONTEND_URL)
DEV_FRONTEND_URL=$(get_env DEV_FRONTEND_URL)

echo "Dumping staging DB and importing to dev..."
docker exec mariadb \
  mysqldump -u"$STAGING_DB_USER" -p"$STAGING_DB_PASSWORD" "$STAGING_DB_NAME" \
  | docker exec -i mariadb \
    mysql -u"$DEV_DB_USER" -p"$DEV_DB_PASSWORD" "$DEV_DB_NAME"

echo "Rewriting WP CMS URLs ($STAGING_CMS → $DEV_CMS)..."
docker exec wp_dev \
  wp --path=/app/web/wp search-replace \
    "${STAGING_CMS%/}" "${DEV_CMS%/}" \
    --all-tables --allow-root --quiet

echo "Rewriting frontend URLs ($STAGING_FRONTEND_URL → $DEV_FRONTEND_URL)..."
docker exec wp_dev \
  wp --path=/app/web/wp search-replace \
    "${STAGING_FRONTEND_URL%/}" "${DEV_FRONTEND_URL%/}" \
    --all-tables --allow-root --quiet

echo "Done. Dev WordPress now has staging content."
