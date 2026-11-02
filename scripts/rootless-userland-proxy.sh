#!/usr/bin/env bash
# Turn the rootless Docker userland proxy off so Caddy logs real client IPs
# (needed by the caddy-wp fail2ban jail). Reversible.
#
# Usage: bash scripts/rootless-userland-proxy.sh apply|rollback|status
#
# apply    writes daemon.json and a systemd override, restarts the user docker
#          daemon (all containers restart), and rolls back by itself if the
#          daemon does not come back.
# rollback removes both files and restarts the daemon.
set -euo pipefail

export DOCKER_HOST="unix:///run/user/$(id -u)/docker.sock"
DAEMON_JSON="$HOME/.config/docker/daemon.json"
OVERRIDE_DIR="$HOME/.config/systemd/user/docker.service.d"
OVERRIDE="$OVERRIDE_DIR/userland-proxy.conf"
BACKUP_DIR="$HOME/.config/docker-userland-proxy-backup"

restart_docker() {
    systemctl --user daemon-reload
    systemctl --user restart docker
}

wait_for_docker() {
    for _ in $(seq 1 30); do
        docker info >/dev/null 2>&1 && return 0
        sleep 2
    done
    return 1
}

rollback() {
    echo "==> Rolling back"
    rm -f "$OVERRIDE"
    if [[ -f "$BACKUP_DIR/daemon.json" ]]; then
        cp "$BACKUP_DIR/daemon.json" "$DAEMON_JSON"
    else
        rm -f "$DAEMON_JSON"
    fi
    restart_docker
    wait_for_docker && echo "==> Docker is back with the previous config" \
        || echo "==> Docker did not come back. Check: journalctl --user -u docker -n 50" >&2
}

status() {
    echo "userland proxy: $(docker info 2>/dev/null | grep -i EnableUserlandProxy || echo 'docker not reachable')"
    echo "daemon.json:    $([[ -f "$DAEMON_JSON" ]] && cat "$DAEMON_JSON" || echo absent)"
    echo "override:       $([[ -f "$OVERRIDE" ]] && echo present || echo absent)"
    echo "running:        $(docker ps --format '{{.Names}}' 2>/dev/null | tr '\n' ' ')"
}

apply() {
    if [[ -f "$DAEMON_JSON" && ! -d "$BACKUP_DIR" ]]; then
        echo "==> $DAEMON_JSON already exists; merge userland-proxy=false by hand first." >&2
        exit 1
    fi
    echo "==> Running before:"; docker ps --format '{{.Names}}' | sort | tr '\n' ' '; echo
    mkdir -p "$BACKUP_DIR" "$(dirname "$DAEMON_JSON")" "$OVERRIDE_DIR"
    [[ -f "$DAEMON_JSON" ]] && cp "$DAEMON_JSON" "$BACKUP_DIR/daemon.json"

    echo '{ "userland-proxy": false }' > "$DAEMON_JSON"
    # Without br_netfilter, dockerd refuses to start when the userland proxy is off.
    printf '[Service]\nEnvironment="DOCKER_IGNORE_BR_NETFILTER_ERROR=1"\n' > "$OVERRIDE"

    echo "==> Restarting docker (all containers restart)"
    restart_docker
    if ! wait_for_docker; then
        echo "==> Docker did not come back" >&2
        rollback
        exit 1
    fi

    if ! docker info 2>/dev/null | grep -q 'EnableUserlandProxy: false'; then
        echo "==> Setting did not take effect" >&2
        rollback
        exit 1
    fi

    echo "==> Waiting for proxy container"
    for _ in $(seq 1 30); do
        [[ "$(docker inspect -f '{{.State.Running}}' proxy 2>/dev/null)" == "true" ]] && break
        sleep 2
    done
    if [[ "$(docker inspect -f '{{.State.Running}}' proxy 2>/dev/null)" != "true" ]]; then
        echo "==> proxy did not start" >&2
        rollback
        exit 1
    fi

    echo "==> Running after:"; docker ps --format '{{.Names}}' | sort | tr '\n' ' '; echo
    echo "==> Done. Verify from an outside device that the newest remote_ip in"
    echo "    proxy/logs/wp-staging-access.log is that device's public IP."
    echo "    Undo with: bash scripts/rootless-userland-proxy.sh rollback"
}

case "${1:-}" in
    apply) apply ;;
    rollback) rollback ;;
    status) status ;;
    *) echo "Usage: $0 apply|rollback|status" >&2; exit 1 ;;
esac
