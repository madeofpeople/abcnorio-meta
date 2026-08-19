#!/usr/bin/env bash
# Fresh-machine install. Run from abcnorio-meta/.
# Usage: bash install.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" #where was the script run from
WORKSPACE_ROOT="$(dirname "$SCRIPT_DIR")"

# Repo URLs. Edit here if this machine should install forks instead.
REPO_ASTRO="git@github.com:madeofpeople/abcnorio-astro.git"
REPO_FUNC="git@github.com:madeofpeople/abcnorio-func.git"
REPO_ORCHESTRATOR="git@github.com:madeofpeople/abcnorio-orchestrator.git"
REPO_DOCS="git@github.com:madeofpeople/abcnorio-docs.git"
REPO_WEBCOMPONENTS="git@github.com:madeofpeople/abcnorio-webcomponents.git"

SHARED_UID=1000
SHARED_GID=2000
SHARED_GROUP="abcnorio"
STAGING_TAG_PREFIX="staging-deploy"
ASTRO_SOURCE_BRANCH="main"

load_compose_env() {
    if [[ ! -f "$SCRIPT_DIR/.env" ]]; then
        echo "==> Missing $SCRIPT_DIR/.env" >&2
        echo "    Create it first (or run install without migrate-permissions-once)." >&2
        exit 1
    fi

    # shellcheck disable=SC1091
    source "$SCRIPT_DIR/.env"
}

ensure_shared_group_contract() {
    local existing_group
    existing_group="$(getent group "$SHARED_GID" | cut -d: -f1 || true)"

    if [[ -n "$existing_group" && "$existing_group" != "$SHARED_GROUP" ]]; then
        echo "==> Host GID $SHARED_GID belongs to group '$existing_group', expected '$SHARED_GROUP'." >&2
        echo "    Resolve this collision manually before continuing." >&2
        exit 1
    fi

    if getent group "$SHARED_GROUP" >/dev/null 2>&1; then
        local name_gid
        name_gid="$(getent group "$SHARED_GROUP" | cut -d: -f3)"
        if [[ "$name_gid" != "$SHARED_GID" ]]; then
            echo "==> Group '$SHARED_GROUP' exists with GID $name_gid, expected $SHARED_GID." >&2
            echo "    Resolve this mismatch manually before continuing." >&2
            exit 1
        fi
        return
    fi

    echo "==> Creating shared host group $SHARED_GROUP:$SHARED_GID"
    sudo groupadd -g "$SHARED_GID" "$SHARED_GROUP"
}

apply_upload_permissions_contract() {
    load_compose_env

    local dev_uploads staging_uploads
    dev_uploads="${DEV_HOST_ROOT%/}/bedrock/web/app/uploads"
    staging_uploads="${STAGING_HOST_ROOT%/}/bedrock/web/app/uploads"

    ensure_shared_group_contract

    for uploads_dir in "$dev_uploads" "$staging_uploads"; do
        echo "==> Applying uploads contract to $uploads_dir"
        sudo install -d -o "$SHARED_UID" -g "$SHARED_GID" -m 2775 "$uploads_dir"
        sudo chown -R "$SHARED_UID:$SHARED_GID" "$uploads_dir"
        sudo find "$uploads_dir" -type d -exec chmod 2775 {} +
        sudo find "$uploads_dir" -type f -exec chmod 0664 {} +
    done
}

if [[ "${1:-}" == "migrate-permissions-once" ]]; then
    echo "==> Running one-time uploads permissions migration"
    apply_upload_permissions_contract
    echo "==> One-time migration complete"
    exit 0
fi

ensure_webcomponents_artifacts() {
    local webcomponents_dir="$WORKSPACE_ROOT/abcnorio-webcomponents"

    if [ ! -d "$webcomponents_dir" ]; then
        echo "==> abcnorio-webcomponents missing; cannot build webcomponents dist" >&2
        exit 1
    fi

    echo "==> Installing abcnorio-webcomponents dependencies..."
    (cd "$webcomponents_dir" && npm install)

    echo "==> Building abcnorio-webcomponents library artifacts for site-dev workshop and WP ingestion..."
    (cd "$webcomponents_dir" && npm run build)

    echo "==> Validating abcnorio-webcomponents manifest contract..."
    (cd "$webcomponents_dir" && npm run check:manifest)

    if [ ! -f "$webcomponents_dir/dist/manifest.json" ]; then
        echo "==> Missing manifest.json after webcomponents build" >&2
        exit 1
    fi
}

should_activate_plugin() {
    local env="$1"

    if ! bash "$SCRIPT_DIR/scripts/wp.sh" "$env" core is-installed >/dev/null 2>&1; then
        echo "==> $env WordPress not installed yet; after install or DB restore run: just wp $env plugin activate abcnorio-func"
        return 1
    fi

    if bash "$SCRIPT_DIR/scripts/wp.sh" "$env" plugin is-active abcnorio-func >/dev/null 2>&1; then
        echo "==> abcnorio-func already active in $env"
        return 1
    fi

    return 0
}

