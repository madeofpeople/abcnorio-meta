#!/usr/bin/env bash
set -euo pipefail

if [[ $# -gt 0 ]]; then
  echo "error: unexpected argument: $1" >&2
  echo "usage: approve-frontend-deploy.sh" >&2
  exit 1
fi

META_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ASTRO_REPO_DIR="${ASTRO_REPO_DIR:-${META_DIR}/../abcnorio-astro}"
SOURCE_BRANCH="${SOURCE_BRANCH:-main}"
TAG_PREFIX="staging-deploy"

cd "$ASTRO_REPO_DIR"

if [[ -n "$(git status --porcelain)" ]]; then
  echo "error: abcnorio-astro working tree is dirty"
  exit 1
fi

CURRENT_BRANCH="$(git rev-parse --abbrev-ref HEAD)"
if [[ "$CURRENT_BRANCH" != "$SOURCE_BRANCH" ]]; then
  echo "error: expected branch '$SOURCE_BRANCH', found '$CURRENT_BRANCH'"
  exit 1
fi

COMMIT_SHA="$(git rev-parse --verify HEAD)"
SHORT_SHA="${COMMIT_SHA:0:7}"
DATE="$(date -u +%Y-%m-%d)"
TAG_NAME="${TAG_PREFIX}-${DATE}-${SHORT_SHA}"

EXISTING_SHA="$(git rev-parse --verify --quiet "${TAG_NAME}^{commit}" || true)"
if [[ -n "$EXISTING_SHA" && "$EXISTING_SHA" != "$COMMIT_SHA" ]]; then
  echo "error: tag ${TAG_NAME} already exists at ${EXISTING_SHA}, expected ${COMMIT_SHA}"
  exit 1
fi

if [[ -z "$EXISTING_SHA" ]]; then
  git tag -a "$TAG_NAME" "$COMMIT_SHA" -m "Staging deploy approval ${DATE} ${SHORT_SHA}"
fi

git push origin "$TAG_NAME"

echo "approved_tag=${TAG_NAME}"
echo "approved_commit=${COMMIT_SHA}"
