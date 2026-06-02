#!/usr/bin/env bash
# Install and configure fail2ban for host SSH and proxy login hardening.
# Safe to re-run.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_F2B_CONF="$SCRIPT_DIR/../f2b/fail2ban/jail.local"
REPO_F2B_FILTER_DIR="$SCRIPT_DIR/../f2b/fail2ban/filter.d"
SYSTEM_JAIL_LOCAL="/etc/fail2ban/jail.local"
ENV_FILE="$SCRIPT_DIR/../.env"
PROXY_LOG_DIR="/var/log/caddy-proxy"

if [[ -f "$ENV_FILE" ]]; then
    _val=$(grep -E '^PROXY_LOG_DIR=' "$ENV_FILE" | cut -d= -f2- | tr -d '"' 2>/dev/null || true)
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

# --- 2. Ensure proxy log paths exist for fail2ban ---
echo "==> Ensuring proxy log paths exist at $PROXY_LOG_DIR..."
sudo mkdir -p "$PROXY_LOG_DIR"
sudo chmod 755 "$PROXY_LOG_DIR"
sudo touch "$PROXY_LOG_DIR/wp-staging-access.log"
sudo touch "$PROXY_LOG_DIR/wp-dev-access.log"
sudo chmod 644 "$PROXY_LOG_DIR/wp-staging-access.log" "$PROXY_LOG_DIR/wp-dev-access.log"

# --- 3. Deploy jail.local ---
if [[ ! -f "$REPO_F2B_CONF" ]]; then
    echo "ERROR: repo jail.local not found at $REPO_F2B_CONF" >&2
    exit 1
fi

RENDERED_JAIL_LOCAL="$(mktemp)"
trap 'rm -f "$RENDERED_JAIL_LOCAL"' EXIT
sed "s|__PROXY_LOG_DIR__|$PROXY_LOG_DIR|g" "$REPO_F2B_CONF" > "$RENDERED_JAIL_LOCAL"

if [[ -f "$SYSTEM_JAIL_LOCAL" ]]; then
    if diff -q "$RENDERED_JAIL_LOCAL" "$SYSTEM_JAIL_LOCAL" &>/dev/null; then
        echo "==> /etc/fail2ban/jail.local already up to date."
    else
        echo "==> Updating /etc/fail2ban/jail.local..."
        sudo cp "$RENDERED_JAIL_LOCAL" "$SYSTEM_JAIL_LOCAL"
        RELOAD=true
    fi
else
    echo "==> Installing /etc/fail2ban/jail.local..."
    sudo cp "$RENDERED_JAIL_LOCAL" "$SYSTEM_JAIL_LOCAL"
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
    if ! sudo systemctl start fail2ban; then
        echo "ERROR: failed to start fail2ban. Recent journal:" >&2
        sudo journalctl -u fail2ban --no-pager -n 50 || true
        exit 1
    fi
elif [[ "${RELOAD:-false}" == "true" ]]; then
    echo "==> Reloading fail2ban to apply updated jail.local..."
    if ! sudo fail2ban-client reload; then
        echo "ERROR: failed to reload fail2ban. Recent journal:" >&2
        sudo journalctl -u fail2ban --no-pager -n 50 || true
        exit 1
    fi
fi

echo ""
echo "Done. fail2ban status:"
sudo fail2ban-client status
