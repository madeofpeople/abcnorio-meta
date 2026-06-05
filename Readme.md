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
- `f2b/fail2ban/jail.local` (fail2ban config for host SSH + Caddy-backed WP login protection)
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
   ├──▶ abcwpdev       (WP admin/REST, dev)           │
   └──▶ abcwpstaging   (WP admin/REST, staging)       │
                                                      │
deploy-orchestrator (:4011) ◀── trigger (bearer) ────┘
   │  └── build queue (in-memory, 1 at a time)
   │       ├── astro container: npm run build:site
   │       ├── web/static/prod/client (static prod served by web)
   │       └── web/static/prod/.ssr (prod SSR runtime mounted by astro-prod)
   │
abcwpdev / abcwpstaging
   ├── MariaDB (shared container, separate DBs)
   └── APCu object cache (in-process, per-container)

Host:
   └── fail2ban (systemd) — protects SSH and watches host-mounted Caddy access logs for repeated WP login failures
```

Networks:
- `abcnorio_net_web` (external): 
  - `proxy`, `web`
- `abcnorio_net_internal` (external): 
   - `proxy`, `astro`, `astro-staging`, `deploy-orchestrator`, `abcwpdev`, `abcwpstaging`, `mariadb`
- `abcnorio_net_orchestrator` (internal):
  - `deploy-orchestrator` ↔ `astro`, `astro-staging`

## Plugin Development Model

- Canonical plugin source lives in `/abcnorio-func/`.
- Dev Bedrock symlinks `packages/abcnorio-func` to the canonical host repo, and the dev container mounts that repo at the same absolute path so the plugin resolves identically on host and in container.
- Staging, bump semver, composer update on staging in the bedrock directory.

## Quick Commands

Requires [just](https://github.com/casey/just).

Fresh machine: run `bash install.sh` on a Debian/Ubuntu host with `sudo`. It installs host prerequisites (`git`, `rsync`, `composer`, `nodejs`, `npm`, `just`), bootstraps Bedrock inline, sets up rootless Docker + fail2ban, and copies the sample env files you still need to fill with real values.

Run `just --list` for all recipes.

```sh
just up                              # bring full stack up (detached)
just down                            # bring stack down
just up dev                          # start dev-only services (astro + abcwpdev)
just down dev                        # stop dev-only services
just rebuild [service …]             # rebuild + restart services
just pull                            # pull latest images and restart
just logs [service]                  # tail logs (default: all)

just wp dev cache flush              # WP-CLI in dev
just wp staging plugin list          # WP-CLI in staging
just composer dev update             # composer in dev bedrock
just composer staging update         # composer in staging bedrock

just build preview                   # trigger preview build (staging content)
just build production                # trigger production build
just build preview events            # scoped build (target scope)
just docs                            # build + deploy docs site

just db-to-staging                   # sync DB + media dev → staging
just db-to-dev                       # sync DB + media staging → dev
just media-to-staging                # copy media uploads dev → staging
just media-to-dev                    # copy media uploads staging → dev
just dump-db staging                 # dump staging DB to backups/mariadb/
just db-shell dev                    # open MariaDB shell

just plugin-build                    # build abcnorio-func plugin JS assets
just plugin-test                     # run PHP tests in the plugin

just setup-fail2ban                  # install fail2ban on host + deploy SSH/Caddy jails
```

For user management and composer ops: `bash scripts/wp-admin.sh <function> [args]`
For standalone Bedrock bootstrap fallback: `bash scripts/bedrock-bootstrap.sh`

The proxy already writes JSON access logs into `PROXY_LOG_DIR`, and fail2ban reads those host-side files directly for the `caddy-wp` jail.

`astro-prod` no longer mounts the Astro source tree. Its container image now comes from `abcnorio-astro/prod-ssr/`, which is a small explicit sidecar package with its own `package.json`. On startup it exits until `deploy.sh` stages `web/static/prod/.ssr`; once `/app/server/entry.mjs` and `/app/node_modules` exist, it runs the Astro SSR server directly on port 3033.

Full preview builds also create a `build-archives/abcnorio-astro-production-candidate-*.zip` archive. If production is triggered while the preview fingerprint still matches that candidate, the orchestrator restores the prebuilt production candidate instead of running a second full production build.
