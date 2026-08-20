#!/usr/bin/env bash
# Wrapper: keep invocation in meta ops, but execute orchestrator-owned warm-cache logic.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
META_DIR="$(dirname "$SCRIPT_DIR")"

HOST="${1:-${WARM_CACHE_HOST:-}}"

if [[ -z "$HOST" && -f "$META_DIR/.env" ]]; then
    # shellcheck disable=SC1091
    source "$META_DIR/.env"
    if [[ -n "${DOMAIN_PRODUCTION:-}" ]]; then
        HOST="https://${DOMAIN_PRODUCTION}"
    fi
fi

if [[ -z "$HOST" ]]; then
    echo "Missing host. Pass host arg, set WARM_CACHE_HOST, or define DOMAIN_PRODUCTION in .env." >&2
    exit 1
fi

echo "Invoking orchestrator warm-cache script for $HOST"
cd "$META_DIR"
docker compose exec -T -e PRODUCTION_HOST="$HOST" deploy-orchestrator bash /orchestrator/scripts/warm-cache.sh
