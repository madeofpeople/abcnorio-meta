#!/usr/bin/env bash
# Copy media uploads between dev and staging environments.
# Usage: scripts/copy-media.sh <direction>
#   direction: dev-to-staging | staging-to-dev
# Runs via the orchestrator's dev-tools endpoint (no direct container access needed).

set -euo pipefail

META_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="$META_DIR/.env"

DIRECTION="${1:?Usage: scripts/copy-media.sh <dev-to-staging|staging-to-dev>}"

case "$DIRECTION" in
  dev-to-staging) ENDPOINT="/dev-tools/copy-media-to-staging"; STATUS_KEY="copyMediaToStagingFromDev" ;;
  staging-to-dev) ENDPOINT="/dev-tools/copy-media-to-dev"; STATUS_KEY="copyMediaFromStagingToDev" ;;
  *) echo "Unknown direction: $DIRECTION (expected dev-to-staging or staging-to-dev)" >&2; exit 1 ;;
esac

if [[ -z "${ASTRO_BUILD_TRIGGER_SECRET:-}" ]]; then
  if [[ ! -f "$ENV_FILE" ]]; then
    echo "ERROR: Missing required env file: $ENV_FILE" >&2
    exit 1
  fi
  # shellcheck source=/dev/null
  source "$ENV_FILE"
fi

: "${ASTRO_BUILD_TRIGGER_SECRET:?ASTRO_BUILD_TRIGGER_SECRET not set}"

ORCHESTRATOR_PORT="${ORCHESTRATOR_PORT:-4011}"

BASE="http://localhost:${ORCHESTRATOR_PORT}"
AUTH="Authorization: Bearer ${ASTRO_BUILD_TRIGGER_SECRET}"

# Prints "<status>|<started>|<message>" for this job.
job_status() {
  curl -sf -H "$AUTH" "$BASE/dev-tools/status" | node -e '
    const j = JSON.parse(require("fs").readFileSync(0, "utf8")).data[process.argv[1]];
    console.log(`${j.status}|${j.started}|${j.message ?? ""}`);
  ' "$STATUS_KEY"
}

previous_started="$(job_status | cut -d'|' -f2)"

curl -sf -X POST -H "$AUTH" "$BASE$ENDPOINT" | cat
echo
echo "waiting for copy to finish..."

begin="$(date +%s)"
while true; do
  IFS='|' read -r status started message <<< "$(job_status)"
  elapsed="$(( $(date +%s) - begin ))"

  # Ignore the previous run's result until this run registers.
  if [[ "$started" != "$previous_started" ]]; then
    case "$status" in
      done)   echo "done (${elapsed}s): $message"; exit 0 ;;
      failed) echo "failed (${elapsed}s): $message" >&2; exit 1 ;;
    esac
  fi

  echo "running (${elapsed}s)"
  sleep 2
done
