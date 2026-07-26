#!/bin/bash
set -euo pipefail

ENV_FILE=".env"
TAG="${1:-}"
POLL_INTERVAL_SECONDS="${POLL_INTERVAL_SECONDS:-2}"
MAX_WAIT_SECONDS="${MAX_WAIT_SECONDS:-1800}"

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

if [ -n "$TAG" ]; then
    PAYLOAD="{\"tag\":\"$TAG\"}"
else
    PAYLOAD='{}'
fi

extract_push_field() {
    local json="$1"
    local field="$2"
    printf '%s' "$json" | node -e '
let data = "";
process.stdin.on("data", (c) => (data += c));
process.stdin.on("end", () => {
  try {
    const parsed = JSON.parse(data);
    const value = parsed?.push?.[process.argv[1]];
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

trigger_response="$(docker exec deploy-orchestrator curl -sf \
    -X POST "http://localhost:4011/dev-tools/push-to-staging" \
    -H "Authorization: Bearer $ASTRO_BUILD_TRIGGER_SECRET" \
    -H "Content-Type: application/json" \
    -d "$PAYLOAD")"

echo "push trigger response: $trigger_response"
echo "waiting for push completion..."

started_at="$(date +%s)"

while true; do
    status_json="$(docker exec deploy-orchestrator curl -sf \
        -H "Authorization: Bearer $ASTRO_BUILD_TRIGGER_SECRET" \
        "http://localhost:4011/dev-tools/status")"

    push_status="$(extract_push_field "$status_json" status)"
    push_message="$(extract_push_field "$status_json" message)"
    elapsed="$(( $(date +%s) - started_at ))"

    case "$push_status" in
        done)
            echo "push status: done (${elapsed}s)"
            if [ -n "$push_message" ] && [ "$push_message" != "null" ]; then
                echo "$push_message"
            fi
            exit 0
            ;;
        failed)
            echo "push status: failed (${elapsed}s)"
            if [ -n "$push_message" ] && [ "$push_message" != "null" ]; then
                echo "$push_message"
            fi
            exit 1
            ;;
        running)
            echo "push status: running (${elapsed}s)"
            ;;
        "")
            echo "push status: unknown (${elapsed}s)"
            ;;
        *)
            echo "push status: $push_status (${elapsed}s)"
            ;;
    esac

    if [ "$elapsed" -ge "$MAX_WAIT_SECONDS" ]; then
        echo "push status: timeout after ${MAX_WAIT_SECONDS}s"
        exit 1
    fi

    sleep "$POLL_INTERVAL_SECONDS"
done
