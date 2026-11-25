import assert from 'node:assert/strict';
import { execFile } from 'node:child_process';
import { chmod, mkdir, mkdtemp, readFile, rm, stat, symlink, writeFile } from 'node:fs/promises';
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
  db[id] = { id, label, tab, cwd: flag('--cwd'), sources: {}, labels: {} };
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
        fs.appendFileSync(process.env.GOAL_MOCK_SENT, JSON.stringify({ to: b, msg: args[3] }) + '\\n');
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
    // A short fixed prefix keeps the stored path under herdr's 79-character cap whatever tmpdir() is.
    const reportDir = await mkdtemp('/tmp/hsr-');
    t.after(() => rm(reportDir, { recursive: true, force: true }));
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
      HERDR_SPAWN_REPORT_DIR: reportDir, GOAL_MOCK_SENT: join(root, 'sent'),
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
    assert.ok(originalBrief.includes(join(scripts, 'heavy.sh')));
    assert.doesNotMatch(originalBrief, /HEAVY_SH/);
    assert.ok(originalBrief.includes(objective));
    const before = await readFile(db, 'utf8');
    await goal(id);
    assert.equal(await readFile(db, 'utf8'), before);
    assert.ok(!before.includes('Exact'), 'objective must not be in terminal metadata');

    const inside = { HERDR_PANE_ID: id, HC_TERMINAL_ID: id, LANE_COORDINATOR: 'parent', LANE_MODE: 'unit' };
    const token = async () => {
      const r = (await rows())[id];
      return surface === 'herdr' ? r.sources['herdr-spawn'].lane_report : r.labels.lane_report;
    };
    const reportFile = join(root, 'report.md');
    const questionFile = join(root, 'question.md');
    const sentFile = join(root, 'sent');
    await writeFile(sentFile, '');
    await writeFile(reportFile, 'The lane finished its unit.');
    await writeFile(questionFile, 'Should the coordinator decide?');
    const sent = async () => (await readFile(sentFile, 'utf8')).split('\n').filter(Boolean).map(l => JSON.parse(l));
    await lane(['escalate', 'a question', questionFile], inside);
    const asked = await token();
    assert.ok(asked.startsWith(reportDir), asked);
    assert.equal(await readFile(asked, 'utf8'), 'Should the coordinator decide?');
    if (surface === 'hc') {
      const sentList = await sent();
      assert.ok(sentList.at(-1).msg.includes(`Read the full question: ${asked}; answer with:`), sentList.at(-1).msg);
    }
    assert.equal((await goal(id)).goal_status, 'escalated');
    await assert.rejects(lane(['reply', 'managed', 'no delivery'], { GOAL_FAIL: '1' }), /state is unchanged/);
    assert.equal((await goal(id)).goal_status, 'escalated');
    await lane(['reply', 'managed', 'an answer']);
    assert.equal((await goal(id)).goal_status, 'active');
    const { stdout: doneOut } = await lane(['done', 'done', reportFile], inside);
    assert.equal((await goal(id)).goal_status, 'done');
    const laneReport = await token();
    assert.equal(doneOut, `lane.sh: stored the report at ${laneReport}\n`);
    assert.ok(laneReport.startsWith('/'), laneReport);
    assert.ok(laneReport.startsWith(reportDir), laneReport);
    const copyStat = await stat(laneReport);
    assert.equal(copyStat.mode & 0o777, 0o600);
    assert.equal(await readFile(laneReport, 'utf8'), 'The lane finished its unit.');
    if (surface === 'hc') {
      const sentList = await sent();
      assert.ok(sentList.at(-1).msg.includes(`Read its report: ${laneReport}`), sentList.at(-1).msg);
    }
    await lane(['working'], inside);
    assert.deepEqual(await goal(id), original);

    // A refused report sets no token or label and sends no notice.
    const beforeRefusals = await readFile(db, 'utf8');
    const sentBefore = await readFile(sentFile, 'utf8');
    await assert.rejects(lane(['done', 'a summary', join(root, 'missing.md')], inside), /report file is not a readable regular file/);
    await writeFile(join(root, 'empty.md'), '');
    await assert.rejects(lane(['done', 'a summary', join(root, 'empty.md')], inside), /report file is empty/);
    await mkdir(join(root, 'adir'));
    await assert.rejects(lane(['done', 'a summary', join(root, 'adir')], inside), /report file is not a readable regular file/);
    await writeFile(join(root, 'big.md'), 'x'.repeat(262145));
    await assert.rejects(lane(['done', 'a summary', join(root, 'big.md')], inside), /report file is larger than 262144 bytes/);
    const linkDir = join(root, 'reports-link');
    await mkdir(join(root, 'reports-real'), { mode: 0o700 });
    await symlink(join(root, 'reports-real'), linkDir);
    await assert.rejects(lane(['done', 'a summary', reportFile], { ...inside, HERDR_SPAWN_REPORT_DIR: linkDir }), /not private/);
    const wideDir = join(root, 'reports-wide');
    await mkdir(wideDir);
    await chmod(wideDir, 0o755);
    await assert.rejects(lane(['done', 'a summary', reportFile], { ...inside, HERDR_SPAWN_REPORT_DIR: wideDir }), /not private/);
    const refuseDir = (dir, pattern) =>
      assert.rejects(lane(['done', 'a summary', reportFile], { ...inside, HERDR_SPAWN_REPORT_DIR: dir }), pattern);
    await refuseDir('reports', /must be an absolute path/);
    await refuseDir(join(reportDir, 'with space'), /must be an absolute path/);
    const longDir = join(reportDir, 'x'.repeat(60));
    await refuseDir(longDir, /herdr cuts token values at 79/);
    await assert.rejects(stat(longDir), { code: 'ENOENT' });
    await refuseDir(join(reportFile, 'sub'), /could not create the report directory/);
    await assert.rejects(
      lane(['done', 'a summary', reportFile], { ...inside, LC_ALL: 'en_US.UTF-8', HERDR_SPAWN_REPORT_DIR: join(reportDir, 'é') }),
      /must be an absolute path of letters, digits/);
    assert.equal(await readFile(db, 'utf8'), beforeRefusals);
    assert.equal(await readFile(sentFile, 'utf8'), sentBefore);

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
