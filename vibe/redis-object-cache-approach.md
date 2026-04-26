# Redis Object Cache Approach (Staging -> Production)

## Goal
Add platform-level cache for WordPress object/meta/query paths with minimal complexity and predictable memory cost.

## Why this is worth doing
- Lowers repeated DB load on read-heavy endpoints.
- Improves tail latency for REST/search/list pages.
- Adds robustness when traffic bursts.

## Scope
- Bedrock WordPress services only.
- Redis used as cache, not as durable data store.
- Keep app behavior unchanged; cache is additive.

## Memory budget (economical)
- Host assumption: 2 GB RAM (current target profile)
- Start Redis at `maxmemory 64mb`.
- Eviction policy: `allkeys-lru`.
- If hit rate poor and evictions high, move to `128mb`, then `256mb`.

## RAM sizing for this stack shape (2 WP + Redis)
- Target stack: proxy + Astro + static web + 2x WordPress (FrankenPHP) + MariaDB + Redis.
- Expected normal-load footprint: ~0.8 GB to 1.2 GB total.
- Recommended host size: 2 GB RAM for current traffic expectations.
- Prefer 4 GB RAM if you want growth headroom and less tuning pressure.
- Redis cap for this profile: start at `maxmemory 64mb` with `allkeys-lru`.
- Keep Redis bounded; do not leave `maxmemory` unlimited.

## Compose/service plan
1. Add `redis` service to compose.
2. Put redis on internal network only.
3. Disable persistence for cache-only mode:
- `save ""`
- `appendonly no`

## WordPress integration plan
1. Install Redis object cache plugin via Composer in Bedrock.
2. Add config constants/env for host/port/password/database.
3. Enable object cache (admin or wp-cli).
4. Verify object cache drop-in active.

## Freshness behavior
- Core WP object cache invalidates related keys on content updates.
- Editors should usually see event updates immediately.
- TTL matters for custom endpoint-level caches (if added), not standard post/meta cache invalidation.

## Rollout sequence
1. Staging: enable Redis with 64 MB cap.
2. Observe 3-7 days:
- Redis memory usage
- Evictions
- Hit/miss ratio
- API latency and DB load
3. Adjust memory cap only if needed.
4. Promote to production with same settings.

## Operational guardrails
- Keep Redis optional/fail-soft (site should still function if Redis unavailable).
- Monitor `used_memory`, `evicted_keys`, and plugin-level cache stats.
- Avoid over-tuning early.

## Near-term code optimizations (without Redis)
These are still useful and now implemented in parallel work:
- Search endpoint response cache with short TTL.
- Set-based lookups in scorer loop.
- Astro taxonomy fetch TTL cache for event filters/tags.
