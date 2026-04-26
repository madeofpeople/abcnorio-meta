import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import { spawn } from 'node:child_process';
import { Queue, Worker } from 'bullmq';
import IORedis from 'ioredis';

const PORT = Number(process.env.ORCHESTRATOR_PORT || 4011);
const SECRET = process.env.ASTRO_BUILD_TRIGGER_SECRET || '';
const REDIS_URL = process.env.REDIS_URL || 'redis://redis:6379';
const QUEUE_NAME = process.env.BUILD_QUEUE_NAME || 'astro-build';
const DEBOUNCE_SECONDS = Number(process.env.BUILD_DEBOUNCE_SECONDS || 120);
const SAVE_TRIGGER_ENABLED = process.env.WP_SAVE_TRIGGER_QUEUE_ENABLED === '1';

const DEBOUNCE_MS = Math.max(0, DEBOUNCE_SECONDS) * 1000;
const WORKDIR = process.env.ASTRO_SITE_ROOT || '/astro-site';
const ARCHIVE_DIR = path.resolve(WORKDIR, 'build-archives');
const STATUS_FILE = process.env.ASTRO_DEPLOYMENT_STATUS_FILE
  ? path.resolve(process.env.ASTRO_DEPLOYMENT_STATUS_FILE)
  : path.resolve(WORKDIR, 'build-archives/deployment-status.json');
const FOLLOWUP_KEY_PREFIX = 'build:astro:followup';
const ENV_KEYS = ['dev', 'staging', 'production'];

const COMMANDS = {
  dev: [path.join(WORKDIR, 'deploy-to-dev.sh'), process.env.DEV_BUILD_PATH || ''],
  staging: [path.join(WORKDIR, 'deploy-to-staging.sh'), process.env.STAGING_BUILD_PATH || ''],
  production: [path.join(WORKDIR, 'deploy-to-production.sh'), process.env.PRODUCTION_BUILD_PATH || ''],
};

/** @type {{ status: 'idle'|'running'|'done'|'failed', target: string|null, started: number|null, finished: number|null, exitCode: number|null, message: string|null }} */
let state = {
  status: 'idle',
  target: null,
  started: null,
  finished: null,
  exitCode: null,
  message: null,
};

const redis = new IORedis(REDIS_URL, { maxRetriesPerRequest: null });
const queue = new Queue(QUEUE_NAME, { connection: redis });

function followupKey(target) {
  return `${FOLLOWUP_KEY_PREFIX}:${target}`;
}

function getAuthToken(req) {
  const auth = req.headers.authorization || '';
  if (!auth.startsWith('Bearer ')) {
    return '';
  }

  return auth.slice('Bearer '.length).trim();
}

function readJsonBody(req) {
  return new Promise((resolve, reject) => {
    let body = '';
    req.on('data', (chunk) => {
      body += chunk;
    });
    req.on('end', () => {
      if (!body.trim()) {
        resolve({});
        return;
      }

      try {
        resolve(JSON.parse(body));
      } catch (error) {
        reject(error);
      }
    });
  });
}

function listArchivesForTarget(target) {
  if (!fs.existsSync(ARCHIVE_DIR)) {
    return [];
  }

  const prefix = `abcnorio-astro-${target}-`;
  return fs
    .readdirSync(ARCHIVE_DIR)
    .filter((name) => name.startsWith(prefix) && name.endsWith('.zip'));
}

function newestArchivePath(target) {
  const names = listArchivesForTarget(target);
  if (names.length === 0) {
    return '';
  }

  let newest = '';
  let newestMtime = -1;

  for (const name of names) {
    const fullPath = path.join(ARCHIVE_DIR, name);
    const mtime = fs.statSync(fullPath).mtimeMs;
    if (mtime > newestMtime) {
      newestMtime = mtime;
      newest = fullPath;
    }
  }

  return newest;
}

function defaultEnvStatus() {
  return {
    lastRequestedAt: null,
    lastStartedAt: null,
    lastFinishedAt: null,
    lastStatus: 'idle',
    lastError: null,
    currentBuild: {
      path: '',
      clientPath: '',
      hasBuild: false,
      updatedAt: null,
    },
    latestBackup: null,
    backups: [],
  };
}

function normalizeStatus(input) {
  const status = input && typeof input === 'object' ? input : {};

  if (!status.envs || typeof status.envs !== 'object') {
    status.envs = {};
  }

  for (const env of ENV_KEYS) {
    const defaults = defaultEnvStatus();
    const envStatus = status.envs[env] && typeof status.envs[env] === 'object'
      ? status.envs[env]
      : {};

    const currentBuild = envStatus.currentBuild && typeof envStatus.currentBuild === 'object'
      ? envStatus.currentBuild
      : {};

    status.envs[env] = {
      ...defaults,
      ...envStatus,
      currentBuild: {
        ...defaults.currentBuild,
        ...currentBuild,
        hasBuild: Boolean(currentBuild.hasBuild),
      },
      backups: Array.isArray(envStatus.backups) ? envStatus.backups : [],
    };
  }

  return status;
}

