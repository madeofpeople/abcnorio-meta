#!/usr/bin/env bash
# Fresh-machine install. Run from abcnorio-meta/.
# Usage: bash install.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE="$(dirname "$SCRIPT_DIR")"

# Repo URLs — edit repos.env before running on a new machine
# shellcheck source=repos.env
source "$SCRIPT_DIR/repos.env"

# --- 1. Clone sibling repos ---
echo "==> Cloning sibling repos..."
[ -d "$WORKSPACE/abcnorio-astro" ]        || git clone "$REPO_ASTRO"        "$WORKSPACE/abcnorio-astro"
[ -d "$WORKSPACE/abcnorio-func" ]         || git clone "$REPO_FUNC"         "$WORKSPACE/abcnorio-func"
[ -d "$WORKSPACE/abcnorio-orchestrator" ] || git clone "$REPO_ORCHESTRATOR" "$WORKSPACE/abcnorio-orchestrator"
[ -d "$WORKSPACE/abcnorio-docs" ]         || git clone "$REPO_DOCS"         "$WORKSPACE/abcnorio-docs"

# --- 2. Copy env samples ---
echo "==> Copying env samples..."
copy_sample() {
    local src="$1" dest="$2"
    if [ ! -f "$dest" ]; then
        cp "$src" "$dest"
        echo "    created: $dest"
    else
        echo "    exists (skipped): $dest"
    fi
}

copy_sample "$SCRIPT_DIR/.env.sample"                                "$SCRIPT_DIR/.env"
copy_sample "$SCRIPT_DIR/wp/runtime.env.sample"                      "$SCRIPT_DIR/wp/runtime.env"
copy_sample "$SCRIPT_DIR/wp/dev.env.sample"                          "$SCRIPT_DIR/wp/dev.env"
copy_sample "$SCRIPT_DIR/wp/staging.env.sample"                      "$SCRIPT_DIR/wp/staging.env"
copy_sample "$WORKSPACE/abcnorio-astro/site/.env.sample"             "$WORKSPACE/abcnorio-astro/site/.env"
copy_sample "$WORKSPACE/abcnorio-astro/site/.env.sample"             "$WORKSPACE/abcnorio-astro/site-staging/.env"
copy_sample "$WORKSPACE/abcnorio-orchestrator/.env.sample"           "$WORKSPACE/abcnorio-orchestrator/.env"

# --- 3. Bootstrap site-staging from site (ephemeral, not tracked in git) ---
echo "==> Bootstrapping site-staging..."
SITE="$WORKSPACE/abcnorio-astro/site"
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

# -- 4. Install rootless docker
bash "$SCRIPT_DIR/scripts/setup-rootless-docker.sh"

# -- 5. Install fail2ban
bash "$SCRIPT_DIR/scripts/setup-fail2ban.sh"

# --- 6. Done — list everything that needs credentials ---
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
echo "  abcnorio-astro/site/"
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
