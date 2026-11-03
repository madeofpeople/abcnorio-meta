#!/usr/bin/env bash
# Local stack smoke test: reports every failing check in one pass. Run after `just up dev`.
set -uo pipefail

META_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$META_DIR"
set -a; source .env; set +a

failed=0
check() {
    local name="$1"; shift
    if "$@" >/dev/null 2>&1; then echo "ok    $name"; else echo "FAIL  $name"; failed=1; fi
}

http_ok() { [ "$(curl -s -m 60 -o /dev/null -w '%{http_code}' "$1")" = "200" ]; }
running() { [ "$(docker inspect -f '{{.State.Health.Status}}' "$1" 2>/dev/null)" = "healthy" ]; }

check "mariadb healthy" running mariadb
check "abcwpdev healthy" running abcwpdev
check "astro-dev healthy" running astro-dev
check "db login as DEV_DB_USER" docker exec mariadb mariadb -u"$DEV_DB_USER" -p"$DEV_DB_PASSWORD" "$DEV_DB_NAME" -e "select 1"
check "WP REST on host port $DEV_WP_PORT" http_ok "http://localhost:$DEV_WP_PORT/wp-json/"
check "astro-dev reaches WP from inside Docker" docker exec astro-dev wget -qO- http://abcwpdev/wp-json/
check "Astro home page on host port $DEV_ASTRO_PORT" http_ok "http://localhost:$DEV_ASTRO_PORT/"

exit $failed
