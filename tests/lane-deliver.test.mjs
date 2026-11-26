import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { chmod, mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { existsSync, readFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { test } from 'node:test';
import { setTimeout as delay } from 'node:timers/promises';

const laneScript = fileURLToPath(new URL('../skills/herdr-spawn/scripts/lane.sh', import.meta.url));

const fakeHc = `#!/usr/bin/env node
const fs = require('node:fs');
const path = require('node:path');
const root = process.env.FAKE_HC_ROOT;
const statusDir = path.join(root, 'status');
const labelsDir = path.join(root, 'labels');
const sendsFile = path.join(root, 'sends.log');
fs.mkdirSync(statusDir, { recursive: true });
fs.mkdirSync(labelsDir, { recursive: true });

function statusOf(t) {
  try { return fs.readFileSync(path.join(statusDir, t), 'utf8').trim(); } catch { return 'idle'; }
}
function labelsOf(t) {
  try { return JSON.parse(fs.readFileSync(path.join(labelsDir, t), 'utf8')); } catch { return {}; }
}
function setLabels(t, kvs) {
  const cur = labelsOf(t);
  for (const kv of kvs) {
    const i = kv.indexOf('=');
    if (i < 0) continue;
    cur[kv.slice(0, i)] = kv.slice(i + 1);
  }
  fs.writeFileSync(path.join(labelsDir, t), JSON.stringify(cur));
}

const args = process.argv.slice(2);
if (args[0] === 'get' && args[2] === '--json') {
  const t = args[1];
  console.log(JSON.stringify({ address: t, name: t, state: 'live', status: { state: statusOf(t) }, labels: labelsOf(t) }));
  process.exit(0);
}
if (args[0] === 'label') {
  setLabels(args[1], args.slice(2));
  process.exit(0);
}
if (args[0] === 'send') {
  const idx = args.indexOf('--');
  const t = args[1];
  const text = args.slice(idx + 1).join(' ');
  if (statusOf(t) === 'blocked') {
    process.stderr.write(JSON.stringify({ error: { hint: 'typing would answer its dialog', kind: 'blocked', message: t + ' is blocked (question)' } }) + '\\n');
    process.exit(9);
  }
  fs.appendFileSync(sendsFile, JSON.stringify({ target: t, sender: process.env.HC_TERMINAL_ID || '', text }) + '\\n');
  process.exit(0);
}
process.exit(0);
`;

// Stops only this test's deliverer, found through its lock.
function stopDeliverer(stateRoot) {
  try {
    process.kill(Number(readFileSync(join(stateRoot, 'herdr-spawn', 'deliver-coord.lock', 'pid'), 'utf8')), 'SIGTERM');
  } catch {}
}

async function setup(t) {
  const root = await mkdtemp(join(tmpdir(), 'hd-'));
  t.after(() => stopDeliverer(join(root, 'xdg')));
  t.after(() => rm(root, { recursive: true, force: true }));
  const hcPath = join(root, 'hc');
  await writeFile(hcPath, fakeHc);
  await chmod(hcPath, 0o700);
  const stateRoot = join(root, 'xdg');
  await mkdir(stateRoot, { recursive: true });
  const reportDir = await mkdtemp(join(tmpdir(), 'r'));
  await chmod(reportDir, 0o700);
  t.after(() => rm(reportDir, { recursive: true, force: true }));
  const reportFile = join(root, 'report.md');
  await writeFile(reportFile, 'hello report\\n');
  const statusDir = join(root, 'status');
  await mkdir(statusDir, { recursive: true });
  await mkdir(join(root, 'labels'), { recursive: true });
  const env = {
    ...process.env,
    PATH: `${root}:${process.env.PATH}`,
    HC_TERMINAL_ID: 'lane',
    LANE_COORDINATOR: 'coord',
    LANE_MODE: 'unit',
    XDG_STATE_HOME: stateRoot,
    HERDR_SPAWN_REPORT_DIR: reportDir,
    FAKE_HC_ROOT: root,
    HERDR_SPAWN_WATCH_INTERVAL: '1',
  };
  delete env.HERDR_ENV;
  return { root, hcPath, stateRoot, reportDir, reportFile, statusDir, env };
}

test('coordinator blocked queues notice and delivers when unblocked', async t => {
  const { root, hcPath, stateRoot, reportFile, statusDir, env } = await setup(t);
  await writeFile(join(statusDir, 'coord'), 'blocked');

  const res = spawnSync('bash', [laneScript, 'done', 'note text', reportFile], { env, encoding: 'utf8' });
  assert.equal(res.status, 0, res.stderr + res.stdout);

  const laneInfo = JSON.parse(spawnSync(hcPath, ['get', 'lane', '--json'], { env, encoding: 'utf8' }).stdout);
  assert.equal(laneInfo.labels.lane_state, 'done');
  const copyPath = laneInfo.labels.lane_report;

  const sendsPath = join(root, 'sends.log');
  assert.ok(!existsSync(sendsPath), 'a send was accepted while blocked');

  const queuePath = join(stateRoot, 'herdr-spawn', 'app-queue-coord.txt');
  const qLines = readFileSync(queuePath, 'utf8').trim().split('\\n');
  assert.equal(qLines.length, 1);

  await writeFile(join(statusDir, 'coord'), 'idle');

  let sends = '';
  for (let i = 0; i < 100 && !sends; i++) {
    if (existsSync(sendsPath)) sends = readFileSync(sendsPath, 'utf8');
    if (!sends) await delay(100);
  }
  const parsed = sends.trim().split('\\n').map(JSON.parse);
  assert.equal(parsed.length, 1);
  assert.equal(parsed[0].target, 'coord');
  assert.equal(parsed[0].sender, 'lane');
  assert.match(parsed[0].text, /\[lane lane\] done: note text\. Read its report: /);
  assert.ok(parsed[0].text.includes(copyPath));

  for (let i = 0; i < 50; i++) {
    if (!existsSync(queuePath)) break;
    await delay(100);
  }
  assert.ok(!existsSync(queuePath), 'queue file not removed');

  const lockPath = join(stateRoot, 'herdr-spawn', 'deliver-coord.lock');
  let lockGone = false;
  for (let i = 0; i < 50; i++) {
    if (!existsSync(lockPath)) { lockGone = true; break; }
    await delay(100);
  }
  assert.ok(lockGone, 'deliverer did not exit');

});

test('escalation answered while blocked is dropped', async t => {
  const { root, hcPath, stateRoot, reportFile, statusDir, env } = await setup(t);
  await writeFile(join(statusDir, 'coord'), 'blocked');

  const res = spawnSync('bash', [laneScript, 'escalate', 'help needed', reportFile], { env, encoding: 'utf8' });
  assert.equal(res.status, 0, res.stderr + res.stdout);

  const laneInfoBefore = JSON.parse(spawnSync(hcPath, ['get', 'lane', '--json'], { env, encoding: 'utf8' }).stdout);
  const reportPath = laneInfoBefore.labels.lane_report;

  // Answered as lane.sh reply does: state back to working.
  spawnSync(hcPath, ['label', 'lane', 'lane_state=working'], { env, encoding: 'utf8' });

  await writeFile(join(statusDir, 'coord'), 'idle');

  await delay(2500);

  const sendsPath = join(root, 'sends.log');
  if (existsSync(sendsPath)) {
    const content = readFileSync(sendsPath, 'utf8').trim();
    assert.equal(content, '', 'a send arrived for a stale escalation');
  }

  const queuePath = join(stateRoot, 'herdr-spawn', 'app-queue-coord.txt');
  assert.ok(!existsSync(queuePath), 'queue file not removed');

  const lockPath = join(stateRoot, 'herdr-spawn', 'deliver-coord.lock');
  let lockGone = false;
  for (let i = 0; i < 50; i++) {
    if (!existsSync(lockPath)) { lockGone = true; break; }
    await delay(100);
  }
  assert.ok(lockGone, 'deliverer did not exit');

});

test('coordinator not blocked sends directly', async t => {
  const { root, hcPath, stateRoot, reportFile, statusDir, env } = await setup(t);
  await writeFile(join(statusDir, 'coord'), 'idle');

  const res = spawnSync('bash', [laneScript, 'done', 'note text', reportFile], { env, encoding: 'utf8' });
  assert.equal(res.status, 0, res.stderr + res.stdout);
  assert.match(res.stdout, /stored the report at/);

  const sendsPath = join(root, 'sends.log');
  const sends = readFileSync(sendsPath, 'utf8').trim().split('\\n').map(JSON.parse);
  assert.equal(sends.length, 1);
  assert.equal(sends[0].sender, 'lane');

  const queuePath = join(stateRoot, 'herdr-spawn', 'app-queue-coord.txt');
  assert.ok(!existsSync(queuePath), 'queue file was created');

});