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
LOCAL_WP_PORT=8201
LOCAL_ASTRO_PORT=3133

for tool in docker git just; do
    command -v "$tool" >/dev/null || { echo "Missing required tool: $tool" >&2; exit 1; }
done

docker info >/dev/null 2>&1 || { echo "Docker daemon not reachable. Start Docker Desktop or OrbStack and rerun." >&2; exit 1; }

# Optional 2nd arg: branch. Plugin work lives on abcnorio-func's dev branch; its default branch (main) lags behind.
clone() {
    [ -d "$WORKSPACE_ROOT/$1" ] || git clone ${2:+-b "$2"} "$REPO_BASE/$1.git" "$WORKSPACE_ROOT/$1"
}

# Runs a command in a throwaway Linux container with the workspace mounted at the same path.
in_node() {
    docker run --rm -v "$WORKSPACE_ROOT":"$WORKSPACE_ROOT" -w "$1" "$NODE_IMAGE" bash -c "$2"
}

copy_env() {
    [ -f "$2" ] || { cp "$1" "$2"; echo "    created: $2"; }
}

# Random alphanumeric only: compose and the shell parse '$' and quotes differently.
rand() { LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c "$1"; }

# Replaces a value only while it is still a sample placeholder, so reruns keep existing credentials.
fill() {
    grep -q "^$2=\(your-\|generate\)" "$1" && set_env "$1" "$2" "$3" || true
}

env_val() { sed -n "s/^$2=//p" "$1"; }

set_env() {
    local file="$1" key="$2" value="$3"
    sed "s|^${key}=.*|${key}=${value}|" "$file" > "$file.tmp" && mv "$file.tmp" "$file"
}

echo "==> Cloning sibling repos..."
clone abcnorio-func dev
for repo in abcnorio-astro abcnorio-webcomponents abcnorio-orchestrator; do
    clone "$repo"
done

echo "==> Building abcnorio-webcomponents..."
in_node "$WORKSPACE_ROOT/abcnorio-webcomponents" "npm install && npm run build && npm run check:manifest"

echo "==> Installing abcnorio-func autoloader and building its assets..."
docker run --rm -v "$WORKSPACE_ROOT":"$WORKSPACE_ROOT" -w "$WORKSPACE_ROOT/abcnorio-func" "$COMPOSER_IMAGE" install --no-dev --optimize-autoloader
in_node "$WORKSPACE_ROOT/abcnorio-func" "npm ci && ABCNORIO_COMPONENTS_DIST_SOURCE=$WORKSPACE_ROOT/abcnorio-webcomponents/dist npm run build"
[ -d "$WORKSPACE_ROOT/abcnorio-func/build/calendar" ] || { echo "abcnorio-func/build/calendar missing: abcnorio-func must be on its dev branch (git -C ../abcnorio-func checkout dev) and rerun." >&2; exit 1; }

echo "==> Creating external Docker networks..."
for net in abcnorio_net_proxy abcnorio_net_web; do
    docker network inspect "$net" >/dev/null 2>&1 || docker network create "$net"
done

echo "==> Copying env samples..."
copy_env "$META_DIR/.env.sample" "$META_DIR/.env"
copy_env "$META_DIR/wp/runtime.env.sample" "$META_DIR/wp/runtime.env"
copy_env "$META_DIR/wp/dev.env.sample" "$META_DIR/wp/dev.env"
copy_env "$WORKSPACE_ROOT/abcnorio-astro/site-frontend/.env.sample" "$WORKSPACE_ROOT/abcnorio-astro/site-frontend/.env.development"
mkdir -p "$META_DIR/build/astro/build-archives"

