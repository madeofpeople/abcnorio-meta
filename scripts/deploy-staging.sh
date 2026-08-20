#!/bin/bash
set -euo pipefail

ENV_FILE=".env"
TAG="${1:-}"
POLL_INTERVAL_SECONDS="${POLL_INTERVAL_SECONDS:-2}"
MAX_WAIT_SECONDS="${MAX_WAIT_SECONDS:-1800}"
WP_RUNTIME_ENV_FILE="wp/runtime.env"

strip_wrapping_quotes() {
    local value="$1"
    value="${value%\"}"
    value="${value#\"}"
    value="${value%\'}"
    value="${value#\'}"
    printf '%s' "$value"
}

read_runtime_env_value() {
    local key="$1"
    local raw=""

    if [ ! -f "$WP_RUNTIME_ENV_FILE" ]; then
        return
    fi

    raw="$(sed -n "s/^${key}=//p" "$WP_RUNTIME_ENV_FILE" | tail -n 1)"
    if [ -z "$raw" ]; then
        return
    fi

    raw="$(strip_wrapping_quotes "$raw")"
    printf '%s\n' "$raw"
}

resolve_deployment_status_path() {
    local explicit_path=""
    local archive_dir=""

    explicit_path="$(read_runtime_env_value "ASTRO_DEPLOYMENT_STATUS_FILE")"
    if [ -n "$explicit_path" ]; then
        printf '%s\n' "$explicit_path"
        return
    fi

    archive_dir="$(read_runtime_env_value "ASTRO_BUILD_ARCHIVE_DIR")"
    if [ -n "$archive_dir" ]; then
        archive_dir="${archive_dir%/}"
        printf '%s/deployment-status.json\n' "$archive_dir"
        return
    fi

    printf '/app/backups/deployment-status.json\n'
}

assert_deployment_status_contract() {
    local phase="$1"
    local status_path="$2"

    if ! docker exec abcwpstaging sh -lc "test -r '$status_path'"; then
        echo "error: ${phase} deployment status contract failed: unreadable file at ${status_path}" >&2
        exit 1
    fi

    if ! docker exec abcwpstaging sh -lc "grep -q '\"envs\"' '$status_path'"; then
        echo "error: ${phase} deployment status contract failed: missing envs payload in ${status_path}" >&2
        exit 1
    fi
}

assert_staging_plugin_artifacts() {
    local required_files=(
        "/app/web/app/plugins/abcnorio-func/build/index.js"
        "/app/web/app/plugins/abcnorio-func/build/index.asset.php"
        "/app/web/app/plugins/abcnorio-func/resources/vendor/components/dist/manifest.json"
    )

    local missing=0
    for file_path in "${required_files[@]}"; do
        if ! docker exec abcwpstaging sh -lc "test -r '$file_path'"; then
            echo "error: postflight artifact contract failed: missing unreadable file at ${file_path}" >&2
            missing=1
        fi
    done

    if [ "$missing" -ne 0 ]; then
        exit 1
    fi
}

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

if ! command -v docker >/dev/null 2>&1; then
    echo "error: docker is required"
    exit 1
fi

DEPLOYMENT_STATUS_PATH="$(resolve_deployment_status_path)"
assert_deployment_status_contract "preflight" "$DEPLOYMENT_STATUS_PATH"

staging_stopped=0
start_staging() {
    echo "starting astro-staging..."
    docker compose start astro-staging >/dev/null
}

wait_for_staging_health() {
    local health_started_at=$SECONDS
    local deadline=$((SECONDS + MAX_WAIT_SECONDS))

    while (( SECONDS < deadline )); do
        local status
        status="$(docker inspect --format '{{if .State.Running}}{{if .State.Health}}{{.State.Health.Status}}{{else}}running{{end}}{{else}}stopped{{end}}' astro-staging 2>/dev/null || true)"

        case "$status" in
            healthy|running)
                echo "astro-staging status: $status"
                return 0
                ;;
            starting)
                echo "astro-staging status: starting"
                ;;
            unhealthy|stopped|exited|dead)
                echo "astro-staging status: $status"
                ;;
            *)
                echo "astro-staging status: ${status:-unknown}"
                ;;
        esac

        sleep "$POLL_INTERVAL_SECONDS"
    done

    echo "error: astro-staging did not become healthy within ${MAX_WAIT_SECONDS}s" >&2
    docker compose logs --tail=120 astro-staging >&2 || true
    return 1
}

cleanup() {
    if [ "$staging_stopped" -eq 1 ]; then
        start_staging
    fi
}
trap cleanup EXIT

cutover_started_at="$(date +%s)"
echo "stopping astro-staging for cutover..."
docker compose stop astro-staging >/dev/null
staging_stopped=1
cutover_stopped_at="$(date +%s)"
echo "timing_stop_seconds=$((cutover_stopped_at - cutover_started_at))"

extract_push_field() {
    local json="$1"
    local field="$2"
    printf '%s' "$json" | node -e '
let data = "";
process.stdin.on("data", (c) => (data += c));
process.stdin.on("end", () => {
  try {
    const parsed = JSON.parse(data);
        const value = parsed?.data?.push?.[process.argv[1]] ?? parsed?.push?.[process.argv[1]];
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
                release_id="$(printf '%s' "$push_message" | sed -n 's/.*from tag \([^ ]*\) at.*/\1/p')"
                if [ -n "$release_id" ]; then
                    echo "release_id=${release_id}"
                fi
            fi
            break
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

push_completed_at="$(date +%s)"
echo "timing_push_seconds=$((push_completed_at - started_at))"

start_staging
wait_for_staging_health
staging_stopped=0

staging_healthy_at="$(date +%s)"
echo "timing_unavailable_seconds=$((staging_healthy_at - cutover_started_at))"

assert_deployment_status_contract "postflight" "$DEPLOYMENT_STATUS_PATH"
assert_staging_plugin_artifacts

echo "staging_push=done"
exit 0