function loadStatus() {
  if (!fs.existsSync(STATUS_FILE)) {
    return normalizeStatus({});
  }

  try {
    const parsed = JSON.parse(fs.readFileSync(STATUS_FILE, 'utf8'));
    return normalizeStatus(parsed);
  } catch {
    return normalizeStatus({});
  }
}

function ensureEnvStatus(status, env) {
  normalizeStatus(status);

  return status.envs[env];
}

function saveStatus(status) {
  const normalized = normalizeStatus(status);
  normalized.updatedAt = new Date().toISOString();
  fs.mkdirSync(path.dirname(STATUS_FILE), { recursive: true });
  fs.writeFileSync(STATUS_FILE, JSON.stringify(normalized, null, 2) + '\n');
}

function markRequested(target) {
  const status = loadStatus();
  const envStatus = ensureEnvStatus(status, target);
  envStatus.lastRequestedAt = new Date().toISOString();
  saveStatus(status);
}

function markStarted(target) {
  const status = loadStatus();
  const envStatus = ensureEnvStatus(status, target);
  envStatus.lastStartedAt = new Date().toISOString();
  envStatus.lastStatus = 'running';
  envStatus.lastError = null;
  saveStatus(status);
}

function markDone(target) {
  const status = loadStatus();
  const envStatus = ensureEnvStatus(status, target);
  envStatus.lastFinishedAt = new Date().toISOString();
  envStatus.lastStatus = 'done';
  envStatus.lastError = null;
  saveStatus(status);
}

function markFailed(target, message) {
  const status = loadStatus();
  const envStatus = ensureEnvStatus(status, target);
  envStatus.lastFinishedAt = new Date().toISOString();
  envStatus.lastStatus = 'failed';
  envStatus.lastError = message || 'job failed';
  saveStatus(status);
}

function recordBackup(status, target, archivePath) {
  const resolvedPath = path.resolve(archivePath);
  if (!fs.existsSync(resolvedPath)) {
    throw new Error(`backup path does not exist: ${resolvedPath}`);
  }

  const stats = fs.statSync(resolvedPath);
  const name = path.basename(resolvedPath);
  const envStatus = ensureEnvStatus(status, target);
  const backup = {
    name,
    path: resolvedPath,
    createdAt: new Date(stats.mtimeMs).toISOString(),
    mtime: Math.floor(stats.mtimeMs / 1000),
    size: stats.size,
  };

  envStatus.backups = [backup, ...envStatus.backups.filter((entry) => entry?.name !== name)]
    .slice(0, 12);
  envStatus.latestBackup = backup;
}

function hasClientBuild(pathToBuildRoot) {
  const clientPath = path.join(pathToBuildRoot, 'client');
  return fs.existsSync(clientPath)
    && fs.readdirSync(clientPath).some((entry) => entry !== '.' && entry !== '..');
}

function recordDeploy(status, target, deployBuildPath) {
  const resolvedBuildPath = path.resolve(deployBuildPath);
  const clientPath = path.join(resolvedBuildPath, 'client');
  const hasBuild = hasClientBuild(resolvedBuildPath);
  const envStatus = ensureEnvStatus(status, target);

  envStatus.currentBuild = {
    path: resolvedBuildPath,
    clientPath,
    hasBuild,
    updatedAt: new Date().toISOString(),
  };

  envStatus.lastDeploy = {
    updatedAt: new Date().toISOString(),
    path: resolvedBuildPath,
    hasBuild,
  };
}

function updateStatus(action, target, payload) {
  const status = loadStatus();

  if (action === 'backup') {
    recordBackup(status, target, payload.archivePath);
  } else if (action === 'deploy') {
    recordDeploy(status, target, payload.deployBuildPath);
  } else {
    throw new Error(`unknown status action: ${action}`);
  }

  saveStatus(status);
}

function runCommand(command, args) {
  return new Promise((resolve) => {
    const proc = spawn(command, args, {
      cwd: WORKDIR,
      env: process.env,
      stdio: 'inherit',
    });

    proc.on('close', (code) => {
      resolve(Number(code ?? 1));
    });
  });
}

function assertDeployPath(target, deployBuildPath) {
  const resolved = String(deployBuildPath || '').trim();
  if (!resolved) {
    throw new Error(`missing deploy path for target=${target}`);
  }

  if (!fs.existsSync(resolved) || !fs.statSync(resolved).isDirectory()) {
    throw new Error(`deploy path not found for target=${target}: ${resolved}`);
  }

  return resolved;
}

async function enqueueTarget(target, source = 'manual') {
  const jobId = `deploy-${target}`;
  const existing = await queue.getJob(jobId);

  if (state.status === 'running' && state.target === target) {
    await redis.set(followupKey(target), '1');
    markRequested(target);
    return { accepted: true, followup: true };
  }

  if (existing) {
    const existingState = await existing.getState();
    if (existingState === 'active') {
      await redis.set(followupKey(target), '1');
      markRequested(target);
      return { accepted: true, followup: true };
    }

    if (['waiting', 'delayed', 'prioritized'].includes(existingState)) {
      await existing.remove();
    }
  }

  const delay = source === 'save' ? DEBOUNCE_MS : 0;
  await queue.add('deploy', { target, source }, {
    jobId,
    delay,
    removeOnComplete: true,
    removeOnFail: 50,
  });

  markRequested(target);

  return { accepted: true, followup: false };
}

