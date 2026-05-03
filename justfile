# justfile — abcnorio-meta admin operations
# Run from abcnorio-meta/
# Install just: https://github.com/casey/just
# List all recipes: just --list

set dotenv-load := false

# ── Stack ──────────────────────────────────────────────────────────────────────

# Bring the full stack up (detached)
up:
    docker compose up -d

# Bring the stack down
down:
    docker compose down

# Start dev-only services (astro + wp_dev) for active development
dev-up:
    docker compose up -d astro cms_dev

# Stop dev-only services to reclaim ~734 MiB when not developing
dev-down:
    docker compose stop astro cms_dev

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

# Run a WP-CLI command in dev   e.g. just wp-dev cache flush
wp-dev *args:
    bash scripts/wp.sh dev {{ args }}

# Run a WP-CLI command in staging   e.g. just wp-staging plugin list
wp-staging *args:
    bash scripts/wp.sh staging {{ args }}

# ── Builds ─────────────────────────────────────────────────────────────────────

# Trigger a preview build (builds from staging content)
build-preview:
    bash scripts/trigger-build.sh preview full

# Trigger a production build
build-production:
    bash scripts/trigger-build.sh production full

# Trigger a scoped build   e.g. just build-scoped preview events
build-scoped target scope:
    bash scripts/trigger-build.sh {{ target }} {{ scope }}

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
    docker exec cms_{{ env }} composer {{ args }} --working-dir=/app

# ── Plugin ─────────────────────────────────────────────────────────────────────

# Build and deploy the docs site to web/static/docs
docs:
    #!/usr/bin/env bash
    set -e
    source .env
    mkdir -p "${STATIC_SERVER_SITE_DIR}docs"
    image=$(docker build -q "${DOCS_HOST_ROOT}")
    docker run --rm \
        -v "${STATIC_SERVER_SITE_DIR}docs:/app/dist" \
        "$image"
    echo "Docs deployed → ${STATIC_SERVER_SITE_DIR}docs"

# Build the abcnorio-func plugin JS assets
plugin-build:
    cd ../abcnorio-func && npm run build

# Run PHP tests in the plugin (via bedrock dev container)
plugin-test:
    docker exec cms_dev composer test --working-dir=/app/web/app/plugins/abcnorio-func
