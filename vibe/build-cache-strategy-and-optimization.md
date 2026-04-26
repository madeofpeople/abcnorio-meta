# Build, Cache Strategy and Optimization Spec

## Overview

Consolidated architecture for Astro build performance and resilience covering:
1. API fetch optimization (parallelization + TTL caching)
2. WordPress save-triggered build queue
3. Build backup retention
4. Database + media backup jobs

---

## Part 1: API Fetch Optimization (Build Cache Strategy)

### Current Implementation
- File-based cache in `.cache/wp-api/` with SHA1 hash keys
- Paginated API fetches (100 items per page)
- Serial pagination: fetch page 1 → 2 → 3 (causes timeout accumulation)
- Cache used as fallback-only on network failure

### Problem
- 500 events = 5 pages × 12s timeout (serial) = ~60s potential delay
- Cache only prevents build failure, not time optimization
- Every build fetches fresh even if data unchanged

### Solution: Parallel Fetch + TTL Cache (Option B)

#### Strategy
1. **Parallel pagination**: Fetch all pages concurrently instead of serially
   - 5 pages in parallel = ~12s total instead of 60s serial
   - Estimated gain: 50+ seconds on scaled builds

2. **TTL-aware cache**: Check file timestamp before network request
   - If cache is < 1h old → skip API call entirely → near-instant build
   - If cache stale or missing → fetch fresh → update with new timestamp
   - Resilience: cache still available on network failure

3. **Maintained locality**: All caching logic stays in `build-cache.js`
   - No new abstractions or dependencies
   - Single source of truth for cache behavior
   - Testable in isolation

#### Implementation Details

**File: `astro/site/src/util/build-cache.js`**

Modify `fetchAllWpItemsWithBuildCache()` to:
- Accept optional `cacheValidMs` parameter (default 3600000 = 1h)
- Before pagination loop: check if cached file exists and is fresh
- If fresh, return cached data immediately
- If stale/missing, fetch all pages in parallel via `Promise.all()`
- After fetching: write new snapshot with updated timestamp

Maintain `readSnapshot()` format (persists `savedAt`, `url`, `data`).

```js
// Pseudocode flow
export async function fetchAllWpItemsWithBuildCache(baseUrl, options = {}) {
  const { cacheValidMs = 3600000, perPage = 100, defaultValue = [] } = options;
  
  // Check cache freshness
  const cached = await readSnapshot(baseUrl);
  if (cached && isFresh(cached.savedAt, cacheValidMs)) {
    console.log(`[build-cache] Using fresh cache for ${baseUrl}`);
    return cached.data ?? cached;
  }
  
  // Fetch all pages in parallel
  const pageCount = await getPageCount(baseUrl, perPage);
  const pageRequests = Array.from({ length: pageCount }, (_, i) =>
    fetchJsonWithBuildCache(`${baseUrl}&page=${i+1}&per_page=${perPage}`)
  );
  
  const items = [];
  const allPages = await Promise.all(pageRequests);
  allPages.forEach(batch => items.push(...(batch || [])));
  
  await writeSnapshot(baseUrl, items);
  return items;
}
```

#### Astro Integration Notes
- Astro's native `fetch()` deduplication is request-scoped; this cache is persistent
- No new npm packages needed; uses Node `fs/promises` (already imported)
- Build time scales: 25-35s current → 12-15s with parallelization + cache hits

### Files Changed/Created
- `astro/site/src/util/build-cache.js` — Add TTL check, parallel pagination
- `astro/site/src/pages/events/[slug].astro` — No change (consumes function)
- `astro/site/src/pages/collectives/[slug].astro` — No change
- `astro/site/src/pages/programming/[slug].astro` — No change
- `astro/site/src/pages/about/[slug].astro` — No change

---

## Part 2: WordPress Save-Triggered Build Queue

### Goal
Trigger Astro build after relevant WordPress content changes without causing build storms during active editing.

Desired behavior:
- Build requests coalesce into one run during active editing
- Build starts only after quiet period (debounce window)
- If new changes arrive while build is running, schedule exactly one follow-up build
- WordPress save request stays fast and non-blocking

### Architecture

#### Tech Stack
- **Queue backend**: Redis 7.4 (existing service)
- **Queue library**: BullMQ (production-grade job queue, low maintenance)
- **Build-API**: Node/Express service listening on port 4011
  - Receives POST requests from WordPress hook
  - Signature verification (shared secret with WordPress)
  - Enqueues job in BullMQ with timestamp
- **Build-Worker**: Node worker consuming BullMQ jobs
  - Implements debounce check (120s default, configurable)
  - Acquires file lock before build to prevent concurrent builds
  - Runs `npm run build` in `/workspace/astro/site`
  - On completion, checks if follow-up build needed (coalesced requests)

#### Compose Additions