echo "==> Setting workspace paths and local URLs in .env..."
ENV="$META_DIR/.env"
set_env "$ENV" DEV_HOST_ROOT "$META_DIR/wp/dev/"
set_env "$ENV" STAGING_HOST_ROOT "$META_DIR/wp/staging/"
set_env "$ENV" ASTRO_HOST_ROOT "$WORKSPACE_ROOT/abcnorio-astro"
set_env "$ENV" ASTRO_SITE_DIR "$WORKSPACE_ROOT/abcnorio-astro/site-frontend"
set_env "$ENV" ASTRO_BUILD_WORKDIR_HOST_DIR "$META_DIR/build/astro"
set_env "$ENV" ASTRO_BUILD_ARCHIVE_HOST_DIR "$META_DIR/build/astro/build-archives"
set_env "$ENV" ASTRO_WEBCOMPONENTS_DIR "$WORKSPACE_ROOT/abcnorio-webcomponents"
set_env "$ENV" ORCHESTRATOR_HOST_DIR "$WORKSPACE_ROOT/abcnorio-orchestrator"
set_env "$ENV" ABCNORIO_FUNC_HOST_DIR "$WORKSPACE_ROOT/abcnorio-func"
# Host ports differ from the server's (8101/3033) so they never collide with an SSH/VS Code tunnel to it.
set_env "$ENV" DOMAIN_DEV_CMS "http://localhost:$LOCAL_WP_PORT/"
grep -q '^COMPOSE_FILE=' "$ENV" || printf '\n# Local overrides (scripts/local-setup.sh)\nCOMPOSE_FILE=compose.yml:compose.local.yml\nDEV_WP_PORT=%s\nDEV_ASTRO_PORT=%s\n' "$LOCAL_WP_PORT" "$LOCAL_ASTRO_PORT" >> "$ENV"

echo "==> Generating local credentials (only where still a sample placeholder)..."
fill "$ENV" ASTRO_BUILD_TRIGGER_SECRET "$(rand 32)"
fill "$ENV" DEV_DB_USER abcdev
fill "$ENV" DEV_DB_PASSWORD "$(rand 24)"
fill "$ENV" DEV_DB_NAME abc_dev
fill "$ENV" STAGING_DB_USER abcstaging
fill "$ENV" STAGING_DB_PASSWORD "$(rand 24)"
fill "$ENV" STAGING_DB_NAME abc_staging
fill "$ENV" STAGING_DB_ROOT_PASSWORD "$(rand 24)"
set_env "$ENV" LOCAL_DB_PORT 3309

# Read back what is actually in .env so wp/*.env always match it, including on reruns.
set_env "$META_DIR/wp/runtime.env" DB_USER "$(env_val "$ENV" DEV_DB_USER)"
set_env "$META_DIR/wp/runtime.env" DB_PASSWORD "$(env_val "$ENV" DEV_DB_PASSWORD)"
set_env "$META_DIR/wp/runtime.env" ASTRO_BUILD_ARCHIVE_DIR /app/backups
fill "$META_DIR/wp/runtime.env" MAILCHIMP_SF_ENCRYPTION_KEY "$(rand 32)"
fill "$META_DIR/wp/runtime.env" MAILCHIMP_SF_ENCRYPTION_SALT "$(rand 32)"
set_env "$META_DIR/wp/dev.env" DB_NAME "$(env_val "$ENV" DEV_DB_NAME)"
set_env "$META_DIR/wp/dev.env" WP_HOME "http://localhost:$LOCAL_WP_PORT"
set_env "$META_DIR/wp/dev.env" WP_SITEURL "http://localhost:$LOCAL_WP_PORT/wp"
for key in AUTH_KEY SECURE_AUTH_KEY LOGGED_IN_KEY NONCE_KEY AUTH_SALT SECURE_AUTH_SALT LOGGED_IN_SALT NONCE_SALT; do
    fill "$META_DIR/wp/dev.env" "$key" "$(rand 48)"
done

echo "==> Scaffolding dev Bedrock..."
bash "$META_DIR/scripts/bedrock-bootstrap.sh" dev

echo "==> Applying uploads permissions contract (setgid, project uid:gid)..."
mkdir -p "$META_DIR/wp/dev/bedrock/web/app/uploads"
docker run --rm -v "$META_DIR/wp/dev/bedrock/web/app/uploads":/u alpine sh -c "chown $(env_val "$ENV" PROJECT_UID):$(env_val "$ENV" PROJECT_GID) /u && chmod 2775 /u"

echo ""
echo "Local setup done. Next:"
echo "  1. cd abcnorio-meta && just up dev"
echo "  2. just local-db-import path/to/dump.sql.gz   (see the local dev doc)"
echo "  3. bash scripts/local-smoke.sh"
