#!/usr/bin/env bash
set -euo pipefail

META_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
for repo in "$META_DIR" "$META_DIR/../abcnorio-func" "$META_DIR/../abcnorio-webcomponents" "$META_DIR/../abcnorio-astro" "$META_DIR/../abcnorio-orchestrator"; do
  [[ -z "$(git -C "$repo" status --porcelain)" ]] || { echo "Commit changes first: $repo" >&2; exit 1; }
done
node - "$META_DIR" <<'NODE'
const fs = require('node:fs');
const path = require('node:path');
const {execFileSync} = require('node:child_process');
const meta = process.argv[2];
const expected = execFileSync('git', ['-C', path.join(meta, '../abcnorio-webcomponents'), 'rev-parse', 'HEAD'], {encoding:'utf8'}).trim();
for (const relative of ['../abcnorio-func/package-lock.json', '../abcnorio-astro/site-frontend/package-lock.json']) {
  const lock = JSON.parse(fs.readFileSync(path.join(meta, relative), 'utf8'));
  const sha = lock.packages?.['node_modules/abcnorio-webcomponents']?.resolved?.split('#')[1];
  if (sha !== expected) throw new Error(`${relative}: component pin differs from component HEAD. Push components, run just wc pin, review and commit both lockfiles.`);
}
NODE

echo "Running release tooling tests."
(
  cd "$META_DIR"
  node --test scripts/test-deploy-staging.mjs scripts/test-webcomponents-pin.mjs scripts/test-plugin-dev.mjs scripts/test-recipe-routing.mjs
)

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
echo "Checking committed source with Node $(node -v), npm $(npm -v). Use the same supported toolchain as the VPS."
for repo in abcnorio-func abcnorio-astro; do
  mkdir "$scratch/$repo"
  git -C "$META_DIR/../$repo" archive HEAD | tar -xf - -C "$scratch/$repo"
  git -C "$META_DIR/../$repo" log -1 --format="$repo %H"
done
(
  cd "$scratch/abcnorio-func"
  npm ci --engine-strict
  env -u ABCNORIO_COMPONENTS_DIST_SOURCE npm run build
)
(
  cd "$scratch/abcnorio-astro/site-frontend"
  npm ci --engine-strict
  # Staging uses SSR; check compilation without a production content export.
  MODE=staging \
    STAGING_CMS="${STAGING_CMS:-http://127.0.0.1:8201}" \
    STAGING_FRONTEND_URL="${STAGING_FRONTEND_URL:-http://127.0.0.1:3133}" \
    ASTRO_WEBCOMPONENTS_SOURCE_DIR="$PWD/node_modules/abcnorio-webcomponents" \
    npm run build
)
echo "Release check passed for the commits above. Push them, update the VPS branches, then run just release staging [plugin <patch|minor|major>]."
