import assert from 'node:assert/strict';
import { execFileSync, spawnSync } from 'node:child_process';
import { chmodSync, copyFileSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';

const just = execFileSync('which', ['just'], { encoding: 'utf8' }).trim();

function fixture(t) {
  const root = mkdtempSync(path.join(os.tmpdir(), 'recipe-routing-'));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  mkdirSync(path.join(root, 'scripts'));
  mkdirSync(path.join(root, 'bin'));
  copyFileSync(new URL('../justfile', import.meta.url), path.join(root, 'justfile'));
  copyFileSync(new URL('./stack.sh', import.meta.url), path.join(root, 'scripts/stack.sh'));
  for (const command of ['just', 'docker']) {
    const file = path.join(root, 'bin', command);
    writeFileSync(file, '#!/usr/bin/env bash\nif [[ "${1:-}" == test-url-rewrite ]]; then printf "TARGET=%s\\n" "${TARGET:-}"; fi\nprintf "%s\\n" "$@"\nexit "${TEST_EXIT:-0}"\n');
    chmodSync(file, 0o755);
  }
  writeFileSync(path.join(root, 'scripts/wp.sh'), 'printf "%s\\n" "$@"\n');
  return (args, exit = 0) => spawnSync(just, args, {
    cwd: root, encoding: 'utf8',
    env: { ...process.env, PATH: `${root}/bin:${process.env.PATH}`, TEST_EXIT: String(exit) },
  });
}

test('public dispatchers route to the intended helper without recursion', t => {
  const run = fixture(t);
  const cases = [
    [['plugin', 'artifact', 'build', 'v1.2.3'], ['plugin-artifact', 'v1.2.3']],
    [['frontend', 'cache', 'clear', 'dev'], ['clear-vite-cache', 'dev']],
    [['wp', 'core', 'update', 'staging', '6.9.5'], ['wp-core-update', 'staging', '6.9.5']],
    [['wp', 'plugins', 'update', 'dev'], ['plugins-update', 'dev']],
    [['wp', 'composer', 'cli', 'staging', 'install'], ['composer', 'staging', 'install']],
    [['wp', 'composer', 'snapshot', 'dev'], ['bedrock-snapshot', 'dev']],
    [['wp', 'cli', 'dev', 'core', 'version'], ['dev', 'core', 'version']],
    [['db', 'import', 'dev', 'dump.sql'], ['local-db-import', 'dump.sql']],
    [['media', 'thumbnails', 'regenerate', 'staging'], ['regen-thumbs', 'staging']],
    [['media', 'originals', 'downscale', 'dev'], ['downscale-originals', 'dev']],
    [['media', 'derivatives', 'copy', 'staging', 'production'], ['sync-regenerated-thumbnails-to-production']],
    [['content', 'urls', 'test', 'staging'], ['TARGET=staging', 'test-url-rewrite']],
  ];
  for (const [args, expected] of cases) {
    const result = run(args);
    assert.equal(result.status, 0, result.stderr);
    assert.deepEqual(result.stdout.trim().split('\n'), expected, args.join(' '));
  }
  assert.equal(run(['plugin', 'artifact', 'build'], 7).status, 7);
});

test('stack actions share environment and role mappings', t => {
  const run = fixture(t);
  for (const action of ['up', 'down', 'restart', 'rebuild', 'logs']) {
    const result = run(['stack', action, 'staging', 'cms']);
    assert.equal(result.status, 0, result.stderr);
    assert.match(result.stdout, /abcwpstaging/);
    assert.doesNotMatch(result.stdout, /astro-staging/);
  }
  for (const [target, services] of [
    [['dev'], ['astro-dev', 'abcwpdev']],
    [['staging'], ['astro-staging', 'abcwpstaging']],
    [['production'], ['astro-prod']],
    [['shared', 'database'], ['mariadb']],
    [['shared', 'orchestrator'], ['deploy-orchestrator']],
    [['shared', 'proxy'], ['proxy']],
    [['shared', 'web'], ['web']],
  ]) {
    const result = run(['stack', 'logs', ...target]);
    assert.equal(result.status, 0, result.stderr);
    for (const service of services) assert.ok(result.stdout.includes(`${service}\n`));
  }
  assert.equal(run(['stack', 'logs', 'staging'], 7).status, 7);
  assert.equal(run(['stack', 'down']).stdout, 'compose\ndown\n');
  assert.equal(run(['stack', 'down', 'staging']).stdout, 'compose\nstop\nastro-staging\nabcwpstaging\n');
  assert.equal(run(['stack', 'logs', 'dev', 'frontend']).stdout,
    'compose\n--profile\ndev\nlogs\n-f\n--tail=100\nastro-dev\n');
  assert.equal(run(['stack', 'rebuild', 'staging', 'cms'], 7).stdout,
    'compose\nbuild\n--pull\nabcwpstaging\n');
});

test('invalid targets and missing maintenance environments fail before execution', t => {
  const run = fixture(t);
  for (const args of [
    ['stack', 'logs', 'abcwp'], ['stack', 'restart', 'production', 'cms'],
    ['stack', 'logs', 'dev', 'cms', 'extra'], ['stack', 'watch', 'staging'],
    ['db', 'import', 'local', 'dump.sql'], ['wp', 'plugins', 'update'],
    ['content', 'urls', 'test'], ['db', 'dump'], ['wp', 'composer', 'snapshot'],
  ]) {
    const result = run(args);
    assert.notEqual(result.status, 0, args.join(' '));
    assert.equal(result.stdout, '');
  }
});
