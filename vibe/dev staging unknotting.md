# Dev/Staging Unknotting

Date: 2026-04-24

## Goal
Untangle copied/stale staging wiring from dev setup, make both environments runnable side-by-side, and keep DB provisioning minimal.

## What We Fixed
- Corrected swapped env mappings in root [.env](.env):
  - `DEV_HOST_ROOT` and `STAGING_HOST_ROOT`
  - `DEV_DB_NAME` and `STAGING_DB_NAME`
- Updated container naming drift in [compose.yml](compose.yml):
  - staging service uses `wp_staging`
  - dev service uses `wp_dev`
- Split WP service host ports in [compose.yml](compose.yml) to avoid collisions:
  - staging `8100:80`
  - dev `8101:80`
- Set dev WP runtime mode in [compose.yml](compose.yml):
  - `WP_ENV=development`
- Verified proxy upstream alignment to current container names in [proxy/Caddyfile](proxy/Caddyfile).
- Replaced stale `frank` references in dev helper scripts under [wp/dev/scripts](wp/dev/scripts).

## DB Provisioning Direction
- Initial intermediate approach used a separate provisioning script/service.
- Final approach is more parsimonious:
  - Use MariaDB init hook mount in [compose.yml](compose.yml)
  - Active script: [wp/sql/001-dev-staging-dbs.sh](wp/sql/001-dev-staging-dbs.sh)
- Script behavior:
  - idempotently ensures both DBs exist
  - ensures users/passwords are set
  - grants privileges for both dev and staging DBs

## Current Wiring (Active)
- [compose.yml](compose.yml) mounts:
  - `/home/madeofpeople/abcnorio.org/wp/sql/001-dev-staging-dbs.sh:/docker-entrypoint-initdb.d/001-dev-staging-dbs.sh:ro`
- No active `db_provision` service remains.
- `mariadb` receives both `DEV_DB_*` and `STAGING_DB_*` env vars.

## Runtime Validation Completed
- Stack recreated with orphan cleanup (`--remove-orphans`) after old container conflicts.
- Verified both DBs exist:
  - `abcnorio_wp_staging`
  - `abcnorio_wp_dev`
- Verified grants for `noriodb` on both schemas.

## Known Caveat
- MariaDB init scripts in `docker-entrypoint-initdb.d` run automatically only on first initialization of a fresh DB volume.
- For already-initialized volumes, script must be run once manually (already done this session).

## Open Cleanup
- Removed unused `scripts/db/provision-mariadb.sh` after confirming no active compose wiring.

## Naming Follow-Up
- Renamed active script to `001-dev-staging-dbs.sh` for clearer intent.
- Updated mount path in [compose.yml](compose.yml).
