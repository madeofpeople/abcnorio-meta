#!/usr/bin/env bash
set -euo pipefail

META_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="$META_DIR/.env"

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
ENDPOINT="/dev-tools/sync-regenerated-thumbnails-to-production"
STATUS_KEY="syncRegeneratedThumbnailsToProduction"

echo "Backing up production uploads, then syncing generated image derivatives from staging..."
response="$(curl -sS -w '\n%{http_code}' \
  -X POST "http://localhost:${ORCHESTRATOR_PORT}${ENDPOINT}" \
  -H "Authorization: Bearer ${ASTRO_BUILD_TRIGGER_SECRET}" \
)" || {
  echo "Could not connect to the deploy orchestrator." >&2
  exit 1
}
http_status="${response##*$'\n'}"
response_body="${response%$'\n'*}"

if [[ "$http_status" != 202 ]]; then
  echo "Deploy orchestrator returned HTTP ${http_status}:" >&2
  printf '%s\n' "$response_body" >&2
  exit 1
fi

deadline=$((SECONDS + 1800))
while (( SECONDS < deadline )); do
  status_json="$(curl -sf \
    -H "Authorization: Bearer ${ASTRO_BUILD_TRIGGER_SECRET}" \
    "http://localhost:${ORCHESTRATOR_PORT}/dev-tools/status")"

  op_state="$(printf '%s' "$status_json" | node -e '
let data = "";
process.stdin.on("data", (chunk) => (data += chunk));
process.stdin.on("end", () => {
  const parsed = JSON.parse(data);
  const root = parsed?.data ?? parsed;
  const op = root?.[process.argv[1]];
  process.stdout.write(JSON.stringify({
    status: String(op?.status || ""),
    message: String(op?.message || ""),
  }));
});
' "$STATUS_KEY")"

  op_status="$(printf '%s' "$op_state" | node -e 'let s="";process.stdin.on("data",c=>s+=c);process.stdin.on("end",()=>process.stdout.write(JSON.parse(s).status));')"
  case "$op_status" in
    done)
      printf '%s\n' "$op_state" | node -e 'let s="";process.stdin.on("data",c=>s+=c);process.stdin.on("end",()=>console.log(JSON.parse(s).message));'
      exit 0
      ;;
    failed)
      printf '%s\n' "$op_state" | node -e 'let s="";process.stdin.on("data",c=>s+=c);process.stdin.on("end",()=>console.error(JSON.parse(s).message));' >&2
      exit 1
      ;;
    running|idle|"")
      sleep 2
      ;;
    *)
      echo "Unexpected status for ${STATUS_KEY}: ${op_status}" >&2
      exit 1
      ;;
  esac
done

echo "Timed out waiting for production thumbnail sync after 1800 seconds." >&2
exit 1
