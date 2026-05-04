#!/usr/bin/env bash
# Install and configure fail2ban on the host.
# Safe to re-run; skips steps already done.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_F2B_CONF="$SCRIPT_DIR/../f2b/fail2ban/jail.local"
REPO_F2B_FILTER_DIR="$SCRIPT_DIR/../f2b/fail2ban/filter.d"
SYSTEM_JAIL_LOCAL="/etc/fail2ban/jail.local"

# Read PROXY_LOG_DIR from .env if present, fall back to the conventional default.
# This path must match logpath in f2b/fail2ban/jail.local.
ENV_FILE="$SCRIPT_DIR/../.env"
PROXY_LOG_DIR="/var/log/caddy-proxy"
if [[ -f "$ENV_FILE" ]]; then
    _val=$(grep -E '^PROXY_LOG_DIR=' "$ENV_FILE" | cut -d= -f2- | tr -d '"'"'" 2>/dev/null || true)
    [[ -n "$_val" ]] && PROXY_LOG_DIR="$_val"
fi

# --- 1. Install fail2ban if not present ---
if ! command -v fail2ban-client &>/dev/null; then
    echo "==> fail2ban not found. Installing..."
    sudo apt-get update
    sudo apt-get install -y fail2ban
else
    echo "==> fail2ban already installed ($(fail2ban-client --version | head -1))."
fi

# --- 2. Create proxy log directory (Caddy bind-mount target) ---
if [[ ! -d "$PROXY_LOG_DIR" ]]; then
    echo "==> Creating proxy log dir at $PROXY_LOG_DIR..."
    sudo mkdir -p "$PROXY_LOG_DIR"
    sudo chmod 755 "$PROXY_LOG_DIR"
else
    echo "==> Proxy log dir exists: $PROXY_LOG_DIR"
fi

# --- 3. Deploy jail.local ---
if [[ ! -f "$REPO_F2B_CONF" ]]; then
    echo "ERROR: repo jail.local not found at $REPO_F2B_CONF" >&2
    exit 1
fi

if [[ -f "$SYSTEM_JAIL_LOCAL" ]]; then
    if diff -q "$REPO_F2B_CONF" "$SYSTEM_JAIL_LOCAL" &>/dev/null; then
        echo "==> /etc/fail2ban/jail.local already up to date."
    else
        echo "==> Updating /etc/fail2ban/jail.local..."
        sudo cp "$REPO_F2B_CONF" "$SYSTEM_JAIL_LOCAL"
        RELOAD=true
    fi
else
    echo "==> Installing /etc/fail2ban/jail.local..."
    sudo cp "$REPO_F2B_CONF" "$SYSTEM_JAIL_LOCAL"
    RELOAD=true
fi

# --- 4. Deploy custom filter definitions ---
if [[ -d "$REPO_F2B_FILTER_DIR" ]]; then
    for filter_file in "$REPO_F2B_FILTER_DIR"/*.conf; do
        [[ -f "$filter_file" ]] || continue
        dest="/etc/fail2ban/filter.d/$(basename "$filter_file")"
        if [[ ! -f "$dest" ]] || ! diff -q "$filter_file" "$dest" &>/dev/null; then
            echo "==> Installing filter $(basename "$filter_file")..."
            sudo cp "$filter_file" "$dest"
            RELOAD=true
        else
            echo "==> Filter $(basename "$filter_file") already up to date."
        fi
    done
fi

# --- 5. Enable and start fail2ban ---
if ! systemctl is-enabled --quiet fail2ban 2>/dev/null; then
    echo "==> Enabling fail2ban service..."
    sudo systemctl enable fail2ban
fi

if ! systemctl is-active --quiet fail2ban 2>/dev/null; then
    echo "==> Starting fail2ban..."
    sudo systemctl start fail2ban
elif [[ "${RELOAD:-false}" == "true" ]]; then
    echo "==> Reloading fail2ban to apply updated jail.local..."
    sudo fail2ban-client reload
fi

echo ""
echo "Done. fail2ban status:"
sudo fail2ban-client status
