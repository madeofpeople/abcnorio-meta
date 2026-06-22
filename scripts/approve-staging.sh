#!/bin/bash
set -e

VERSION="${1:?Usage: approve-staging.sh VERSION (e.g. 0.1.0)}"

SITE_DEV="$(cd "$(dirname "$0")/../../abcnorio-astro/site-dev" && pwd)"
cd "$SITE_DEV"

# Validate working tree is clean
if [ -n "$(git status -s)" ]; then
    echo "error: working tree must be clean"
    echo "run: git status"
    exit 1
fi

# Validate tag doesn't already exist
TAG="staging-v$VERSION"
if git rev-parse "$TAG" 2>/dev/null >/dev/null; then
    echo "error: tag $TAG already exists"
    exit 1
fi

# Create and push tag
git tag -a "$TAG" -m "Approved for staging: v$VERSION"
git push origin "$TAG"
echo "✓ Approved: $TAG"
