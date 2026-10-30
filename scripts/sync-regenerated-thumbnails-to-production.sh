#!/usr/bin/env bash
# Back up production uploads, then sync regenerated image derivatives from staging.

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib/orchestrator.sh"

orchestrator_init
run_dev_tool "/dev-tools/sync-regenerated-thumbnails-to-production" "syncRegeneratedThumbnailsToProduction" "Sync thumbnails to production"
