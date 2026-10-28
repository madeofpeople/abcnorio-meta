#!/usr/bin/env bash
set -euo pipefail

META_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="$META_DIR/.env"

TARGET="${1:?Usage: scripts/deploy-release.sh <target> <release_id>}"
RELEASE_ID="${2:-}"

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

if [[ "$TARGET" == "production" && -z "$RELEASE_ID" ]]; then
  fetch_status() {
    docker exec "$ORCHESTRATOR_CONTAINER" curl -sf \
      -H "Authorization: Bearer ${ASTRO_BUILD_TRIGGER_SECRET}" \
      "http://localhost:${ORCHESTRATOR_PORT}/status"
  }

  status_field() {
    local json="$1"
    local field="$2"
    printf '%s' "$json" | node -e '
let data = "";
process.stdin.on("data", (chunk) => (data += chunk));
process.stdin.on("end", () => {
  const parsed = JSON.parse(data);
  const root = parsed?.data ?? parsed;
  const value = root?.[process.argv[1]];
  process.stdout.write(value === null || value === undefined ? "" : String(value));
});
' "$field"
  }

  before_status="$(fetch_status)"
  before_started="$(status_field "$before_status" started)"
  response="$(docker exec "$ORCHESTRATOR_CONTAINER" curl -sf \
    -X POST "http://localhost:${ORCHESTRATOR_PORT}/promote-staging" \
    -H "Authorization: Bearer ${ASTRO_BUILD_TRIGGER_SECRET}" \
    -H "Content-Type: application/json" \
    -d '{}')"
  printf '%s\n' "$response"
  promoted_sha="$(printf '%s' "$response" | node -e 'let s="";process.stdin.on("data",c=>s+=c);process.stdin.on("end",()=>{const j=JSON.parse(s);process.stdout.write(String(j?.data?.source_commit_sha||""));});')"
  [[ "$promoted_sha" =~ ^[a-f0-9]{40}$ ]] || {
    echo "Promotion response did not include a full staged commit SHA" >&2
    exit 1
  }
  echo "promoting_staging_sha=$promoted_sha"

  poll_interval="${POLL_INTERVAL_SECONDS:-2}"
  max_wait="${MAX_WAIT_SECONDS:-3600}"
  started_at="$SECONDS"
  while (( SECONDS - started_at < max_wait )); do
    current_status="$(fetch_status)"
    current_state="$(status_field "$current_status" status)"
    current_target="$(status_field "$current_status" target)"
    current_started="$(status_field "$current_status" started)"
    current_exit="$(status_field "$current_status" exitCode)"
    current_message="$(status_field "$current_status" message)"

    if [[ "$current_target" == "production" && -n "$current_started" && "$current_started" != "$before_started" ]]; then
      case "$current_state" in
        done)
          echo "Production promotion completed from staged commit."
          exit 0
          ;;
        failed)
          echo "Production promotion failed (exit ${current_exit:-unknown}): ${current_message:-no details}" >&2
          exit 1
          ;;
      esac
    fi
    sleep "$poll_interval"
  done

  echo "Timed out waiting for production promotion after ${max_wait}s." >&2
  exit 1
fi

if [[ -z "$RELEASE_ID" ]]; then
  echo "Usage: scripts/deploy-release.sh <target> <release_id>" >&2
  echo "Use 'just deploy production' to promote the commit currently running on healthy staging." >&2
  exit 1
fi

response="$(docker exec "$ORCHESTRATOR_CONTAINER" curl -sf \
  -X POST "http://localhost:${ORCHESTRATOR_PORT}/restore" \
  -H "Authorization: Bearer ${ASTRO_BUILD_TRIGGER_SECRET}" \
  -H "Content-Type: application/json" \
  -d "{\"target\":\"${TARGET}\",\"release_id\":\"${RELEASE_ID}\"}")"

printf '%s\n' "$response"
