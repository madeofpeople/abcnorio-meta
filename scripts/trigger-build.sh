#!/usr/bin/env bash
# Trigger an Astro build via the deploy orchestrator.
# Usage: scripts/trigger-build.sh <target> [scope]
#   target: production | preview
#   scope:  full (default) | events | <page-slug>
# Optional env flags:
#   WAIT_FOR_COMPLETION=0 to return after enqueue (legacy behavior)
#   POLL_INTERVAL_SECONDS=2 and MAX_WAIT_SECONDS=3600 to tune polling
# Requires ASTRO_BUILD_TRIGGER_SECRET in environment or abcnorio-meta/.env

set -euo pipefail

META_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="$META_DIR/.env"

TARGET="${1:?Usage: scripts/trigger-build.sh <production|preview> [scope]}"
SCOPE="${2:-full}"

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
ORCHESTRATOR_CONTAINER="${ORCHESTRATOR_CONTAINER:-deploy-orchestrator}"
WAIT_FOR_COMPLETION="${WAIT_FOR_COMPLETION:-1}"
POLL_INTERVAL_SECONDS="${POLL_INTERVAL_SECONDS:-2}"
MAX_WAIT_SECONDS="${MAX_WAIT_SECONDS:-3600}"

read_runtime_status_field() {
  local json="$1"
  local field="$2"
  printf '%s' "$json" | node -e '
let data = "";
process.stdin.on("data", (c) => (data += c));
process.stdin.on("end", () => {
  try {
    const parsed = JSON.parse(data);
    const value = parsed?.[process.argv[1]];
    if (value === null || value === undefined) {
      process.stdout.write("");
      return;
    }
    process.stdout.write(String(value));
  } catch {
    process.stdout.write("");
  }
});
' "$field"
}

fetch_runtime_status() {
  docker exec "$ORCHESTRATOR_CONTAINER" curl -sf \
    -H "Authorization: Bearer ${ASTRO_BUILD_TRIGGER_SECRET}" \
    "http://localhost:${ORCHESTRATOR_PORT}/status"
}

printf 'Triggering %s build (%s) via orchestrator...\n' "$TARGET" "$SCOPE"

pre_status_json="$(fetch_runtime_status)"
pre_status="$(read_runtime_status_field "$pre_status_json" status)"
pre_target="$(read_runtime_status_field "$pre_status_json" target)"
pre_started="$(read_runtime_status_field "$pre_status_json" started)"

response="$(docker exec "$ORCHESTRATOR_CONTAINER" curl -sf \
  -X POST "http://localhost:${ORCHESTRATOR_PORT}/trigger" \
  -H "Authorization: Bearer ${ASTRO_BUILD_TRIGGER_SECRET}" \
  -H "Content-Type: application/json" \
  -d "{\"target\":\"${TARGET}\",\"scope\":\"${SCOPE}\",\"source\":\"manual\"}")"

printf '%s\n' "$response"

if [[ "$WAIT_FOR_COMPLETION" == "0" ]]; then
  printf 'Build request accepted. Monitor orchestrator status for completion.\n'
  exit 0
fi

printf 'Build request accepted. Waiting for completion...\n'

seen_current_target_run=false
deadline=$((SECONDS + MAX_WAIT_SECONDS))

while (( SECONDS < deadline )); do
  status_json="$(fetch_runtime_status)"
  runtime_status="$(read_runtime_status_field "$status_json" status)"
  runtime_target="$(read_runtime_status_field "$status_json" target)"
  runtime_started="$(read_runtime_status_field "$status_json" started)"
  runtime_message="$(read_runtime_status_field "$status_json" message)"

  is_preexisting_same_target_run=false
  if [[ "$pre_status" == "running" && "$pre_target" == "$TARGET" && -n "$pre_started" && "$runtime_started" == "$pre_started" ]]; then
    is_preexisting_same_target_run=true
  fi

  if [[ "$runtime_target" == "$TARGET" && -n "$runtime_started" && "$is_preexisting_same_target_run" == false ]]; then
    seen_current_target_run=true
  fi

  if [[ "$runtime_target" == "$TARGET" && ( "$runtime_status" == "done" || "$runtime_status" == "failed" ) ]]; then
    if [[ "$seen_current_target_run" == true || "$is_preexisting_same_target_run" == false ]]; then
      if [[ "$runtime_status" == "done" ]]; then
        printf 'Build completed successfully for %s.\n' "$TARGET"
        exit 0
      fi

      printf 'Build failed for %s' "$TARGET" >&2
      if [[ -n "$runtime_message" ]]; then
        printf ': %s\n' "$runtime_message" >&2
      else
        printf '.\n' >&2
      fi
      exit 1
    fi
  fi

  sleep "$POLL_INTERVAL_SECONDS"
done

printf 'Build timed out waiting for %s after %ss.\n' "$TARGET" "$MAX_WAIT_SECONDS" >&2
exit 1
