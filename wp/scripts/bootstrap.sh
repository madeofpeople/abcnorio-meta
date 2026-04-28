#!/usr/bin/env bash
# Bootstrap dev and staging Bedrock directories.
# Run once from abcnorio-meta/ before `docker compose up`.
# Requires: composer, node, npm (for post-install plugin JS build)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
META_DIR="$(dirname "$SCRIPT_DIR")"
FUNC_SOURCE_DIR="${META_DIR}/../abcnorio-func"

bootstrap_bedrock() {
    local env="$1"
    local bedrock_dir="${META_DIR}/wp/${env}/bedrock"
    local seed="${META_DIR}/wp/${env}/bedrock.composer.json"

    if [ -d "$bedrock_dir" ]; then
        echo "[${env}] bedrock directory already exists, skipping"
        return
    fi

    echo "[${env}] scaffolding bedrock from roots/bedrock..."
    composer create-project roots/bedrock "$bedrock_dir" --no-install --no-interaction

    echo "[${env}] applying project composer.json..."
    cp "$seed" "$bedrock_dir/composer.json"

    if [ "$env" = "dev" ]; then
        echo "[${env}] symlinking abcnorio-func into packages/..."
        mkdir -p "$bedrock_dir/packages"
        ln -sf "$FUNC_SOURCE_DIR" "$bedrock_dir/packages/abcnorio-func"
    fi

    echo "[${env}] running composer install..."
    (cd "$bedrock_dir" && composer install)

    if [ ! -f "$bedrock_dir/.env" ]; then
        cp "$bedrock_dir/.env.example" "$bedrock_dir/.env"
        echo "[${env}] created .env from .env.example"
        echo "[${env}] !! fill in ${bedrock_dir}/.env with DB credentials, WP_HOME, and salts before starting the stack"
    fi

    echo "[${env}] done"
}

bootstrap_bedrock dev
bootstrap_bedrock staging
