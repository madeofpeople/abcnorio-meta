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

ensure_webcomponents_artifacts() {
    local webcomponents_dir="$WORKSPACE_ROOT/abcnorio-webcomponents"

    if [ ! -d "$webcomponents_dir" ]; then
        echo "==> abcnorio-webcomponents missing; cannot build webcomponents dist" >&2
        exit 1
    fi

    echo "==> Installing abcnorio-webcomponents dependencies..."
    (cd "$webcomponents_dir" && npm install)

    echo "==> Building abcnorio-webcomponents library artifacts..."
    (cd "$webcomponents_dir" && npm run build:lib)

    if [ ! -f "$webcomponents_dir/dist/fixtures-manifest.json" ]; then
        echo "==> Missing fixtures-manifest.json after webcomponents build" >&2
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

# --- 4. Bootstrap site-staging from site-dev (ephemeral, not tracked in git) ---
echo "==> Bootstrapping site-staging..."
SITE="$WORKSPACE_ROOT/abcnorio-astro/site-dev"
STAGING="$WORKSPACE_ROOT/abcnorio-astro/site-staging"
if [ ! -d "$STAGING" ]; then
    rsync -a \
        --exclude='.git' \
        --exclude='node_modules' \
        --exclude='.astro' \
        --exclude='dist' \
        --exclude='build-archives' \
        --exclude='.env' \
        "$SITE/" "$STAGING/"
    echo "    bootstrapped: $STAGING"
else
    echo "    exists (skipped): $STAGING"
fi

# site-staging may have been created by bootstrap above.
[ -f "$WORKSPACE_ROOT/abcnorio-astro/site-staging/.env" ] || { cp "$WORKSPACE_ROOT/abcnorio-astro/site-dev/.env.sample" "$WORKSPACE_ROOT/abcnorio-astro/site-staging/.env"; echo "    created: $WORKSPACE_ROOT/abcnorio-astro/site-staging/.env"; }

# --- 5. Bootstrap bedrock dirs ---
echo "==> Bootstrapping Bedrock..."
bash "$SCRIPT_DIR/scripts/bedrock-bootstrap.sh"

# -- 6. Install rootless docker
bash "$SCRIPT_DIR/scripts/setup-rootless-docker.sh"

# -- 7. Bring stack up
echo "==> Bringing stack up (full rebuild)..."
export DOCKER_HOST="unix:///run/user/$(id -u)/docker.sock"
(cd "$SCRIPT_DIR" && docker compose up -d --build)

echo "==> Aligning dev plugin symlink to runtime contract..."
(cd "$SCRIPT_DIR" && docker compose exec -T abcwpdev sh -lc 'set -euo pipefail; mkdir -p /app/packages; rm -f /app/packages/abcnorio-func; ln -s /abcnorio-func /app/packages/abcnorio-func; cd /app && composer reinstall madeofpeople/abcnorio-func --no-interaction')

if should_activate_plugin dev; then
    echo "==> Activating abcnorio-func in dev..."
    bash "$SCRIPT_DIR/scripts/wp.sh" dev plugin activate abcnorio-func
fi

ensure_headless_theme_active dev

if bash "$SCRIPT_DIR/scripts/wp.sh" dev core is-installed >/dev/null 2>&1 && bash "$SCRIPT_DIR/scripts/wp.sh" dev plugin is-active abcnorio-func >/dev/null 2>&1; then
    echo "==> Seeding minimal content in dev..."
    bash "$SCRIPT_DIR/scripts/wp.sh" dev abcnorio seed-minimal
fi

if should_activate_plugin staging; then
    echo "==> Activating abcnorio-func in staging..."
    bash "$SCRIPT_DIR/scripts/wp.sh" staging plugin activate abcnorio-func
fi

ensure_headless_theme_active staging

if bash "$SCRIPT_DIR/scripts/wp.sh" staging core is-installed >/dev/null 2>&1 && bash "$SCRIPT_DIR/scripts/wp.sh" staging plugin is-active abcnorio-func >/dev/null 2>&1; then
    echo "==> Seeding minimal content in staging..."
    bash "$SCRIPT_DIR/scripts/wp.sh" staging abcnorio seed-minimal
fi

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
echo "After install or restore, activate and seed if needed:"
echo "  just wp dev plugin activate abcnorio-func"
echo "  just wp dev abcnorio seed-minimal"
echo "  just wp staging plugin activate abcnorio-func"
echo "  just wp staging abcnorio seed-minimal"
echo ""
echo "Dev Astro expects active abcnorio-func and real or seeded REST content."
echo "Staging and production frontend paths remain incomplete until deployments run."
echo "astro-prod restarting before first deployment is expected."
