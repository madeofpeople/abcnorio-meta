#!/usr/bin/env bash
# Regenerate WP thumbnails in batches with progress output, outputting WebP.
# Usage: scripts/regen-thumbs.sh <dev|staging>

set -euo pipefail

ENV="${1:?Usage: scripts/regen-thumbs.sh <dev|staging>}"

case "$ENV" in
  dev)     CONTAINER=wp_dev ;;
  staging) CONTAINER=wp_staging ;;
  *) echo "Unknown env: $ENV (expected dev or staging)" >&2; exit 1 ;;
esac

WP="wp --allow-root --path=/app/web/wp"
BATCH_SIZE=3
WEBP_FILTER=/tmp/abcnorio-webp-output.php

docker exec "$CONTAINER" bash -c \
    "printf '<?php WP_CLI::add_hook(\"after_wp_load\", fn() => add_filter(\"image_editor_output_format\", fn() => [\"image/jpeg\" => \"image/webp\", \"image/png\" => \"image/webp\"]));\n' > $WEBP_FILTER"

mapfile -t IDS < <(docker exec "$CONTAINER" $WP post list --post_type=attachment --post_status=inherit --field=ID)

TOTAL=${#IDS[@]}
BATCHES=$(( (TOTAL + BATCH_SIZE - 1) / BATCH_SIZE ))

echo "[$ENV] $TOTAL images → $BATCHES batches of $BATCH_SIZE (output: webp)"

batch=0
batch_ids=()

for id in "${IDS[@]}"; do
    batch_ids+=("$id")
    if [[ ${#batch_ids[@]} -eq $BATCH_SIZE ]]; then
        batch=$((batch + 1))
        echo "batch $batch / $BATCHES"
        docker exec "$CONTAINER" $WP --require="$WEBP_FILTER" media regenerate --yes "${batch_ids[@]}" || true
        batch_ids=()
    fi
done

if [[ ${#batch_ids[@]} -gt 0 ]]; then
    batch=$((batch + 1))
    echo "batch $batch / $BATCHES"
    docker exec "$CONTAINER" $WP --require="$WEBP_FILTER" media regenerate --yes "${batch_ids[@]}" || true
fi

docker exec "$CONTAINER" rm -f "$WEBP_FILTER"
echo "[$ENV] done"
