# justfile — abcnorio-meta admin operations
# Run from abcnorio-meta/
# Install just: https://github.com/casey/just
# List all recipes: just --list

set dotenv-load := false
set positional-arguments := true

# ── Host setup ────────────────────────────────────────────────────────────────

# Migrate from root Docker to rootless Docker.
# Installs Docker CE if not present. Safe to re-run.
setup-rootless-docker:
    bash scripts/setup-rootless-docker.sh

# Host swapfile (4G default, SWAP_SIZE overrides) plus vm.swappiness=10.
# Safe to re-run.
setup-swap:
    bash scripts/setup-swap.sh

# Host fail2ban setup.
# Deploys the repo SSH and Caddy-backed WP login jails plus any extra filters.
# Safe to re-run.
setup-fail2ban:
    bash scripts/setup-fail2ban.sh

# ── Stack ──────────────────────────────────────────────────────────────────────

# Bring services up: full stack, or env-specific   e.g. just up | just up dev
up env="":
    #!/usr/bin/env bash
    if [[ "{{ env }}" == "dev" ]]; then
        docker compose --profile dev up -d astro-dev abcwpdev
    elif [[ "{{ env }}" == "staging" ]]; then
        docker compose up -d deploy-orchestrator abcwpstaging
    else
        docker compose up -d
    fi

# Bring services down: full stack, or stop env-specific   e.g. just down | just down dev
down env="":
    #!/usr/bin/env bash
    if [[ "{{ env }}" == "dev" ]]; then
        docker compose stop astro-dev abcwpdev
    elif [[ "{{ env }}" == "staging" ]]; then
        docker compose stop astro-staging abcwpstaging
    else
        docker compose down
    fi

# restart services
restart env="":
    docker compose restart {{env}}

# Rebuild and restart specific services (space-separated)
rebuild *services:
    docker compose up -d --build {{ services }}

# Pull latest images and restart
pull:
    docker compose pull && docker compose up -d

# ── Logs ───────────────────────────────────────────────────────────────────────

# Tail logs for a service (default: all)
logs service="":
    docker compose logs -f --tail=100 {{ service }}

# ── WP-CLI ─────────────────────────────────────────────────────────────────────

# Run a WP-CLI command   e.g. just wp dev cache flush
wp env *args:
    bash scripts/wp.sh "$@"

# Run a WP-CLI eval expression safely as one argument.
# Example: just wp-eval dev '$v = wp_cache_get("test_key"); echo ($v === false ? "cache-miss-ok" : "cache-hit");'
wp-eval env code:
    bash scripts/wp.sh {{ env }} eval '{{ code }}'

# Flush WP object cache + DB transients for an env.
# Usage: just flush-wp-caches dev
flush-wp-caches ENV:
    bash scripts/wp.sh {{ ENV }} cache flush
    bash scripts/wp.sh {{ ENV }} transient delete --all

# ── Builds ─────────────────────────────────────────────────────────────────────

# deploy preview [scope]: static build from source (scope: full | events | <page-slug>)
# deploy staging: activate astro `staging` branch head; aborts if webcomponents pin != origin/main (FORCE=1 skips)
# deploy production [release_id]: promote healthy staging commit, or restore an archived release_id
# Deploy the Astro frontend: just deploy preview|staging|production
deploy target="" arg="":
    #!/usr/bin/env bash
    set -euo pipefail
    case "{{ target }}" in
      preview)    bash scripts/trigger-build.sh preview "{{ arg }}" ;;
      staging)    bash scripts/deploy-staging.sh ;;
      production) bash scripts/deploy-release.sh production "{{ arg }}" ;;
      *) echo "Usage: just deploy preview [scope] | staging | production [release_id]" >&2; exit 1 ;;
    esac

# Roll back target to previous successful release, or explicit release_id when provided.
# e.g. just rollback production | just rollback preview 20260819-120000-abc1234
rollback target release_id="":
    bash scripts/rollback-release.sh {{ target }} {{ release_id }}

# Bump the abcnorio-webcomponents pin in abcnorio-astro's package-lock.json to origin/main (you commit it).
wc-pin:
    bash scripts/update-webcomponents-pin.sh

# Clear vite cache inside astro containers and restart them
clear-vite-cache:
    docker compose exec astro-dev rm -rf /app/node_modules/.vite
    docker compose exec astro-staging rm -rf /app/node_modules/.vite
    docker compose restart astro-dev astro-staging
    echo "done"

# ── Data sync ──────────────────────────────────────────────────────────────────

# Copy media uploads from dev → staging
media-dev-to-staging:
    bash scripts/copy-media.sh dev-to-staging

# Copy media uploads from staging → dev
media-staging-to-dev:
    bash scripts/copy-media.sh staging-to-dev

# Sync DB + media from dev → staging
db-dev-to-staging:
    bash scripts/sync-db.sh dev-to-staging

# Sync DB + media from staging → dev
db-staging-to-dev:
    bash scripts/sync-db.sh staging-to-dev

# ── Media ──────────────────────────────────────────────────────────────────────

# Regenerate thumbnails   e.g. just regen-thumbs dev
regen-thumbs env:
    bash scripts/regen-thumbs.sh {{ env }}