ensure_headless_theme_active() {
    local env="$1"

    if ! bash "$SCRIPT_DIR/scripts/wp.sh" "$env" core is-installed >/dev/null 2>&1; then
        echo "==> $env WordPress not installed yet; skip headless theme activation"
        return
    fi

    if ! bash "$SCRIPT_DIR/scripts/wp.sh" "$env" theme is-installed headless >/dev/null 2>&1; then
        echo "==> $env missing headless theme; rerun: bash scripts/bedrock-bootstrap.sh" >&2
        return
    fi

    if bash "$SCRIPT_DIR/scripts/wp.sh" "$env" theme is-active headless >/dev/null 2>&1; then
        echo "==> headless theme already active in $env"
        return
    fi

    echo "==> Activating headless theme in $env..."
    bash "$SCRIPT_DIR/scripts/wp.sh" "$env" theme activate headless
}

bootstrap_site_staging_from_tag() {
    local astro_repo="$WORKSPACE_ROOT/abcnorio-astro"
    local staging_dir="$astro_repo/site-staging"
    local latest_tag=""
    local current_branch=""
    local commit_sha=""
    local short_sha=""
    local tag_date=""

    if [[ ! -d "$astro_repo/.git" ]]; then
        echo "==> Missing git repo at $astro_repo" >&2
        exit 1
    fi

    if [[ -n "$(git -C "$astro_repo" status --porcelain)" ]]; then
        echo "==> abcnorio-astro working tree is dirty" >&2
        exit 1
    fi

    current_branch="$(git -C "$astro_repo" rev-parse --abbrev-ref HEAD)"
    if [[ "$current_branch" != "$ASTRO_SOURCE_BRANCH" ]]; then
        echo "==> Expected abcnorio-astro branch '$ASTRO_SOURCE_BRANCH', found '$current_branch'" >&2
        exit 1
    fi

    latest_tag="$(git -C "$astro_repo" for-each-ref --sort=-creatordate --format='%(refname:strip=2)' "refs/tags/${STAGING_TAG_PREFIX}-*" | head -n 1)"

    if [[ -z "$latest_tag" ]]; then
        commit_sha="$(git -C "$astro_repo" rev-parse --verify HEAD)"
        short_sha="${commit_sha:0:7}"
        tag_date="$(date -u +%Y-%m-%d)"
        latest_tag="${STAGING_TAG_PREFIX}-${tag_date}-${short_sha}"

        echo "==> No ${STAGING_TAG_PREFIX}-* tag found; creating $latest_tag from main HEAD"
        git -C "$astro_repo" tag -a "$latest_tag" "$commit_sha" -m "Staging deploy approval ${tag_date} ${short_sha}"
        git -C "$astro_repo" push origin "$latest_tag"
    fi

    commit_sha="$(git -C "$astro_repo" rev-parse --verify "${latest_tag}^{commit}")"

    if [[ ! -d "$staging_dir" ]]; then
        mkdir -p "$staging_dir"
        git -C "$astro_repo" archive --format=tar "$latest_tag" site-dev | tar -xf - -C "$staging_dir" --strip-components=1

        [[ -f "$staging_dir/package.json" ]] || { echo "==> staging bootstrap contract failed: missing package.json" >&2; exit 1; }
        [[ -f "$staging_dir/astro.config.mjs" ]] || { echo "==> staging bootstrap contract failed: missing astro.config.mjs" >&2; exit 1; }
        [[ -f "$staging_dir/src/pages/index.astro" ]] || { echo "==> staging bootstrap contract failed: missing src/pages/index.astro" >&2; exit 1; }

        echo "    bootstrapped: $staging_dir"
        echo "    source_tag: $latest_tag"
        echo "    source_commit: $commit_sha"
        return
    fi

    echo "    exists (skipped): $staging_dir"
    echo "    current_bootstrap_source_tag: $latest_tag"
    echo "    current_bootstrap_source_commit: $commit_sha"
}

# --- 1. Install host packages ---
echo "==> Installing host packages..."
sudo apt-get update
sudo apt-get install -y git rsync composer nodejs npm just unzip php-zip php-xml php-curl curl

# --- 2. Clone sibling repos ---
echo "==> Cloning sibling repos..."
[ -d "$WORKSPACE_ROOT/abcnorio-astro" ]        || git clone "$REPO_ASTRO"        "$WORKSPACE_ROOT/abcnorio-astro"
[ -d "$WORKSPACE_ROOT/abcnorio-func" ]         || git clone "$REPO_FUNC"         "$WORKSPACE_ROOT/abcnorio-func"
[ -d "$WORKSPACE_ROOT/abcnorio-orchestrator" ] || git clone "$REPO_ORCHESTRATOR" "$WORKSPACE_ROOT/abcnorio-orchestrator"
[ -d "$WORKSPACE_ROOT/abcnorio-docs" ]         || git clone "$REPO_DOCS"         "$WORKSPACE_ROOT/abcnorio-docs"
[ -d "$WORKSPACE_ROOT/abcnorio-webcomponents" ] || git clone "$REPO_WEBCOMPONENTS" "$WORKSPACE_ROOT/abcnorio-webcomponents"

ensure_webcomponents_artifacts

