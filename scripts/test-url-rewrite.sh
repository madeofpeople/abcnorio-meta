#!/usr/bin/env bash
# Integration test for URL normalization against a throwaway copy of a staging dump.
# Never touches the live DBs. Usage: scripts/test-url-rewrite.sh [dump.sql]
# Env vars: TARGET=dev|staging (env the dump is loaded into, default dev; source dump is the other env)
# Default dump: newest build/astro/build-archives/database/abcnorio-database-<source>-*.sql

set -euo pipefail

META_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$META_DIR"

set -a; source .env; set +a

TARGET="${TARGET:-dev}"
if [ "$TARGET" = "dev" ]; then
  SOURCE=staging; OTHER_WP="$DOMAIN_WP_STAGING"; OWN_FRONTEND="$DOMAIN_DEV"
else
  SOURCE=dev; OTHER_WP="$DOMAIN_WP_DEV"; OWN_FRONTEND="$DOMAIN_STAGING"
fi
DUMP="${1:-$(ls -t build/astro/build-archives/database/abcnorio-database-$SOURCE-*.sql | head -1)}"
# Older dumps predate the prefix migration; use the dump's own prefix
DB_PREFIX="$(grep -m1 -o 'CREATE TABLE `[A-Za-z0-9_]*posts`' "$DUMP" | sed 's/CREATE TABLE `//; s/posts`//')"
TMP_DB="abcwp_urltest_$$"
export MYSQL_PWD="$DB_ROOT_PASSWORD"
PASS=0; FAIL=0

mysql_root() { docker exec -i -e MYSQL_PWD mariadb mariadb -uroot "$@"; }
cleanup() { mysql_root -e "DROP DATABASE IF EXISTS \`$TMP_DB\`" >/dev/null 2>&1 || true; }
trap cleanup EXIT

ok()   { echo "ok    $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL  $1"; FAIL=$((FAIL+1)); }

# Run WP-CLI as dev (own host = DEV_WP_URL) against the temp DB. Extra args: -e KEY=VAL overrides first.
wp_test() {
  docker compose --profile dev run --rm --no-deps -T -v "$ABCNORIO_FUNC_HOST_DIR:/app/web/app/plugins/abcnorio-func" \
    -e DB_PREFIX="$DB_PREFIX" -e DB_NAME="$TMP_DB" -e DB_USER=root -e DB_PASSWORD="$DB_ROOT_PASSWORD" \
    "${OVERRIDES[@]}" \
    abcwp$TARGET wp --allow-root --path=/app/web/wp abcnorio normalize-urls "$@" 2>&1
}
OVERRIDES=()

count_foreign() {
  # '/host' matches plain '//host' and JSON-escaped '\/\/host'; the '/' prefix keeps 'abcwpdev' from matching 'dev.'
  local cond=""
  for h in "$OTHER_WP" "$DOMAIN_DEV" "$DOMAIN_STAGING" "$DOMAIN_PREVIEW" "$DOMAIN_PRODUCTION"; do
    cond="$cond OR @c LIKE '%/$h%'"
  done
  mysql_root -N "$TMP_DB" -e "SELECT
    (SELECT COUNT(*) FROM ${DB_PREFIX}posts WHERE 0 ${cond//@c/post_content})
  + (SELECT COUNT(*) FROM ${DB_PREFIX}postmeta WHERE 0 ${cond//@c/meta_value})"
}
count_rows() {
  # options excluded: WP-CLI boot writes transients/cron
  mysql_root -N "$TMP_DB" -e "SELECT (SELECT COUNT(*) FROM ${DB_PREFIX}posts),(SELECT COUNT(*) FROM ${DB_PREFIX}postmeta),(SELECT COUNT(*) FROM ${DB_PREFIX}termmeta)"
}

echo "Dump: $DUMP"
mysql_root -e "CREATE DATABASE \`$TMP_DB\`"
mysql_root "$TMP_DB" < "$DUMP"
ROWS_BEFORE="$(count_rows)"
FOREIGN_BEFORE="$(count_foreign)"
echo "Rows before: $ROWS_BEFORE; rows with staging-origin hosts (own host is $TARGET): $FOREIGN_BEFORE"

# 1. Guards refuse to run
OVERRIDES=(-e DEV_WP_URL= -e STAGING_WP_URL=)
if guard_out="$(wp_test --apply || true)"; echo "$guard_out" | grep -q "Error:"; then ok "guard: empty WP host list refused"; else fail "guard: empty WP host list refused"; fi
OVERRIDES=(-e "WP_HOME=https://${OWN_FRONTEND}")
if guard_out="$(wp_test --apply || true)"; echo "$guard_out" | grep -q "Error:"; then ok "guard: own host that is a frontend host refused"; else fail "guard: own host that is a frontend host refused"; fi
OVERRIDES=(-e WP_HOME=https://unlisted.example.org)
if guard_out="$(wp_test --apply || true)"; echo "$guard_out" | grep -q "Error:"; then ok "guard: own host not in host list refused"; else fail "guard: own host not in host list refused"; fi
OVERRIDES=()
[ "$(count_foreign)" = "$FOREIGN_BEFORE" ] && ok "guards left data untouched" || fail "guards left data untouched"

# 2. Dry run changes nothing
OUT="$(wp_test || true)"; echo "$OUT" | tail -8
echo "$OUT" | grep -q "Dry run" && ok "dry run reports" || fail "dry run reports"
[ "$(count_foreign)" = "$FOREIGN_BEFORE" ] && ok "dry run wrote nothing" || fail "dry run wrote nothing"

# 3. Apply
OUT="$(wp_test --apply || true)"; echo "$OUT" | tail -8
echo "$OUT" | grep -q "Applied" && ok "apply succeeds" || fail "apply succeeds"
[ "$(count_foreign)" = "0" ] && ok "no foreign hosts remain" || fail "no foreign hosts remain ($(count_foreign))"
ROWS_AFTER="$(count_rows)"
[ "$ROWS_AFTER" = "$ROWS_BEFORE" ] && ok "row counts unchanged" || fail "row counts unchanged ($ROWS_BEFORE -> $ROWS_AFTER)"

# 4. Idempotent
OUT="$(wp_test || true)"
echo "$OUT" | grep -q "0 rows would change" && ok "second run is a no-op" || fail "second run is a no-op"

echo; echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
