#!/usr/bin/env bash
# Create a host swapfile and set low swappiness so swap is an OOM safety valve.
# Safe to re-run. Size via SWAP_SIZE (default 4G).

set -euo pipefail

SWAPFILE="/swapfile"
SWAP_SIZE="${SWAP_SIZE:-4G}"
SYSCTL_CONF="/etc/sysctl.d/99-swappiness.conf"

# /proc/swaps avoids needing /usr/sbin on PATH
if [[ "$(wc -l < /proc/swaps)" -gt 1 ]]; then
    echo "==> Swap already active:"
    cat /proc/swaps
else
    echo "==> Creating ${SWAP_SIZE} swapfile at ${SWAPFILE}..."
    if [[ ! -f "$SWAPFILE" ]]; then
        sudo fallocate -l "$SWAP_SIZE" "$SWAPFILE"
        sudo chmod 600 "$SWAPFILE"
        sudo mkswap "$SWAPFILE"
    fi
    sudo swapon "$SWAPFILE"
fi

if ! grep -qs "^${SWAPFILE} " /etc/fstab; then
    echo "${SWAPFILE} none swap sw 0 0" | sudo tee -a /etc/fstab >/dev/null
fi

echo "vm.swappiness=10" | sudo tee "$SYSCTL_CONF" >/dev/null
sudo sysctl --system >/dev/null

echo "==> Swap ready:"
cat /proc/swaps
echo "vm.swappiness=$(cat /proc/sys/vm/swappiness)"
