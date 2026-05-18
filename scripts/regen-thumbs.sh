#!/usr/bin/env bash
# Regenerate WP thumbnails in batches with progress output.
# Usage: scripts/regen-thumbs.sh <dev|staging>

set -euo pipefail

ENV="${1:?Usage: scripts/regen-thumbs.sh <dev|staging>}"

case "$ENV" in
  dev)     CONTAINER=wp_dev ;;
  staging) CONTAINER=wp_staging ;;
  *) echo "Unknown env: $ENV (expected dev or staging)" >&2; exit 1 ;;
esac

WP="wp --allow-root --path=/app/web/wp"
BATCH_SIZE=5

mapfile -t IDS < <(docker exec "$CONTAINER" $WP post list --post_type=attachment --post_status=inherit --field=ID)

TOTAL=${#IDS[@]}
BATCHES=$(( (TOTAL + BATCH_SIZE - 1) / BATCH_SIZE ))

echo "[$ENV] $TOTAL images → $BATCHES batches of $BATCH_SIZE"

batch=0
batch_ids=()

for id in "${IDS[@]}"; do
    batch_ids+=("$id")
    if [[ ${#batch_ids[@]} -eq $BATCH_SIZE ]]; then
        batch=$((batch + 1))
        echo "batch $batch / $BATCHES"
        docker exec "$CONTAINER" $WP media regenerate --yes "${batch_ids[@]}" || true
        batch_ids=()
    fi
done

# remaining
if [[ ${#batch_ids[@]} -gt 0 ]]; then
    batch=$((batch + 1))
    echo "batch $batch / $BATCHES"
    docker exec "$CONTAINER" $WP media regenerate --yes "${batch_ids[@]}" || true
fi

echo "[$ENV] done"
