import { spawn, spawnSync } from 'node:child_process';
import { existsSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const meta = fileURLToPath(new URL('../', import.meta.url));
const plugin = path.resolve(meta, '../abcnorio-func');
const components = path.resolve(meta, '../abcnorio-webcomponents');
const check = spawnSync('watchexec', ['--version'], { stdio: 'inherit' });
if (check.error || check.status !== 0) {
  throw new Error('Install watchexec first (macOS: brew install watchexec).');
}
for (const root of [plugin, components]) {
  if (!existsSync(path.join(root, 'node_modules'))) {
    throw new Error(`Missing dependencies in ${root}. Run npm ci there first.`);
  }
}
const calendar = spawnSync('npm', ['run', 'copy:calendar'], { cwd: plugin, stdio: 'inherit' });
if (calendar.error || calendar.status !== 0) {
  throw calendar.error ?? new Error('Calendar asset preparation failed.');
}
const children = new Set();
let stopping = false;
let timeout;
function signalGroup(child, signal) {
  try {
    process.kill(-child.pid, signal);
  } catch (error) {
    if (error.code !== 'ESRCH') throw error;
  }
}
function stop(code) {
  if (stopping) return;
  stopping = true;
  process.exitCode = code;
  for (const child of children) signalGroup(child, 'SIGTERM');
  timeout = setTimeout(() => {
    for (const child of children) signalGroup(child, 'SIGKILL');
  }, 10000);
  if (children.size === 0) clearTimeout(timeout);
}
function start(command, args, options) {
  const child = spawn(command, args, { ...options, stdio: 'inherit', detached: true });
  if (child.pid) children.add(child);
  child.on('error', error => { console.error(error); stop(1); });
  child.on('exit', (code, signal) => {
    if (!stopping) signalGroup(child, 'SIGTERM');
    children.delete(child);
    if (!stopping) {
      console.error(`[plugin-dev] ${command} exited (${signal ?? code}); stopping both watchers.`);
      stop(code || 1);
    }
    if (children.size === 0) clearTimeout(timeout);
  });
}
for (const signal of ['SIGINT', 'SIGTERM']) process.on(signal, () => stop(0));
start('npm', ['start'], { cwd: plugin });
start('watchexec', [
  '--on-busy-update=queue', '--debounce=100ms',
  ...['src', 'scripts', 'vendor', 'package.json', 'package-lock.json', 'astro.config.mjs',
    'vite.elements.config.mjs', 'tsconfig.json'].flatMap(input => ['--watch', input]),
  '--', 'bash', path.join(plugin, 'scripts/build-components.sh'), '--development',
], {
  cwd: components,
  env: { ...process.env, ABCNORIO_COMPONENTS_DIST_SOURCE: path.join(components, 'dist') },
});
