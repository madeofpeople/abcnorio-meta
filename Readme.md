## Repository Strategy

This repository is the meta repo.

It owns:
- `compose.yml`
- shared directory layout and mounts
- environment wiring
- WordPress directories (`wp/dev`, `wp/staging`)
- runtime orchestration between services

It does **not** own source history for application components.

## Current Directory Structure

Umbrella root (`~/abcnorio.org`):
- `abcnorio-meta/` (this repo)
- `abcnorio-astro/` (Astro frontend)
- `abcnorio-orchestrator/` (deploy orchestrator)
- `abcnorio-func/` (WordPress plugin)

Inside abcnorio-meta:
- `wp/dev/` (Bedrock based wp dev environment)
- `wp/staging/` (Bedrock based wp staging environment)
- `wp/plugin-artifacts/` (gitignored `abcnorio-func` release tarballs, consumed by staging Bedrock's Composer `artifact` repository — built via `just plugin-artifact`, never committed to git)
- `wp/runtime.env`, `wp/dev.env`, `wp/staging.env`
- `scripts/` (admin shell scripts)
- `f2b/fail2ban/jail.local` (fail2ban config for host SSH + Caddy-backed WP login protection)
- `justfile` (task runner — run `just --list` for all recipes)

## Runtime Topology

```
Internet
   │
   ▼
 proxy  ──────────────────────────────────────────────┐
(Caddy)                                               │
   │                                                  │
   ├──▶ astro          (SSR dev,     :3033)           │
   ├──▶ astro-staging  (SSR staging, :3034)           │
   ├──▶ web            (static prod/preview/docs)     │
   ├──▶ abcwpdev       (WP admin/REST, dev)           │
   └──▶ abcwpstaging   (WP admin/REST, staging)       │
                                                      │
deploy-orchestrator (:4011) ◀── trigger (bearer) -────┘
   │  └── build queue (in-memory, 1 at a time)
   │       ├── astro container: npm run build:site
   │       ├── web/static/prod/client (static prod served by web)
   │       └── web/static/prod/.ssr (prod SSR runtime mounted by astro-prod)
   │
abcwpdev / abcwpstaging
   ├── MariaDB (shared container, separate DBs)
   └── APCu object cache (in-process, per-container)

Host:
   └── fail2ban (systemd) — protects SSH and watches host-mounted Caddy access logs for repeated WP login failures
```

Networks:
- `abcnorio_net_web` (external): 
  - `proxy`, `web`
- `abcnorio_net_internal` (external): 
   - `proxy`, `astro`, `astro-staging`, `deploy-orchestrator`, `abcwpdev`, `abcwpstaging`, `mariadb`
- `abcnorio_net_orchestrator` (internal):
  - `deploy-orchestrator` ↔ `astro`, `astro-staging`

## Plugin Development Model

- Canonical plugin source lives in `/abcnorio-func/`.
- Dev WordPress bind-mounts `${ABCNORIO_FUNC_HOST_DIR}` directly to `/app/web/app/plugins/abcnorio-func` for live iteration.
- Dev and staging Composer operations run on the host from their Bedrock directories.
- `abcnorio-webcomponents` is a package dependency for Astro and the plugin, and workshop pages in `abcnorio-astro/site-frontend` are the preview surface.
- Staging stays Composer-managed (no plugin source bind mount); release flow is bump semver, push, then host-side Composer updates staging Bedrock.
- Plugin release artifacts must include `resources/vendor/components/dist` so staging runtime does not require in-container builds.

## Frontend Release Flow (webcomponents → production)

Astro deploys install the webcomponents SHA pinned in the committed `abcnorio-astro/site-frontend/package-lock.json`, not `main`. Pushing webcomponents alone changes nothing on staging or production.

1. Commit and push `abcnorio-webcomponents` (`main`).
2. `just wc-pin`, review the SHA change, commit on `abcnorio-astro` `main`.
3. Merge `main` into `staging` in `abcnorio-astro`. Deploys use the `staging` branch head, not `main`.
4. `just deploy staging` (aborts if the `staging` branch pin is stale; `FORCE=1` skips).
5. Verify staging.
6. `just deploy production`.

Plugin-side changes (editor blocks, REST) go through `just plugin-release staging` instead.

## Which recipe do I run?

| Change | Run |
|---|---|
| Webcomponent markup/SCSS, check in WP editor (dev) | `just plugin-dev-assets` |
| Webcomponent change, ship to Astro | push webcomponents `main`, `just wc-pin`, commit, merge to `staging`, `just deploy staging`, verify, `just deploy production` |
| Plugin change (editor blocks, REST, PHP) | `just plugin-release dev` or `just plugin-release staging [bump]` |
| Webcomponent change that also affects plugin blocks | plugin release first, then the Astro flow above |
| Astro-only change (pages, layouts) | merge to `staging`, `just deploy staging`, verify, `just deploy production` |
| Static preview of current source | `just deploy preview [scope]` |
| Bad production release | `just rollback production` |

Recipes are grouped by prefix: `deploy`/`rollback` (Astro frontend), `wc-*` (webcomponents), `plugin-*` (abcnorio-func), `db-*`/`media-*` (data sync).

## Quick Commands

Requires [just](https://github.com/casey/just).

Fresh machine: run `bash install.sh` on a Debian/Ubuntu host with `sudo`. It installs host prerequisites (`git`, `rsync`, `composer`, `nodejs`, `npm`, `just`), bootstraps Bedrock inline, sets up a 4G host swapfile, rootless Docker + fail2ban, and copies the sample env files you still need to fill with real values.

Permissions contract is deterministic and fixed: uploads run as `UID 1000`, shared group `abcnorio` with `GID 2000`, directories `2775`, files `0664`.

For already-installed machines, run one explicit migration once:

```sh
bash install.sh migrate-permissions-once
```

After migration, runtime services only validate this contract and fail on mismatch; they do not auto-repair permissions.

If dev or staging WordPress is already installed when the stack comes up, `install.sh` activates `abcnorio-func` with WP-CLI. If not, install or restore WordPress first, then run `just wp dev plugin activate abcnorio-func` and `just wp staging plugin activate abcnorio-func` as needed.

Dev Astro expects active `abcnorio-func` plus real REST content. A fresh empty WordPress tree will answer many frontend requests with `404` until content exists. `astro-prod` restarting before the first production deploy is expected, and staging or production frontend paths remain incomplete until the deploy flow runs.

Run `just --list` for all recipes.

```sh
just up                              # bring full stack up (detached)
just down                            # bring stack down
just up dev                          # start dev-only services (astro + abcwpdev)
just down dev                        # stop dev-only services
just rebuild [service …]             # rebuild + restart services
just pull                            # pull latest images and restart
just logs [service]                  # tail logs (default: all)

just wp dev cache flush              # WP-CLI in dev
just wp staging plugin list          # WP-CLI in staging
just composer dev update             # host Composer in dev bedrock
just composer staging update         # host Composer in staging bedrock

just deploy preview                  # static preview build from source (full)
just deploy preview events           # scoped preview build (scope: full | events | <page-slug>)
just deploy staging                  # deploy astro `staging` branch head; aborts if its webcomponents pin != origin/main (FORCE=1 skips)
just deploy production               # build and promote exact healthy staging SHA
just deploy production <release_id>  # restore an archived production release
just rollback production             # restore previous production archive
just docs                            # build + deploy docs site

just wc-pin                          # bump webcomponents pin in abcnorio-astro package-lock.json to origin/main; then commit it

just db-dev-to-staging               # sync DB + media dev → staging
just db-staging-to-dev               # sync DB + media staging → dev
just media-dev-to-staging            # copy media uploads dev → staging
just media-staging-to-dev            # copy media uploads staging → dev
just dump-db staging                 # dump staging DB to backups/mariadb/
just db-shell dev                    # open MariaDB shell

just wc-build                        # build local webcomponents dist (does not affect deploys)
just plugin-dev-assets               # rebuild local webcomponents + refresh WP dev preview assets; no release/deploy
just plugin-release dev              # version, commit, tag, push, and verify plugin release
just plugin-release staging minor    # release plugin and update staging Composer dependency; stops astro-dev/staging during the build, logs to backups/
just plugin-test                     # run PHP tests in the plugin

just setup-swap                      # 4G host swapfile + vm.swappiness=10 (SWAP_SIZE overrides); idempotent
just setup-fail2ban                  # install fail2ban on host + deploy SSH/Caddy jails
```

Dev and staging auto-reload on CMS changes: the plugin exposes `/wp-json/abcnorio/v1/last-change`, `proxy/Caddyfile` serves it same-origin at `/_cms-last-change`, and `html.astro` polls it every 3 s in live modes. Edits made via WP-CLI don't bump it (APCu object cache is per-process).

For user management: `bash scripts/wp-utils.sh <function> [args]`
For standalone Bedrock bootstrap fallback: `bash scripts/bedrock-bootstrap.sh`
To snapshot live Bedrock composer state back into the bootstrap seed files: `just bedrock-snapshot dev`

The proxy already writes JSON access logs into `PROXY_LOG_DIR`, and fail2ban reads those host-side files directly for the `caddy-wp` jail.

`astro-prod` runs from the `abcnorio-astro/prod-ssr/` container image and does not mount the Astro source tree. The image is a small explicit sidecar package with its own `package.json`. On startup it exits until `deploy.sh` stages `web/static/prod/.ssr`; once `/app/server/entry.mjs` and `/app/node_modules` exist, it runs the Astro SSR server directly on port 3033.

Full preview builds also create a `build-archives/abcnorio-astro-production-candidate-*.zip` archive. If production is triggered while the preview fingerprint still matches that candidate, the orchestrator restores the prebuilt production candidate instead of running a second full production build.
