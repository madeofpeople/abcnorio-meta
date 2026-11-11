import assert from 'node:assert/strict';
import { execFileSync, spawnSync } from 'node:child_process';
import { chmodSync, copyFileSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import test from 'node:test';

const script = fileURLToPath(new URL('./update-webcomponents-pin.sh', import.meta.url));
const oldSha = 'a'.repeat(40);

function setup(t) {
  const root = mkdtempSync(path.join(os.tmpdir(), 'wc-pin-test-'));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  const meta = path.join(root, 'abcnorio-meta');
  const wc = path.join(root, 'abcnorio-webcomponents');
  const astro = path.join(root, 'abcnorio-astro');
  const frontend = path.join(astro, 'site-frontend');
  const plugin = path.join(root, 'abcnorio-func');
  const bin = path.join(root, 'bin');
  for (const dir of [path.join(meta, 'scripts'), wc, frontend, plugin, bin]) {
    mkdirSync(dir, { recursive: true });
  }
  copyFileSync(script, path.join(meta, 'scripts/update-webcomponents-pin.sh'));

  const git = (repo, ...args) => execFileSync('git', ['-C', repo, ...args], { stdio: 'pipe' }).toString().trim();
  for (const repo of [wc, astro, plugin]) {
    git(repo, 'init', '-b', 'main');
    git(repo, 'config', 'user.name', 'Test');
    git(repo, 'config', 'user.email', 'test@example.invalid');
  }
  writeFileSync(path.join(wc, 'component'), 'fixture');
  git(wc, 'add', '.');
  git(wc, 'commit', '-m', 'fixture');
  git(wc, 'remote', 'add', 'origin', wc);
  const sha = git(wc, 'rev-parse', 'HEAD');
  const lock = (value) => JSON.stringify({ packages: { 'node_modules/abcnorio-webcomponents': { resolved: `git+ssh://example.invalid/repo#${value}` } } });
  for (const dir of [frontend, plugin]) {
    writeFileSync(path.join(dir, 'package.json'), '{}');
    writeFileSync(path.join(dir, 'package-lock.json'), lock(oldSha));
  }
  for (const repo of [astro, plugin]) {
    git(repo, 'add', '.');
    git(repo, 'commit', '-m', 'fixture');
  }

  const npm = path.join(bin, 'npm');
  writeFileSync(npm, `#!/usr/bin/env node
const fs = require('fs');
if (process.env.FAIL_PLUGIN && process.cwd().endsWith('/plugin')) process.exit(1);
const file = 'package-lock.json';
const lock = JSON.parse(fs.readFileSync(file, 'utf8'));
lock.packages['node_modules/abcnorio-webcomponents'].resolved = 'git+ssh://example.invalid/repo#' + (process.env.TEST_SHA);
fs.writeFileSync(file, JSON.stringify(lock));
`);
  chmodSync(npm, 0o755);
  const run = (extra = {}) => spawnSync('bash', [path.join(meta, 'scripts/update-webcomponents-pin.sh')], {
    encoding: 'utf8',
    env: { ...process.env, PATH: `${bin}:${process.env.PATH}`, TEST_SHA: sha, ...extra },
  });
  return { run, sha, frontend, plugin, lock, git };
}

test('updates both lockfiles to the same webcomponents commit', (t) => {
  const { run, sha, frontend, plugin } = setup(t);
  const result = run();
  assert.equal(result.status, 0, result.stderr);
  for (const dir of [frontend, plugin]) {
    const lock = JSON.parse(readFileSync(path.join(dir, 'package-lock.json'), 'utf8'));
    assert.ok(lock.packages['node_modules/abcnorio-webcomponents'].resolved.endsWith(`#${sha}`));
  }
  assert.equal(run().status, 0);
});

test('preserves both lockfiles when either update fails', (t) => {
  const { run, frontend, plugin, lock } = setup(t);
  const result = run({ FAIL_PLUGIN: '1' });
  assert.notEqual(result.status, 0);
  for (const dir of [frontend, plugin]) {
    assert.equal(readFileSync(path.join(dir, 'package-lock.json'), 'utf8'), lock(oldSha));
  }
});

test('refuses to overwrite a modified lockfile', (t) => {
  const { run, frontend, plugin, lock } = setup(t);
  writeFileSync(path.join(plugin, 'package-lock.json'), `${lock(oldSha)}\n`);
  const result = run();
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /uncommitted changes/);
  assert.equal(readFileSync(path.join(frontend, 'package-lock.json'), 'utf8'), lock(oldSha));
  assert.equal(readFileSync(path.join(plugin, 'package-lock.json'), 'utf8'), `${lock(oldSha)}\n`);
});

test('rejects a resolved commit different from origin main', (t) => {
  const { run, frontend, plugin, lock } = setup(t);
  const result = run({ TEST_SHA: 'b'.repeat(40) });
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /instead of expected/);
  for (const dir of [frontend, plugin]) {
    assert.equal(readFileSync(path.join(dir, 'package-lock.json'), 'utf8'), lock(oldSha));
  }
});