# Back up production uploads, then replace generated image derivatives from staging.
# Run after staging thumbnail regeneration: just sync-regenerated-thumbnails-to-production
sync-regenerated-thumbnails-to-production:
    bash scripts/sync-regenerated-thumbnails-to-production.sh

# One-off: downscale all upload originals to max 1600px   e.g. just downscale-originals staging
downscale-originals env:
    bash scripts/downscale-originals.sh {{ env }}

# ── DB admin ───────────────────────────────────────────────────────────────────

# Dump a database to backups/mariadb/   e.g. just dump-db staging
dump-db env="staging":
    bash scripts/dump-db.sh {{ env }}

# Open a MariaDB shell (env: dev or staging)
db-shell env="staging":
    #!/usr/bin/env bash
    source .env
    case "{{ env }}" in
      dev)     docker exec -it mariadb mariadb -u"$DEV_DB_USER"     -p"$DEV_DB_PASSWORD"     "$DEV_DB_NAME" ;;
      staging) docker exec -it mariadb mariadb -u"$STAGING_DB_USER" -p"$STAGING_DB_PASSWORD" "$STAGING_DB_NAME" ;;
      *) echo "Unknown env: {{ env }} (expected dev or staging)"; exit 1 ;;
    esac

# ── Composer ───────────────────────────────────────────────────────────────────

# Run host Composer in a Bedrock dir (env: dev or staging)
composer env *args:
    #!/usr/bin/env bash
    set -euo pipefail
    case "{{ env }}" in
        dev|staging) ;;
        *) echo "Unknown env: {{ env }} (expected dev or staging)" >&2; exit 1 ;;
    esac
    (cd "wp/{{ env }}/bedrock" && composer {{ args }})

# Copy live Bedrock composer files back to the bootstrap seed files (env: dev or staging)
bedrock-snapshot env="dev":
        #!/usr/bin/env bash
        case "{{ env }}" in
            dev|staging) ;;
            *) echo "Unknown env: {{ env }} (expected dev or staging)"; exit 1 ;;
        esac
        cp "wp/{{ env }}/bedrock/composer.json" "wp/bootstrap/{{ env }}/bedrock.composer.json"
        cp "wp/{{ env }}/bedrock/composer.lock" "wp/bootstrap/{{ env }}/bedrock.composer.lock"
        echo "synced {{ env }} bedrock composer files back to seed"

# ── Plugin ─────────────────────────────────────────────────────────────────────

# Build and deploy the docs site to web/static/docs
docs:
    bash scripts/deploy-docs.sh

# Releases use plugin-release instead; this does not release, commit, push, or deploy.
# Build local webcomponents and refresh the mounted dev plugin preview assets
plugin-dev-assets:
    #!/usr/bin/env bash
    set -euo pipefail
    WEBCOMPONENTS_DIST="$(cd ../abcnorio-webcomponents && pwd)/dist"
    (cd ../abcnorio-webcomponents && npm run build)
    (cd ../abcnorio-func && ABCNORIO_COMPONENTS_DIST_SOURCE="$WEBCOMPONENTS_DIST" npm run build)

# Build a clean-room release zip for an abcnorio-func tag (defaults to current composer.json version).
# Writes to wp/plugin-artifacts/, consumed by Bedrock's Composer artifact repository.
# e.g. just plugin-artifact | just plugin-artifact v0.23.0
plugin-artifact tag="":
    bash scripts/build-plugin-release.sh {{tag}}

# Build the abcnorio-webcomponents package (dist + manifest generation/validation)
wc-build:
    cd ../abcnorio-webcomponents && npm run build

# Sync webcomponents module declarations from package exports
wc-sync-types:
    cd ../abcnorio-webcomponents && npm run sync:types

# Verify current webcomponents manifest contract without rebuilding
wc-verify:
    cd ../abcnorio-webcomponents && npm run check:manifest

# Scaffold a new webcomponent directory with starter Astro debug file.
# Usage:
#   just wc-create event-card
#   just wc-create cover --scope wp-blocks --wp-block core/cover
wc-create *args:
    bash ../abcnorio-webcomponents/scripts/create-webcomponent.sh {{ args }}

# Scaffold a wp-block webcomponent wrapper with required block key wiring.
# Usage:
#   just wc-create-wp announcement-tout abcnorio/announcement-tout
#   just wc-create-wp youtube core/embed
wc-create-wp component wp_block:
    bash ../abcnorio-webcomponents/scripts/create-webcomponent.sh {{ component }} --scope wp-blocks --wp-block {{ wp_block }}

# Release plugin into selected WP env: build artifact, bump version, commit, tag, push, and verify.
# Usage:
#   just plugin-release dev
#   just plugin-release staging minor
plugin-release env bump="patch" message="":
    if [ -n "{{ message }}" ]; then bash scripts/update-wp-plugin.sh {{ env }} {{ bump }} "{{ message }}"; else bash scripts/update-wp-plugin.sh {{ env }} {{ bump }}; fi

# Run PHP tests in the plugin (via bedrock dev container)
plugin-test:
    docker exec abcwpdev composer test --working-dir=/app/web/app/plugins/abcnorio-func