const worker = new Worker(
  QUEUE_NAME,
  async (job) => {
    const { target } = job.data;

    if (!COMMANDS[target]) {
      throw new Error(`invalid target: ${target}`);
    }

    const [scriptPath, deployBuildPath] = COMMANDS[target];
    const resolvedDeployPath = assertDeployPath(target, deployBuildPath);

    state = {
      status: 'running',
      target,
      started: Date.now(),
      finished: null,
      exitCode: null,
      message: null,
    };
    markStarted(target);

    const archiveBefore = new Set(listArchivesForTarget(target));
    const exitCode = await runCommand('bash', [scriptPath]);

    if (exitCode !== 0) {
      state = {
        ...state,
        status: 'failed',
        finished: Date.now(),
        exitCode,
        message: `script failed with exit ${exitCode}`,
      };
      throw new Error(state.message);
    }

    const archiveAfter = listArchivesForTarget(target);
    const createdArchive = archiveAfter.find((name) => !archiveBefore.has(name));
    const archivePath = createdArchive
      ? path.join(ARCHIVE_DIR, createdArchive)
      : newestArchivePath(target);

    if (!archivePath) {
      throw new Error(`no backup archive discovered for target=${target}`);
    }

    updateStatus('backup', target, {
      archivePath,
    });

    updateStatus('deploy', target, {
      deployBuildPath: resolvedDeployPath,
    });

    state = {
      ...state,
      status: 'done',
      finished: Date.now(),
      exitCode: 0,
      message: null,
    };
    markDone(target);

    const fk = followupKey(target);
    const needsFollowup = (await redis.get(fk)) === '1';
    if (needsFollowup) {
      await redis.del(fk);
      await queue.add('deploy', { target, source: 'followup' }, {
        jobId: `deploy:${target}`,
        delay: DEBOUNCE_MS,
        removeOnComplete: true,
        removeOnFail: 50,
      });
    }
  },
  {
    connection: redis,
    concurrency: 1,
  }
);

worker.on('failed', async (job, error) => {
  const target = job?.data?.target || state.target;
  const fk = target ? followupKey(target) : '';
  if (fk) {
    await redis.del(fk);
  }

  if (state.status !== 'failed') {
    state = {
      ...state,
      status: 'failed',
      finished: Date.now(),
      exitCode: state.exitCode ?? 1,
      message: error?.message || 'job failed',
    };
  }

  if (target) {
    markFailed(target, error?.message || 'job failed');
  }
});

const server = http.createServer(async (req, res) => {
  if (!SECRET || getAuthToken(req) !== SECRET) {
    res.writeHead(401, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ error: 'unauthorized' }));
    return;
  }

  res.setHeader('Content-Type', 'application/json');

  if (req.method === 'GET' && req.url === '/status') {
    res.writeHead(200);
    res.end(JSON.stringify(state));
    return;
  }

  if (req.method === 'POST' && req.url === '/trigger') {
    let body = {};
    try {
      body = await readJsonBody(req);
    } catch {
      res.writeHead(400);
      res.end(JSON.stringify({ error: 'invalid json' }));
      return;
    }

    const target = String(body.target || '').trim();
    const source = String(body.source || 'manual').trim();

    if (!COMMANDS[target]) {
      res.writeHead(400);
      res.end(JSON.stringify({ error: 'invalid target', valid: Object.keys(COMMANDS) }));
      return;
    }

    if (source === 'save' && !SAVE_TRIGGER_ENABLED) {
      res.writeHead(202);
      res.end(JSON.stringify({ status: 'ignored', reason: 'save trigger disabled', target }));
      return;
    }

    if (source === 'save' && target === 'production') {
      res.writeHead(403);
      res.end(JSON.stringify({ error: 'production save-trigger is disabled' }));
      return;
    }

    try {
      const result = await enqueueTarget(target, source);
      res.writeHead(202);
      res.end(JSON.stringify({ status: result.followup ? 'queued_followup' : 'queued', target, source }));
    } catch (error) {
      res.writeHead(500);
      res.end(JSON.stringify({ error: 'trigger failed', message: error instanceof Error ? error.message : 'unknown error' }));
    }

    return;
  }

  if (req.method === 'GET' && req.url === '/health') {
    res.writeHead(200);
    res.end(JSON.stringify({ status: 'ok' }));
    return;
  }

  res.writeHead(404);
  res.end(JSON.stringify({ error: 'not found' }));
});

server.listen(PORT, '0.0.0.0', () => {
  saveStatus(loadStatus());
  console.log(`[deploy-orchestrator] listening on :${PORT}`);
  console.log(`[deploy-orchestrator] queue=${QUEUE_NAME} redis=${REDIS_URL}`);
});
