import assert from 'node:assert/strict';
import { execFile } from 'node:child_process';
import { chmod, mkdir, mkdtemp, readFile, rename, rm, stat, symlink, writeFile } from 'node:fs/promises';
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
const flag = k => args.includes(k) ? args[args.indexOf(k) + 1] : undefined;
const values = k => args.flatMap((x, i) => x === k ? [args[i + 1]] : []);
const kv = x => [x.slice(0, x.indexOf('=')), x.slice(x.indexOf('=') + 1)];
const find = key => Object.values(db).find(row => row.id === key || row.name === key);
const create = (label, parent) => {
  const seq = Object.keys(db).length + 1;
  const tab = parent?.tab ?? 'tab' + seq;
  const id = (basename(process.argv[1]) === 'hc' ? 't' : tab + ':p') + seq;
  db[id] = { id, label, tab, cwd: flag('--cwd'), sources: {}, labels: {},
    session: process.env.MOCK_NO_SESSION === '1' ? null : 'session-' + seq,
    session_after: Number(process.env.MOCK_SESSION_AFTER) || 0, session_calls: 0 };
  return db[id];
};
const pane = (row, hidden = false) => {
  const agent = { pane_id: row.id, name: row.name ?? null,
    tokens: Object.assign({}, ...Object.values(row.sources)),
    agent: row.label === 'managed' ? 'opencode' : 'claude', agent_status: 'working' };
  if (!hidden && row.session) agent.agent_session = { value: row.session };
  return agent;
};
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
        row.parent = flag('--parent');
        row.line = args.at(-1);
        row.labels = Object.fromEntries(values('--label').map(kv));
        if (row.labels.lane_mode) assert.equal(row.labels.goal_startup, 'pending');
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
        if (row.session_after) {
          row.session_calls = (row.session_calls ?? 0) + 1;
          save();
        }
        out({ result: { agent: pane(row, row.session_after > 0 && row.session_calls < row.session_after) } });
        break;
      }
      case 'agent list':
        out({ result: { agents: Object.values(db).map(row => pane(row)) } });
        break;
      case 'pane get':
        out({ result: { pane: pane((db[c] ?? db[c.replace(/^p_(\\d+)$/, 'tab1:p$1')]) ?? no()) } });
        break;
      case 'tab create': {
        const row = create(flag('--label'));
        save();
        out({ result: { root_pane: { pane_id: row.id } } });
        break;
      }
      case 'pane split': {
        const parent = find(c);
        assert.ok(parent, 'split must target the resolved root pane');
        const row = create(undefined, parent);
        row.split = parent.id;
        save();
        out({ result: { pane: { pane_id: row.id } } });
        break;
      }
      case 'pane report-metadata':
        // Replace this source, forcing immutable goal tokens to live separately.
        (find(c) ?? no()).sources[flag('--source')] = Object.fromEntries(values('--token').map(kv));
        save();
        break;
      case 'pane run':
        if (db[c].sources['herdr-spawn-goal']) assert.equal(db[c].sources['herdr-spawn-goal'].goal_startup, 'pending');
        if (process.env.GOAL_FAIL === '1') no();
        db[c].line = args[3];
        save();
        break;
      case 'agent rename':
        if (process.env.GOAL_FAIL === 'rename' || process.env.RENAME_FAIL_PANE === c) no();
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
    await writeFile(conf, [
      'lane:legacy legacy --goal {goal}',
      'lane:custom custom {modelarg} --model-id {model} --goal {goal}',
      'model:custom:frontier vendor/custom:v2',
      'model:claude:small compact-claude',
      'model:claude:frontier -invalid',
      '',
    ].join('\n'));
    await writeFile(join(root, 'cli'), cli, { mode: 0o700 });
    for (const name of ['herdr-app', 'herdr', 'hc']) await symlink('cli', join(root, name));
    await writeFile(join(root, 'setsid'), '#!/bin/sh\nexit 0\n', { mode: 0o700 });
    const env = {
      ...process.env, PATH: `${root}:${process.env.PATH}`, GOAL_MOCK: db, GOAL_FAIL: '0',
      HERDR_ENV: surface === 'herdr' ? '1' : '', HERDR_PANE_ID: 'parent', HC_TERMINAL_ID: 'parent',
      HC_SOCKET: 'mock-socket', HC_SESSION: 'mock-session',
      HERDR_SPAWN_CONFIG: conf, XDG_STATE_HOME: state, SHELL: '/bin/bash', OPENCODE_CONFIG_CONTENT: '',
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
    assert.equal(original.parent_lane, null);
    assert.equal(original.workdir, root);
    assert.equal(original.task_class, 'simple');
    assert.equal(original.model, 'openai/gpt-6.1-terra');
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
    const { stderr: warning } = await spawnLane('legacy', 'legacy');
    const legacy = await goal('legacy');
    assert.equal(legacy.goal_mode, 'custom');
    assert.equal(legacy.model, null);
    assert.match(warning, /custom template kept its own model.*\{modelarg\}/);
    assert.doesNotMatch(Object.values(await rows()).find(row => row.name === 'legacy').line, /--model/);

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
    assert.equal(JSON.parse(await readFile(join(reusedDir, 'opencode.json'), 'utf8')).model, 'openai/gpt-6.1-terra');

    const workdir = join(root, 'different worktree');
    const worklink = join(root, 'worktree-link');
    await mkdir(workdir);
    await symlink(workdir, worklink);
    const start = (opts, agent, name, extra) => invoke('spawn.sh', [...opts, agent, name, brief], extra);
    const rootOpts = ['--tab', worklink, '--lane', 'driver', '--goal', 'Root objective'];
    const subOpts = ['--subtask-of', 'root', '--goal', 'Subtask objective'];
    const idOf = stdout => stdout.trim().split(' ')[0];
    const rootId = idOf((await start(rootOpts, 'claude', 'root')).stdout);
    assert.equal((await goal(rootId)).workdir, workdir);
    assert.equal((await goal(rootId)).model, 'opus');
    assert.equal((await goal(rootId)).task_class, 'complex');
    assert.match((await rows())[rootId].line, /--model opus/);
    if (surface === 'hc') {
      const moved = await rows();
      moved[rootId].labels['herdr.space'] = 's-root';
      moved[rootId].labels['herdr.tab'] = 'tab-root';
      await writeFile(db, JSON.stringify(moved));
    }
    const first = idOf((await start([...subOpts, '--task', 'mechanical'], 'claude', 'sub-first')).stdout);
    const second = idOf((await start(['--subtask-of', rootId, '--goal', 'Another subtask',
      '--task', 'fact-check'], 'custom', 'sub-second')).stdout);
    const third = idOf((await start([...subOpts, '--task', 'exceptional', '--model', 'vendor/chosen@v1'],
      'claude', 'sub-third')).stdout);
    const fourth = idOf((await start([...subOpts, '--task', 'exceptional'], 'omp', 'sub-fourth')).stdout);
    assert.equal(new Set([rootId, first, second, third, fourth]).size, 5);
    const placements = await rows();
    for (const [target, taskClass, model] of [
      [first, 'mechanical', 'compact-claude'],
      [second, 'fact-check', 'vendor/custom:v2'],
      [third, 'exceptional', 'vendor/chosen@v1'],
      [fourth, 'exceptional', 'openai-codex/gpt-6.2-astra'],
    ]) {
      const row = placements[target];
      const manifest = await goal(target);
      assert.equal(manifest.workdir, workdir);
      assert.equal(manifest.parent_lane, rootId);
      assert.equal(manifest.lane_mode, 'unit');
      assert.equal(manifest.task_class, taskClass);
      assert.equal(manifest.model, model);
      assert.equal(row.cwd, workdir);
      assert.match(row.line, /LANE_COORDINATOR=parent/);
      assert.ok(row.line.includes(`--model ${model}`), row.line);
      if (surface === 'hc') {
        assert.equal(row.parent, 'parent');
        assert.equal(row.labels.lane_of, 'parent');
        assert.equal(row.labels['herdr.tab'], placements[rootId].labels['herdr.tab']);
        assert.equal(row.labels['herdr.space'], placements[rootId].labels['herdr.space']);
      } else {
        assert.equal(row.sources['herdr-spawn'].lane_of, 'parent');
        assert.equal(row.tab, placements[rootId].tab);
        assert.equal(row.split, rootId);
      }
    }
    assert.match(placements[second].line, /--model-id vendor\/custom:v2/);

    const beforeInvalid = await readFile(db, 'utf8');
    for (const [opts, agent, message, extra] of [
      [['--lane', 'unit', '--goal', 'Missing tab'], 'claude', /--lane needs --tab/],
      [['--subtask-of', rootId], 'claude', /needs --goal/],
      [[...subOpts, '--tab', workdir], 'claude', /does not combine/],
      [[...subOpts, '--lane', 'unit'], 'claude', /does not combine/],
      [['--subtask-of', first, '--goal', 'Nested'], 'claude', /not a registered root lane/],
      [['--subtask-of', 'missing', '--goal', 'Missing'], 'claude', /no root lane/],
      [subOpts, 'claude', /not a ready lane of the caller/, { HERDR_PANE_ID: first, HC_TERMINAL_ID: first }],
      [[...subOpts, '--task', 'hardness'], 'claude', /--task must be/],
      [[...subOpts, '--task', 'exceptional'], 'claude', /invalid model ID/],
      [[...subOpts, '--model', 'openai/model --auto'], 'opencode', /safe model ID/],
      [[...subOpts, '--task', 'simple'], 'legacy', /template cannot route a model/],
      [[...subOpts, '--model', 'direct'], 'legacy', /template cannot route a model/],
      [[...subOpts, '--task', 'simple'], 'custom', /no model mapping/],
      [subOpts, 'opencode', /one valid JSON object/, { OPENCODE_CONFIG_CONTENT: '{} {}' }],
    ]) {
      await assert.rejects(start(opts, agent, 'rejected', extra), message);
    }
    await assert.rejects(invoke('spawn.sh', [...subOpts, 'claude', 'rejected', brief, rootId, 'right']), /does not combine/);
    const manifestPath = join(state, 'herdr-spawn', 'goals', (await goal(rootId)).goal_id, 'goal.json');
    await chmod(manifestPath, 0o644);
    await assert.rejects(start(subOpts, 'claude', 'rejected'), /no private goal manifest/);
    const rootManifest = await readFile(manifestPath, 'utf8');
    await writeFile(manifestPath, JSON.stringify({ ...JSON.parse(rootManifest), goal_id: 'g.Wrong0000000' }));
    await chmod(manifestPath, 0o400);
    await assert.rejects(start(subOpts, 'claude', 'rejected'), /matching goal manifest/);
    await chmod(manifestPath, 0o600);
    await writeFile(manifestPath, rootManifest);
    await chmod(manifestPath, 0o400);
    assert.equal(await readFile(db, 'utf8'), beforeInvalid, 'an invalid launch must not create a pane');

    const defaultOpts = [...subOpts, '--task', 'simple', '--model', 'default'];
    const noModel = idOf((await start(defaultOpts, 'legacy', 'sub-default')).stdout);
    assert.equal((await goal(noModel)).model, null);
    assert.doesNotMatch((await rows())[noModel].line, /--model/);

    const childEnv = {
      ...env, SHELL: '/bin/true', CAPTURE: join(root, 'oc-env'),
      OPENCODE_CONFIG_CONTENT: JSON.stringify({
        model: 'ignore/this', permissions: { shell: 'deny' }, plugins: [['existing', { fixture: true }]],
        fixture: 'private $HOME $(false) "value"',
      }),
    };
    await writeFile(join(root, 'opencode'), '#!/bin/sh\nprintf "%s\\n" "$OPENCODE_CONFIG_CONTENT" >"$CAPTURE"\n', { mode: 0o700 });
    const oc = idOf((await start([...subOpts, '--task', 'fact-check'], 'opencode', 'sub-oc', childEnv)).stdout);
    const ocLine = (await rows())[oc].line;
    assert.doesNotMatch(ocLine, /private \$HOME/);
    assert.doesNotMatch(ocLine, /--model /);
    await run('bash', ['-c', ocLine], { cwd: workdir, env: childEnv, timeout: 2000 });
    const captured = JSON.parse(await readFile(childEnv.CAPTURE, 'utf8'));
    const inherited = JSON.parse(childEnv.OPENCODE_CONFIG_CONTENT);
    assert.equal(captured.model, 'openai/gpt-6.2-astra');
    assert.deepEqual(captured.permissions, inherited.permissions);
    assert.equal(captured.fixture, inherited.fixture);
    assert.deepEqual(captured.plugins.slice(0, -1), inherited.plugins);
    assert.match(captured.plugins.at(-1), /\/adapters\/opencode\/herdr-lanes$/);
    const ocManifest = await goal(oc);
    assert.equal(ocManifest.model, captured.model);
    const ocConfig = JSON.parse(await readFile(join(state, 'herdr-spawn', 'goals', ocManifest.goal_id, 'opencode.json'), 'utf8'));
    assert.deepEqual(ocConfig, { model: captured.model, plugins: [captured.plugins.at(-1)] });
    await rm(childEnv.CAPTURE);
    const invalidChild = run('bash', ['-c', ocLine], {
      cwd: workdir, env: { ...childEnv, OPENCODE_CONFIG_CONTENT: '[' }, timeout: 2000,
    });
    if (surface === 'hc') assert.match((await invalidChild).stderr, /invalid child OPENCODE_CONFIG_CONTENT/);
    else await assert.rejects(invalidChild, /invalid child OPENCODE_CONFIG_CONTENT/);
    await assert.rejects(readFile(childEnv.CAPTURE), { code: 'ENOENT' });
    const { stderr: trace } = await run('bash', ['-xc', ocLine], { cwd: workdir, env: childEnv, timeout: 2000 });
    assert.doesNotMatch(trace, /private \$HOME/);

    await assert.rejects(spawnLane('claude', 'failed', objective, { GOAL_FAIL: '1' }), /left open/);
    const failed = Object.values(await rows()).find(row => row.label === 'failed').id;
    assert.equal((await goal(failed)).goal_status, 'failed');
    const beforeFailedParent = await rows();
    await assert.rejects(start(['--subtask-of', failed, '--goal', 'Invalid parent'], 'claude', 'rejected'), /not a ready lane/);
    assert.deepEqual(await rows(), beforeFailedParent);
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
    await assert.rejects(start(['--subtask-of', id, '--goal', 'Invalid parent'], 'claude', 'rejected'), /not a ready lane|goal manifest/);
    await lane(['working'], inside);
  });
}

