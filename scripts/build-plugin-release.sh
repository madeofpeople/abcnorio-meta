#!/usr/bin/env bash
# Build a clean-room, deployable zip artifact for a tagged abcnorio-func release.
#
# Exports the exact tagged commit via `git archive` (not the working tree),
# builds it in an isolated scratch dir, and zips the runtime footprint.
# The zip is never committed to git; it is consumed by Bedrock's Composer
# `artifact` repository at wp/plugin-artifacts/.
set -euo pipefail

TAG=""
CANDIDATE_VERSION=""
SOURCE_REF=""

if [[ "${1:-}" == "--candidate-version" ]]; then
  CANDIDATE_VERSION="${2:-}"
  [[ "$CANDIDATE_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
    echo "Usage: $0 --candidate-version <major.minor.patch>" >&2
    exit 1
  }
  SOURCE_REF="HEAD"
elif [[ $# -le 1 ]]; then
  TAG="${1:-}"
else
  echo "Usage: $0 [tag] | --candidate-version <major.minor.patch>" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
META_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
FUNC_DIR="${META_DIR}/../abcnorio-func"
ARTIFACT_DIR="${META_DIR}/wp/plugin-artifacts"
RETAIN_COUNT=3

[[ -d "$FUNC_DIR" ]] || { echo "Missing plugin repo: $FUNC_DIR" >&2; exit 1; }

if [[ -z "$CANDIDATE_VERSION" && -z "$TAG" ]]; then
  CURRENT_VERSION="$(node -e 'const fs=require("fs"); const p=JSON.parse(fs.readFileSync(process.argv[1],"utf8")); process.stdout.write(String(p.version||""));' "$FUNC_DIR/composer.json")"
  [[ -n "$CURRENT_VERSION" ]] || { echo "Failed reading current version from composer.json" >&2; exit 1; }
  TAG="v$CURRENT_VERSION"
fi

if [[ -n "$CANDIDATE_VERSION" ]]; then
  SOURCE_REF="HEAD"
else
  SOURCE_REF="$TAG"
  (cd "$FUNC_DIR" && git rev-parse --verify "refs/tags/$TAG" >/dev/null) || {
    echo "Tag not found in $FUNC_DIR: $TAG" >&2
    exit 1
  }
fi

for cmd in git npm node tar; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "Missing required command: $cmd" >&2; exit 1; }
done

SCRATCH_DIR="$(mktemp -d)"
cleanup() { rm -rf "$SCRATCH_DIR"; }
trap cleanup EXIT

if [[ -n "$CANDIDATE_VERSION" ]]; then
  echo "[1/4] Exporting HEAD for candidate v$CANDIDATE_VERSION into scratch dir"
else
  echo "[1/4] Exporting $TAG into scratch dir"
fi
(cd "$FUNC_DIR" && git archive --format=tar "$SOURCE_REF") | tar -x -C "$SCRATCH_DIR"

if [[ -n "$CANDIDATE_VERSION" ]]; then
  node - "$SCRATCH_DIR/composer.json" "$SCRATCH_DIR/custom-func.php" "$CANDIDATE_VERSION" <<'NODE'
const fs = require('fs');
const composerPath = process.argv[2];
const headerPath = process.argv[3];
const version = process.argv[4];

const composer = JSON.parse(fs.readFileSync(composerPath, 'utf8'));
composer.version = version;
fs.writeFileSync(composerPath, JSON.stringify(composer, null, 4) + '\n');

const header = fs.readFileSync(headerPath, 'utf8');
const updated = header.replace(/(\* Version:\s*)([^\n]+)/, `$1${version}`);
if (updated === header) {
  throw new Error('Could not update plugin header version in candidate export');
}
fs.writeFileSync(headerPath, updated);
NODE
fi

echo "[2/4] Building exported tree"
(cd "$SCRATCH_DIR" && npm ci && npm run build)

for required_file in \
  "build/index.js" \
  "build/index.asset.php" \
  "resources/vendor/components/dist/manifest.json"
do
  [[ -f "$SCRATCH_DIR/$required_file" ]] || {
    echo "Build did not produce required runtime file: $required_file" >&2
    exit 1
  }
done

VERSION="$(node -e 'const fs=require("fs"); const p=JSON.parse(fs.readFileSync(process.argv[1],"utf8")); process.stdout.write(String(p.version||""));' "$SCRATCH_DIR/composer.json")"
[[ -n "$VERSION" ]] || { echo "Failed reading version from exported composer.json" >&2; exit 1; }
EXPECTED_VERSION="${CANDIDATE_VERSION:-${TAG#v}}"
if [[ "$VERSION" != "$EXPECTED_VERSION" ]]; then
  echo "Release version mismatch: expected $EXPECTED_VERSION got $VERSION" >&2
  exit 1
fi

ZIP_NAME="abcnorio-func-$VERSION.tar.gz"
mkdir -p "$ARTIFACT_DIR"

echo "[3/4] Packaging $ZIP_NAME"
rm -f "${ARTIFACT_DIR:?}/$ZIP_NAME"
(cd "$SCRATCH_DIR" && tar czf "$ARTIFACT_DIR/$ZIP_NAME" composer.json custom-func.php src resources build)

ARCHIVE_ENTRIES="$(tar -tzf "$ARTIFACT_DIR/$ZIP_NAME")"
for required_entry in \
  "composer.json" \
  "custom-func.php" \
  "build/index.js" \
  "build/index.asset.php" \
  "resources/vendor/components/dist/manifest.json"
do
  if ! grep -Fx "$required_entry" <<<"$ARCHIVE_ENTRIES" >/dev/null; then
    echo "Release artifact missing required entry: $required_entry" >&2
    exit 1
  fi
done

echo "[4/4] Pruning artifact folder to latest $RETAIN_COUNT"
# shellcheck disable=SC2012
ls -1t "$ARTIFACT_DIR"/abcnorio-func-*.tar.gz 2>/dev/null | tail -n +$((RETAIN_COUNT + 1)) | while IFS= read -r stale_zip; do
  rm -f -- "$stale_zip"
done

echo "done: $ARTIFACT_DIR/$ZIP_NAME"
