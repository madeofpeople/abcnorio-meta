#!/bin/bash
# Bump the abcnorio-webcomponents pin in abcnorio-astro's package-lock.json to origin/main.
# Deploys install the locked SHA, so this must be committed in abcnorio-astro before deploy-staging.
set -euo pipefail

META_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WC_DIR="${META_DIR}/../abcnorio-webcomponents"
ASTRO_DIR="${META_DIR}/../abcnorio-astro"
FRONTEND_DIR="${ASTRO_DIR}/site-frontend"
LOCK_KEY='node_modules/abcnorio-webcomponents'

lock_sha() {
    node -e "
        const lock = JSON.parse(require('fs').readFileSync(process.argv[1], 'utf8'));
        console.log(lock.packages[process.argv[2]].resolved.split('#')[1]);
    " "$FRONTEND_DIR/package-lock.json" "$LOCK_KEY"
}

if [ -n "$(git -C "$WC_DIR" status --porcelain)" ]; then
    echo "error: $WC_DIR has uncommitted changes. Commit and push first." >&2
    exit 1
fi

remote_sha="$(git -C "$WC_DIR" ls-remote origin refs/heads/main | cut -f1)"
if [ "$(git -C "$WC_DIR" rev-parse HEAD)" != "$remote_sha" ]; then
    echo "error: webcomponents HEAD is not origin/main ($remote_sha). Push (or check out main) first." >&2
    exit 1
fi

old_sha="$(lock_sha)"
(cd "$FRONTEND_DIR" && npm update abcnorio-webcomponents --package-lock-only --ignore-scripts)
new_sha="$(lock_sha)"

if [ "$old_sha" = "$new_sha" ]; then
    echo "Pin already current: $new_sha"
    exit 0
fi

echo "Pin: ${old_sha:0:7} -> ${new_sha:0:7}"
git -C "$ASTRO_DIR" --no-pager diff --stat -- site-frontend/package-lock.json
echo "Review, commit on abcnorio-astro main, then merge main into staging:"
echo "  git -C $ASTRO_DIR commit -am 'Bump abcnorio-webcomponents pin to ${new_sha:0:7}'"
echo "  git -C $ASTRO_DIR checkout staging && git -C $ASTRO_DIR merge main && git -C $ASTRO_DIR checkout main"
