## Repository Strategy

This repository is the meta repo.

It owns:
- `compose.yml`
- shared directory layout and mounts
- environment wiring
- WordPress directories (`wp/dev`, `wp/staging`)
- runtime orchestration between services

## Structure

Umbrella root (`~/abcnorio.org`):
- `abcnorio-meta/` (this repo)
- `abcnorio-astro/` (Astro frontend)
- `abcnorio-orchestrator/` (deploy orchestrator)
- `abcnorio-func/` (WordPress plugin)

Inside abcnorio-meta:
- `wp/dev/` (Bedrock based wp dev environment)
- `wp/staging/` (Bedrock based wp staging environment)
- `wp/plugin-artifacts/` (gitignored `abcnorio-func` release tarballs, consumed by staging Bedrock's Composer `artifact` repository — built via `just plugin artifact build`, never committed to git)
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
   ├──▶ astro          (SSR dev)                      │
   ├──▶ astro-staging  (SSR staging)                  │
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
   └── MariaDB (shared container, separate DBs)

Host:
   └── fail2ban (systemd) — protects SSH and watches host-mounted Caddy access logs for repeated WP login failures
```

Networks:
- `abcnorio_net_web` (external): 
  - `proxy`, `web`
- `abcnorio_net_proxy` (external):
  - `proxy`, `astro-dev`, `astro-staging`, `astro-prod`, `abcwpdev`, `abcwpstaging`
- `abcnorio_net_orchestrator` (managed by compose):
  - `deploy-orchestrator`, `astro-dev`, `astro-staging`, `abcwpdev`, `abcwpstaging`
- `abcnorio_net_db` (managed by compose): database clients only
  - `mariadb`, `abcwpdev`, `abcwpstaging`, `deploy-orchestrator`

## Plugin Development Model

- Plugin source lives in `/abcnorio-func/`.
- Dev WordPress bind-mounts `${ABCNORIO_FUNC_HOST_DIR}` directly to `/app/web/app/plugins/abcnorio-func` for live iteration.
- Astro dev bind-mounts webcomponents source for native frontend live updates.
- For WordPress, `just stack watch dev` starts the plugin's existing JS/CSS watcher and a queued component build/publication watcher. Wait for `[components] Ready`, then refresh WordPress. PHP changes need only refresh.
- Dev and staging Composer operations run on the host from their respective Bedrock directories.
- `abcnorio-webcomponents` is a package dependency for Astro and the plugin.
- Staging stays Composer-managed.

## Frontend Release Flow (webcomponents → production)

Local WordPress supports `/abcnorio-login` on `localhost` and `127.0.0.1`,
matching the hosted login alias. The dev web server preserves query parameters
and forwards the request internally to WordPress login; admin protection is unchanged.

### Everyday release workflow

Run all commands from `abcnorio-meta`. Plugin packages are built on the VPS
from Git source and installed by Composer; generated archives stay out of Git.

```sh
# Development machine: commit your work on meta, astro, func.
just release check
# Push the checked commits.

# VPS: pull the intended branches
just release staging plugin minor   # new plugin version plus Astro staging deployment
# Inspect staging WordPress/editor and frontend.
just release preview         # optional full static rehearsal of staged source
just release production      # promote the verified staged frontend
```

`release staging` without a bump reuses the installed plugin. An explicit `plugin patch`,
`plugin minor`, or `plugin major` builds a candidate before versioning/tagging/pushing
the plugin and installing it.

`just release rollback production [release-id]` restores frontend output only.


Commands are grouped by concern (`just --list`); old flat names are
private implementation helpers or removed. Examples:

```sh
just stack up dev
just stack image pull                 # Compose pull AND up; not Git
just frontend cache clear staging     # selected environment only
just wc pin                           # review/commit both consumer lockfiles
just wc create cover --scope wp-blocks --wp-block core/cover
just plugin artifact build v0.62.0    # recreate a tagged installable package
just wp cli staging plugin list       # raw WP-CLI, preserving argument boundaries
just wp composer snapshot staging
just content copy dev staging         # database + uploads
just db copy staging dev              # database only; uploads unchanged
just media copy staging dev           # uploads only
just db dump staging
just db import dev path/to/dump.sql.gz
just media thumbnails regenerate staging
just content urls normalize staging dry
just release docs
```

Astro deploys install the webcomponents in the committed `abcnorio-astro/site-frontend/package-lock.json`. Staging deploys use that pin.

To include new webcomponents:

1. Commit and push `abcnorio-webcomponents` (`main`).
2. Run `just wc pin`, review both consumer lockfiles, and commit the Astro change on `main`.
3. Update the `staging` branch in `abcnorio-astro`. ***Deploys use the local `staging` branch head.***
4. Run `just frontend deploy staging`, verify staging, then run `just frontend deploy preview` if you are feeling cautious, and finally `just frontend deploy production`.

There is a deploy dashboard in the Wordpress admin to manage some of these functions.

For Astro-only changes, merge to `staging` and deploy without updating the webcomponents pin.
Production promotes the verified staging version.

Wordpress changes (editor blocks, REST) go through `just release staging`.
