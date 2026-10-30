#!/usr/bin/env bash
# Copy media uploads between dev and staging environments.
# Usage: scripts/copy-media.sh <dev-to-staging|staging-to-dev>
# Runs via the orchestrator's dev-tools endpoint (no direct container access needed).

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib/orchestrator.sh"

DIRECTION="${1:?Usage: scripts/copy-media.sh <dev-to-staging|staging-to-dev>}"

case "$DIRECTION" in
  dev-to-staging) ENDPOINT="/dev-tools/copy-media-to-staging"; STATUS_KEY="copyMediaToStagingFromDev" ;;
  staging-to-dev) ENDPOINT="/dev-tools/copy-media-to-dev"; STATUS_KEY="copyMediaFromStagingToDev" ;;
  *) echo "Unknown direction: $DIRECTION (expected dev-to-staging or staging-to-dev)" >&2; exit 1 ;;
esac

orchestrator_init
run_dev_tool "$ENDPOINT" "$STATUS_KEY" "Copy media ($DIRECTION)"
