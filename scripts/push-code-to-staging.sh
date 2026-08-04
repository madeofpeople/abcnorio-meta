#!/bin/bash
set -euo pipefail

ENV_FILE=".env"
TAG="${1:-}"
POLL_INTERVAL_SECONDS="${POLL_INTERVAL_SECONDS:-2}"
MAX_WAIT_SECONDS="${MAX_WAIT_SECONDS:-1800}"
ASTRO_REPO_DIR="${ASTRO_REPO_DIR:-../abcnorio-astro}"
STAGING_BRANCH_NAME="${STAGING_BRANCH_NAME:-staging}"
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

if ! command -v git >/dev/null 2>&1; then
    echo "error: git is required"
    exit 1
fi

if ! command -v docker >/dev/null 2>&1; then
    echo "error: docker is required"
    exit 1
fi

DEPLOYMENT_STATUS_PATH="$(resolve_deployment_status_path)"
assert_deployment_status_contract "preflight" "$DEPLOYMENT_STATUS_PATH"

resolve_effective_tag() {
    if [ -n "$TAG" ]; then
        printf '%s\n' "$TAG"
        return
    fi

    (
      cd "$ASTRO_REPO_DIR"
      git tag --list 'staging-deploy-*' --sort=-creatordate | head -n 1
    )
}

EFFECTIVE_TAG="$(resolve_effective_tag)"
if [ -z "$EFFECTIVE_TAG" ]; then
    echo "error: no staging-deploy-* tag found"
    exit 1
fi

APPROVED_SHA="$(cd "$ASTRO_REPO_DIR" && git rev-list -n 1 "$EFFECTIVE_TAG")"
if [ -z "$APPROVED_SHA" ]; then
    echo "error: failed to resolve commit for tag $EFFECTIVE_TAG"
    exit 1
fi

REMOTE_STAGING_SHA="$(cd "$ASTRO_REPO_DIR" && git rev-parse --verify --quiet "origin/${STAGING_BRANCH_NAME}^{commit}" || true)"
if [ -n "$REMOTE_STAGING_SHA" ]; then
    if ! (cd "$ASTRO_REPO_DIR" && git merge-base --is-ancestor "$REMOTE_STAGING_SHA" "$APPROVED_SHA"); then
        echo "error: refusing non-fast-forward update for ${STAGING_BRANCH_NAME}: $REMOTE_STAGING_SHA is not ancestor of $APPROVED_SHA"
        exit 1
    fi
fi

echo "selected_tag=$EFFECTIVE_TAG"
echo "selected_commit=$APPROVED_SHA"

if [ -z "$TAG" ]; then
    PAYLOAD="{\"tag\":\"$EFFECTIVE_TAG\"}"
fi

staging_stopped=0
cleanup() {
    if [ "$staging_stopped" -eq 1 ]; then
        echo "starting astro-staging..."
        docker compose start astro-staging >/dev/null
    fi
}
trap cleanup EXIT

echo "stopping astro-staging for cutover..."
docker compose stop astro-staging >/dev/null
staging_stopped=1

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

echo "fast-forwarding ${STAGING_BRANCH_NAME} -> $APPROVED_SHA"
(
    cd "$ASTRO_REPO_DIR"
    git fetch origin --prune
    CURRENT_BRANCH="$(git rev-parse --abbrev-ref HEAD)"
    git checkout "$STAGING_BRANCH_NAME"
    git merge --ff-only "$APPROVED_SHA"
    git push origin "$STAGING_BRANCH_NAME"
    git checkout "$CURRENT_BRANCH"
)

assert_deployment_status_contract "postflight" "$DEPLOYMENT_STATUS_PATH"

echo "branch_update=done"
exit 0
