#!/usr/bin/env bash
# Fresh-machine install. Run from abcnorio-meta/.
# Usage: bash install.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE="$(dirname "$SCRIPT_DIR")"

# Repo URLs — update these if cloning on a new machine
REPO_ASTRO="git@github.com:YOURORG/abcnorio-astro.git"
REPO_FUNC="git@github.com:YOURORG/abcnorio-func.git"
REPO_ORCHESTRATOR="git@github.com:YOURORG/abcnorio-orchestrator.git"
REPO_DOCS="git@github.com:YOURORG/abcnorio-docs.git"

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
copy_sample "$WORKSPACE/abcnorio-orchestrator/.env.sample"           "$WORKSPACE/abcnorio-orchestrator/.env"

# --- 3. Bootstrap Bedrock ---
echo "==> Bootstrapping Bedrock..."
bash "$SCRIPT_DIR/scripts/bootstrap.sh"

# --- 4. Done — list everything that needs credentials ---
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
echo "  just up        # bring the full stack up (requires just: https://github.com/casey/just)"
echo "  just --list    # see all available recipes"
echo ""
echo "  If just is not installed:"
echo "  curl -sSf https://just.systems/install.sh | bash -s -- --to ~/.local/bin"
echo "  # add ~/.local/bin to PATH if not already there"
echo ""
echo "  # Visit WP_HOME/wp/wp-admin/install.php for each env, or restore a DB backup"
