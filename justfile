# justfile — abcnorio-meta admin operations
# Run from abcnorio-meta/
# Install just: https://github.com/casey/just
# List all recipes: just --list

set dotenv-load := false
set positional-arguments := true

# ── Daily development and releases ────────────────────────────────────────────

# Check, stage, preview, publish production/docs, or roll back a release.
release target *args:
    bash scripts/release.sh "$@"

# ── Concern-based entry points ────────────────────────────────────────────────

# Stack lifecycle, logs, or image pull (also reconciles services).
stack action *args:
    #!/usr/bin/env bash
    set -euo pipefail
    action="$1"; shift
    case "$action" in
      up|down|restart|rebuild|logs)
        if [[ ( "$action" == up || "$action" == rebuild ) && $# -ge 1 && $# -le 2 && "$1" == dev && ( "${2:-}" == "" || "${2:-}" == cms || "${2:-}" == frontend ) ]]; then
          [[ -d ../abcnorio-func/build/calendar && -f ../abcnorio-func/build/index.js && -f ../abcnorio-func/resources/vendor/components/dist/manifest.json ]] || just _plugin-dev-assets
        fi
        bash scripts/stack.sh "$action" "$@" ;;
      watch) [[ $# -eq 1 && "$1" == dev ]] || { echo "Usage: just stack watch dev" >&2; exit 1; }; node scripts/plugin-dev.mjs ;;
      image) [[ $# -eq 1 && "$1" == pull ]] || { echo "Usage: just stack image pull" >&2; exit 1; }; just image-pull ;;
      *) echo "Usage: just stack up|down|restart|rebuild|logs [environment [role]] | watch dev | image pull" >&2; exit 1 ;;
    esac

# Component build, pin, scaffold, or manifest check.
wc action *args:
    #!/usr/bin/env bash
    set -euo pipefail
    action="$1"; shift
    case "$action" in
      build|pin|create) just "wc-$action" "$@" ;;
      manifest) [[ $# -eq 1 && "$1" == check ]] || { echo "Usage: just wc manifest check" >&2; exit 1; }; just wc-verify ;;
      *) echo "Usage: just wc build|pin|create|manifest check" >&2; exit 1 ;;
    esac

# Rebuild a tagged artifact or run existing PHP tests.
plugin action *args:
    #!/usr/bin/env bash
    set -euo pipefail
    action="$1"; shift
    case "$action" in
      artifact) [[ $# -ge 1 && "$1" == build ]] || { echo "Usage: just plugin artifact build [tag]" >&2; exit 1; }; shift; just plugin-artifact "$@" ;;
      test) just plugin-test "$@" ;;
      *) echo "Usage: just plugin artifact build [tag] | test" >&2; exit 1 ;;
    esac

# Low-level frontend deploy or selected-environment Vite cache clearing.
frontend action *args:
    #!/usr/bin/env bash
    set -euo pipefail
    action="$1"; shift
    case "$action" in
      deploy) just deploy "$@" ;;
      cache) [[ $# -eq 2 && "$1" == clear ]] || { echo "Usage: just frontend cache clear <dev|staging>" >&2; exit 1; }; shift; just clear-vite-cache "$@" ;;
      *) echo "Usage: just frontend deploy <target> [argument] | cache clear <env>" >&2; exit 1 ;;
    esac

# WP-CLI gateway and Composer-aware WordPress maintenance.
wp action *args:
    #!/usr/bin/env bash
    set -euo pipefail
    action="$1"; shift
    case "$action" in
      cli) bash scripts/wp.sh "$@" ;;
      core) [[ $# -eq 3 && "$1" == update ]] || { echo "Usage: just wp core update <env> <version>" >&2; exit 1; }; shift; just wp-core-update "$@" ;;
      plugins) [[ $# -eq 2 && "$1" == update ]] || { echo "Usage: just wp plugins update <env>" >&2; exit 1; }; shift; just plugins-update "$@" ;;
      composer)
        sub="${1:-}"; shift || true
        case "$sub" in
          cli) just composer "$@" ;;
          snapshot) [[ $# -eq 1 ]] || { echo "Usage: just wp composer snapshot <env>" >&2; exit 1; }; just bedrock-snapshot "$@" ;;
          *) echo "Usage: just wp composer cli <env> <args...> | snapshot <env>" >&2; exit 1 ;;
        esac ;;
      *) echo "Usage: just wp cli|core update|plugins update|composer ..." >&2; exit 1 ;;
    esac

