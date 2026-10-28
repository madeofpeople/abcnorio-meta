#!/bin/bash
set -euo pipefail

ENV_FILE=".env"
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

if ! command -v docker >/dev/null 2>&1; then
    echo "error: docker is required"
    exit 1
fi

# Deploys install the webcomponents SHA pinned in the committed lockfile.
if [ "${FORCE:-0}" != "1" ]; then
    ASTRO_DIR="../abcnorio-astro"
    locked_sha="$(git -C "$ASTRO_DIR" show staging:site-frontend/package-lock.json | node -e "
        const lock = JSON.parse(require('fs').readFileSync(0, 'utf8'));
        console.log(lock.packages['node_modules/abcnorio-webcomponents'].resolved.split('#')[1]);
    ")"
    remote_sha="$(git -C ../abcnorio-webcomponents ls-remote origin refs/heads/main | cut -f1)"
    if [ "$locked_sha" != "$remote_sha" ]; then
        echo "error: webcomponents pin is stale." >&2
        echo "  lock on abcnorio-astro 'staging' branch: ${locked_sha:0:7}" >&2
        echo "  origin/main:    ${remote_sha:0:7}" >&2
        echo "Run 'just update-webcomponents', commit on main, merge main into staging, then retry (FORCE=1 to skip)." >&2
        exit 1
    fi
fi

if [ ! -f "$WP_RUNTIME_ENV_FILE" ]; then
    echo "error: $WP_RUNTIME_ENV_FILE not found" >&2
    exit 1
fi

archive_dir="$(sed -n 's/^ASTRO_BUILD_ARCHIVE_DIR=//p' "$WP_RUNTIME_ENV_FILE" | tail -n 1)"
archive_dir="$(strip_wrapping_quotes "$archive_dir")"
if [ -z "$archive_dir" ]; then
    echo "error: ASTRO_BUILD_ARCHIVE_DIR not set in $WP_RUNTIME_ENV_FILE" >&2
    exit 1
fi
DEPLOYMENT_STATUS_PATH="${archive_dir%/}/deployment-status.json"
assert_deployment_status_contract "preflight" "$DEPLOYMENT_STATUS_PATH"

staging_stopped=0
start_staging() {
    echo "starting astro-staging..."
    docker compose up -d --no-deps --force-recreate astro-staging >/dev/null
}

assert_staging_mount() {
    local expected_source actual_source
    expected_source="$(realpath "${ASTRO_BUILD_WORKDIR_HOST_DIR%/}/staging-site-frontend")"
    actual_source="$(docker inspect --format '{{range .Mounts}}{{if eq .Destination "/app"}}{{.Source}}{{end}}{{end}}' astro-staging)"
    if [[ -z "$actual_source" ]]; then
        echo "error: astro-staging has no /app bind mount" >&2
        exit 1
    fi
    actual_source="$(realpath "$actual_source")"
    if [[ "$actual_source" != "$expected_source" ]]; then
        echo "error: astro-staging /app mount is '$actual_source', expected '$expected_source'" >&2
        exit 1
    fi
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
if docker inspect astro-staging >/dev/null 2>&1; then
    docker compose stop astro-staging >/dev/null
    staging_stopped=1
else
    echo "astro-staging has not been created yet; first deployment will create it"
fi
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
        const value = parsed?.data?.push?.[process.argv[1]];
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
    -d '{}')"

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
                release_id="$(printf '%s' "$push_message" | sed -n 's/.*staging release \([^ ]*\) for commit.*/\1/p')"
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
assert_staging_mount
staging_stopped=0

verify_curl_status=0
verify_response="$(docker exec deploy-orchestrator curl -sS \
    -w '\nHTTP_STATUS:%{http_code}' \
    -X POST "http://localhost:4011/dev-tools/verify-staging" \
    -H "Authorization: Bearer $ASTRO_BUILD_TRIGGER_SECRET" \
    -H "Content-Type: application/json" \
    -d '{}')" || verify_curl_status=$?

if [[ "$verify_curl_status" -ne 0 ]]; then
    echo "error: staging verification request failed (curl exit $verify_curl_status): $verify_response" >&2
    exit "$verify_curl_status"
fi

verify_http_status="${verify_response##*$'\n'HTTP_STATUS:}"
verify_body="${verify_response%$'\n'HTTP_STATUS:*}"
echo "staging verification HTTP status: $verify_http_status"
echo "staging verification response: $verify_body"
if [[ "$verify_http_status" != "200" ]]; then
    echo "error: staging verification returned HTTP $verify_http_status" >&2
    exit 1
fi

staging_healthy_at="$(date +%s)"
echo "timing_unavailable_seconds=$((staging_healthy_at - cutover_started_at))"

assert_deployment_status_contract "postflight" "$DEPLOYMENT_STATUS_PATH"
assert_staging_plugin_artifacts

echo "staging_push=done"
exit 0