async function restoreFixture(t) {
  const root = await mkdtemp(join(tmpdir(), 'herdr-lane-restore-'));
  t.after(() => rm(root, { recursive: true, force: true, maxRetries: 5 }));
  const db = join(root, 'db');
  const brief = join(root, 'brief');
  const state = join(root, 'state');
  const goals = join(state, 'herdr-spawn', 'goals');
  const watchlog = join(root, 'watch.log');
  await mkdir(state);
  await writeFile(db, '{}');
  await writeFile(brief, 'Test brief');
  await writeFile(join(root, 'cli'), cli, { mode: 0o700 });
  for (const name of ['herdr-app', 'herdr', 'hc']) await symlink('cli', join(root, name));
  await writeFile(join(root, 'setsid'), '#!/bin/sh\nprintf "%s\\n" "$*" >>"$WATCH_LOG"\n', { mode: 0o700 });
  const env = {
    ...process.env, PATH: `${root}:${process.env.PATH}`, GOAL_MOCK: db, GOAL_FAIL: '0',
    HERDR_ENV: '1', HERDR_PANE_ID: 'parent', HC_TERMINAL_ID: '',
    XDG_STATE_HOME: state, SHELL: '/bin/bash', WATCH_LOG: watchlog,
    HERDR_SPAWN_CONFIG: join(root, 'agents.conf'), OPENCODE_CONFIG_CONTENT: '',
  };
  const invoke = (script, args, extra = {}, timeout = 10_000) =>
    run('bash', [join(scripts, script), ...args], { cwd: root, env: { ...env, ...extra }, timeout });
  const spawn = (name, extra, timeout) => invoke('spawn.sh',
    ['--tab', root, '--lane', 'unit', '--goal', `Objective for ${name}`, 'opencode', name, brief], extra, timeout);
  const idOf = stdout => stdout.trim().split(' ')[0];
  const rows = async () => JSON.parse(await readFile(db, 'utf8'));
  const setRows = async all => writeFile(db, JSON.stringify(all));
  const goalId = async pane => (await rows())[pane].sources['herdr-spawn-goal'].goal_id;
  const recordFile = async pane => join(goals, await goalId(pane), 'lane.json');
  const record = async pane => JSON.parse(await readFile(await recordFile(pane), 'utf8'));
  const forget = async pane => {
    const all = await rows();
    delete all[pane].name;
    delete all[pane].sources['herdr-spawn'];
    delete all[pane].sources['herdr-spawn-goal'];
    await setRows(all);
  };
  const watch = async () => {
    try { return await readFile(watchlog, 'utf8'); } catch (e) { if (e.code === 'ENOENT') return ''; throw e; }
  };
  // spawn.sh itself starts the watcher, so discard that start before checking a later one. The detached stub
  // writes asynchronously, so give it a moment before reading the log.
  const clearWatch = () => rm(watchlog, { force: true });
  const pause = () => new Promise(resolve => setTimeout(resolve, 200));
  const settledWatch = async () => {
    for (let i = 0; i < 20 && !(await watch()); i++) await pause();
    return watch();
  };
  return { root, goals, invoke, spawn, idOf, rows, setRows, goalId, recordFile, record, forget, watch, clearWatch, pause, settledWatch };
}