# Database-only copy, dump, or local import.
db action *args:
    #!/usr/bin/env bash
    set -euo pipefail
    action="$1"; shift
    case "$action" in
      dump) [[ $# -eq 1 ]] || { echo "Usage: just db dump <env>" >&2; exit 1; }; just dump-db "$@" ;;
      import) [[ $# -eq 2 && "$1" == dev ]] || { echo "Usage: just db import dev <file>" >&2; exit 1; }; shift; just local-db-import "$@" ;;
      copy)
        [[ $# -eq 2 ]] || { echo "Usage: just db copy <source> <destination>" >&2; exit 1; }
        bash scripts/sync-db.sh "$1-to-$2" --database-only ;;
      *) echo "Usage: just db dump <env> | import dev <file> | copy <source> <destination>" >&2; exit 1 ;;
    esac

# Combined DB/uploads copy, URL normalization, or URL tests.
content action *args:
    #!/usr/bin/env bash
    set -euo pipefail
    action="$1"; shift
    case "$action" in
      copy) [[ $# -eq 2 ]] || { echo "Usage: just content copy <source> <destination>" >&2; exit 1; }; bash scripts/sync-db.sh "$1-to-$2" ;;
      urls)
        sub="${1:-}"; shift || true
        case "$sub" in
          normalize) just rewrite-hosts "$@" ;;
          test) [[ $# -eq 1 && ( "$1" == dev || "$1" == staging ) ]] || { echo "Usage: just content urls test <dev|staging>" >&2; exit 1; }; TARGET="$1" just test-url-rewrite ;;
          *) echo "Usage: just content urls normalize <env> <dry|apply> | test <env>" >&2; exit 1 ;;
        esac ;;
      *) echo "Usage: just content copy <source> <destination> | urls ..." >&2; exit 1 ;;
    esac

# Upload copies and specialist image maintenance.
media action *args:
    #!/usr/bin/env bash
    set -euo pipefail
    action="$1"; shift
    case "$action" in
      copy) [[ $# -eq 2 ]] || { echo "Usage: just media copy <source> <destination>" >&2; exit 1; }; bash scripts/copy-media.sh "$1-to-$2" ;;
      thumbnails) [[ $# -eq 2 && "$1" == regenerate ]] || { echo "Usage: just media thumbnails regenerate <env>" >&2; exit 1; }; shift; just regen-thumbs "$@" ;;
      originals) [[ $# -eq 2 && "$1" == downscale ]] || { echo "Usage: just media originals downscale <env>" >&2; exit 1; }; shift; just downscale-originals "$@" ;;
      derivatives) [[ $# -eq 3 && "$1" == copy && "$2" == staging && "$3" == production ]] || { echo "Usage: just media derivatives copy staging production" >&2; exit 1; }; just sync-regenerated-thumbnails-to-production ;;
      *) echo "Usage: just media copy|thumbnails regenerate|originals downscale|derivatives copy ..." >&2; exit 1 ;;
    esac

# Compatibility alias; prefer just stack watch dev.
dev-local:
    node scripts/plugin-dev.mjs

# ── Internal stack operations ──────────────────────────────────────────────────

# Pull the pinned image: services only (mariadb, caddy) and restart; does not touch built services
[private]
image-pull:
    docker compose pull && docker compose up -d

# ── Builds ─────────────────────────────────────────────────────────────────────

# deploy preview [scope]: static build from source (scope: full | events | <page-slug>)
# deploy staging: activate astro `staging` branch head with its locked webcomponents version
# deploy production [release_id]: promote healthy staging commit, or restore an archived release_id
# Deploy the Astro frontend: just frontend deploy preview|staging|production
[private]
deploy target="" arg="":
    #!/usr/bin/env bash
    set -euo pipefail
    case "{{ target }}" in
      preview)    bash scripts/trigger-build.sh preview "{{ arg }}" ;;
      staging)    bash scripts/deploy-staging.sh ;;
      production) bash scripts/deploy-release.sh production "{{ arg }}" ;;
      *) echo "Usage: just frontend deploy preview [scope] | staging | production [release_id]" >&2; exit 1 ;;
    esac