# --- 3. Copy env samples ---
echo "==> Copying env samples..."
[ -f "$SCRIPT_DIR/.env" ] || { 
    cp "$SCRIPT_DIR/.env.sample" "$SCRIPT_DIR/.env"; echo "    created: $SCRIPT_DIR/.env"; 
    }
[ -f "$SCRIPT_DIR/wp/runtime.env" ] || { cp "$SCRIPT_DIR/wp/runtime.env.sample" "$SCRIPT_DIR/wp/runtime.env"; echo "    created: $SCRIPT_DIR/wp/runtime.env"; }
[ -f "$SCRIPT_DIR/wp/dev.env" ] || { cp "$SCRIPT_DIR/wp/dev.env.sample" "$SCRIPT_DIR/wp/dev.env"; echo "    created: $SCRIPT_DIR/wp/dev.env"; }
[ -f "$SCRIPT_DIR/wp/staging.env" ] || { cp "$SCRIPT_DIR/wp/staging.env.sample" "$SCRIPT_DIR/wp/staging.env"; echo "    created: $SCRIPT_DIR/wp/staging.env"; }
[ -f "$WORKSPACE_ROOT/abcnorio-astro/site-dev/.env" ] || { cp "$WORKSPACE_ROOT/abcnorio-astro/site-dev/.env.sample" "$WORKSPACE_ROOT/abcnorio-astro/site-dev/.env"; echo "    created: $WORKSPACE_ROOT/abcnorio-astro/site-dev/.env"; }
[ -f "$WORKSPACE_ROOT/abcnorio-orchestrator/.env" ] || { cp "$WORKSPACE_ROOT/abcnorio-orchestrator/.env.sample" "$WORKSPACE_ROOT/abcnorio-orchestrator/.env"; echo "    created: $WORKSPACE_ROOT/abcnorio-orchestrator/.env"; }
mkdir -p "$SCRIPT_DIR/build/astro/build-archives"

# --- 4. Bootstrap site-staging from approved staging tag (ephemeral, not tracked in git) ---
echo "==> Bootstrapping site-staging..."
bootstrap_site_staging_from_tag

# site-staging may have been created by bootstrap above.
[ -f "$WORKSPACE_ROOT/abcnorio-astro/site-staging/.env" ] || { cp "$WORKSPACE_ROOT/abcnorio-astro/site-dev/.env.sample" "$WORKSPACE_ROOT/abcnorio-astro/site-staging/.env"; echo "    created: $WORKSPACE_ROOT/abcnorio-astro/site-staging/.env"; }

# --- 5. Bootstrap bedrock dirs ---
echo "==> Bootstrapping Bedrock..."
bash "$SCRIPT_DIR/scripts/bedrock-bootstrap.sh"

echo "==> Applying deterministic uploads permissions contract..."
apply_upload_permissions_contract

# -- 6. Install rootless docker
bash "$SCRIPT_DIR/scripts/setup-rootless-docker.sh"

# -- 7. Bring stack up
echo "==> Bringing stack up (full rebuild)..."
export DOCKER_HOST="unix:///run/user/$(id -u)/docker.sock"
(cd "$SCRIPT_DIR" && docker compose up -d --build)

echo "==> Validating dev plugin mount contract..."
(cd "$SCRIPT_DIR" && docker compose exec -T abcwpdev sh -lc 'set -euo pipefail; test -f /app/web/app/plugins/abcnorio-func/custom-func.php')

if should_activate_plugin dev; then
    echo "==> Activating abcnorio-func in dev..."
    bash "$SCRIPT_DIR/scripts/wp.sh" dev plugin activate abcnorio-func
fi

ensure_headless_theme_active dev

if should_activate_plugin staging; then
    echo "==> Activating abcnorio-func in staging..."
    bash "$SCRIPT_DIR/scripts/wp.sh" staging plugin activate abcnorio-func
fi

ensure_headless_theme_active staging

# -- 8. Install fail2ban
bash "$SCRIPT_DIR/scripts/setup-fail2ban.sh"

# --- 9. Done ---
echo ""
echo "Install complete. Fill in credentials before first real use:"
echo "  - abcnorio-meta/.env"
echo "  - abcnorio-meta/wp/runtime.env"
echo "  - abcnorio-meta/wp/dev.env"
echo "  - abcnorio-meta/wp/staging.env"
echo "  - abcnorio-meta/wp/dev/bedrock/.env"
echo "  - abcnorio-meta/wp/staging/bedrock/.env"
echo "  - abcnorio-astro/site-dev/.env"
echo "  - abcnorio-orchestrator/.env"
echo ""
echo "Then run:"
echo "  just up"
echo "  just --list"
echo ""
echo "For fresh WordPress trees, visit each env's /wp/wp-admin/install.php or restore a DB backup."
echo "After install or restore, activate plugin if needed:"
echo "  just wp dev plugin activate abcnorio-func"
echo "  just wp staging plugin activate abcnorio-func"
echo ""
echo "Dev Astro expects active abcnorio-func and real REST content."
echo "Staging and production frontend paths remain incomplete until deployments run."
echo "astro-prod restarting before first deployment is expected."