test('spawn.sh records a restorable TUI lane', async t => {
  const f = await restoreFixture(t);
  const id = f.idOf((await f.spawn('managed')).stdout);
  assert.deepEqual(await f.record(id), {
    name: 'managed', pane: id, lane_of: 'parent', lane_mode: 'unit',
    agent: 'opencode', agent_session: (await f.rows())[id].session,
  });
  assert.equal((await stat(await f.recordFile(id))).mode & 0o777, 0o400);

  // The session reaches the mock on the third agent get; the bounded poll must wait for it.
  const late = await f.spawn('late', { MOCK_SESSION_AFTER: '3' });
  const lateId = f.idOf(late.stdout);
  assert.doesNotMatch(late.stderr, /cannot be restored/);
  assert.deepEqual(await f.record(lateId), {
    name: 'late', pane: lateId, lane_of: 'parent', lane_mode: 'unit',
    agent: 'claude', agent_session: (await f.rows())[lateId].session,
  });

  const { stdout, stderr } = await f.spawn('nosession', { MOCK_NO_SESSION: '1' }, 15_000);
  assert.match(stderr, /no agent_session after 5s \(is Herdr's claude integration installed\? see: herdr integration status\)/);
  const noId = f.idOf(stdout);
  assert.equal((await f.rows())[noId].name, 'nosession');
  await assert.rejects(f.record(noId), { code: 'ENOENT' });
});

test('lane.sh restore re-applies a restarted lane and starts its watcher', async t => {
  const f = await restoreFixture(t);
  const id = f.idOf((await f.spawn('managed')).stdout);
  const gid = await f.goalId(id);
  await f.forget(id);
  await f.clearWatch();
  const { stdout } = await f.invoke('lane.sh', ['restore']);
  assert.match(stdout, new RegExp(`managed: restored on ${id}`));
  const row = (await f.rows())[id];
  assert.equal(row.name, 'managed');
  assert.deepEqual(row.sources['herdr-spawn-goal'], { goal_id: gid, goal_mode: 'managed', goal_startup: 'ready' });
  const tokens = row.sources['herdr-spawn'];
  assert.equal(tokens.lane_of, 'parent');
  assert.equal(tokens.lane_mode, 'unit');
  assert.equal(tokens.lane_state, 'working');
  assert.match(tokens.lane_report, /^\d+-\d+-\d+$/);
  assert.match(await f.settledWatch(), /lanes-watch.sh parent/);
});

test('lane.sh restore ignores other coordinators and already named lanes', async t => {
  const f = await restoreFixture(t);
  const mine = f.idOf((await f.spawn('managed')).stdout);
  const other = f.idOf((await f.spawn('other')).stdout);
  const named = f.idOf((await f.spawn('keeper')).stdout);
  const otherFile = await f.recordFile(other);
  await f.forget(mine);
  await f.forget(other);
  await chmod(otherFile, 0o600);
  await writeFile(otherFile, JSON.stringify({ ...JSON.parse(await readFile(otherFile, 'utf8')), lane_of: 'elsewhere' }));
  await chmod(otherFile, 0o400);
  const keeperTokens = JSON.stringify((await f.rows())[named].sources);

  const { stdout } = await f.invoke('lane.sh', ['restore']);
  assert.match(stdout, /managed: restored on/);
  assert.match(stdout, /keeper: present/);
  assert.doesNotMatch(stdout, /other:/);
  const all = await f.rows();
  assert.equal(all[other].name, undefined);
  assert.deepEqual(all[other].sources, {});
  assert.equal(JSON.stringify(all[named].sources), keeperTokens);
});

test('lane.sh restore reports not running and ambiguous sessions', async t => {
  const f = await restoreFixture(t);
  const gone = f.idOf((await f.spawn('managed')).stdout);
  await f.forget(gone);
  const all = await f.rows();
  delete all[gone];
  await f.setRows(all);
  await f.clearWatch();
  assert.match((await f.invoke('lane.sh', ['restore'])).stdout, /managed: not running/);
  await f.pause();
  assert.equal(await f.watch(), '');

  const g = await restoreFixture(t);
  const a = g.idOf((await g.spawn('managed')).stdout);
  const b = g.idOf((await g.spawn('second')).stdout);
  const files = [await g.recordFile(a), await g.recordFile(b)];
  await g.forget(a);
  await g.forget(b);
  const both = await g.rows();
  both[a].session = 'shared-session';
  both[b].session = 'shared-session';
  await g.setRows(both);
  for (const file of files) {
    await chmod(file, 0o600);
    await writeFile(file, JSON.stringify({ ...JSON.parse(await readFile(file, 'utf8')), agent_session: 'shared-session' }));
    await chmod(file, 0o400);
  }
  await g.clearWatch();
  const { stdout } = await g.invoke('lane.sh', ['restore']);
  assert.match(stdout, /managed: ambiguous, 2 panes share its session/);
  assert.match(stdout, /second: ambiguous, 2 panes share its session/);
  assert.equal((await g.rows())[a].name, undefined);
  assert.equal((await g.rows())[b].name, undefined);
  await g.pause();
  assert.equal(await g.watch(), '');
});

test('lane.sh restore works in the herdr TUI only', async t => {
  const f = await restoreFixture(t);
  await assert.rejects(f.invoke('lane.sh', ['restore'], { HERDR_ENV: '', HC_TERMINAL_ID: 'parent' }),
    /lane.sh restore works in the herdr TUI only/);
});

test('in-lane done reads lane tokens after a restart', async t => {
  const f = await restoreFixture(t);
  const id = f.idOf((await f.spawn('managed')).stdout);
  const before = (await f.rows())[id].sources['herdr-spawn'];
  await f.clearWatch();
  await f.invoke('lane.sh', ['done', 'finished from pane tokens'],
    { HERDR_PANE_ID: id, LANE_COORDINATOR: '', LANE_MODE: '' });
  const tokens = (await f.rows())[id].sources['herdr-spawn'];
  assert.equal(tokens.lane_of, before.lane_of);
  assert.equal(tokens.lane_mode, before.lane_mode);
  assert.equal(tokens.lane_state, 'done');
  assert.equal(tokens.lane_note, 'finished from pane tokens');
  assert.match(tokens.lane_report, /^\d+-\d+-\d+$/);
  await f.pause();
  assert.equal(await f.watch(), '');
});

test('in-lane done restores itself from its lane record', async t => {
  const f = await restoreFixture(t);
  const id = f.idOf((await f.spawn('managed')).stdout);
  const gid = await f.goalId(id);
  await f.forget(id);
  await f.clearWatch();
  const { stdout } = await f.invoke('lane.sh', ['done', 'finished after restore'],
    { HERDR_PANE_ID: id, LANE_COORDINATOR: '', LANE_MODE: '' });
  assert.match(stdout, new RegExp(`managed: restored on ${id}`));
  const row = (await f.rows())[id];
  assert.equal(row.name, 'managed');
  assert.deepEqual(row.sources['herdr-spawn-goal'], { goal_id: gid, goal_mode: 'managed', goal_startup: 'ready' });
  const tokens = row.sources['herdr-spawn'];
  assert.equal(tokens.lane_of, 'parent');
  assert.equal(tokens.lane_mode, 'unit');
  assert.equal(tokens.lane_state, 'done');
  assert.equal(tokens.lane_note, 'finished after restore');
  assert.match(tokens.lane_report, /^\d+-\d+-\d+$/);
  assert.match(await f.settledWatch(), /lanes-watch.sh parent/);
});

test('in-lane done fails without tokens or a lane record', async t => {
  const f = await restoreFixture(t);
  const id = f.idOf((await f.spawn('managed')).stdout);
  const file = await f.recordFile(id);
  await f.forget(id);
  await rm(file);
  await f.clearWatch();
  await assert.rejects(f.invoke('lane.sh', ['done', 'nothing'],
    { HERDR_PANE_ID: id, LANE_COORDINATOR: '', LANE_MODE: '' }), /has no lane tokens and no single lane record/);
  assert.deepEqual((await f.rows())[id].sources, {});
  await f.pause();
  assert.equal(await f.watch(), '');
});

test('in-lane done rejects pane tokens that do not name a coordinator and mode', async t => {
  for (const tokens of [{ lane_mode: 'unit' }, { lane_of: '-', lane_mode: 'unit' }, { lane_of: 'w1:p1', lane_mode: 'x' }]) {
    const f = await restoreFixture(t);
    const id = f.idOf((await f.spawn('managed')).stdout);
    const file = await f.recordFile(id);
    await f.forget(id);
    await rm(file);
    const all = await f.rows();
    all[id].sources['herdr-spawn'] = tokens;
    await f.setRows(all);
    await assert.rejects(f.invoke('lane.sh', ['done', 'nothing'],
      { HERDR_PANE_ID: id, LANE_COORDINATOR: '', LANE_MODE: '' }), /has no lane tokens and no single lane record/);
    assert.deepEqual((await f.rows())[id].sources['herdr-spawn'], tokens);
  }
});

test('lane.sh restore does not treat another coordinator\'s same-named lane as present', async t => {
  const f = await restoreFixture(t);
  const x = f.idOf((await f.spawn('managed')).stdout);
  const y = f.idOf((await f.spawn('squatter')).stdout);
  await rm(await f.recordFile(y));
  await f.forget(x);
  await f.forget(y);
  const all = await f.rows();
  all[y].name = 'managed';
  all[y].sources['herdr-spawn'] = { lane_of: 'elsewhere', lane_mode: 'unit' };
  await f.setRows(all);
  await f.clearWatch();
  const { stdout } = await f.invoke('lane.sh', ['restore']);
  assert.match(stdout, new RegExp(`managed: cannot restore, pane ${y} holds the name`));
  assert.doesNotMatch(stdout, /present/);
  const after = await f.rows();
  assert.equal(after[x].name, undefined);
  assert.deepEqual(after[x].sources, {});
  await f.pause();
  assert.equal(await f.watch(), '');
});

test('in-lane self-restore reports a name another pane holds', async t => {
  const f = await restoreFixture(t);
  const x = f.idOf((await f.spawn('managed')).stdout);
  const y = f.idOf((await f.spawn('squatter')).stdout);
  await rm(await f.recordFile(y));
  await f.forget(x);
  await f.forget(y);
  const all = await f.rows();
  all[y].name = 'managed';
  await f.setRows(all);
  await f.clearWatch();
  await assert.rejects(f.invoke('lane.sh', ['done', 'nothing'],
    { HERDR_PANE_ID: x, LANE_COORDINATOR: '', LANE_MODE: '' }), err => {
    assert.match(err.stdout, new RegExp(`pane ${y} holds the name`));
    return true;
  });
  const after = await f.rows();
  assert.equal(after[x].name, undefined);
  assert.deepEqual(after[x].sources, {});
  await f.pause();
  assert.equal(await f.watch(), '');
});

test('lane.sh restore does not treat a same-coordinator lane on another pane as present', async t => {
  const f = await restoreFixture(t);
  const x = f.idOf((await f.spawn('managed')).stdout);
  const y = f.idOf((await f.spawn('squatter')).stdout);
  await rm(await f.recordFile(y));
  await f.forget(x);
  await f.forget(y);
  const all = await f.rows();
  all[y].name = 'managed';
  all[y].sources['herdr-spawn'] = { lane_of: 'parent', lane_mode: 'unit' };
  await f.setRows(all);
  await f.clearWatch();
  const { stdout } = await f.invoke('lane.sh', ['restore']);
  assert.match(stdout, new RegExp(`managed: cannot restore, pane ${y} holds the name`));
  assert.doesNotMatch(stdout, /present/);
  const after = await f.rows();
  assert.equal(after[x].name, undefined);
  assert.deepEqual(after[x].sources, {});
});

test('in-lane self-restore reports a same-coordinator lane on another pane holding the name', async t => {
  const f = await restoreFixture(t);
  const x = f.idOf((await f.spawn('managed')).stdout);
  const y = f.idOf((await f.spawn('squatter')).stdout);
  await rm(await f.recordFile(y));
  await f.forget(x);
  await f.forget(y);
  const all = await f.rows();
  all[y].name = 'managed';
  all[y].sources['herdr-spawn'] = { lane_of: 'parent', lane_mode: 'unit' };
  await f.setRows(all);
  await assert.rejects(f.invoke('lane.sh', ['done', 'nothing'],
    { HERDR_PANE_ID: x, LANE_COORDINATOR: '', LANE_MODE: '' }), err => {
    assert.match(err.stdout, new RegExp(`pane ${y} holds the name`));
    return true;
  });
  const after = await f.rows();
  assert.equal(after[x].name, undefined);
  assert.deepEqual(after[x].sources, {});
});

test('lane.sh restore carries on after one lane fails to rename', async t => {
  const f = await restoreFixture(t);
  const a = f.idOf((await f.spawn('managed')).stdout);
  const b = f.idOf((await f.spawn('second')).stdout);
  await f.forget(a);
  await f.forget(b);
  const { stdout } = await f.invoke('lane.sh', ['restore'], { RENAME_FAIL_PANE: a });
  assert.match(stdout, /managed: cannot restore, rename failed/);
  assert.match(stdout, new RegExp(`second: restored on ${b}`));
  const after = await f.rows();
  assert.equal(after[a].name, undefined);
  assert.deepEqual(after[a].sources, {});
  assert.equal(after[b].name, 'second');
});

test('lane.sh restore says when goal.json has no goal_mode', async t => {
  const f = await restoreFixture(t);
  const id = f.idOf((await f.spawn('managed')).stdout);
  const gid = await f.goalId(id);
  const manifest = join(f.goals, gid, 'goal.json');
  await chmod(manifest, 0o600);
  const { goal_mode: _, ...rest } = JSON.parse(await readFile(manifest, 'utf8'));
  await writeFile(manifest, JSON.stringify(rest));
  await f.forget(id);
  const { stdout } = await f.invoke('lane.sh', ['restore']);
  assert.match(stdout, new RegExp(`managed: cannot restore, no goal_mode in .*${gid}/goal.json`));
  assert.equal((await f.rows())[id].name, undefined);
});

test('lane.sh restore gives tokens back to a pane that kept its name', async t => {
  const f = await restoreFixture(t);
  const id = f.idOf((await f.spawn('managed')).stdout);
  await f.forget(id);
  const all = await f.rows();
  all[id].name = 'managed';
  await f.setRows(all);
  await f.clearWatch();
  const { stdout } = await f.invoke('lane.sh', ['restore']);
  assert.match(stdout, new RegExp(`managed: restored on ${id}`));
  const row = (await f.rows())[id];
  assert.equal(row.name, 'managed');
  assert.equal(row.sources['herdr-spawn'].lane_of, 'parent');
  assert.equal(row.sources['herdr-spawn'].lane_state, 'working');
  assert.match(await f.settledWatch(), /lanes-watch.sh parent/);
});

test('lane.sh restore does not take a name another pane holds', async t => {
  const f = await restoreFixture(t);
  const x = f.idOf((await f.spawn('managed')).stdout);
  const y = f.idOf((await f.spawn('squatter')).stdout);
  await rm(await f.recordFile(y));
  await f.forget(x);
  await f.forget(y);
  const all = await f.rows();
  all[y].name = 'managed';
  await f.setRows(all);
  await f.clearWatch();
  const { stdout } = await f.invoke('lane.sh', ['restore']);
  assert.match(stdout, new RegExp(`managed: cannot restore, pane ${y} holds the name`));
  const after = await f.rows();
  assert.equal(after[x].name, undefined);
  assert.deepEqual(after[x].sources, {});
  assert.equal(after[y].name, 'managed');
  await f.pause();
  assert.equal(await f.watch(), '');
});

test('lane.sh restore skips symlinked goal directories and lane records', async t => {
  const f = await restoreFixture(t);
  const dirPane = f.idOf((await f.spawn('managed')).stdout);
  const dir = join(f.goals, await f.goalId(dirPane));
  await f.forget(dirPane);
  await rename(dir, join(f.goals, 'hidden'));
  await symlink(join(f.goals, 'hidden'), dir);

  const filePane = f.idOf((await f.spawn('second')).stdout);
  const file = await f.recordFile(filePane);
  await f.forget(filePane);
  await rename(file, `${file}.real`);
  await symlink(`${file}.real`, file);

  await f.clearWatch();
  const { stdout } = await f.invoke('lane.sh', ['restore']);
  assert.doesNotMatch(stdout, /restored on/);
  assert.match(stdout, /lane\.json: skipped, not a valid lane record/);
  const all = await f.rows();
  assert.equal(all[dirPane].name, undefined);
  assert.equal(all[filePane].name, undefined);
  await f.pause();
  assert.equal(await f.watch(), '');
});
