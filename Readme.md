## Repository Strategy

This repository is the meta repo.

It owns:
- `compose.yml`
- shared directory layout and mounts
- environment wiring
- WordPress environment directories (`wp/dev`, `wp/staging`)
- runtime orchestration between services

It does **not** own source history for application components.

## Current Directory Structure

Umbrella root (`~/abcnorio.org`):
- `abcnorio-meta/` (this repo)
- `abcnorio-astro/` (Astro frontend repo)
- `abcnorio-orchestrator/` (deploy orchestrator repo)
- `abcnorio-func/` (WordPress plugin source repo)
- `.notes/` (root-level operational notes)
- `.vscode/` (root-level workspace/editor settings)

Inside meta repo (`~/abcnorio.org/abcnorio-meta`):
- `wp/dev/` (Bedrock dev environment)
- `wp/staging/` (Bedrock staging environment)
- `wp/runtime.env`, `wp/dev.env`, `wp/staging.env`
- `scripts/` (admin shell scripts)
- `justfile` (task runner — run `just --list` for all recipes)

## Runtime Topology

Core services:
- `proxy` (public edge)
- `web` (static Caddy)
- `astro` (Astro app)
- `astro-staging` (staging Astro app)
- `docs` (Starlight docs)
- `deploy-orchestrator` (build queue worker/API)
- `wp_dev` / `wp_staging` (WordPress/FrankenPHP)
- `mariadb`

Network policy:
- `abcnorio_net_web` (external): only `proxy`, `web`
- `abcnorio_net_internal` (external): app/backend services (`astro`, `astro-staging`, `deploy-orchestrator`, `wp_dev`, `wp_staging`, `mariadb`) plus `proxy`
- `abcnorio_net_orchestrator` (internal): `deploy-orchestrator` ↔ `astro`, `astro-staging`

## Plugin Development Model

- Canonical plugin source lives in `../abcnorio-func/`.
- Dev WordPress live-mounts plugin source to `/app/packages/abcnorio-func`.
- Bedrock package wiring stays path-based in dev for fast iteration.

## Workflow Conventions

1. Work on Astro in `../abcnorio-astro/`.
2. Work on orchestrator in `../abcnorio-orchestrator/`.
3. Work on plugin source in `../abcnorio-func/`.
4. Work on infra wiring (compose/env/mounts/wp env dirs) in this repo.
5. Commit by repo boundary: component commits in component repos, infra commits here.

## Quick Commands

Requires [just](https://github.com/casey/just). Run `just --list` for all recipes.

```sh
just up                        # bring stack up
just down                      # bring stack down
just rebuild <service>         # rebuild + restart a service
just logs [service]            # tail logs

just wp-dev cache flush        # WP-CLI in dev
just wp-staging plugin list    # WP-CLI in staging

just build-staging             # trigger staging build
just build-production          # trigger production build

just db-to-staging             # sync DB+media dev → staging
just db-to-dev                 # sync DB+media staging → dev
just dump-db staging           # dump staging DB to backups/mariadb/

just db-shell dev              # open MariaDB shell
```

For user management and composer ops: `bash scripts/wp-admin.sh <function> [args]`
For initial bedrock setup: `bash scripts/bootstrap.sh`
