#!/usr/bin/env bash
# Dump a WordPress database to backups/mariadb/.
# Usage: scripts/dump-db.sh <dev|staging>
#
# Reads DB credentials from abcnorio-meta/.env
# Uses the mariadb container for the dump.

set -euo pipefail

ENV="${1:?Usage: scripts/dump-db.sh <dev|staging>}"

META_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="$META_DIR/.env"
BACKUP_DIR="$META_DIR/backups/mariadb"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "ERROR: .env not found at $ENV_FILE" >&2
  exit 1
fi

get_env() { grep -E "^$1=" "$ENV_FILE" | head -1 | cut -d= -f2- | tr -d "'\""; }

case "$ENV" in
  dev)
    DB_NAME=$(get_env DEV_DB_NAME)
    DB_USER=$(get_env DEV_DB_USER)
    DB_PASSWORD=$(get_env DEV_DB_PASSWORD)
    ;;
  staging)
    DB_NAME=$(get_env STAGING_DB_NAME)
    DB_USER=$(get_env STAGING_DB_USER)
    DB_PASSWORD=$(get_env STAGING_DB_PASSWORD)
    ;;
  *)
    echo "Unknown env: $ENV (expected dev or staging)" >&2; exit 1 ;;
esac

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
OUT="$BACKUP_DIR/${ENV}-${TIMESTAMP}.sql.gz"

mkdir -p "$BACKUP_DIR"

echo "Dumping $ENV DB ($DB_NAME) to $OUT ..."
docker exec mariadb \
  mariadb-dump -u"$DB_USER" -p"$DB_PASSWORD" \
    --single-transaction --no-tablespaces "$DB_NAME" \
  | gzip > "$OUT"

echo "Done: $OUT ($(du -h "$OUT" | cut -f1))"
