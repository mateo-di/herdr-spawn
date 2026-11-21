import assert from 'node:assert/strict';
import { execFile } from 'node:child_process';
import { mkdir, mkdtemp, readFile, rm, stat, symlink, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { test } from 'node:test';
import { promisify } from 'node:util';

const run = promisify(execFile);
const scripts = fileURLToPath(new URL('../skills/herdr-spawn/scripts/', import.meta.url));
const objective = '  Exact "$HOME" {name}\n\n' + 'é'.repeat(100) + '\n';

const cli = `#!/usr/bin/env node
const assert = require('node:assert/strict');
const fs = require('node:fs');
const { basename } = require('node:path');
const [a, b, c] = process.argv.slice(2);
const args = process.argv.slice(2);
const file = process.env.GOAL_MOCK;
const db = JSON.parse(fs.readFileSync(file, 'utf8'));
const save = () => fs.writeFileSync(file, JSON.stringify(db));
const out = x => console.log(JSON.stringify(x));
const flag = k => args[args.indexOf(k) + 1];
const values = k => args.flatMap((x, i) => x === k ? [args[i + 1]] : []);
const kv = x => [x.slice(0, x.indexOf('=')), x.slice(x.indexOf('=') + 1)];
const find = key => Object.values(db).find(row => row.id === key || row.name === key);
const create = label => {
  const id = (basename(process.argv[1]) === 'hc' ? 't' : 'tab1:p') + (Object.keys(db).length + 1);
  db[id] = { id, label, sources: {}, labels: {} };
  return db[id];
};
const pane = row => ({ pane_id: row.id, tokens: Object.assign({}, ...Object.values(row.sources)),
  agent: row.label === 'managed' ? 'opencode' : 'claude', agent_status: 'working' });
const no = () => process.exit(1);
switch (basename(process.argv[1])) {
  case 'herdr-app':
    assert.fail('unexpected call to herdr-app');
  case 'hc':
    switch (a) {
      case 'get': {
        if (b === 'parent') {
          assert.equal(c, '--json');
          out({ labels: { 'herdr.space': 's1', 'herdr.tab': 'tab1' } });
          break;
        }
        if (process.env.CHECK_READ_ONLY === '1') {
          assert.equal(process.env.HC_TERMINAL_ID, undefined);
          assert.equal(process.env.HC_SOCKET, 'mock-socket');
          assert.equal(process.env.HC_SESSION, 'mock-session');
        }
        const row = find(b) ?? no();
        out({ address: row.id, name: row.name, labels: row.labels, status: { app: 'OpenCode', state: 'working' } });
        break;
      }
      case 'run': {
        const row = create(flag('--name'));
        row.name = row.label;
        row.labels = Object.fromEntries(values('--label').map(kv));
        assert.equal(row.labels.goal_startup, 'pending');
        save();
        out({ address: row.id });
        break;
      }
      case 'label': {
        const row = find(b) ?? no();
        if (process.env.GOAL_FAIL === '1' && c === 'goal_startup=ready') no();
        for (const [key, value] of args.slice(2).map(kv)) {
          if (value) row.labels[key] = value;
          else delete row.labels[key];
        }
        save();
        break;
      }
      case 'send':
        if (process.env.GOAL_FAIL === '1') no();
        break;
      default: assert.fail(a);
    }
    break;
  case 'herdr':
    switch (a + ' ' + b) {
      case 'agent get': {
        const row = find(c) ?? no();
        out({ result: { agent: pane(row) } });
        break;
      }
      case 'pane get':
        out({ result: { pane: pane((db[c] ?? db[c.replace(/^p_(\\d+)$/, 'tab1:p$1')]) ?? no()) } });
        break;
      case 'tab create': {
        const row = create(flag('--label'));
        save();
        out({ result: { root_pane: { pane_id: row.id } } });
        break;
      }
      case 'pane report-metadata':
        // Replace this source, forcing immutable goal tokens to live separately.
        (find(c) ?? no()).sources[flag('--source')] = Object.fromEntries(values('--token').map(kv));
        save();
        break;
      case 'pane run':
        assert.equal(db[c].sources['herdr-spawn-goal'].goal_startup, 'pending');
        if (process.env.GOAL_FAIL === '1') no();
        break;
      case 'agent rename':
        if (process.env.GOAL_FAIL === 'rename') no();
        (find(c) ?? no()).name = args[3];
        save();
        break;
      case 'agent prompt':
        if (process.env.GOAL_FAIL === '1') no();
        break;
      default: assert.fail(a + ' ' + b);
    }
}
`;

for (const surface of ['herdr', 'hc']) {
  test(`goal manifests and lifecycle over ${surface}`, async t => {
    const root = await mkdtemp(join(tmpdir(), 'herdr-lane-goal-'));
    t.after(() => rm(root, { recursive: true, force: true }));
    const db = join(root, 'db');
    const brief = join(root, 'brief');
    const conf = join(root, 'agents.conf');
    const state = join(root, 'state');
    await mkdir(state);
    await writeFile(db, '{}');
    await writeFile(brief, 'Test brief');
    await writeFile(conf, 'lane:omp omp --goal {goal} --append-system-prompt {promptfile} -e {adapters}/omp/herdr-lanes.ts\n');
    await writeFile(join(root, 'cli'), cli, { mode: 0o700 });
    for (const name of ['herdr-app', 'herdr', 'hc']) await symlink('cli', join(root, name));
    await writeFile(join(root, 'setsid'), '#!/bin/sh\nexit 0\n', { mode: 0o700 });
    const env = {
      ...process.env, PATH: `${root}:${process.env.PATH}`, GOAL_MOCK: db, GOAL_FAIL: '0',
      HERDR_ENV: surface === 'herdr' ? '1' : '', HERDR_PANE_ID: 'parent', HC_TERMINAL_ID: 'parent',
      HC_SOCKET: 'mock-socket', HC_SESSION: 'mock-session',
      HERDR_SPAWN_CONFIG: conf, XDG_STATE_HOME: state,
    };
    const invoke = (script, args, extra = {}) =>
      run('bash', [join(scripts, script), ...args], { cwd: root, env: { ...env, ...extra }, timeout: 10_000 });
    const spawnLane = (agent, name, goal = objective, extra) =>
      invoke('spawn.sh', ['--tab', root, '--lane', 'unit', '--goal', goal, agent, name, brief], extra);
    const lane = (args, extra) => invoke('lane.sh', args, extra);
    const goal = async target => JSON.parse((await lane(['goal', target], { CHECK_READ_ONLY: '1' })).stdout);
    const rows = async () => JSON.parse(await readFile(db, 'utf8'));
    await assert.rejects(spawnLane('opencode', 'blank', ' \t\n'), /--goal needs a non-empty objective/);
    assert.deepEqual(await rows(), {});
    const { stdout } = await spawnLane('opencode', 'managed');
    const id = stdout.split(' ')[0];
    const original = await goal('managed');
    assert.deepEqual(await goal(id), original);
    if (surface === 'herdr') {
      // The legacy pane alias p_1 refers to the managed pane, not the lane named p_1.
      await assert.rejects(goal('p_1'), /no agent p_1/);
      await spawnLane('claude', 'p_1', 'named lane objective');
      assert.equal((await goal('p_1')).objective, 'named lane objective');
      assert.equal((await goal(id)).objective, objective);
    }
    assert.equal(original.objective, objective);
    assert.equal(original.goal_mode, 'managed');
    assert.equal(original.goal_verification, 'not_applicable');
    assert.equal(original.goal_status, 'active');
    assert.equal(original.lane_mode, 'unit');
    const manifest = join(state, 'herdr-spawn', 'goals', original.goal_id, 'goal.json');
    const composed = join(state, 'herdr-spawn', 'goals', original.goal_id, 'brief.md');
    assert.equal((await stat(manifest)).mode & 0o777, 0o400);
    const originalBrief = await readFile(composed, 'utf8');
    assert.ok(originalBrief.includes(objective));
    const before = await readFile(db, 'utf8');
    await goal(id);
    assert.equal(await readFile(db, 'utf8'), before);
    assert.ok(!before.includes('Exact'), 'objective must not be in terminal metadata');

    const inside = { HERDR_PANE_ID: id, HC_TERMINAL_ID: id, LANE_COORDINATOR: 'parent', LANE_MODE: 'unit' };
    await lane(['escalate', 'a question'], inside);
    assert.equal((await goal(id)).goal_status, 'escalated');
    await assert.rejects(lane(['reply', 'managed', 'no delivery'], { GOAL_FAIL: '1' }), /state is unchanged/);
    assert.equal((await goal(id)).goal_status, 'escalated');
    await lane(['reply', 'managed', 'an answer']);
    assert.equal((await goal(id)).goal_status, 'active');
    await lane(['done', 'done'], inside);
    assert.equal((await goal(id)).goal_status, 'done');
    await lane(['working'], inside);
    assert.deepEqual(await goal(id), original);

    await spawnLane('claude', 'native');
    const native = await goal('native');
    assert.equal(native.goal_mode, 'native');
    assert.equal(native.goal_verification, 'unverified');
    await spawnLane('omp', 'custom');
    assert.equal((await goal('custom')).goal_mode, 'custom');

    const current = await rows();
    delete current[id].name; // Simulate freeing the name while the old pane is still inspectable.
    await writeFile(db, JSON.stringify(current));
    await spawnLane('opencode', 'managed', 'a different objective');
    const reused = await goal('managed');
    assert.notEqual(reused.goal_id, original.goal_id);
    assert.equal(reused.objective, 'a different objective');
    assert.deepEqual(await goal(id), original);
    assert.equal(await readFile(composed, 'utf8'), originalBrief);
    const reusedDir = join(state, 'herdr-spawn', 'goals', reused.goal_id);
    assert.match(await readFile(join(reusedDir, 'brief.md'), 'utf8'), /a different objective/);
    assert.match(await readFile(join(reusedDir, 'opencode.json'), 'utf8'), /herdr-lanes/);

    await assert.rejects(spawnLane('claude', 'failed', objective, { GOAL_FAIL: '1' }), /left open/);
    const failed = Object.values(await rows()).find(row => row.label === 'failed').id;
    assert.equal((await goal(failed)).goal_status, 'failed');
    if (surface === 'herdr') {
      await assert.rejects(spawnLane('claude', 'rename-failed', objective, { GOAL_FAIL: 'rename' }), /rename to rename-failed failed/);
      const renameFailed = Object.values(await rows()).find(row => row.label === 'rename-failed').id;
      assert.equal((await goal(renameFailed)).goal_startup, 'failed');
    }

    const old = await rows();
    if (surface === 'hc') delete old[id].labels.goal_id;
    else delete old[id].sources['herdr-spawn-goal'];
    await writeFile(db, JSON.stringify(old));
    await assert.rejects(lane(['goal', id]), /has no goal manifest/);
    await lane(['working'], inside);
  });
}
