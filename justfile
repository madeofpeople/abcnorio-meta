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

# Build and deploy a production promotion from staged code with: just deploy-release production.
# Manual builds are for preview: just build preview | just build preview events
build env scope="full":
    bash scripts/trigger-build.sh {{ env }} {{ scope }}

# Promote the exact frontend commit currently running on healthy staging, or restore a specific archived release.
# e.g. just deploy-release production | just deploy-release production 20260819-120000-abc1234
deploy-release target release_id="":
    bash scripts/deploy-release.sh {{ target }} {{ release_id }}

# Roll back target to previous successful release_id, or explicit release_id when provided.
# e.g. just rollback-release production | just rollback-release preview 20260819-120000-abc1234
rollback-release target release_id="":
    if [ -n "{{ release_id }}" ]; then bash scripts/rollback-release.sh {{ target }} {{ release_id }}; else bash scripts/rollback-release.sh {{ target }}; fi

# Push current staging branch head to staging runtime with completion feedback.
# Script polls orchestrator, temporarily stops astro-staging during cutover,
# waits for astro-staging health, and verifies staging plugin/editor artifacts.
# e.g. just deploy-staging
deploy-staging:
    bash scripts/deploy-staging.sh

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
build-docs:
    bash scripts/deploy-docs.sh

# Build the abcnorio-func plugin JS assets
build-plugin:
    cd ../abcnorio-func && npm run build

# Build local webcomponents and refresh the mounted dev plugin preview assets.
# Does not release, commit, push, or deploy.
# Usage: just update-plugin dev
update-plugin env:
    #!/usr/bin/env bash
    set -euo pipefail
    if [[ "{{ env }}" != "dev" ]]; then
        echo "update-plugin only supports dev; use release-plugin for releases." >&2
        exit 1
    fi
    WEBCOMPONENTS_DIST="$(cd ../abcnorio-webcomponents && pwd)/dist"
    (cd ../abcnorio-webcomponents && npm run build)
    (cd ../abcnorio-func && ABCNORIO_COMPONENTS_DIST_SOURCE="$WEBCOMPONENTS_DIST" npm run build)

# Build a clean-room release zip for an abcnorio-func tag (defaults to current composer.json version).
# Writes to wp/plugin-artifacts/, consumed by Bedrock's Composer artifact repository.
# e.g. just build-plugin-release | just build-plugin-release v0.23.0
build-plugin-release tag="":
    bash scripts/build-plugin-release.sh {{tag}}

# Build the abcnorio-webcomponents package (dist + manifest generation/validation)
build-webcomponents:
    cd ../abcnorio-webcomponents && npm run build

# Sync webcomponents module declarations from package exports
sync-webcomponents-types:
    cd ../abcnorio-webcomponents && npm run sync:types

# Verify current webcomponents manifest contract without rebuilding
verify-webcomponents:
    cd ../abcnorio-webcomponents && npm run check:manifest

# Scaffold a new webcomponent directory with starter Astro debug file.
# Usage:
#   just create-webcomponent event-card
#   just create-webcomponent cover --scope wp-blocks --wp-block core/cover
create-webcomponent *args:
    bash ../abcnorio-webcomponents/scripts/create-webcomponent.sh {{ args }}

# Scaffold a wp-block webcomponent wrapper with required block key wiring.
# Usage:
#   just create-webcomponent-wp announcement-tout abcnorio/announcement-tout
#   just create-webcomponent-wp youtube core/embed
create-webcomponent-wp component wp_block:
    bash ../abcnorio-webcomponents/scripts/create-webcomponent.sh {{ component }} --scope wp-blocks --wp-block {{ wp_block }}

# Release plugin into selected WP env: build artifact, bump version, commit, tag, push, and verify.
# Usage:
#   just release-plugin dev
#   just release-plugin staging minor
release-plugin env bump="patch" message="":
    if [ -n "{{ message }}" ]; then bash scripts/update-wp-plugin.sh {{ env }} {{ bump }} "{{ message }}"; else bash scripts/update-wp-plugin.sh {{ env }} {{ bump }}; fi

# Run PHP tests in the plugin (via bedrock dev container)
plugin-test:
    docker exec abcwpdev composer test --working-dir=/app/web/app/plugins/abcnorio-func
