## Repository Strategy

This repository is the meta repo.

It owns:
- `compose.yml`
- shared directory layout and mounts
- environment wiring
- WordPress directories (`wp/dev`, `wp/staging`)
- runtime orchestration between services

It does **not** own source history for application components.

## Current Directory Structure

Umbrella root (`~/abcnorio.org`):
- `abcnorio-meta/` (this repo)
- `abcnorio-astro/` (Astro frontend)
- `abcnorio-orchestrator/` (deploy orchestrator)
- `abcnorio-func/` (WordPress plugin)

Inside abcnorio-meta:
- `wp/dev/` (Bedrock based wp dev environment)
- `wp/staging/` (Bedrock based wp staging environment)
- `wp/runtime.env`, `wp/dev.env`, `wp/staging.env`
- `scripts/` (admin shell scripts)
- `f2b/fail2ban/jail.local` (fail2ban config — deployed to host by `just setup-fail2ban`)
- `justfile` (task runner — run `just --list` for all recipes)

## Runtime Topology

```
Internet
   │
   ▼
 proxy  ──────────────────────────────────────────────┐
(Caddy)                                               │
   │                                                  │
   ├──▶ astro          (SSR dev,     :3033)           │
   ├──▶ astro-staging  (SSR staging, :3034)           │
   ├──▶ web            (static prod/preview/docs)     │
   ├──▶ wp_dev         (WP admin/REST, dev)           │
   └──▶ wp_staging     (WP admin/REST, staging)       │
                                                      │
deploy-orchestrator (:4011) ◀── trigger (bearer) ────┘
   │  └── build queue (in-memory, 1 at a time)
   │       ├── astro container: npm run build:site
   │       └── web/static/ (bind mount, served by web)
   │
wp_dev / wp_staging
   ├── MariaDB (shared container, separate DBs)
   └── APCu object cache (in-process, per-container)

Host:
   └── fail2ban (systemd) — reads Caddy access logs from PROXY_LOG_DIR bind mount
```

Networks:
- `abcnorio_net_web` (external): 
  - `proxy`, `web`
- `abcnorio_net_internal` (external): 
  - `proxy`, `astro`, `astro-staging`, `deploy-orchestrator`, `wp_dev`, `wp_staging`, `mariadb`
- `abcnorio_net_orchestrator` (internal):
  - `deploy-orchestrator` ↔ `astro`, `astro-staging`

## Plugin Development Model

- Canonical plugin source lives in `/abcnorio-func/`.
- Dev WordPress live-mounts plugin source to `/app/packages/abcnorio-func`, hot loads changes.
- Staging, bump semver, composer update on staging in the bedrock directory.

## Quick Commands

Requires [just](https://github.com/casey/just).

Run `just --list` for all recipes.

```sh
just up                              # bring full stack up (detached)
just down                            # bring stack down
just dev-up                          # start dev-only services (astro + wp_dev)
just dev-down                        # stop dev-only services (~734 MiB reclaimed)
just rebuild [service …]             # rebuild + restart services
just pull                            # pull latest images and restart
just logs [service]                  # tail logs (default: all)

just wp-dev cache flush              # WP-CLI in dev
just wp-staging plugin list          # WP-CLI in staging
just composer dev update             # composer in dev bedrock
just composer staging update         # composer in staging bedrock

just build-preview                   # trigger preview build (staging content)
just build-production                # trigger production build
just build-scoped preview events     # scoped build (target scope)
just docs                            # build + deploy docs site

just db-to-staging                   # sync DB + media dev → staging
just db-to-dev                       # sync DB + media staging → dev
just media-to-staging                # copy media uploads dev → staging
just media-to-dev                    # copy media uploads staging → dev
just dump-db staging                 # dump staging DB to backups/mariadb/
just db-shell dev                    # open MariaDB shell

just plugin-build                    # build abcnorio-func plugin JS assets
just plugin-test                     # run PHP tests in the plugin

just setup-fail2ban                  # install fail2ban on host + deploy jail.local
```

For user management and composer ops: `bash scripts/wp-admin.sh <function> [args]`
For initial bedrock setup: `bash scripts/bootstrap.sh`
