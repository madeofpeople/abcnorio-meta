#!/usr/bin/env bash
# Fresh-machine install. Run from abcnorio-meta/.
# Usage: bash install.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE="$(dirname "$SCRIPT_DIR")"
FUNC_SOURCE_DIR="$WORKSPACE/abcnorio-func"

# --- 1. Install host packages ---
echo "==> Installing host packages..."
sudo apt-get update
sudo apt-get install -y git rsync composer nodejs npm just

# Repo URLs — edit repos.env before running on a new machine
# shellcheck source=repos.env
source "$SCRIPT_DIR/repos.env"

# --- 2. Clone sibling repos ---
echo "==> Cloning sibling repos..."
[ -d "$WORKSPACE/abcnorio-astro" ]        || git clone "$REPO_ASTRO"        "$WORKSPACE/abcnorio-astro"
[ -d "$WORKSPACE/abcnorio-func" ]         || git clone "$REPO_FUNC"         "$WORKSPACE/abcnorio-func"
[ -d "$WORKSPACE/abcnorio-orchestrator" ] || git clone "$REPO_ORCHESTRATOR" "$WORKSPACE/abcnorio-orchestrator"
[ -d "$WORKSPACE/abcnorio-docs" ]         || git clone "$REPO_DOCS"         "$WORKSPACE/abcnorio-docs"

# --- 3. Copy env samples ---
echo "==> Copying env samples..."
[ -f "$SCRIPT_DIR/.env" ] || { cp "$SCRIPT_DIR/.env.sample" "$SCRIPT_DIR/.env"; echo "    created: $SCRIPT_DIR/.env"; }
[ -f "$SCRIPT_DIR/wp/runtime.env" ] || { cp "$SCRIPT_DIR/wp/runtime.env.sample" "$SCRIPT_DIR/wp/runtime.env"; echo "    created: $SCRIPT_DIR/wp/runtime.env"; }
[ -f "$SCRIPT_DIR/wp/dev.env" ] || { cp "$SCRIPT_DIR/wp/dev.env.sample" "$SCRIPT_DIR/wp/dev.env"; echo "    created: $SCRIPT_DIR/wp/dev.env"; }
[ -f "$SCRIPT_DIR/wp/staging.env" ] || { cp "$SCRIPT_DIR/wp/staging.env.sample" "$SCRIPT_DIR/wp/staging.env"; echo "    created: $SCRIPT_DIR/wp/staging.env"; }
[ -f "$WORKSPACE/abcnorio-astro/site-dev/.env" ] || { cp "$WORKSPACE/abcnorio-astro/site-dev/.env.sample" "$WORKSPACE/abcnorio-astro/site-dev/.env"; echo "    created: $WORKSPACE/abcnorio-astro/site-dev/.env"; }
[ -f "$WORKSPACE/abcnorio-orchestrator/.env" ] || { cp "$WORKSPACE/abcnorio-orchestrator/.env.sample" "$WORKSPACE/abcnorio-orchestrator/.env"; echo "    created: $WORKSPACE/abcnorio-orchestrator/.env"; }

# --- 4. Bootstrap site-staging from site-dev (ephemeral, not tracked in git) ---
echo "==> Bootstrapping site-staging..."
SITE="$WORKSPACE/abcnorio-astro/site-dev"
STAGING="$WORKSPACE/abcnorio-astro/site-staging"
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
[ -f "$WORKSPACE/abcnorio-astro/site-staging/.env" ] || { cp "$WORKSPACE/abcnorio-astro/site-dev/.env.sample" "$WORKSPACE/abcnorio-astro/site-staging/.env"; echo "    created: $WORKSPACE/abcnorio-astro/site-staging/.env"; }

# --- 5. Bootstrap bedrock dirs ---
echo "==> Bootstrapping Bedrock..."
DEV_BEDROCK="$SCRIPT_DIR/wp/dev/bedrock"
DEV_SEED="$SCRIPT_DIR/wp/dev/bedrock.composer.json"
if [ ! -d "$DEV_BEDROCK" ]; then
    echo "[dev] scaffolding bedrock from roots/bedrock..."
    composer create-project roots/bedrock "$DEV_BEDROCK" --no-install --no-interaction

    echo "[dev] linking project composer.json..."
    ln -sf "$DEV_SEED" "$DEV_BEDROCK/composer.json"

    echo "[dev] symlinking abcnorio-func into packages/..."
    mkdir -p "$DEV_BEDROCK/packages"
    ln -sf "$FUNC_SOURCE_DIR" "$DEV_BEDROCK/packages/abcnorio-func"

    echo "[dev] running composer install..."
    (cd "$DEV_BEDROCK" && composer install)

    if [ ! -f "$DEV_BEDROCK/.env" ]; then
        cp "$DEV_BEDROCK/.env.example" "$DEV_BEDROCK/.env"
        echo "[dev] created .env from .env.example"
        echo "[dev] !! fill in $DEV_BEDROCK/.env with DB credentials, WP_HOME, and salts before starting the stack"
    fi

    echo "[dev] done"
else
    echo "[dev] bedrock directory already exists, skipping"
fi

