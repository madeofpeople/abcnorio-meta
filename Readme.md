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

Inside meta repo (`~/abcnorio.org/abcnorio-meta`):
- `wp/dev/` (Bedrock dev environment)
- `wp/staging/` (Bedrock staging environment)
- `wp/runtime.env`, `wp/dev.env`, `wp/staging.env`

## Runtime Topology

Core services:
- `proxy` (public edge)
- `web` (static Caddy)
- `astro` (Astro app)
- `deploy-orchestrator` (build queue worker/API)
- `cms_dev` / `cms_staging` (WordPress)
- `mariadb`
- `redis`

Network policy:
- `abcnorio_net_web` (external): only `proxy`, `web`
- `abcnorio_net_internal` (external): app/backend services (`astro`, `deploy-orchestrator`, `cms_dev`, `cms_staging`, `mariadb`, `redis`) plus `proxy`

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

Bring stack up:
- `docker compose up -d`

Rebuild/restart selected services:
- `docker compose up -d --build deploy-orchestrator cms_dev cms_staging`

Trigger orchestrated build:
- `docker exec deploy-orchestrator sh -lc "curl -s -X POST http://localhost:4011/trigger -H 'Authorization: Bearer $ASTRO_BUILD_TRIGGER_SECRET' -H 'Content-Type: application/json' -d '{\"target\":\"staging\",\"source\":\"manual\"}'"`
