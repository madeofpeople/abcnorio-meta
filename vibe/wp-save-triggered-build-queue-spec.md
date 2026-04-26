# WP Save Triggered Astro Build Queue Spec

## Goal

Trigger Astro build after relevant WordPress content changes without causing build storms.

Desired behavior:
- Build requests coalesce into one run during active editing.
- Build starts only after quiet period (debounce window).
- If new changes arrive while build is running, schedule exactly one follow-up build.
- WordPress save request stays fast and non-blocking.

## Scope

In scope:
- Trigger from WordPress save/edit actions.
- Debounced and lock-safe build orchestration.
- Local docker-compose workflow.

Out of scope (initial phase):
- Full CI/CD replacement.
- Multi-tenant scheduling.
- Historical analytics dashboard.

## Why not run build directly in plugin hooks

Direct build on save causes:
- Too many builds during rapid edits.
- Slow admin requests and potential timeouts.
- Competing builds and race conditions.

Queue + debounce avoids this.

## Recommended architecture

Use existing Redis service as state/queue backend.

Components:
1. WordPress plugin trigger hook
2. Small Build API service (receives trigger)
3. Small Build Worker service (runs build)
4. Redis keys for pending state + lock

Flow:
1. WP hook sends signed HTTP request to Build API.
2. Build API updates pending marker in Redis (last-change timestamp).
3. Worker polls Redis and checks debounce window.
4. If quiet period elapsed and no lock, worker acquires lock and runs build.
5. If requests arrive during build, worker runs one additional build after current one completes.

## Debounce and lock model

Suggested defaults:
- Debounce window: 120s
- Poll interval: 5s
- Build timeout: 20m
- Max retries: 1 (optional)

Redis keys:
- build:astro:last_request_ts
- build:astro:building_lock
- build:astro:needs_followup
- build:astro:last_success_ts
- build:astro:last_error

Rules:
- New trigger always refreshes last_request_ts.
- If lock exists, set needs_followup=true and return.
- Worker starts build only when now - last_request_ts >= debounce window and lock absent.
- At build end: if needs_followup=true, clear flag and rerun once after debounce check.

## Small, modern, maintained packages

### Preferred option: BullMQ

Package:
- bullmq

Why:
- Active maintenance.
- Redis-native.
- Retries, delayed jobs, priorities.
- Good fit with existing Redis in compose.

Tradeoff:
- Slightly more setup than custom Redis key polling.

### Minimal option: custom Redis debounce worker

Packages:
- ioredis
- pino (logging)

Why:
- Very small footprint.
- Easy to reason about for one queue.

Tradeoff:
- You own reliability features (retry/backoff/visibility).

### Optional helper UI

Packages:
- @bull-board/api
- @bull-board/express

Why:
- Quick queue visibility during development.

Tradeoff:
- Extra service/routes to secure.

## Recommendation

Start with BullMQ unless strict minimalism is required.

Rationale:
- Lower long-term maintenance than hand-rolled edge-case handling.
- Better observability and retry semantics out of box.
- Easy to keep scope small with one queue and one worker.

## Compose additions

Add services:
- build-api (Node)
- build-worker (Node)

Reuse existing:
- redis

Environment:
- BUILD_WEBHOOK_SECRET
- BUILD_DEBOUNCE_SECONDS=120
- BUILD_TIMEOUT_SECONDS=1200
- BUILD_COMMAND="npm run build"
- BUILD_WORKDIR="/workspace/astro/site"

Proposed `compose.yml` service blocks (spec only, not applied yet):

```yaml
services:
  build-api:
    image: node:22-alpine
    container_name: build-api
    working_dir: /workspace/build-orchestrator
    command: ["sh", "-lc", "npm ci && npm run start:api"]
    volumes:
      - ./:/workspace
    environment:
      NODE_ENV: development
      PORT: 4011
      REDIS_URL: redis://redis:6379
      BUILD_QUEUE_NAME: astro-build
      BUILD_WEBHOOK_SECRET: ${BUILD_WEBHOOK_SECRET}
      BUILD_DEBOUNCE_SECONDS: ${BUILD_DEBOUNCE_SECONDS:-120}
    depends_on:
      - redis
    restart: unless-stopped

  build-worker:
    image: node:22-alpine
    container_name: build-worker
    working_dir: /workspace/build-orchestrator
    command: ["sh", "-lc", "npm ci && npm run start:worker"]
    volumes:
      - ./:/workspace
    environment:
      NODE_ENV: development
      REDIS_URL: redis://redis:6379
      BUILD_QUEUE_NAME: astro-build
      BUILD_DEBOUNCE_SECONDS: ${BUILD_DEBOUNCE_SECONDS:-120}
      BUILD_TIMEOUT_SECONDS: ${BUILD_TIMEOUT_SECONDS:-1200}
      BUILD_COMMAND: ${BUILD_COMMAND:-npm run build}
      BUILD_WORKDIR: ${BUILD_WORKDIR:-/workspace/astro/site}
      BACKUP_FLAG_ENV: ASTRO_BUILD_BACKUP
    depends_on:
      - redis
    restart: unless-stopped
```

Notes:
- Worker must have repo volume mounted so it can execute Astro build command.
- Keep `redis` service as shared queue backend.
- Keep API and worker separate so incoming triggers are decoupled from build runtime.

## Proposed file structure (new components)

```text
build-orchestrator/
  package.json
  tsconfig.json
  src/
    config/
      env.ts
    queue/
      queue.ts
      jobs.ts
    api/
      server.ts
      routes/
        trigger-build.ts
        health.ts
    worker/
      worker.ts
      run-build.ts
      debounce.ts
      lock.ts
    util/
      logger.ts
      signature.ts
      time.ts
  test/
    api.trigger-build.test.ts
    worker.debounce.test.ts
```

Optional monitoring UI:

```text
build-orchestrator/
  src/
    api/
      routes/
        queue-dashboard.ts
```

## WordPress trigger contract

Trigger only on relevant content mutations:
- post types: event, news_item, page, collective (adjustable)
- term edits that impact routes/filtering

Avoid triggering for:
- autosaves/revisions
- unrelated admin options

Request payload (example):
- reason: post_updated
- object_type: post
- object_id
- post_type
- changed_at (UTC ISO string)

Auth:
- Shared secret header (for example X-Build-Signature)

## Operational safeguards

- Single active build lock.
- Build timeout kill and lock cleanup.
- Follow-up build cap of 1 per active build cycle.
- Structured logs with request id.
- Explicit dev/staging enable flag.

## Rollout plan

1. Implement Build API + worker with BullMQ and Redis.
2. Add plugin trigger hook behind feature flag.
3. Validate debounce behavior under rapid edits.
4. Add follow-up build behavior test (edit during build).
5. Add light status endpoint and logs.
6. Enable in staging first, then production.

## Success criteria

- Rapid sequence of edits yields one build per quiet period.
- No overlapping builds.
- WP save latency unaffected by build duration.
- Build failures visible and recoverable.
