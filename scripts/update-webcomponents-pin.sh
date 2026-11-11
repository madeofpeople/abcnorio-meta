#!/bin/bash
# Update Astro and plugin lockfiles to the pushed webcomponents main revision.
set -euo pipefail

META_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WC_DIR="${META_DIR}/../abcnorio-webcomponents"
ASTRO_DIR="${META_DIR}/../abcnorio-astro"
FUNC_DIR="${META_DIR}/../abcnorio-func"
FRONTEND_DIR="${ASTRO_DIR}/site-frontend"

lock_sha() {
    node -e '
        const lock = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
        const resolved = lock.packages?.["node_modules/abcnorio-webcomponents"]?.resolved;
        const sha = resolved?.split("#")[1];
        if (!sha || !/^[0-9a-f]{40}$/i.test(sha)) {
            throw new Error(`Missing webcomponents commit in ${process.argv[1]}`);
        }
        console.log(sha);
    ' "$1"
}

if [ -n "$(git -C "$WC_DIR" status --porcelain)" ]; then
    echo "error: $WC_DIR has uncommitted changes. Commit and push first." >&2
    exit 1
fi

remote_sha="$(git -C "$WC_DIR" ls-remote origin refs/heads/main | cut -f1)"
if [ -z "$remote_sha" ] || [ "$(git -C "$WC_DIR" rev-parse HEAD)" != "$remote_sha" ]; then
    echo "error: webcomponents HEAD is not origin/main ($remote_sha). Push (or check out main) first." >&2
    exit 1
fi

astro_lock="$FRONTEND_DIR/package-lock.json"
plugin_lock="$FUNC_DIR/package-lock.json"
for lock in "$astro_lock" "$plugin_lock"; do
    if [ ! -f "$lock" ]; then
        echo "error: missing lockfile: $lock" >&2
        exit 1
    fi
done

astro_old="$(lock_sha "$astro_lock")"
plugin_old="$(lock_sha "$plugin_lock")"

check_clean_lock() {
    local repo="$1" path="$2" old="$3"
    if [ "$old" != "$remote_sha" ] && [ -n "$(git -C "$repo" status --porcelain -- "$path")" ]; then
        echo "error: $repo/$path has uncommitted changes. Review and commit them before updating its pin." >&2
        exit 1
    fi
}

check_clean_lock "$ASTRO_DIR" site-frontend/package-lock.json "$astro_old"
check_clean_lock "$FUNC_DIR" package-lock.json "$plugin_old"

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

prepare_lock() {
    local source="$1" name="$2" old="$3"
    if [ "$old" = "$remote_sha" ]; then
        echo "$name pin already current: $remote_sha"
        return
    fi

    mkdir -p "$scratch/$name"
    cp "$source/package.json" "$source/package-lock.json" "$scratch/$name/"
    (cd "$scratch/$name" && npm update abcnorio-webcomponents --package-lock-only --ignore-scripts)
    local new_sha
    new_sha="$(lock_sha "$scratch/$name/package-lock.json")"
    if [ "$new_sha" != "$remote_sha" ]; then
        echo "error: $name resolved $new_sha instead of expected $remote_sha. No lockfiles updated." >&2
        exit 1
    fi
    echo "$name pin: ${old:0:7} -> ${new_sha:0:7}"
}

prepare_lock "$FRONTEND_DIR" astro "$astro_old"
prepare_lock "$FUNC_DIR" plugin "$plugin_old"

if [ "$(git -C "$WC_DIR" ls-remote origin refs/heads/main | cut -f1)" != "$remote_sha" ]; then
    echo "error: webcomponents origin/main changed during update. No lockfiles updated; retry." >&2
    exit 1
fi

if [ "$astro_old" != "$remote_sha" ]; then
    cp "$scratch/astro/package-lock.json" "$astro_lock"
fi
if [ "$plugin_old" != "$remote_sha" ]; then
    cp "$scratch/plugin/package-lock.json" "$plugin_lock"
fi

echo "Review both lockfiles, then commit the Astro and plugin changes."
git -C "$ASTRO_DIR" --no-pager diff --stat HEAD -- site-frontend/package-lock.json
git -C "$FUNC_DIR" --no-pager diff --stat HEAD -- package-lock.json
if [ -n "$(git -C "$FUNC_DIR" ls-files --others --exclude-standard -- package-lock.json)" ]; then
    echo "Plugin package-lock.json is untracked; review and add it before release."
fi
