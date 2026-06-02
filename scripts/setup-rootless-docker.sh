#!/usr/bin/env bash
# Set up rootless Docker for the current user.
# Run once on a fresh machine before bringing the stack up.
# Safe to re-run; skips steps already done.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"

# --- 1. Install Docker CE if not present ---
if ! command -v docker &>/dev/null; then
    echo "==> Docker not found. Installing Docker CE..."
    sudo apt-get update
    sudo apt-get install -y ca-certificates curl gnupg lsb-release
    sudo install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/debian/gpg \
        | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    echo \
        "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/debian $(lsb_release -cs) stable" \
        | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
    sudo apt-get update
    sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
else
    echo "==> Docker already installed ($(docker --version))."
fi

# --- 2. Disable root Docker daemon if running ---
if systemctl is-active --quiet docker 2>/dev/null || systemctl is-enabled --quiet docker 2>/dev/null; then
    echo "==> Disabling root Docker daemon..."
    sudo systemctl disable --now docker docker.socket
else
    echo "==> Root Docker daemon not active, skipping."
fi

# --- 3. Install rootless extras ---
echo "==> Installing rootless extras..."
sudo apt-get install -y docker-ce-rootless-extras uidmap
ROOTLESS_SETUP_TOOL="$(command -v dockerd-rootless-setuptool.sh)"

# --- 4. Install rootless Docker for current user ---
if ! systemctl --user is-active --quiet docker 2>/dev/null; then
    echo "==> Installing rootless Docker for $USER..."
    "$ROOTLESS_SETUP_TOOL" install
else
    echo "==> Rootless Docker already running for $USER, skipping install."
fi

# --- 5. Allow unprivileged port binding (80/443) ---
SYSCTL_CONF=/etc/sysctl.d/99-rootless-docker.conf
if [[ ! -f "$SYSCTL_CONF" ]] || ! grep -q 'ip_unprivileged_port_start=0' "$SYSCTL_CONF"; then
    echo "==> Allowing unprivileged port binding (80/443)..."
    echo 'net.ipv4.ip_unprivileged_port_start=0' | sudo tee "$SYSCTL_CONF"
    sudo sysctl -w net.ipv4.ip_unprivileged_port_start=0
else
    echo "==> Unprivileged port binding already configured."
fi

# --- 6. Enable linger so user services survive logout ---
if ! loginctl show-user "$USER" 2>/dev/null | grep -q 'Linger=yes'; then
    echo "==> Enabling linger for $USER..."
    sudo loginctl enable-linger "$USER"
else
    echo "==> Linger already enabled for $USER."
fi

# --- 7. Set DOCKER_HOST ---
DOCKER_HOST_VAL="unix:///run/user/$(id -u)/docker.sock"
export DOCKER_HOST="$DOCKER_HOST_VAL"

BASHRC_LINE="export DOCKER_HOST=\"unix:///run/user/\$(id -u)/docker.sock\""
if ! grep -qxF "$BASHRC_LINE" ~/.bashrc; then
    echo "==> Adding DOCKER_HOST to ~/.bashrc..."
    echo "$BASHRC_LINE" >> ~/.bashrc
else
    echo "==> DOCKER_HOST already in ~/.bashrc."
fi

# --- 8. Create external networks ---
echo "==> Ensuring external networks exist..."
docker network inspect abcnorio_net_internal &>/dev/null || docker network create abcnorio_net_internal
docker network inspect abcnorio_net_web &>/dev/null      || docker network create abcnorio_net_web

# --- 9. Bring stack up ---
echo "==> Bringing stack up (full rebuild)..."
cd "$SCRIPT_DIR/.."
docker compose up -d --build

echo ""
echo "Done. Rootless Docker is active."
echo "Run: source ~/.bashrc   (or open a new shell) to persist DOCKER_HOST."
echo "Run: just status        to verify all containers are healthy."