# Pin Astro and plugin lockfiles to webcomponents origin/main (review and commit both).
[private]
wc-pin:
    bash scripts/update-webcomponents-pin.sh

# Clear the selected Astro environment's Vite cache and restart it (dev | staging).
[private]
clear-vite-cache env:
    #!/usr/bin/env bash
    set -euo pipefail
    case "$1" in
      dev|staging) ;;
      *) echo "Usage: just frontend cache clear <dev|staging>" >&2; exit 1 ;;
    esac
    docker compose exec "astro-$1" rm -rf /app/node_modules/.vite
    docker compose restart "astro-$1"

# ── Data sync ──────────────────────────────────────────────────────────────────

# Rewrite other environments' hosts in <env> content. Mode is required: dry | apply
# Examples: just content urls normalize staging dry   |   just content urls normalize staging apply
[private]
rewrite-hosts env mode="":
    #!/usr/bin/env bash
    set -euo pipefail
    case "{{mode}}" in
      dry)   bash scripts/wp.sh {{env}} abcnorio normalize-urls ;;
      apply) bash scripts/wp.sh {{env}} abcnorio normalize-urls --apply ;;
      *)     echo "For data sanctity, please run with either 'dry' or 'apply'" >&2; exit 1 ;;
    esac

# Integration test of URL rewriting on a throwaway DB copy. TARGET=dev|staging (default dev)
[private]
test-url-rewrite:
    bash scripts/test-url-rewrite.sh

# ── Media ──────────────────────────────────────────────────────────────────────

# Regenerate thumbnails   e.g. just media thumbnails regenerate dev
[private]
regen-thumbs env:
    bash scripts/regen-thumbs.sh {{ env }}

# Back up production uploads, then replace generated image derivatives from staging.
# Run after staging thumbnail regeneration: just media derivatives copy staging production
[private]
sync-regenerated-thumbnails-to-production:
    bash scripts/sync-regenerated-thumbnails-to-production.sh

# One-off: downscale all upload originals to max 1600px   e.g. just media originals downscale staging
[private]
downscale-originals env:
    bash scripts/downscale-originals.sh {{ env }}

# ── DB admin ───────────────────────────────────────────────────────────────────

# Dump a database to backups/mariadb/   e.g. just db dump staging
[private]
dump-db env:
    bash scripts/dump-db.sh {{ env }}

# e.g. just db import dev ~/Downloads/staging-20261102.sql.gz
# Import a SQL dump (.sql or .sql.gz) into the local dev DB.
[private]
local-db-import file:
    #!/usr/bin/env bash
    set -euo pipefail
    source .env
    if [[ "$1" == *.gz ]]; then
      gunzip -c -- "$1"
    else
      cat -- "$1"
    fi | docker exec -i mariadb mariadb -u"$DEV_DB_USER" -p"$DEV_DB_PASSWORD" "$DEV_DB_NAME"
    echo "Imported. Set WP_HOME/WP_SITEURL in wp/dev.env to your local WP URL (see DEV_WP_PORT in .env) and disable FluentSMTP/Mailchimp locally."

# ── Composer ───────────────────────────────────────────────────────────────────

# Run host Composer in a Bedrock dir (env: dev or staging)
[private]
composer env *args:
    #!/usr/bin/env bash
    set -euo pipefail
    env="$1"; shift
    case "$env" in
        dev|staging) ;;
        *) echo "Unknown env: $env (expected dev or staging)" >&2; exit 1 ;;
    esac
    (cd "wp/$env/bedrock" && composer "$@")