Add to `docker-compose.yml`:

```yaml
  build-api:
    image: node:22-alpine
    container_name: abcnorio-build-api
    working_dir: /workspace
    volumes:
      - .:/workspace
    environment:
      - NODE_ENV=production
      - REDIS_URL=redis://redis:6379
      - BUILD_API_PORT=4011
      - BUILD_API_SECRET=${BUILD_API_SECRET:-dev-secret-change-in-prod}
    ports:
      - "4011:4011"
    depends_on:
      - redis
    command: >
      sh -c "cd build-orchestrator/api && npm install && npm start"

  build-worker:
    image: node:22-alpine
    container_name: abcnorio-build-worker
    working_dir: /workspace
    volumes:
      - .:/workspace
    environment:
      - NODE_ENV=production
      - REDIS_URL=redis://redis:6379
      - ASTRO_BUILD_DEBOUNCE_MS=120000
      - BUILD_LOCK_TIMEOUT_MS=600000
    depends_on:
      - redis
    command: >
      sh -c "cd build-orchestrator/worker && npm install && npm start"
```

#### Proposed File Structure

```
build-orchestrator/
├── api/
│   ├── package.json
│   ├── src/
│   │   ├── index.js          (Express server, job enqueue)
│   │   ├── signature.js      (HMAC verification)
│   │   └── queue.js          (BullMQ client setup)
│   └── README.md
├── worker/
│   ├── package.json
│   ├── src/
│   │   ├── index.js          (Worker process, job consumer)
│   │   ├── build.js          (Build executor, lock handling)
│   │   └── queue.js          (BullMQ worker setup)
│   └── README.md
├── shared/
│   ├── constants.js          (Debounce times, lock timeouts)
│   └── env.js                (Redis URL, secrets)
└── README.md                 (Architecture, deployment notes)
```

#### Debounce Model
- Job enqueued with timestamp when WordPress save fires
- Worker checks: is this job > 120s old?
  - If yes: acquire lock, run build
  - If no: wait until 120s elapsed before acquiring lock
- During build: new save requests added to queue
- Post-build: if queue has pending jobs, schedule exactly one follow-up build
- Lock prevents concurrent builds; file-based lock at `/tmp/abcnorio-build.lock`

#### Resilience
- If Redis down: build-api returns 5xx (WordPress ignores gracefully)
- If build-worker crashes: BullMQ will retry job on restart
- If build process hangs: timeout set to 600s, lock is forcibly released

### Integration: WordPress Plugin Hook

**File: `wp/staging/abcnorio-func/src/Hooks/BuildTrigger.php`** (new file)

Register `save_post` and `acf/save_post` hooks to:
1. Check if post type is in trigger list (event, news_item, page, collective)
2. POST to `http://build-api:4011/trigger-build` with:
   - Post ID, post type, timestamp
   - HMAC signature of payload
3. Return immediately (fire-and-forget)

```php
public static function onSavePost($post_id, WP_Post $post): void {
  $triggerTypes = ['event', 'news_item', 'page', 'collective'];
  if (!in_array($post->post_type, $triggerTypes)) return;
  
  $payload = ['postId' => $post_id, 'type' => $post->post_type, 'timestamp' => time()];
  $signature = hash_hmac('sha256', json_encode($payload), getenv('BUILD_API_SECRET'));
  
  wp_remote_post(getenv('BUILD_API_URL'), [
    'method' => 'POST',
    'body' => json_encode($payload),
    'headers' => ['X-Signature' => $signature],
    'blocking' => false,
    'timeout' => 0.01,  // Fire-and-forget
  ]);
}
```

### Files Changed/Created
- `build-orchestrator/api/package.json` — New
- `build-orchestrator/api/src/index.js` — New
- `build-orchestrator/api/src/signature.js` — New
- `build-orchestrator/api/src/queue.js` — New
- `build-orchestrator/worker/package.json` — New
- `build-orchestrator/worker/src/index.js` — New
- `build-orchestrator/worker/src/build.js` — New
- `build-orchestrator/worker/src/queue.js` — New
- `build-orchestrator/shared/constants.js` — New
- `build-orchestrator/shared/env.js` — New
- `docker-compose.yml` — Add build-api, build-worker services
- `wp/staging/abcnorio-func/src/Hooks/BuildTrigger.php` — New
- `wp/staging/abcnorio-func/composer.json` — Add BullMQ as dev dependency

---

## Part 3: Build Backup Retention

### Strategy
Optional pre-build backup to local archive with "keep last 3 builds" retention.

Gated by `ASTRO_BUILD_BACKUP=1` environment variable (disabled by default for fast dev builds).

### Current Implementation
- Script in `astro/site/package.json`
- Creates `.zip` file with timestamp in `build-archives/`
- Uses `tar` or `zip` depending on availability

