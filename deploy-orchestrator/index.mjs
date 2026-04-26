import http from 'node:http';
import path from 'node:path';
import { Queue, Worker } from 'bullmq';
import IORedis from 'ioredis';
import { getAuthToken, readJsonBody } from './http.mjs';
import { listArchivesForTarget, newestArchivePath, runCommand, assertDeployPath, cleanupOldArchives } from './files.mjs';
import {
  loadStatus, saveStatus, markRequested, markStarted, markDone, markFailed, updateStatus,
} from './status.mjs';

const PORT = Number(process.env.ORCHESTRATOR_PORT || 4011);
const SECRET = process.env.ASTRO_BUILD_TRIGGER_SECRET || '';
const REDIS_URL = process.env.REDIS_URL || 'redis://redis:6379';
const QUEUE_NAME = process.env.BUILD_QUEUE_NAME || 'astro-build';
const DEBOUNCE_SECONDS = Number(process.env.BUILD_DEBOUNCE_SECONDS || 120);
const SAVE_TRIGGER_ENABLED = process.env.WP_SAVE_TRIGGER_QUEUE_ENABLED === '1';
const MAX_BACKUPS = Number(process.env.MAX_BACKUPS || 12);

const DEBOUNCE_MS = Math.max(0, DEBOUNCE_SECONDS) * 1000;
const WORKDIR = process.env.ASTRO_SITE_ROOT || '/astro-site';
const ARCHIVE_DIR = path.resolve(WORKDIR, 'build-archives');
const FOLLOWUP_KEY_PREFIX = 'build:astro:followup';

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
        status: 'failed',
        target,
        started: state.started,
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

    cleanupOldArchives(target, MAX_BACKUPS);
    updateStatus('backup', target, { archivePath });
    updateStatus('deploy', target, { deployBuildPath: resolvedDeployPath });

    state = {
      status: 'done',
      target,
      started: state.started,
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
        jobId: `deploy_${target}`,
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
  const respond = (code, data) => {
    res.writeHead(code, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify(data));
  };

  if (!SECRET || getAuthToken(req) !== SECRET) {
    return respond(401, { error: 'unauthorized' });
  }

  if (req.method === 'GET' && req.url === '/status') {
    return respond(200, state);
  }

  if (req.method === 'GET' && req.url === '/health') {
    return respond(200, { status: 'ok' });
  }

  if (req.method === 'POST' && req.url === '/trigger') {
    let body = {};
    try {
      body = await readJsonBody(req);
    } catch {
      return respond(400, { error: 'invalid json' });
    }

    const target = String(body.target || '').trim();
    const source = String(body.source || 'manual').trim();

    if (!COMMANDS[target]) {
      return respond(400, { error: 'invalid target', valid: Object.keys(COMMANDS) });
    }

    if (source === 'save' && !SAVE_TRIGGER_ENABLED) {
      return respond(202, { status: 'ignored', reason: 'save trigger disabled', target });
    }

    if (source === 'save' && target === 'production') {
      return respond(403, { error: 'production save-trigger is disabled' });
    }

    try {
      const result = await enqueueTarget(target, source);
      return respond(202, { status: result.followup ? 'queued_followup' : 'queued', target, source });
    } catch (error) {
      return respond(500, { error: 'trigger failed', message: error instanceof Error ? error.message : 'unknown error' });
    }
  }

  respond(404, { error: 'not found' });
});

server.listen(PORT, '0.0.0.0', () => {
  saveStatus(loadStatus());
  console.log(`[deploy-orchestrator] listening on :${PORT}`);
  console.log(`[deploy-orchestrator] queue=${QUEUE_NAME} redis=${REDIS_URL}`);
});
