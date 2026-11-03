#!/usr/bin/env bash
# Local dev setup (macOS or Linux). Needs only: docker, git, just.
# Clones the sibling repos, builds assets in throwaway Linux containers (same binaries as the server),
# scaffolds dev Bedrock, creates the external networks and writes env files.
# Safe to re-run. Run from anywhere: bash abcnorio-meta/scripts/local-setup.sh
# Server provisioning is install.sh; this script never uses sudo.

set -euo pipefail

META_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKSPACE_ROOT="$(dirname "$META_DIR")"
REPO_BASE="${REPO_BASE:-https://github.com/madeofpeople}"
# Same major as the server host; its npm also matches the committed lockfiles (npm ci fails on older npm).
NODE_IMAGE="node:lts"
COMPOSER_IMAGE="composer:2"

for tool in docker git just; do
    command -v "$tool" >/dev/null || { echo "Missing required tool: $tool" >&2; exit 1; }
done

clone() {
    [ -d "$WORKSPACE_ROOT/$1" ] || git clone "$REPO_BASE/$1.git" "$WORKSPACE_ROOT/$1"
}

# Runs a command in a throwaway Linux container with the workspace mounted at the same path.
in_node() {
    docker run --rm -v "$WORKSPACE_ROOT":"$WORKSPACE_ROOT" -w "$1" -e ABCNORIO_COMPONENTS_DIST_SOURCE="${ABCNORIO_COMPONENTS_DIST_SOURCE:-}" "$NODE_IMAGE" bash -c "$2"
}

copy_env() {
    [ -f "$2" ] || { cp "$1" "$2"; echo "    created: $2"; }
}

set_env() {
    local file="$1" key="$2" value="$3"
    sed "s|^${key}=.*|${key}=${value}|" "$file" > "$file.tmp" && mv "$file.tmp" "$file"
}

echo "==> Cloning sibling repos..."
for repo in abcnorio-astro abcnorio-func abcnorio-webcomponents abcnorio-orchestrator; do
    clone "$repo"
done

echo "==> Building abcnorio-webcomponents..."
in_node "$WORKSPACE_ROOT/abcnorio-webcomponents" "npm install && npm run build && npm run check:manifest"

echo "==> Installing abcnorio-func autoloader and building its assets..."
docker run --rm -v "$WORKSPACE_ROOT":"$WORKSPACE_ROOT" -w "$WORKSPACE_ROOT/abcnorio-func" "$COMPOSER_IMAGE" install --no-dev --optimize-autoloader
ABCNORIO_COMPONENTS_DIST_SOURCE="$WORKSPACE_ROOT/abcnorio-webcomponents/dist" \
    in_node "$WORKSPACE_ROOT/abcnorio-func" "npm ci && npm run build"

echo "==> Creating external Docker networks..."
for net in abcnorio_net_proxy abcnorio_net_web; do
    docker network inspect "$net" >/dev/null 2>&1 || docker network create "$net"
done

echo "==> Copying env samples..."
copy_env "$META_DIR/.env.sample" "$META_DIR/.env"
copy_env "$META_DIR/wp/runtime.env.sample" "$META_DIR/wp/runtime.env"
copy_env "$META_DIR/wp/dev.env.sample" "$META_DIR/wp/dev.env"
copy_env "$WORKSPACE_ROOT/abcnorio-astro/site-frontend/.env.sample" "$WORKSPACE_ROOT/abcnorio-astro/site-frontend/.env.development"
# Compose parses every service's env_file even when only the dev profile runs, so the unused ones must exist.
copy_env "$META_DIR/wp/staging.env.sample" "$META_DIR/wp/staging.env"
copy_env "$WORKSPACE_ROOT/abcnorio-astro/site-frontend/.env.sample" "$WORKSPACE_ROOT/abcnorio-astro/site-frontend/.env.staging"
copy_env "$WORKSPACE_ROOT/abcnorio-orchestrator/.env.sample" "$WORKSPACE_ROOT/abcnorio-orchestrator/.env"
mkdir -p "$META_DIR/build/astro/build-archives"

echo "==> Setting workspace paths and local URLs in .env..."
set_env "$META_DIR/.env" DEV_HOST_ROOT "$META_DIR/wp/dev/"
set_env "$META_DIR/.env" STAGING_HOST_ROOT "$META_DIR/wp/staging/"
set_env "$META_DIR/.env" ASTRO_HOST_ROOT "$WORKSPACE_ROOT/abcnorio-astro"
set_env "$META_DIR/.env" ASTRO_SITE_DIR "$WORKSPACE_ROOT/abcnorio-astro/site-frontend"
set_env "$META_DIR/.env" ASTRO_BUILD_WORKDIR_HOST_DIR "$META_DIR/build/astro"
set_env "$META_DIR/.env" ASTRO_BUILD_ARCHIVE_HOST_DIR "$META_DIR/build/astro/build-archives"
set_env "$META_DIR/.env" ASTRO_WEBCOMPONENTS_DIR "$WORKSPACE_ROOT/abcnorio-webcomponents"
set_env "$META_DIR/.env" ORCHESTRATOR_HOST_DIR "$WORKSPACE_ROOT/abcnorio-orchestrator"
set_env "$META_DIR/.env" ABCNORIO_FUNC_HOST_DIR "$WORKSPACE_ROOT/abcnorio-func"
set_env "$META_DIR/.env" DOMAIN_DEV_CMS "http://localhost:8101/"

echo "==> Scaffolding dev Bedrock..."
bash "$META_DIR/scripts/bedrock-bootstrap.sh" dev

echo ""
echo "Local setup done. Next:"
echo "  1. Fill in abcnorio-meta/.env: DEV_DB_* and STAGING_DB_* (mariadb reads both; any values work locally), ASTRO_BUILD_TRIGGER_SECRET."
echo "  2. Fill in wp/runtime.env, wp/dev.env (DB_NAME/DB_USER/DB_PASSWORD matching DEV_DB_*, salts), and wp/dev/bedrock/.env."
echo "  3. cd abcnorio-meta && just up dev"
echo "  4. just local-db-import path/to/staging-dump.sql.gz   (see the local dev doc)"
