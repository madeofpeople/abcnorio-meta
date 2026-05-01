#!/usr/bin/env bash
# Dump staging WordPress database to backups/mariadb/.
# Run from anywhere on the host: bash wp/scripts/dump-staging-db.sh
#
# Reads STAGING_DB_* from abcnorio-meta/.env
# Uses mariadb container for the dump.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/../../.env"
BACKUP_DIR="$SCRIPT_DIR/../../backups/mariadb"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "ERROR: .env not found at $ENV_FILE" >&2
  exit 1
fi

get_env() { grep -E "^$1=" "$ENV_FILE" | head -1 | cut -d= -f2- | tr -d "'\""; }

STAGING_DB_NAME=$(get_env STAGING_DB_NAME)
STAGING_DB_USER=$(get_env STAGING_DB_USER)
STAGING_DB_PASSWORD=$(get_env STAGING_DB_PASSWORD)

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
OUT="$BACKUP_DIR/staging-${TIMESTAMP}.sql.gz"

mkdir -p "$BACKUP_DIR"

echo "Dumping staging DB ($STAGING_DB_NAME) to $OUT ..."
docker exec mariadb \
  mariadb-dump -u"$STAGING_DB_USER" -p"$STAGING_DB_PASSWORD" \
    --single-transaction --no-tablespaces "$STAGING_DB_NAME" \
  | gzip > "$OUT"

echo "Done: $OUT ($(du -h "$OUT" | cut -f1))"
