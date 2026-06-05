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

# --- 3. Copy env samples ---
echo "==> Copying env samples..."
[ -f "$SCRIPT_DIR/.env" ] || { cp "$SCRIPT_DIR/.env.sample" "$SCRIPT_DIR/.env"; echo "    created: $SCRIPT_DIR/.env"; }
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