### Proposed Enhancement

**File: `scripts/backup-astro-build.sh`** (new file)

```bash
#!/bin/bash
set -e

BACKUP_DIR="./astro/site/build-archives"
MAX_BACKUPS=3
ARCHIVE_NAME="abcnorio-astro-$(date +%Y%m%d-%H%M%S).zip"

# Create backup
mkdir -p "$BACKUP_DIR"
zip -qr "$BACKUP_DIR/$ARCHIVE_NAME" ./web/static/prod

# Retain only last N backups
cd "$BACKUP_DIR"
ls -t *.zip | tail -n +$((MAX_BACKUPS + 1)) | xargs -r rm

echo "✓ Backup saved: $ARCHIVE_NAME"
echo "✓ Retained backups: $(ls -1 *.zip 2>/dev/null | wc -l)"
```

Update `astro/site/package.json` to call shell script:

```json
"maybe:backup:build": "if [ \"$ASTRO_BUILD_BACKUP\" = \"1\" ]; then bash ../../scripts/backup-astro-build.sh; else echo 'Skipping build backup (set ASTRO_BUILD_BACKUP=1 to enable)'; fi"
```

### Files Changed/Created
- `scripts/backup-astro-build.sh` — New
- `astro/site/package.json` — Update script to call shell wrapper

---

## Part 4: Database + Media Backups (BullMQ Jobs)

### Strategy
Extend build queue to also handle:
1. **Database backups**: Daily at 2 AM, keep last 7
2. **Media file backups**: Weekly rsync to S3/Backblaze, belt-and-suspenders with Hetzner backup

### Implementation (Future Phase)

Use same BullMQ queue for backup jobs:

**Enqueue in WordPress Admin:**
- Add WP admin page for manual backup trigger
- Display last backup timestamp and size

**Worker schedules recurring jobs:**
- Database: every 24h at 2 AM via BullMQ `repeat` option
- Media: every 7 days via BullMQ `repeat` option

**Database job flow:**
1. Run `mysqldump` → compress to gzip
2. Store in `/backups/wordpress-$(date).sql.gz`
3. Keep local last 3, upload to S3 (keep last 7)
4. Cleanup old files
5. Retry 2x on failure with exponential backoff

**Media job flow:**
1. Run rsync from `/web/app/uploads` → S3/Backblaze
2. Delete old media blocks (older than 90 days)
3. Log summary

### Files Changed/Created (Future)
- `build-orchestrator/worker/src/jobs/backup-database.js` — New
- `build-orchestrator/worker/src/jobs/backup-media.js` — New
- `wp/staging/abcnorio-func/src/Admin/BackupPage.php` — New
- `docker-compose.yml` — Add AWS credentials env vars
- `.env.example` — Add backup scheduling vars

---

## Implementation Priority

**Phase 1 (Immediate):**
1. Parallelize API pagination in `build-cache.js` → 50s build time savings
2. Add TTL check to cache logic → near-instant repeat builds

**Phase 2 (Build queue):**
1. Create `build-orchestrator/` directory structure
2. Implement build-api service + signature verification
3. Implement build-worker service + lock handling
4. Add WordPress hook to `abcnorio-func` plugin
5. Test with docker-compose stack

**Phase 3 (Backup jobs, optional):**
1. Database backup job with retention
2. Media backup with rsync
3. WordPress admin UI for manual triggers

---

## Summary of All Files Changed/Created

### Phase 1: API Optimization
- ✏️ `astro/site/src/util/build-cache.js` — Parallelize + TTL

### Phase 2: Build Queue
- ➕ `build-orchestrator/api/package.json`
- ➕ `build-orchestrator/api/src/index.js`
- ➕ `build-orchestrator/api/src/signature.js`
- ➕ `build-orchestrator/api/src/queue.js`
- ➕ `build-orchestrator/worker/package.json`
- ➕ `build-orchestrator/worker/src/index.js`
- ➕ `build-orchestrator/worker/src/build.js`
- ➕ `build-orchestrator/worker/src/queue.js`
- ➕ `build-orchestrator/shared/constants.js`
- ➕ `build-orchestrator/shared/env.js`
- ✏️ `docker-compose.yml` — Add services
- ➕ `wp/staging/abcnorio-func/src/Hooks/BuildTrigger.php`

### Phase 3: Backup Infrastructure
- ➕ `scripts/backup-astro-build.sh`
- ✏️ `astro/site/package.json` — Link backup script
- ➕ `build-orchestrator/worker/src/jobs/backup-database.js` (future)
- ➕ `build-orchestrator/worker/src/jobs/backup-media.js` (future)
- ➕ `wp/staging/abcnorio-func/src/Admin/BackupPage.php` (future)

Legend: ➕ = new file, ✏️ = modified file
