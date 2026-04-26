# Filesystem Permissions Strategy

Date: 2026-04-26

## Latest Current Plan

- Active approach: pragmatic shared-group model now, cleaner identity unification later if needed.
- Canonical shared artifact group identity: `abcnorio`.
- Backing numeric gid: configurable via `ARTIFACT_SHARED_GID` (currently `2000`, moved off `1000`).
- Standardized shared-write paths:
  - `web/static/`
  - `web/static/dev/`
  - `web/static/staging/`
  - `web/static/prod/`
  - `astro/site/build-archives/`
- Shared path policy:
  - directories: `2775` (setgid)
  - files: `664`
  - writer `umask`: `0002`
- Runtime state:
  - Astro, `cms_dev`, and `cms_staging` rebuild/recreate flow succeeds.
  - Shared paths/group membership validate as `abcnorio` in writer containers.
  - Shared group `abcnorio` now resolves to gid `2000` in writer containers.
  - Deploy scripts no longer run recursive chmod normalization; validation confirms no mode drift and cross-writer writes still succeed.
  - WordPress restore flow no longer runs explicit chmod normalization; live restore validation confirms redirect-path success, compliant modes, and cross-writer writes.
- Next focus:
  - keep only permission-repair logic that is still required after live validation.

## Implementation Checklist

### Phase 1: Shared-Write Paths
- [x] Define first-class shared-write paths:
  - `web/static/`
  - `astro/site/build-archives/`
- [x] Record pragmatic near-term approach as active direction.
- [x] Begin implementation in runtime config and deploy/restore flows.

### Phase 1: Container Wiring
- [x] Mount full static build tree into WordPress containers so restore/build inspection works for all environments.
- [x] Pass internal shared static paths into container env instead of relying on host absolute paths.
- [x] Introduce shared artifact gid setting in Compose/build args.
- [x] Rename shared artifact group identity from generic `artifact-shared` to explicit `abcnorio`.
- [x] Add shared group membership for writer containers.

### Phase 1: Permission Policy
- [x] Set writer `umask` to `0002`.
- [x] Normalize shared-write directories to setgid mode (`2775`).
- [x] Normalize shared-write files to group-writable mode (`664`).
- [x] Remove any remaining permission-repair logic that is no longer needed after validation.

### Phase 1: Validation
- [x] Confirm Astro deploy/rebuild/recreate flow completes without permission failures.
- [x] Confirm WordPress restore works for environment targets without permission errors.
- [x] Confirm host user can edit and inspect artifacts without `sudo`.
- [x] Confirm writer containers share `abcnorio` group identity and shared paths stay setgid/group-writable.

### Phase 2: Remaining Cleanup
- [x] Audit remaining permission-repair steps in deploy scripts and restore copy flow.
- [x] Prove safe removal path for recursive chmod in deploy scripts without breaking cross-writer updates.
- [x] Keep only minimal normalization where bind-mount behavior still requires it.

### Phase 3: Optional Hardening
- [x] Move `abcnorio` to dedicated non-`1000` gid across containers (default `2000`) and validate cross-writer behavior.