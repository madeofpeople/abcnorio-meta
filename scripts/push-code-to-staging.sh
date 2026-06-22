#!/bin/bash
set -e

VERSION="${1:-}"
ENV_FILE=".env"

# Validate env file exists
if [ ! -f "$ENV_FILE" ]; then
    echo "error: $ENV_FILE not found in $(pwd)"
    exit 1
fi

# Load env vars
set -a
. "$ENV_FILE"
set +a

# Validate secret is set
if [ -z "$ASTRO_BUILD_TRIGGER_SECRET" ]; then
    echo "error: ASTRO_BUILD_TRIGGER_SECRET not set in $ENV_FILE"
    exit 1
fi

# Build JSON payload
PAYLOAD=$(jq -rn --arg version "$VERSION" '{version: $version}')

# Send to orchestrator
docker exec deploy-orchestrator curl -sf \
    -X POST "http://localhost:4011/dev-tools/push-to-staging" \
    -H "Authorization: Bearer $ASTRO_BUILD_TRIGGER_SECRET" \
    -H "Content-Type: application/json" \
    -d "$PAYLOAD"

echo
