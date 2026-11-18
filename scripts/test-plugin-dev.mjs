import assert from 'node:assert/strict';
import { spawn, spawnSync } from 'node:child_process';
import { copyFileSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';

for (const mode of ['signal', 'unexpected-exit']) {
  test(`host coordinator stops both jobs on ${mode}`, { timeout: 15000 }, async t => {
    const root = mkdtempSync(path.join(os.tmpdir(), 'plugin-dev-'));
    t.after(() => rmSync(root, { recursive: true, force: true }));
    const scripts = path.join(root, 'abcnorio-meta/scripts');
    const bin = path.join(root, 'bin');
    mkdirSync(scripts, { recursive: true });
    mkdirSync(bin);
    for (const repo of ['abcnorio-func', 'abcnorio-webcomponents']) {
      mkdirSync(path.join(root, repo, 'node_modules'), { recursive: true });
    }

    copyFileSync(new URL('./plugin-dev.mjs', import.meta.url), path.join(scripts, 'plugin-dev.mjs'));
    const log = path.join(root, 'events');
    writeFileSync(log, '');
    const stub = `#!/usr/bin/env node
const fs = require('node:fs');
const path = require('node:path');
const tool = path.basename(process.argv[1]);
if (process.argv.includes('--version') || process.argv.includes('copy:calendar')) process.exit(0);
fs.appendFileSync(process.env.TEST_EVENTS, JSON.stringify({tool,pid:process.pid,args:process.argv.slice(2)})+'\\n');
process.on('SIGTERM', () => process.exit(0));
setInterval(() => {}, 1000);
if (process.env.TEST_MODE === 'unexpected-exit' && tool === 'watchexec') setTimeout(() => process.exit(7), 600);
`;
    for (const tool of ['npm', 'watchexec']) writeFileSync(path.join(bin, tool), stub, { mode: 0o755 });
    const child = spawn(process.execPath, [path.join(scripts, 'plugin-dev.mjs')], {
      env: { ...process.env, PATH: `${bin}:${process.env.PATH}`, TEST_EVENTS: log, TEST_MODE: mode },
      stdio: 'pipe',
    });
    let output = '';
    child.stdout.on('data', data => { output += data; });
    child.stderr.on('data', data => { output += data; });
    t.after(() => { if (child.exitCode === null) child.kill('SIGTERM'); });
    const exited = new Promise((resolve, reject) => {
      child.once('error', reject);
      child.once('exit', (code, signal) => resolve({ code, signal }));
    });
    let jobs;
    for (let i = 0; i < 80; i++) {
      jobs = readFileSync(log, 'utf8').trim().split('\n').filter(Boolean).map(line => JSON.parse(line));
      if (jobs.length === 2) break;
      await new Promise(resolve => setTimeout(resolve, 50));
    }
    assert.equal(jobs.length, 2, output);
    const watcher = jobs.find(job => job.tool === 'watchexec');
    assert(watcher.args.includes('--on-busy-update=queue'));
    assert(!watcher.args.includes('--restart'));
    assert(!watcher.args.includes('dist'));
    if (mode === 'signal') child.kill('SIGTERM');
    const result = await exited;
    assert.equal(result.code, mode === 'signal' ? 0 : 7, output);
    for (const job of jobs) {
      assert.throws(() => process.kill(job.pid, 0), { code: 'ESRCH' });
    }
  });
}

test('real Watchexec serializes saves and queues one follow-up build', {
  timeout: 15000,
  skip: spawnSync('watchexec', ['--version']).status !== 0 ? 'Install Watchexec to run integration check' : false,
}, async t => {
  const root = mkdtempSync(path.join(os.tmpdir(), 'queued-watcher-'));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  const source = path.join(root, 'input.txt');
  const log = path.join(root, 'events');
  writeFileSync(source, 'initial');
  writeFileSync(log, '');
  const runner = path.join(root, 'build.cjs');
  writeFileSync(runner, `const fs=require('node:fs');const log=${JSON.stringify(log)};
fs.appendFileSync(log,'start\\n');setTimeout(()=>{fs.appendFileSync(log,'end\\n');},1200);`);
  const child = spawn('watchexec', [
    '--on-busy-update=queue', '--debounce=100ms', '--watch', source,
    '--', process.execPath, runner,
  ], { cwd: root, stdio: 'ignore' });
  const stopped = new Promise((resolve, reject) => {
    child.once('error', reject);
    child.once('exit', resolve);
  });
  const rows = () => readFileSync(log, 'utf8').trim().split('\n').filter(Boolean);
  async function waitFor(count) {
    for (let i = 0; i < 120; i++) {
      if (rows().length >= count) return;
      await new Promise(resolve => setTimeout(resolve, 50));
    }
    throw new Error(`Missing watcher events: ${rows()}`);
  }
  try {
    await waitFor(1);
    for (let i = 0; i < 5; i++) {
      writeFileSync(source, `save ${i}`);
      await new Promise(resolve => setTimeout(resolve, 80));
    }
    await waitFor(4);
    await new Promise(resolve => setTimeout(resolve, 350));
    assert.deepEqual(rows(), ['start', 'end', 'start', 'end']);
  } finally {
    child.kill('SIGTERM');
    await stopped;
  }
});
