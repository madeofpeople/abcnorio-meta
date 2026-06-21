#!/usr/bin/env bash
set -euo pipefail

ENV="${1:-}"
BUMP="${2:-patch}"
MODE="${3:-}"

require_clean_repo() {
  local repo_dir="$1"
  local message="$2"

  if [[ -n "$(cd "$repo_dir" && git status --porcelain)" ]]; then
    echo "$message" >&2
    exit 1
  fi
}

case "$ENV" in
  dev|staging) ;;
  *) echo "Unknown env: $ENV (expected dev or staging)" >&2; exit 1 ;;
esac

case "$BUMP" in
  patch|minor|major) ;;
  *) echo "Unknown bump: $BUMP (expected patch|minor|major)" >&2; exit 1 ;;
esac

case "$MODE" in
  ""|dry) ;;
  *) echo "Unknown mode: $MODE (expected 'dry' or empty)" >&2; exit 1 ;;
esac

for cmd in npm git docker node; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "Missing required command: $cmd" >&2; exit 1; }
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
META_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
FUNC_DIR="${META_DIR}/../abcnorio-func"
WC_DIR="${META_DIR}/../abcnorio-webcomponents"

[[ -d "$FUNC_DIR" ]] || { echo "Missing plugin repo: $FUNC_DIR" >&2; exit 1; }
[[ -d "$WC_DIR" ]] || { echo "Missing webcomponents repo: $WC_DIR" >&2; exit 1; }

if [[ "$ENV" == "dev" ]]; then
  CONTAINER="abcwpdev"
else
  CONTAINER="abcwpstaging"
fi

PLUGIN_BOOTSTRAP_PATH="/app/web/app/plugins/abcnorio-func/custom-func.php"
PLUGIN_MANIFEST_PATH="/app/web/app/plugins/abcnorio-func/resources/vendor/components/dist/manifest.json"
PLUGIN_SLUG="$(basename "$(dirname "$PLUGIN_BOOTSTRAP_PATH")")"

if ! docker ps --format '{{.Names}}' | grep -qx "$CONTAINER"; then
  echo "Container not running: $CONTAINER. Start it with: just up $ENV" >&2
  exit 1
fi

if [[ "$MODE" != "dry" ]]; then
  require_clean_repo "$WC_DIR" "Dirty tree in $WC_DIR. Commit/stash first."
  require_clean_repo "$FUNC_DIR" "Dirty tree in $FUNC_DIR. Commit/stash first."
fi

echo "[1/7] Build webcomponents"
(cd "$WC_DIR" && npm run build)

echo "[2/7] Verify webcomponents manifest"
(cd "$WC_DIR" && npm run check:manifest)

echo "[3/7] Build plugin and ingest dist"
(cd "$FUNC_DIR" && npm install && npm run build)

MANIFEST_PATH="$FUNC_DIR/resources/vendor/components/dist/manifest.json"
[[ -f "$MANIFEST_PATH" ]] || {
  echo "Missing ingested manifest: $MANIFEST_PATH" >&2
  exit 1
}

if [[ "$MODE" != "dry" ]]; then
  require_clean_repo "$WC_DIR" "Build changed $WC_DIR. Commit/stash those changes before release."
  require_clean_repo "$FUNC_DIR" "Build changed $FUNC_DIR. Commit/stash those changes before release."
fi

CURRENT_VERSION="$(node -e 'const fs=require("fs"); const p=JSON.parse(fs.readFileSync(process.argv[1],"utf8")); process.stdout.write(String(p.version||""));' "$FUNC_DIR/composer.json")"
[[ -n "$CURRENT_VERSION" ]] || { echo "Failed reading current version from composer.json" >&2; exit 1; }

NEXT_VERSION="$(node -e 'const [v,b]=process.argv.slice(1); const m=v.match(/^(\d+)\.(\d+)\.(\d+)$/); if(!m){process.exit(2)} let [_,M,mn,p]=m; M=+M; mn=+mn; p=+p; if(b==="patch") p+=1; else if(b==="minor"){mn+=1;p=0}else if(b==="major"){M+=1;mn=0;p=0}else{process.exit(3)} process.stdout.write(`${M}.${mn}.${p}`);' "$CURRENT_VERSION" "$BUMP")"
[[ -n "$NEXT_VERSION" ]] || { echo "Failed computing next version" >&2; exit 1; }

echo "Current version: $CURRENT_VERSION"
echo "Next version:    $NEXT_VERSION"

if [[ "$MODE" == "dry" ]]; then
  echo "[dry-run] Skipping version write, commit, tag, push, composer update, cache flush, snapshot"
  exit 0
fi

echo "[4/7] Bump plugin versions"
node -e '
  const fs=require("fs");
  const composerPath=process.argv[1];
  const headerPath=process.argv[2];
  const next=process.argv[3];

  const composer=JSON.parse(fs.readFileSync(composerPath,"utf8"));
  composer.version=next;
  fs.writeFileSync(composerPath, JSON.stringify(composer,null,4)+"\n");

  const header=fs.readFileSync(headerPath,"utf8");
  const updated=header.replace(/(\* Version:\s*)([^\n]+)/, `$1${next}`);
  if(updated===header){
    throw new Error("Could not update plugin header version in custom-func.php");
  }
  fs.writeFileSync(headerPath, updated);
' "$FUNC_DIR/composer.json" "$FUNC_DIR/custom-func.php" "$NEXT_VERSION"

echo "[5/7] Commit, tag, and push plugin"
(
  cd "$FUNC_DIR"
  git add composer.json custom-func.php
  git commit -m "release(plugin): v$NEXT_VERSION"
  git tag -a "v$NEXT_VERSION" -m "v$NEXT_VERSION"
  git push
  git push --tags
)

echo "[6/7] Update $ENV Bedrock plugin dependency"
if [[ "$ENV" == "dev" ]]; then
  docker exec "$CONTAINER" sh -lc 'set -euo pipefail; mkdir -p /app/packages; rm -f /app/packages/abcnorio-func; ln -s /abcnorio-func /app/packages/abcnorio-func; cd /app && composer require madeofpeople/abcnorio-func:'"$NEXT_VERSION"' --no-interaction'
else
  docker exec "$CONTAINER" sh -lc 'set -euo pipefail; cd /app && composer require madeofpeople/abcnorio-func:'"$NEXT_VERSION"' --no-interaction'
fi

docker exec "$CONTAINER" test -f "$PLUGIN_BOOTSTRAP_PATH"
docker exec "$CONTAINER" test -f "$PLUGIN_MANIFEST_PATH"
INSTALLED_VERSION="$(docker exec "$CONTAINER" wp --allow-root --path=/app/web/wp plugin get "$PLUGIN_SLUG" --field=version)"
echo "Runtime plugin version ($ENV): $INSTALLED_VERSION"
if [[ "$INSTALLED_VERSION" != "$NEXT_VERSION" ]]; then
  echo "Version mismatch: expected $NEXT_VERSION got $INSTALLED_VERSION" >&2
  exit 1
fi

docker exec "$CONTAINER" wp --allow-root --path=/app/web/wp cache flush

echo "[7/7] Sync Bedrock seed composer files"
cp "${META_DIR}/wp/${ENV}/bedrock/composer.json" "${META_DIR}/wp/bootstrap/${ENV}/bedrock.composer.json"
cp "${META_DIR}/wp/${ENV}/bedrock/composer.lock" "${META_DIR}/wp/bootstrap/${ENV}/bedrock.composer.lock"

echo "done: updated plugin to v$NEXT_VERSION for $ENV"
