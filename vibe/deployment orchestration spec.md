# Deployment Orchestration Spec

Date: 2026-04-26

## Purpose

Define a single orchestration service for deployment and queued build concerns.

Scope owned by `deploy-orchestrator`:
- Queueing and debounce/coalescing
- Serialized execution of deploy jobs
- Trigger and status API endpoints
- Canonical deployment state writes

Scope not owned by Astro frontend runtime:
- Trigger endpoint handling
- Queue semantics
- Deployment state ownership

## Runtime Topology

Services and responsibilities:
- `astro`: frontend build/dev runtime only
- `deploy-orchestrator`: queue + trigger API + worker execution
- `redis`: queue backend
- `cms_dev` / `cms_staging`: trigger callers and status readers via plugin UI

Current endpoint contract:
- `POST /trigger`
- `GET /status`
- `GET /health`

Auth:
- Bearer token with `ASTRO_BUILD_TRIGGER_SECRET`

## Execution Contract

Queue job target keys:
- `dev`
- `staging`
- `production`

Script execution (from Astro site workspace mount):
- `deploy-to-dev.sh`
- `deploy-to-staging.sh`
- `deploy-to-production.sh`

Rules:
- No overlapping runs
- Save-triggered requests are debounced
- If request arrives while same target active, queue one follow-up

## Canonical State Contract

Status file path:
- `astro/site/build-archives/deployment-status.json`

State model per env (`dev`, `staging`, `production`):
- `lastRequestedAt`
- `lastStartedAt`
- `lastFinishedAt`
- `lastStatus`
- `lastError`
- `currentBuild.path`
- `currentBuild.clientPath`
- `currentBuild.hasBuild`
- `currentBuild.updatedAt`
- `latestBackup`
- `backups[]`

Ownership:
- Writer: `deploy-orchestrator` only
- Reader: WordPress deployment UI

## Configuration

Required/used env vars:
- `ASTRO_BUILD_TRIGGER_SECRET`
- `REDIS_URL`
- `BUILD_QUEUE_NAME`
- `BUILD_DEBOUNCE_SECONDS`
- `ORCHESTRATOR_PORT`
- `WP_SAVE_TRIGGER_QUEUE_ENABLED`
- `DEV_BUILD_PATH`
- `STAGING_BUILD_PATH`
- `PRODUCTION_BUILD_PATH`
- Optional: `ASTRO_SITE_ROOT`
- Optional: `ASTRO_DEPLOYMENT_STATUS_FILE`

## Architecture

Module structure (`deploy-orchestrator/`):
- `index.mjs` (~130 lines): core orchestration, HTTP routes, worker startup
- `status.mjs` (~165 lines): status file operations, env state tracking
- `files.mjs` (~60 lines): archive discovery, command execution, path validation
- `http.mjs` (~30 lines): request auth, body parsing utilities
- `package.json`: dependencies (bullmq, ioredis)
- `Dockerfile`: Node.js LTS environment

## Operations

Health checks:
1. `docker compose logs --tail=120 deploy-orchestrator`
2. `GET /health` with bearer auth
3. Verify status file exists and updates timestamps

Failure checks:
1. Shell script exit output in orchestrator logs
2. Build target path exists in container
3. Status JSON remains valid schema

## Working Plan (Living)

- [x] Move orchestrator runtime into top-level `deploy-orchestrator/`
- [x] Rewire compose service command and volume mounts to new folder
- [x] Remove legacy `astro/site/deploy-orchestrator/` runtime file
- [x] Recreate `deploy-orchestrator` container
- [x] Verify status file auto-creation on startup
- [x] Verify `POST /trigger` and `GET /status` end-to-end from container network
- [x] Verify WP deployment page unblocked
- [x] Fix BullMQ jobId format constraint (colon → hyphen)
- [x] Modularize index.mjs → status/files/http utilities
- [ ] Implement shell scripts for deploy targets (dev/staging/production)
- [ ] Wire queue job processor to execute actual deployments

## Change Log

- 2026-04-26: Initial spec created as living orchestration contract and migration tracker.
- 2026-04-26: Modularized runtime into status/files/http utilities. Verified orchestrator responsive.
