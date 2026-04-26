# Normalize Deployment Strategy

Date: 2026-04-26

## Goal

Settle deployment flow into simple contracts with minimal inference, while staying compatible with planned BullMQ queueing.

Design priorities:
- Parsimonious components
- Clear ownership boundaries
- Contract-first state updates
- Keep shell scripts where practical

---

## Current pain (why regressions happen)

Regressions are mostly state-model issues, not build issues:
- UI infers build availability from filesystem scans.
- UI infers backup history from filename patterns.
- Multiple layers compute same state (PHP, JS, shell, env).
- Dev/staging code paths drift.

Result: visibility flips when any path/env/naming assumption changes.

---

## Settled model (target)

Use one canonical deployment status record, written by deployment runtime, read by WordPress UI.

### Canonical status file
- Path: `astro/site/build-archives/deployment-status.json`
- Writer: deployment runtime only (orchestrator / status updater)
- Reader: WordPress plugin UI
- WordPress should not derive primary state by scanning paths or parsing zip names.

### Existing status updater
- `astro/site/update-deployment-status.mjs` already establishes this pattern.
- Keep this file and make it the only place that mutates status JSON.

---

## Component boundaries

### 1) WordPress plugin (UI + user actions)
Responsibilities:
- Render deployment page from canonical status.
- Trigger actions (build/deploy/restore) via API.
- Show notices from action result/status.

Non-responsibilities:
- No primary inference from filesystem.
- No backup ownership logic via filename parsing (fallback only during transition).

### 2) Build orchestrator (queue + execution control)
Responsibilities:
- Accept trigger requests.
- Enqueue/debounce via BullMQ.
- Serialize execution (single active job).
- Run scripts.
- Write success/failure + artifacts into status JSON.

Non-responsibilities:
- No UI concerns.

### 3) Shell scripts (execution primitives)
Responsibilities:
- Build static artifacts.
- Make backup archive.
- Copy artifacts to target.

Contract with orchestrator:
- Exit code is authoritative for success/failure.
- Export/return concrete values needed for status update (target, archive path, deploy path).
- No UI state management.

### 4) Redis/BullMQ
Responsibilities:
- Queue, debounce, retry, lock/serialization.

---

## BullMQ shape with few moving parts

Prefer one deploy-orchestrator service, not two separate services initially.

Single service process can expose API and run worker loop in same container:
- Keeps compose smaller.
- Keeps logs/cohesion simpler.
- Still uses BullMQ for durable queue semantics.

If load/operational pressure increases, split API/worker later without changing contracts.

---

## Job contracts

## Trigger sources
- Manual from WP deployment page (build/deploy/restore actions).
- Automatic from WP save hook (debounced coalescing).

### Queue job types
1. `build_static`
- payload: `{ env: dev|staging }`

2. `deploy_production`
- payload: `{ env: production }`
- includes backup + deploy sequence

3. `restore_backup` (optional queued or immediate)
- payload: `{ env, archiveName }`

### Queue behavior
- Debounce save-triggered builds (120s default).
- Coalesce repeated requests per env.
- Single active execution lock.
- If request arrives during run, schedule exactly one follow-up.

---

## Status JSON contract (authoritative)

Top-level shape:
- `updatedAt`
- `envs.dev|staging|production`

Per env:
- `lastRequestedAt`
- `lastStartedAt`
- `lastFinishedAt`
- `lastStatus` (`idle|running|done|failed`)
- `lastError` (string|null)
- `currentBuild`:
  - `path`
  - `clientPath`
  - `hasBuild`
  - `updatedAt`
- `latestBackup`:
  - `name`
  - `path`
  - `createdAt`
  - `size`
- `backups[]` (recent N, e.g., 12)

This should be written only by `update-deployment-status.mjs` or a direct wrapper around it.

---

## Transition plan (practical)

### Phase 1: settle now (no major architecture break)
- Keep existing Astro scripts.
- Keep existing build server trigger path.
- Ensure every backup/deploy path calls `update-deployment-status.mjs` with concrete args.
- Update WP deployment page to read canonical status first.
- Keep old inference logic as fallback only.

### Phase 2: introduce BullMQ orchestrator
- Add single `deploy-orchestrator` service using BullMQ + Redis.
- Move trigger/status endpoints from current ad-hoc server to orchestrator.
- Keep shell scripts unchanged.
- Keep `update-deployment-status.mjs` unchanged as write contract.

### Phase 3: remove fallback inference
- Remove backup filename parsing as primary source.
- Remove filesystem-based `buildExists()` as primary source.
- Keep only health checks for diagnostics.

---

## Rules to prevent regression

1. One writer for deployment state.
2. UI reads status, does not derive status.
3. Scripts perform work, do not own UI semantics.
4. Queue owns timing and serialization.
5. Keep env naming canonical: `dev`, `staging`, `production` (map to `prod` path internally only in one resolver).

---

## Immediate implementation checklist

- [ ] Ensure backup script exports `ARCHIVE_PATH` and calls `update-deployment-status.mjs backup <env>` on success.
- [ ] Ensure deploy scripts export `DEPLOY_BUILD_PATH` and call `update-deployment-status.mjs deploy <env>` on success.
- [ ] Add WP helper to read `deployment-status.json` and render backups/build visibility from it.
- [ ] Keep legacy inference fallback behind `if status file missing`.
- [ ] Add small schema validation for status file reads (defensive but minimal).

---

## Decision summary

- Keep shell scripts: yes.
- Adopt BullMQ: yes.
- Keep moving parts minimal: use one orchestrator service first.
- Reduce inference: status JSON becomes primary contract.
