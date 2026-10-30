#!/usr/bin/env bash
# Shared helpers for scripts that trigger an orchestrator dev-tools job and wait for it.
# Usage: source "$(dirname "${BASH_SOURCE[0]}")/lib/orchestrator.sh"
#        orchestrator_init
#        run_dev_tool <endpoint> <status_key> <label> [timeout_seconds]

META_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

orchestrator_init() {
  if [[ -z "${ASTRO_BUILD_TRIGGER_SECRET:-}" ]]; then
    if [[ ! -f "$META_DIR/.env" ]]; then
      echo "ERROR: Missing required env file: $META_DIR/.env" >&2
      exit 1
    fi
    # shellcheck source=/dev/null
    source "$META_DIR/.env"
  fi
  : "${ASTRO_BUILD_TRIGGER_SECRET:?ASTRO_BUILD_TRIGGER_SECRET not set}"

  ORCHESTRATOR_BASE="http://localhost:${ORCHESTRATOR_PORT:-4011}"
  ORCHESTRATOR_AUTH="Authorization: Bearer ${ASTRO_BUILD_TRIGGER_SECRET}"
}

# Prints "<status>|<started>|<message>" for a job.
dev_tool_status() {
  curl -sf -H "$ORCHESTRATOR_AUTH" "$ORCHESTRATOR_BASE/dev-tools/status" | node -e '
    const j = JSON.parse(require("fs").readFileSync(0, "utf8")).data[process.argv[1]];
    console.log(`${j.status}|${j.started}|${j.message ?? ""}`);
  ' "$1"
}

# Starts a job, prints progress every 2s, returns 0 on done, exits 1 on failed or timeout.
run_dev_tool() {
  local endpoint="$1" key="$2" label="$3" timeout="${4:-1800}"
  local previous_started response http_status body begin elapsed status started message

  previous_started="$(dev_tool_status "$key" | cut -d'|' -f2)"

  response="$(curl -sS -w '\n%{http_code}' -X POST -H "$ORCHESTRATOR_AUTH" "$ORCHESTRATOR_BASE$endpoint")" || {
    echo "Could not connect to the deploy orchestrator." >&2
    exit 1
  }
  http_status="${response##*$'\n'}"
  body="${response%$'\n'*}"
  if [[ "$http_status" != 202 ]]; then
    echo "Deploy orchestrator returned HTTP ${http_status}: $body" >&2
    exit 1
  fi

  echo "$label: started"
  begin="$(date +%s)"
  while true; do
    IFS='|' read -r status started message <<< "$(dev_tool_status "$key")"
    elapsed="$(( $(date +%s) - begin ))"

    # Ignore the previous run's result until this run registers.
    if [[ "$started" != "$previous_started" ]]; then
      case "$status" in
        done)   echo "$label: done (${elapsed}s): $message"; return 0 ;;
        failed) echo "$label: failed (${elapsed}s): $message" >&2; exit 1 ;;
      esac
    fi

    if (( elapsed > timeout )); then
      echo "$label: timed out after ${timeout}s" >&2
      exit 1
    fi
    echo "$label: running (${elapsed}s)"
    sleep 2
  done
}
