#!/usr/bin/env bash
# Bootstrap dev and staging Bedrock directories.
# Run once from abcnorio-meta/ before `docker compose up`.
# Requires: composer

set -euo pipefail

META_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FUNC_SOURCE_DIR="$(cd "${META_DIR}/../abcnorio-func" && pwd)"
WORKER_SOURCE="${META_DIR}/wp/worker.php"
HEADLESS_THEME_SOURCE_DIR="${META_DIR}/wp/theme-headless-placeholder"
BEDROCK_VERSION="1.31.0"

seed_headless_theme() {
    local env="$1"
    local target_dir="${META_DIR}/wp/${env}/bedrock/web/app/themes/headless"

    if [ ! -d "${META_DIR}/wp/${env}/bedrock" ]; then
        echo "[${env}] bedrock missing, cannot seed headless theme" >&2
        exit 1
    fi

    mkdir -p "$target_dir"
    rsync -a --delete "${HEADLESS_THEME_SOURCE_DIR}/" "$target_dir/"
    echo "[${env}] seeded headless theme"
}

bootstrap_bedrock() {
    local env="$1"
    local bedrock_dir="${META_DIR}/wp/${env}/bedrock"
    local seed="${META_DIR}/wp/${env}/bedrock.composer.json"
    local lock_seed="${META_DIR}/wp/${env}/bedrock.composer.lock"
    local wp_entry="${bedrock_dir}/web/wp/wp-blog-header.php"
    local autoload_file="${bedrock_dir}/vendor/autoload.php"

    if [ -d "$bedrock_dir" ]; then
        if [ -f "$wp_entry" ] && [ -f "$autoload_file" ]; then
            echo "[${env}] bedrock directory already exists, skipping"
            return
        fi

        echo "[${env}] existing bedrock directory is incomplete: ${bedrock_dir}" >&2
        echo "[${env}] remove it and rerun bootstrap" >&2
        exit 1
    fi

    echo "[${env}] scaffolding bedrock ${BEDROCK_VERSION} from roots/bedrock..."
    composer create-project roots/bedrock "$bedrock_dir" "$BEDROCK_VERSION" --no-install --no-interaction

    echo "[${env}] copying project composer.json..."
    cp "$seed" "$bedrock_dir/composer.json"

    if [ -f "$lock_seed" ]; then
        echo "[${env}] copying project composer.lock..."
        cp "$lock_seed" "$bedrock_dir/composer.lock"
    fi

    if [ "$env" = "dev" ]; then
        echo "[${env}] symlinking abcnorio-func into packages/..."
        mkdir -p "$bedrock_dir/packages"
        if [ -e "$bedrock_dir/packages/abcnorio-func" ] && [ ! -L "$bedrock_dir/packages/abcnorio-func" ]; then
            echo "[${env}] unexpected non-symlink at ${bedrock_dir}/packages/abcnorio-func" >&2
            echo "[${env}] remove it and rerun bootstrap" >&2
            exit 1
        fi
        rm -f "$bedrock_dir/packages/abcnorio-func"
        ln -s "$FUNC_SOURCE_DIR" "$bedrock_dir/packages/abcnorio-func"
    fi

    echo "[${env}] running composer install..."
    (cd "$bedrock_dir" && composer install)

    if [ ! -f "$bedrock_dir/.env" ]; then
        cp "$bedrock_dir/.env.example" "$bedrock_dir/.env"
        echo "[${env}] created .env from .env.example"
        echo "[${env}] !! fill in ${bedrock_dir}/.env with DB credentials, WP_HOME, and salts before starting the stack"
    fi

    if [ ! -s "$bedrock_dir/web/worker.php" ]; then
        cp "$WORKER_SOURCE" "$bedrock_dir/web/worker.php"
        echo "[${env}] seeded web/worker.php"
    fi

    echo "[${env}] done"
}

bootstrap_bedrock dev
bootstrap_bedrock staging

seed_headless_theme dev
seed_headless_theme staging