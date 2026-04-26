# Build and Deployment Strategy April 26

Date: 2026-04-26

## Objective

Settle build/deploy strategy around BullMQ now, while keeping execution primitives simple and understandable.

Principles:
- Simple contracts over inference
- Few moving parts
- Keep shell scripts for execution
- Separate UI concerns from execution concerns
- One authoritative deployment state source

Environment note:
- Production is static-only (no production WordPress instance).
- Production deploys are manual queue triggers only; no save-trigger source exists for production.

## Initial Rollout Assumptions

- Build archives were intentionally reset before rollout.
- No legacy archive migration path is required.
- Strategy should prefer explicit warning/error states over fallback inference.
- Keep first implementation narrow and understandable; avoid optional branches unless required.

## Settled Architecture

### 1) WordPress plugin
Role:
- Trigger actions (manual deploy/build/restore, optional save-triggered request)
- Render deployment UI from canonical status
- Show success/failure notices

Not responsible for:
- Primary filesystem inference for state
- Backup/build discovery from filename assumptions

### 2) Orchestrator (BullMQ-based)
Role:
- Accept trigger requests
- Apply debounce/coalescing rules
- Ensure single active execution
- Run shell scripts
- Persist canonical deployment status

### 3) Shell scripts
Role:
- Build static output
- Create backup archives
- Copy/deploy artifacts

Contract:
- Exit code indicates success/failure
- Provide explicit values for status update inputs (`ARCHIVE_PATH`, `DEPLOY_BUILD_PATH`, `target`)

### 4) Canonical status file
Primary contract:
- `astro/site/build-archives/deployment-status.json`

Write ownership:
- Runtime/orchestrator path only (`astro/site/deploy-orchestrator/index.mjs`)

Read ownership:
- WordPress deployment UI as primary source

## Canonical State Contract

Per environment (`dev`, `staging`, `production`) keep:
- `lastRequestedAt`
- `lastStartedAt`
- `lastFinishedAt`
- `lastStatus` (`idle|running|done|failed`)
- `lastError`
- `currentBuild.path`
- `currentBuild.clientPath`
- `currentBuild.hasBuild`
- `currentBuild.updatedAt`
- `latestBackup` metadata
- `backups[]` recent archive entries

Rule:
- UI reads this model as authoritative source.
- If missing/unreadable, UI should show clear error state and recovery guidance.
- Do not infer primary state from filesystem or filename parsing.

## Queue Model (BullMQ-first)

Queue jobs:
- `build_static` (dev/staging)
- `deploy_production`
- `restore_backup` (optional queued path)

Behavior:
- Debounce save-triggered requests (default 120s)
- Coalesce repeated requests per environment
- No overlapping builds/deploys
- If request arrives mid-run, allow one follow-up run

## Phased Plan and Checklist

## Phase 1: BullMQ foundation now
Goal: Establish queue/orchestrator path as default executin plane.

Checklist:
- [x] Add single `deploy-orchestrator` service using BullMQ + Redis
- [x] Move trigger endpoint handling into orchestrator
- [x] Move status/poll endpoint handling into orchestrator
- [x] Keep shell scripts unchanged as execution primitives
- [x] Keep status contract unchanged while moving status writes into orchestrator runtime
- [x] Add feature flag for WP save-triggered enqueue
- [x] Add WP save-trigger hooks (post save/delete) to enqueue `source=save` when feature flag enabled

Exit criteria:
- Rapid edit bursts coalesce as expected
- No overlapping builds
- Follow-up behavior works when requests arrive during active run

## Phase 2: Status-first UI and strict failure handling
Goal: Make canonical status mandatory for operator visibility.

Checklist:
- [x] Ensure all backup success paths call status updater with `backup` action and env target
- [x] Ensure all deploy success paths call status updater with `deploy` action and env target
- [x] Ensure status writes include explicit `ARCHIVE_PATH` and `DEPLOY_BUILD_PATH` inputs when applicable
- [x] Update WP deployment page to read canonical status only
- [x] If status is missing/unreadable, show blocking warning + troubleshooting steps
- [x] Add minimal status-read schema checks in WP
- [x] Validate dev/staging/production naming consistency in one resolver

Exit criteria:
- Build/backup visibility comes from canonical status only
- Status file faults are explicit and visible to operator

## Phase 3: Harden contracts and operations
Goal: Fully normalize strategy around explicit contracts.

Checklist:
- [x] Remove filename-based backup discovery code paths
- [x] Remove filesystem build-exists inference code paths
- [x] Keep diagnostic checks only (non-authoritative)
- [x] Ensure dev/staging deployment UI logic uses same contract path
- [x] Add lightweight operational runbook for failures/timeouts

Exit criteria:
- One writer + one reader model is enforced
- Deployment UI behavior remains stable across path/env refactors

## Operating Rules

- One writer for deployment state
- UI consumes state, does not derive state
- Scripts execute work, do not own UI semantics
- Queue controls timing and concurrency
- Canonical env keys stay `dev`, `staging`, `production`
- Missing/unreadable status is an error condition, not a fallback condition
- Save-trigger queue envs are single-source in root Compose substitution (`WP_SAVE_TRIGGER_QUEUE_ENABLED`, `WP_SAVE_TRIGGER_TARGET`) and must be passed through to orchestrator + WP containers from one origin.
- Do not model or assume a production WP container/path in deploy flow; production is static artifact publish target only.
- Canonical plugin source path is `wp/dev/bedrock/packages/abcnorio-func`; do not edit mirrored copies in `wp/staging/*` directly.

## Practical Decision Summary

- Keep shell scripts: yes
- Adopt BullMQ: yes
- Start BullMQ-first (single orchestrator service): yes
- Prioritize contract-first state over inference: yes

## Default Decisions (for implementation)

1. Missing/unreadable status should keep page visible, block deployment actions, and show explicit recovery steps.
2. Production is manual-only; save-triggered queueing should be ignored for production.
3. `restore_backup` stays manual/direct in initial rollout (not queued in phase 1).
4. Status write failure marks job failed (strict), even if artifact generation completed.

If any default above should change, update here first, then implement.

## Lightweight Operational Runbook

1. Trigger accepted but no deployment progress
	- Check orchestrator health/logs: `docker compose logs --no-color --tail=120 deploy-orchestrator`
	- Verify queue prerequisites: Redis reachable and `maxmemory-policy=noeviction`
	- Confirm status file path exists and writable (`astro/site/build-archives/deployment-status.json`)

2. Deployment page shows blocking status warning
	- Inspect status file JSON + schema (`envs.dev|staging|production`, `currentBuild.hasBuild`, `backups[]`)
	- Run one manual trigger to repopulate canonical status
	- Refresh deployment page after status write succeeds

3. Job failed in orchestrator
	- Review shell script exit output from orchestrator logs
	- Confirm target build path exists and is mounted in container
	- Confirm backup archive was created and status updater received explicit `ARCHIVE_PATH`/`DEPLOY_BUILD_PATH`

4. Save-trigger not enqueueing
	- Confirm `WP_SAVE_TRIGGER_QUEUE_ENABLED=1` in root env and container recreate done
	- Confirm `ASTRO_BUILD_TRIGGER_URL` and secret alignment between WP + orchestrator
	- Verify save event is not autosave/revision/auto-draft
