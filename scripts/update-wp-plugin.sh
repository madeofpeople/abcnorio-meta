#!/usr/bin/env bash
set -euo pipefail

ENV="${1:-}"
BUMP="${2:-patch}"
COMMIT_MESSAGE_OVERRIDE=""
COMMIT_MESSAGE_SET=false

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

shift 2

while [[ $# -gt 0 ]]; do
  case "$1" in
    -m=*)
      COMMIT_MESSAGE_OVERRIDE="${1#-m=}"
      COMMIT_MESSAGE_SET=true
      ;;
    *)
      echo "Unexpected argument: $1" >&2
      echo "Usage: update-wp-plugin.sh <dev|staging> [patch|minor|major] [-m=<message>]" >&2
      exit 1
      ;;
  esac
  shift
done

for cmd in npm git docker node composer; do
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

assert_bedrock_write_contract() {
  local bedrock_dir="$1"
  local plugin_dir="$bedrock_dir/web/app/plugins/abcnorio-func"
  local plugin_parent="$(dirname "$plugin_dir")"

  [[ -d "$bedrock_dir" ]] || { echo "Bedrock directory missing: $bedrock_dir" >&2; exit 1; }
  [[ -w "$bedrock_dir/composer.json" ]] || { echo "Bedrock composer.json is not writable: $bedrock_dir/composer.json" >&2; exit 1; }
  [[ -w "$bedrock_dir/composer.lock" ]] || { echo "Bedrock composer.lock is not writable: $bedrock_dir/composer.lock" >&2; exit 1; }
  [[ -d "$plugin_dir" ]] || { echo "Installed plugin directory missing: $plugin_dir" >&2; exit 1; }
  [[ -w "$plugin_parent" ]] || { echo "Plugin parent directory is not writable: $plugin_parent" >&2; exit 1; }

  local unwritable_dir
  unwritable_dir="$(find "$plugin_dir" -type d ! -writable -print -quit)"
  if [[ -n "$unwritable_dir" ]]; then
    echo "Installed plugin directory contains an unwritable directory: $unwritable_dir" >&2
    exit 1
  fi
}

if ! docker ps --format '{{.Names}}' | grep -qx "$CONTAINER"; then
  echo "Container not running: $CONTAINER. Start it with: just up $ENV" >&2
  exit 1
fi

if [[ "$ENV" == "staging" ]]; then
  assert_bedrock_write_contract "$META_DIR/wp/staging/bedrock"
else
  assert_bedrock_write_contract "$META_DIR/wp/dev/bedrock"
fi

require_clean_repo "$WC_DIR" "Dirty tree in $WC_DIR. Commit/stash first."
require_clean_repo "$FUNC_DIR" "Dirty tree in $FUNC_DIR. Commit/stash first."

CURRENT_VERSION="$(node -e 'const fs=require("fs"); const p=JSON.parse(fs.readFileSync(process.argv[1],"utf8")); process.stdout.write(String(p.version||""));' "$FUNC_DIR/composer.json")"
[[ -n "$CURRENT_VERSION" ]] || { echo "Failed reading current version from composer.json" >&2; exit 1; }

NEXT_VERSION="$(node -e 'const [v,b]=process.argv.slice(1); const m=v.match(/^(\d+)\.(\d+)\.(\d+)$/); if(!m){process.exit(2)} let [_,M,mn,p]=m; M=+M; mn=+mn; p=+p; if(b==="patch") p+=1; else if(b==="minor"){mn+=1;p=0}else if(b==="major"){M+=1;mn=0;p=0}else{process.exit(3)} process.stdout.write(`${M}.${mn}.${p}`);' "$CURRENT_VERSION" "$BUMP")"
[[ -n "$NEXT_VERSION" ]] || { echo "Failed computing next version" >&2; exit 1; }

echo "[1/6] Verify webcomponents manifest without rebuilding live dist"
(cd "$WC_DIR" && npm run check:manifest)

require_clean_repo "$WC_DIR" "Build changed $WC_DIR. Commit/stash those changes before release."
require_clean_repo "$FUNC_DIR" "Build changed $FUNC_DIR. Commit/stash those changes before release."

echo "Current version: $CURRENT_VERSION"
echo "Next version:    $NEXT_VERSION"

COMMIT_MESSAGE="release(plugin): v$NEXT_VERSION"
if [[ "$COMMIT_MESSAGE_SET" == true ]]; then
  [[ -n "$COMMIT_MESSAGE_OVERRIDE" ]] || { echo "Commit message override cannot be empty" >&2; exit 1; }
  COMMIT_MESSAGE="$COMMIT_MESSAGE_OVERRIDE"
fi

echo "[2/6] Build and validate candidate artifact before release commit/tag"
bash "${SCRIPT_DIR}/build-plugin-release.sh" --candidate-version "$NEXT_VERSION"

echo "[3/6] Bump plugin versions"
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

echo "[4/6] Commit, tag, and push plugin"
(
  cd "$FUNC_DIR"
  git add composer.json custom-func.php
  git commit -m "$COMMIT_MESSAGE"
  git tag -a "v$NEXT_VERSION" -m "v$NEXT_VERSION"
  git push
  git push --tags
)

echo "[5/6] Update $ENV Bedrock plugin dependency"
if [[ "$ENV" == "staging" ]]; then
  BEDROCK_DIR="${META_DIR}/wp/staging/bedrock"
  [[ -d "$BEDROCK_DIR" ]] || { echo "Staging Bedrock directory not found: $BEDROCK_DIR" >&2; exit 1; }
  [[ -f "$BEDROCK_DIR/composer.json" ]] || { echo "Missing composer.json in staging Bedrock directory: $BEDROCK_DIR" >&2; exit 1; }
  echo "Updating staging Bedrock dependency from host-side composer"
  (
    cd "$BEDROCK_DIR"
    composer require "madeofpeople/abcnorio-func:$NEXT_VERSION" --no-interaction
  )
else
  echo "Skipping composer require for dev (mount-only plugin contract)."
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

echo "[6/6] Sync Bedrock seed composer files"
cp "${META_DIR}/wp/${ENV}/bedrock/composer.json" "${META_DIR}/wp/bootstrap/${ENV}/bedrock.composer.json"
cp "${META_DIR}/wp/${ENV}/bedrock/composer.lock" "${META_DIR}/wp/bootstrap/${ENV}/bedrock.composer.lock"

echo "done: updated plugin to v$NEXT_VERSION for $ENV"
