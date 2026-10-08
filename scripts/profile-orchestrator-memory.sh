#!/usr/bin/env bash
set -euo pipefail

CONTAINER="${1:-deploy-orchestrator}"
INTERVAL_SECONDS="${2:-1}"

if ! docker inspect "$CONTAINER" >/dev/null 2>&1; then
    echo "container not found: $CONTAINER" >&2
    exit 1
fi

printf 'timestamp_utc container memory_usage memory_percent cpu_percent\n'
while [[ "$(docker inspect --format '{{.State.Status}}' "$CONTAINER")" == "running" ]]; do
    sample="$(docker stats --no-stream --format '{{.MemUsage}} {{.MemPerc}} {{.CPUPerc}}' "$CONTAINER")"
    printf '%s %s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$CONTAINER" "$sample"
    sleep "$INTERVAL_SECONDS"
done