STAGING_BEDROCK="$SCRIPT_DIR/wp/staging/bedrock"
STAGING_SEED="$SCRIPT_DIR/wp/staging/bedrock.composer.json"
if [ ! -d "$STAGING_BEDROCK" ]; then
    echo "[staging] scaffolding bedrock from roots/bedrock..."
    composer create-project roots/bedrock "$STAGING_BEDROCK" --no-install --no-interaction

    echo "[staging] linking project composer.json..."
    ln -sf "$STAGING_SEED" "$STAGING_BEDROCK/composer.json"

    echo "[staging] running composer install..."
    (cd "$STAGING_BEDROCK" && composer install)

    if [ ! -f "$STAGING_BEDROCK/.env" ]; then
        cp "$STAGING_BEDROCK/.env.example" "$STAGING_BEDROCK/.env"
        echo "[staging] created .env from .env.example"
        echo "[staging] !! fill in $STAGING_BEDROCK/.env with DB credentials, WP_HOME, and salts before starting the stack"
    fi

    echo "[staging] done"
else
    echo "[staging] bedrock directory already exists, skipping"
fi

# -- 6. Install rootless docker
bash "$SCRIPT_DIR/scripts/setup-rootless-docker.sh"

# -- 7. Install fail2ban
bash "$SCRIPT_DIR/scripts/setup-fail2ban.sh"

# --- 8. Done — list everything that needs credentials ---
echo "░▒▓██████▓▒░  ░▒▓███████▓▒░   ░▒▓██████▓▒░                          "
echo "░▒▓█▓▒░░▒▓█▓▒░ ░▒▓█▓▒░░▒▓█▓▒░ ░▒▓█▓▒░░▒▓█▓▒░                        "
echo "░▒▓█▓▒░░▒▓█▓▒░ ░▒▓█▓▒░░▒▓█▓▒░ ░▒▓█▓▒░                               "
echo "░▒▓████████▓▒░ ░▒▓███████▓▒░  ░▒▓█▓▒░                               "
echo "░▒▓█▓▒░░▒▓█▓▒░ ░▒▓█▓▒░░▒▓█▓▒░ ░▒▓█▓▒░                               "
echo "░▒▓█▓▒░░▒▓█▓▒░ ░▒▓█▓▒░░▒▓█▓▒░ ░▒▓█▓▒░░▒▓█▓▒░                        "
echo "░▒▓█▓▒░░▒▓█▓▒░ ░▒▓███████▓▒░   ░▒▓██████▓▒░                         "
echo "                                                                    "                                                             
echo "░▒▓███████▓▒░   ░▒▓██████▓▒░  ░▒▓███████▓▒░  ░▒▓█▓▒░  ░▒▓██████▓▒░  "
echo "░▒▓█▓▒░░▒▓█▓▒░ ░▒▓█▓▒░░▒▓█▓▒░ ░▒▓█▓▒░░▒▓█▓▒░ ░▒▓█▓▒░ ░▒▓█▓▒░░▒▓█▓▒░ "
echo "░▒▓█▓▒░░▒▓█▓▒░ ░▒▓█▓▒░░▒▓█▓▒░ ░▒▓█▓▒░░▒▓█▓▒░ ░▒▓█▓▒░ ░▒▓█▓▒░░▒▓█▓▒░ "
echo "░▒▓█▓▒░░▒▓█▓▒░ ░▒▓█▓▒░░▒▓█▓▒░ ░▒▓███████▓▒░  ░▒▓█▓▒░ ░▒▓█▓▒░░▒▓█▓▒░ "
echo "░▒▓█▓▒░░▒▓█▓▒░ ░▒▓█▓▒░░▒▓█▓▒░ ░▒▓█▓▒░░▒▓█▓▒░ ░▒▓█▓▒░ ░▒▓█▓▒░░▒▓█▓▒░ "
echo "░▒▓█▓▒░░▒▓█▓▒░ ░▒▓█▓▒░░▒▓█▓▒░ ░▒▓█▓▒░░▒▓█▓▒░ ░▒▓█▓▒░ ░▒▓█▓▒░░▒▓█▓▒░ "
echo "░▒▓█▓▒░░▒▓█▓▒░  ░▒▓██████▓▒░  ░▒▓█▓▒░░▒▓█▓▒░ ░▒▓█▓▒░  ░▒▓██████▓▒░  "                                                                                                                                  
echo ""
echo "Done. Fill in credentials in these files before running the stack:"
echo ""
echo "  abcnorio-meta/"
echo "  ├── .env                             # compose vars: host paths, domain names, secrets"
echo "  └── wp/"
echo "      ├── runtime.env                  # shared WP: salts, cache TTL"
echo "      ├── dev.env                      # dev WP: DB creds, WP_HOME, save-trigger vars"
echo "      ├── staging.env                  # staging WP: DB creds, WP_HOME, save-trigger vars"
echo "      ├── dev/bedrock/.env             # Bedrock dev: DB connection, WP_HOME, WP_SITEURL"
echo "      └── staging/bedrock/.env         # Bedrock staging: DB connection, WP_HOME, WP_SITEURL"
echo ""
echo "  abcnorio-astro/site-dev/"
echo "  └── .env                             # Astro: CMS URLs, REST endpoints, build trigger secret"
echo ""
echo "  abcnorio-orchestrator/"
echo "  └── .env                             # Orchestrator: port, manual trigger flag, max backups"
echo ""
echo "Then:"
echo "  just up                              # bring the full stack up"
echo "  just --list                          # see all available recipes"
echo ""
echo ""
echo "  # Visit WP_HOME/wp/wp-admin/install.php for each env, or restore a DB backup"
