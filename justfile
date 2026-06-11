# justfile — abcnorio-meta admin operations
# Run from abcnorio-meta/
# Install just: https://github.com/casey/just
# List all recipes: just --list

set dotenv-load := false

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
        docker compose up -d astro-dev abcwpdev
    elif [[ "{{ env }}" == "staging" ]]; then
        docker compose up -d astro-staging abcwpstaging
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

# Just astro restart
astro-restart:
    docker compose restart astro-dev && docker compose restart astro-staging

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
    bash scripts/wp.sh {{ env }} {{ args }}

# ── Builds ─────────────────────────────────────────────────────────────────────

# Trigger a build   e.g. just build production | just build preview events
build env scope="full":
    bash scripts/trigger-build.sh {{ env }} {{ scope }}

# Push Astro source code to staging workdir via orchestrator endpoint
push-code-to-staging:
    #!/usr/bin/env bash
    set -e
    source .env

    docker exec deploy-orchestrator curl -sf \
        -X POST "http://localhost:4011/dev-tools/push-to-staging" \
        -H "Authorization: Bearer ${ASTRO_BUILD_TRIGGER_SECRET}" \
        | cat
    echo

# Clear vite cache inside astro containers and restart them
clear-vite-cache:
    docker compose exec astro-dev rm -rf /app/node_modules/.vite
    docker compose exec astro-staging rm -rf /app/node_modules/.vite
    docker compose restart astro-dev astro-staging
    echo "done"

# ── Data sync ──────────────────────────────────────────────────────────────────

# Copy media uploads from dev → staging
media-to-staging:
    bash scripts/copy-media.sh dev-to-staging

# Copy media uploads from staging → dev
media-to-dev:
    bash scripts/copy-media.sh staging-to-dev

# Sync DB + media from dev → staging
db-to-staging:
    bash scripts/sync-db.sh dev-to-staging

# Sync DB + media from staging → dev
db-to-dev:
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

# Run composer in a bedrock dir (env: dev or staging)
composer env *args:
    docker exec abcwp{{ if env == "staging" { "staging" } else { "dev" } }} composer {{ args }} --working-dir=/app

# Copy live Bedrock composer files back to the bootstrap seed files (env: dev or staging)
bedrock-snapshot env="dev":
        #!/usr/bin/env bash
        case "{{ env }}" in
            dev|staging) ;;
            *) echo "Unknown env: {{ env }} (expected dev or staging)"; exit 1 ;;
        esac
        cp "wp/{{ env }}/bedrock/composer.json" "wp/{{ env }}/bedrock.composer.json"
        cp "wp/{{ env }}/bedrock/composer.lock" "wp/{{ env }}/bedrock.composer.lock"
        echo "synced {{ env }} bedrock composer files back to seed"

# ── Plugin ─────────────────────────────────────────────────────────────────────

# Build and deploy the docs site to web/static/docs
docs:
    bash scripts/deploy-docs.sh

# Build the abcnorio-func plugin JS assets
plugin-build:
    cd ../abcnorio-func && npm run build

# Run PHP tests in the plugin (via bedrock dev container)
plugin-test:
    docker exec abcwpdev composer test --working-dir=/app/web/app/plugins/abcnorio-func

# Build admin styles
#build-admin-styles:
#    cd ../abcnorio-astro/site-dev/ && npm run build:wp-admin-styles

# Capture host, Docker, filesystem, and bind-mount facts for comparing this machine
# with another environment where astro/orchestrator write permissions worked.
# Usage: just runtime-host-report
#    or: just runtime-host-report /tmp/runtime-host-report.txt
runtime-host-report target="":
    #!/usr/bin/env bash
    target="{{ target }}"

    if [[ "$target" == *=* ]]; then
        echo "Use: just runtime-host-report [output-path]" >&2
        exit 1
    fi

    if [[ -n "$target" ]]; then
        bash scripts/runtime-host-report.sh > "$target"
        echo "wrote $target"
    else
        bash scripts/runtime-host-report.sh
    fi