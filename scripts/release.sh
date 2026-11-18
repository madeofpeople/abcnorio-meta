#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
target="${1:-}"
shift || true
case "$target" in
  check)
    [[ $# -eq 0 ]] || { echo "Usage: just release check" >&2; exit 1; }
    bash scripts/release-check.sh
    ;;
  staging)
    if [[ $# -ne 0 ]]; then
      [[ $# -eq 2 && "$1" == plugin ]] || { echo "Usage: just release staging [plugin <patch|minor|major>]" >&2; exit 1; }
      case "$2" in patch|minor|major) ;; *) echo "Invalid plugin version bump: $2" >&2; exit 1 ;; esac
    fi
    [[ -z "$(git -C ../abcnorio-astro status --porcelain)" ]] || {
      echo "Astro checkout has uncommitted changes. Commit or resolve them before releasing." >&2; exit 1;
    }
    git -C ../abcnorio-astro show-ref --verify --quiet refs/heads/staging || {
      echo "Missing local Astro staging branch. Update it to the intended committed revision first." >&2; exit 1;
    }
    if [[ $# -eq 2 ]]; then
      bash scripts/update-wp-plugin.sh staging "$2"
      echo "Plugin installed. Deploying Astro staging next; a failure does not undo the plugin installation."
    fi
    bash scripts/deploy-staging.sh
    ;;
  preview)
    [[ $# -eq 0 ]] || { echo "Usage: just release preview" >&2; exit 1; }
    ABCNORIO_PREVIEW_STAGING=1 bash scripts/trigger-build.sh preview
    ;;
  production)
    [[ $# -eq 0 ]] || { echo "Usage: just release production" >&2; exit 1; }
    bash scripts/deploy-release.sh production
    ;;
  rollback)
    [[ $# -ge 1 && $# -le 2 ]] || { echo "Usage: just release rollback <target> [release-id]" >&2; exit 1; }
    bash scripts/rollback-release.sh "$@"
    ;;
  docs)
    [[ $# -eq 0 ]] || { echo "Usage: just release docs" >&2; exit 1; }
    bash scripts/deploy-docs.sh
    ;;
  *) echo "Usage: just release check | staging [plugin <patch|minor|major>] | preview | production | rollback <target> [release-id] | docs" >&2; exit 1 ;;
esac
