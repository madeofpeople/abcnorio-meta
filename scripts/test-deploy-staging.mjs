import assert from 'node:assert/strict';
import { randomBytes } from 'node:crypto';
import { execFileSync, spawnSync } from 'node:child_process';
import { chmodSync, copyFileSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';

function setup(t, staging = true) {
  const root = mkdtempSync(path.join(os.tmpdir(), 'staging-deploy-test-'));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  const meta = path.join(root, 'abcnorio-meta');
  const astro = path.join(root, 'abcnorio-astro');
  const bin = path.join(root, 'bin');
  const workdir = path.join(root, 'build');
  for (const dir of [path.join(meta, 'scripts'), path.join(meta, 'wp'), path.join(astro, 'site-frontend'), path.join(workdir, 'staging-site-frontend'), bin]) {
    mkdirSync(dir, { recursive: true });
  }
  copyFileSync(new URL('./deploy-staging.sh', import.meta.url), path.join(meta, 'scripts/deploy-staging.sh'));
  writeFileSync(path.join(meta, '.env'), `ASTRO_BUILD_TRIGGER_SECRET=${randomBytes(24).toString('hex')}\nASTRO_BUILD_WORKDIR_HOST_DIR=${workdir}\n`);
  writeFileSync(path.join(meta, 'wp/runtime.env'), 'ASTRO_BUILD_ARCHIVE_DIR=/app/backups\n');
  writeFileSync(path.join(astro, 'site-frontend/package-lock.json'), JSON.stringify({
    packages: { 'node_modules/abcnorio-webcomponents': { resolved: `git+https://example.invalid/components#${'a'.repeat(40)}` } },
  }));
  const git = (...args) => execFileSync('git', ['-C', astro, ...args], { stdio: 'pipe' });
  git('init', '-b', 'main');
  git('config', 'user.name', 'Test');
  git('config', 'user.email', 'test@example.invalid');
  git('add', '.');
  git('commit', '-m', 'fixture');
  if (staging) git('branch', 'staging');

  const docker = path.join(bin, 'docker');
  writeFileSync(docker, `#!/bin/bash
set -euo pipefail
if [[ "$1" == exec && "$2" == deploy-orchestrator && "$*" == *"/dev-tools/push-to-staging"* ]]; then
  echo '{"success":true}'
elif [[ "$1" == exec && "$2" == deploy-orchestrator && "$*" == *"/dev-tools/status"* ]]; then
  echo '{"data":{"push":{"status":"done","message":"done"}}}'
elif [[ "$1" == exec && "$2" == deploy-orchestrator && "$*" == *"/dev-tools/verify-staging"* ]]; then
  printf '{"success":true}\\nHTTP_STATUS:200'
elif [[ "$1" == inspect && "$*" == *"State.Running"* ]]; then
  echo healthy
elif [[ "$1" == inspect && "$*" == *".Mounts"* ]]; then
  echo "$TEST_STAGING_MOUNT"
fi
`);
  chmodSync(docker, 0o755);
  return () => spawnSync('bash', ['scripts/deploy-staging.sh'], {
    cwd: meta,
    encoding: 'utf8',
    env: { ...process.env, PATH: `${bin}:${process.env.PATH}`, TEST_STAGING_MOUNT: path.join(workdir, 'staging-site-frontend') },
  });
}

test('deploys staging with its lockfile without consulting webcomponents main', (t) => {
  const result = setup(t)();
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /staging_push=done/);
});

test('reports missing local staging branch before cutover', (t) => {
  const result = setup(t, false)();
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /local Astro staging branch is missing/);
  assert.doesNotMatch(result.stdout, /stopping astro-staging/);
});
