# abcnorio/custom-func Current Spec (Consolidated)

## 1. Scope and Intent

- Plugin package: `abcnorio/custom-func`
- Namespace root: `abcnorio`
- Runtime namespace prefix: `abcnorio\\CustomFunc\\`
- Deployment context: Roots Bedrock (Composer-first)
- Architectural style: Declarative config + registrar classes

Primary goals:

- Keep code simple, explicit, and local in behavior.
- Prefer readable, minimal ceremony over abstractions.
- Preserve headless-friendly REST behavior and predictable editor workflows.

## 2. Runtime and Package Contract

### Required package contract

- Composer package type must be `wordpress-plugin`.
- Autoloading is PSR-4 only.
- No mixed autoload strategies by default (no PSR-0/classmap/custom wrappers unless justified).

### Plugin bootstrap contract

Root plugin file must:

- contain standard WP plugin headers,
- guard direct access,
- load `vendor/autoload.php` if present,
- delegate to `Plugin::boot()`.

### Bedrock integration contract

- Current local development uses Bedrock `path` repository with `symlink: true`; target state is to remove symlink usage when moving to VCS-based plugin sourcing.
- Plugin is required from Bedrock `composer.json`.
- Production direction is VCS repository + pinned semantic version.

## 3. Content Model Strategy

- Declarative model definitions in:
  - `src/ContentModel/post-types.php`
  - `src/ContentModel/taxonomies.php`
- Registration logic in:
  - `src/ContentModel/PostTypeRegistrar.php`
  - `src/ContentModel/TaxonomyRegistrar.php`

Conventions:

- Register CPTs and taxonomies on `init`.
- Keep `show_in_rest` explicit.
- Keep rewrite slugs explicit.
- Keep capability mappings explicit where permissions matter.

## 4. Domain Decisions Finalized

### Collectives and associations

- `collective` CPT exists.
- Shared taxonomy `collective_association` is attached to both `collective` and `event`.
- Association model is canonical: matching taxonomy term links collectives to events.

Fixed seeded collective list (current phase):

- Punk/Hardcore Collective
- Visual Arts Collective
- Zine Library Collective
- Silkscreen PrintShop
- Darkroom Collective
- Computer Center

Seeding rules:

- Seed `collective_association` terms for the fixed list.
- Seed corresponding `collective` posts.
- Assign each seeded collective post its matching `collective_association` term.

### Events and types

- `event` CPT exists.
- `event_type` taxonomy exists on `event`.
- Seeded default event types:
  - Show
  - Exhibition
  - Meeting

## 5. Event Data and Meta Naming Contract

Use canonical event-prefixed field names across plugin meta, ACF, and frontend consumption.

Current canonical keys include:

- `event_start_date`
- `event_end_date`
- `event_venue_name`
- `event_venue_address`
- `event_timezone`

Rules:

- Avoid parallel alias keys unless explicitly required.
- Align naming across WP meta registration, ACF field names, and frontend usage.
- Prefer reading canonical fields directly from the REST/source post object; only add intermediate mappings when there is a clear payoff in reuse, normalization, or isolating complex transformations.

## 6. ACF and Editor Behavior

- ACF owns all editorial custom field UI.
- ACF local field group registration is used for event and collective details.
- Event post type supports `custom-fields`.
- Post meta registration remains the storage contract for canonical keys.
- Do not introduce parallel custom Gutenberg panels for editorial field entry unless there is a clear exception and it is added to this spec first.
- Stored event and collective data must always use the canonical meta keys defined in plugin registration.

## 7. Security and Capability Direction

- Capability mappings are explicit for custom post types.
- Role capability sync/migration is managed in plugin code.
- Avoid over-engineering permissions; keep explicit and auditable mappings.
- Capability configuration should be minimal-by-default: only override capabilities where behavior must differ from WordPress defaults.
- For CPTs, prefer `capability_type` + `map_meta_cap` over full per-key `capabilities` arrays unless a concrete exception requires custom remapping.
- Taxonomy term permissions are an explicit exception: keep custom taxonomy `capabilities` maps where we need assign-only behavior for non-admin users.
- Current required taxonomy management capabilities are:
  - `manage_event_type_associations` for `event_type`
  - `manage_collective_associations` for `collective_association`
- Administrators manage term lists; non-admin editorial roles may assign terms (`assign_terms`) but must not create/edit/delete terms.
- Any change to role capability assignments must include a `SCHEMA_VERSION` bump in `src/Security/CapabilityManager.php` so existing installs are migrated.

## 8. Headless/Admin Direction

- Admin experience is tailored for headless workflows.
- Frontend URL rewriting from wp-admin links is environment-driven.
- Theme administration restrictions are policy-driven and configurable via env flags.

## 9. Quality and Release Workflow

### Implemented workflow

- Lint baseline available from Bedrock (`composer lint`).
- Plugin docs validation command: `npm run docs:check`.
- Semantic release dry-run and bump commands via `standard-version`.
- Bedrock wrapper commands exist for plugin docs/release tasks.

### Commit/versioning convention

- Conventional Commit semantics drive release intent.
- `CHANGELOG.md` and version bumps are managed through release scripts.

### Dependency policy

- Use npm `overrides` only for justified transitive vulnerability mitigation.
- Prefer upstream package upgrades first.
- Re-check with `npm audit` after dependency changes.

## 10. Working Style Constraints

These are part of the implementation spec, not optional notes:

- Prefer parsimonious, direct code.
- Keep behavior local and explicit.
- Prefer direct data flow from source objects over extra mapping layers unless the extra indirection has a concrete payoff.
- Avoid nested conditional complexity when a flatter structure is available.
- Avoid placeholder content like "TBA" unless requested.
- Make the smallest practical change that solves the issue.

## 11. Current Completion Status (Spec-Level)

Done:

- Package identity, bootstrap, and PSR-4 architecture are in place.
- Option C is selected and implemented.
- Bedrock local path-repo integration is in place and active.
- Plugin activation/boot path validated.
- Staging smoke checks validated.
- Tooling coherence validated for local lint/docs/release-dry-run workflow.

Pending (release hardening):

- Move from local `path` repo to production `vcs` repo.
- Pin final semantic version strategy in Bedrock require for production.
- Final release lock/commit/tag process enforcement.
- Add static analysis only if complexity justifies it.

Backlog possibility:

- If we add multiple ACF field groups or repeated ACF patterns, consider treating ACF field groups like post types and taxonomies: a declarative definition file plus a very small registrar, but only when that indirection has a clear payoff.

## 12. Source of Truth Policy

For ongoing work:

- This file is the single consolidated spec for current direction.
- If decisions change, update this file first, then implementation.