# Copy live Bedrock composer files back to the bootstrap seed files (env: dev or staging)
[private]
bedrock-snapshot env:
        #!/usr/bin/env bash
        case "{{ env }}" in
            dev|staging) ;;
            *) echo "Unknown env: {{ env }} (expected dev or staging)"; exit 1 ;;
        esac
        cp "wp/{{ env }}/bedrock/composer.json" "wp/bootstrap/{{ env }}/bedrock.composer.json"
        cp "wp/{{ env }}/bedrock/composer.lock" "wp/bootstrap/{{ env }}/bedrock.composer.lock"
        echo "synced {{ env }} bedrock composer files back to seed"

# Update wpackagist plugins (wp-plugin/*) and reseed the bootstrap composer files.
# Excludes abcnorio-func (use just release staging) and vip-block-data-api (dev-trunk VCS repo; update by hand).   e.g. just wp plugins update dev
[private]
plugins-update env:
    #!/usr/bin/env bash
    set -euo pipefail
    case "{{ env }}" in
        dev|staging) ;;
        *) echo "Unknown env: {{ env }} (expected dev or staging)" >&2; exit 1 ;;
    esac
    (cd "wp/{{ env }}/bedrock" && composer update "wp-plugin/*" --with-dependencies)
    just bedrock-snapshot {{ env }}
    # Workers keep WordPress code in memory (OPcache on staging); restart to load the new code.
    docker restart abcwp{{ env }}
    echo "Review wp/bootstrap/{{ env }}/bedrock.composer.lock, then commit."

# Update WordPress core to a version and reseed the bootstrap composer files.   e.g. just wp core update dev 6.9.5
[private]
wp-core-update env version:
    #!/usr/bin/env bash
    set -euo pipefail
    case "{{ env }}" in
        dev|staging) ;;
        *) echo "Unknown env: {{ env }} (expected dev or staging)" >&2; exit 1 ;;
    esac
    (cd "wp/{{ env }}/bedrock" && composer require "roots/wordpress:{{ version }}" --update-with-dependencies)
    just bedrock-snapshot {{ env }}
    bash scripts/wp.sh {{ env }} core update-db
    # Workers keep WordPress code in memory (OPcache on staging); restart to load the new code.
    docker restart abcwp{{ env }}
    echo "Review wp/bootstrap/{{ env }}/bedrock.composer.lock, then commit."

# ── Plugin ─────────────────────────────────────────────────────────────────────

# Internal bootstrap for up dev when built assets are missing.
[private]
_plugin-dev-assets:
    #!/usr/bin/env bash
    set -euo pipefail
    WEBCOMPONENTS_DIST="$(cd ../abcnorio-webcomponents && pwd)/dist"
    (cd ../abcnorio-func && ABCNORIO_COMPONENTS_DIST_SOURCE="$WEBCOMPONENTS_DIST" npm run build)
    ABCNORIO_COMPONENTS_DIST_SOURCE="$WEBCOMPONENTS_DIST" node ../abcnorio-func/scripts/publish-components-dev.mjs

# Build a clean-room release zip for an abcnorio-func tag (defaults to current composer.json version).
# Writes to wp/plugin-artifacts/, consumed by Bedrock's Composer artifact repository.
# e.g. just plugin artifact build | just plugin artifact build v0.23.0
[private]
plugin-artifact tag="":
    bash scripts/build-plugin-release.sh {{tag}}

# Build the abcnorio-webcomponents package (dist + manifest generation/validation)
[private]
wc-build:
    cd ../abcnorio-webcomponents && npm run build

# Verify current webcomponents manifest contract without rebuilding
[private]
wc-verify:
    cd ../abcnorio-webcomponents && npm run check:manifest

# Scaffold a new webcomponent directory with starter Astro debug file.
# Usage:
#   just wc create event-card
#   just wc create cover --scope wp-blocks --wp-block core/cover
[private]
wc-create *args:
    bash ../abcnorio-webcomponents/scripts/create-webcomponent.sh "$@"

# Run PHP tests in the plugin (via bedrock dev container)
[private]
plugin-test:
    docker exec abcwpdev composer test --working-dir=/app/web/app/plugins/abcnorio-func
