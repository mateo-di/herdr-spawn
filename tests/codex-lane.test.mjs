import assert from 'node:assert/strict';
import { execFile, spawn, spawnSync } from 'node:child_process';
import { once } from 'node:events';
import { chmod, mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { createServer } from 'node:http';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { test } from 'node:test';
import { setTimeout as delay } from 'node:timers/promises';
import { promisify } from 'node:util';

const helper = fileURLToPath(new URL('../skills/herdr-spawn/scripts/codex-lane.mjs', import.meta.url));
const spawnScript = fileURLToPath(new URL('../skills/herdr-spawn/scripts/spawn.sh', import.meta.url));
const run = promisify(execFile);
const id = '019abcde-0123-7123-8000-0123456789ab';
const name = 'codex_child-1';
const goal = 'Check "$HOME" and $(false).\nDone when it is verified.';
const inheritShell = 'shell_environment_policy.inherit=all';

async function fixture(t) {
  const root = await mkdtemp(join(tmpdir(), 'codex-lane-test-'));
  t.after(() => rm(root, { recursive: true, force: true }));
  const startup = join(root, 'startup');
  const brief = join(root, `brief "$HOME" $(false) 'Ω'.md`);
  await mkdir(startup);
  await writeFile(brief, 'Test brief');
  const env = {
    ...process.env, HERDR_PANE_ID: 'child', LANE_MODE: 'unit', LANE_COORDINATOR: 'parent',
    HOME: root, CLAUDE_CONFIG_DIR: join(root, 'claude'), CLAUDE_CODE_SESSION_ID: '',
  };
  return { root, startup, brief, env };
}

async function waitForFile(path, timeout = 5000) {
  const deadline = Date.now() + timeout;
  do {
    const data = await readFile(path, 'utf8').catch(error => {
      if (error.code !== 'ENOENT') throw error;
    });
    if (data) return data.trim();
    await delay(50);
  } while (Date.now() < deadline);
  assert.fail(`Timed out waiting for ${path}`);
}

const fakeCodex = `#!/usr/bin/env node
const assert = require('node:assert/strict');
const { appendFileSync, existsSync, writeFileSync } = require('node:fs');
const { createInterface } = require('node:readline');
const { join } = require('node:path');
const args = process.argv.slice(2);
const [command] = args;
const model = process.env.FAKE_MODEL;
const lane = process.cwd();
const id = process.env.FAKE_THREAD_ID ?? '${id}';
const expectedName = process.env.FAKE_THREAD_NAME ?? '${name}';
const nameOnly = process.env.FAKE_NAME_ONLY === '1';
const rollout = join(lane, 'rollout.jsonl');
const finish = join(lane, 'finish');
const event = payload => appendFileSync(rollout, JSON.stringify({ type: 'event_msg', payload }) + '\\n');
assert.equal(process.env.HERDR_PANE_ID, 'child');
assert.equal(process.env.LANE_MODE, 'unit');
assert.equal(process.env.LANE_COORDINATOR, 'parent');
if (command === 'resume') {
  assert.deepEqual(args, ['resume', '--no-daemon', '-c', '${inheritShell}', ...(model ? ['--model', model] : []), '--', id]);
  writeFileSync(join(lane, 'resumed'), id);
  if (process.env.FAKE === 'resume-exited') process.exit(17);
  const interval = setInterval(() => {
    if (!existsSync(finish)) return;
    const trigger = process.env.FAKE === 'wrong-turn' ? 'user' : 'goal';
    event({ type: 'task_started', turn_attribution: { turn_trigger: trigger } });
    writeFileSync(join(lane, 'turn'), trigger);
    clearInterval(interval);
    const leave = setInterval(() => {
      if (existsSync(join(lane, 'leave'))) clearInterval(leave);
    }, 25);
  }, 25);
} else {
  assert.deepEqual(args, ['app-server', ...(nameOnly ? [] : ['-c', '${inheritShell}']), '--listen', 'stdio://']);
  let named;
  let stored;
  process.stdin.on('end', () => { if (process.env.FAKE === 'bad-exit') process.exit(3); });
  createInterface({ input: process.stdin }).on('line', line => {
    const { id: requestId, method, params } = JSON.parse(line);
    const write = message => process.stdout.write(JSON.stringify(message) + '\\n');
    const reply = result => write({ id: requestId, result });
    if (method === 'initialize') reply({});
    else if (method === 'initialized') write({ method: 'irrelevant/notification' });
    else if (method === 'thread/start') {
      assert.deepEqual(params, {
        cwd: lane, ephemeral: false, ...(nameOnly ? {} : { config: { 'features.goals': false } }), ...(model ? { model } : {}),
      });
      reply({ thread: { id, path: rollout, cwd: lane, ephemeral: false } });
    } else if (method === 'thread/name/set') {
      assert.deepEqual(params, { threadId: id, name: expectedName });
      if (process.env.FAKE === 'name-error') {
        write({ id: requestId, error: { message: 'name could not be set' } });
        return;
      }
      named = params.name;
      // A lane's rollout comes from its goal.
      if (nameOnly && process.env.FAKE !== 'not-saved') writeFileSync(rollout, '');
      reply({});
    } else if (method === 'thread/read') {
      assert.deepEqual(params, { threadId: id, includeTurns: false });
      writeFileSync(join(lane, 'name-read'), named);
      reply({ thread: {
        id: process.env.FAKE === 'wrong-named-thread' ? 'different-id' : id,
        name: process.env.FAKE === 'wrong-name' ? named.toUpperCase() : named,
      } });
    } else if (method === 'thread/goal/set') {
      assert.ok(!nameOnly);
      assert.equal(params.threadId, id);
      assert.equal(params.status, 'active');
      assert.equal(params.origin, 'automatic');
      if (process.env.FAKE === 'rpc-error') {
        write({ id: requestId, error: { message: 'goals feature is disabled' } });
        return;
      }
      stored = { threadId: id, status: params.status, objective: params.objective };
      if (process.env.FAKE !== 'not-saved') event({ type: 'thread_goal_updated', goal: stored });
      if (process.env.FAKE === 'bootstrap-turn') event({ type: 'task_started', turn_attribution: { turn_trigger: 'goal' } });
      reply({ goal: stored });
    } else if (method === 'thread/goal/get') {
      assert.deepEqual(params, { threadId: id });
      reply({ goal: process.env.FAKE === 'mismatch' ? { ...stored, objective: 'wrong' } : stored });
    } else assert.fail(method);
  });
}
`;

async function withFake(t, scenario) {
  const f = await fixture(t);
  await executable(join(f.root, 'codex'), fakeCodex);
  const proc = spawn(process.execPath, [helper, f.startup, f.brief, goal, name], {
    cwd: f.root,
    env: { ...f.env, PATH: `${f.root}:${f.env.PATH}`, FAKE: scenario },
    stdio: ['ignore', 'ignore', 'pipe'],
    detached: true,
  });
  const exit = once(proc, 'close');
  let stderr = '';
  proc.stderr.setEncoding('utf8').on('data', chunk => { stderr += chunk; });
  t.after(() => {
    if (proc.exitCode === null && proc.signalCode === null) process.kill(-proc.pid, 'SIGTERM');
  });
  return { ...f, exit, warnings: () => stderr };
}

async function executable(path, source) {
  await writeFile(path, source);
  await chmod(path, 0o700);
}

test('acknowledges only a native goal turn in the exact saved thread', async t => {
  const { root, startup, brief, exit, warnings } = await withFake(t, 'ok');
  assert.equal(await waitForFile(join(root, 'resumed')), id);
  assert.equal(await readFile(join(root, 'name-read'), 'utf8'), name);
  assert.equal(warnings(), '');
  const event = JSON.parse(await readFile(join(root, 'rollout.jsonl'), 'utf8')).payload;
  assert.equal(event.goal.objective, `${goal}\n\nBefore working, read and follow the lane protocol and brief at ${JSON.stringify(brief)}.`);
  await assert.rejects(readFile(join(startup, 'result')), { code: 'ENOENT' });
  await writeFile(join(root, 'finish'), '');
  assert.equal(await waitForFile(join(startup, 'result')), `ready ${id}`);
  await rm(startup, { recursive: true });
  await writeFile(join(root, 'leave'), '');
  assert.deepEqual(await exit, [0, null]);
});

test('an ordinary TUI turn cannot acknowledge native goal startup', async t => {
  const { root, startup, exit } = await withFake(t, 'wrong-turn');
  await writeFile(join(root, 'finish'), '');
  assert.equal(await waitForFile(join(root, 'turn')), 'user');
  await delay(350);
  await assert.rejects(readFile(join(startup, 'result')), { code: 'ENOENT' });
  await writeFile(join(root, 'leave'), '');
  assert.match(await waitForFile(join(startup, 'result')), /^error Codex TUI .* exited with 0/);
  assert.deepEqual(await exit, [1, null]);
});

for (const [scenario, message] of [
  ['name-error', /thread\/name\/set: name could not be set/],
  ['wrong-name', /thread\/read did not return the matching name/],
  ['wrong-named-thread', /thread\/read did not return the matching name/],
]) {
  test(`a lane warns and still pursues its goal when naming fails: ${scenario}`, async t => {
    const { root, startup, exit, warnings } = await withFake(t, scenario);
    assert.equal(await waitForFile(join(root, 'resumed')), id);
    await writeFile(join(root, 'finish'), '');
    assert.equal(await waitForFile(join(startup, 'result')), `ready ${id}`);
    assert.match(warnings(), /could not name thread .*, continuing: /);
    assert.match(warnings(), message);
    await rm(startup, { recursive: true });
    await writeFile(join(root, 'leave'), '');
    assert.deepEqual(await exit, [0, null]);
  });
}

async function nameOnly(t, scenario, model) {
  const { root, env } = await fixture(t);
  await executable(join(root, 'codex'), fakeCodex);
  const launch = run(process.execPath, [helper, '--name-only', name, ...(model ? [model] : [])], {
    cwd: root, timeout: 10_000,
    env: { ...env, PATH: `${root}:${env.PATH}`, FAKE: scenario, FAKE_NAME_ONLY: '1', FAKE_MODEL: model ?? '' },
  });
  return { root, launch };
}

for (const model of [undefined, 'gpt-6.1-terra']) {
  test(`name-only mode saves a named thread, prints its ID and starts no TUI: ${model ?? 'no model'}`, async t => {
    const { root, launch } = await nameOnly(t, 'ok', model);
    assert.deepEqual(await launch, { stdout: `${id}\n`, stderr: '' });
    assert.equal(await readFile(join(root, 'name-read'), 'utf8'), name);
    await assert.rejects(readFile(join(root, 'resumed')), { code: 'ENOENT' });
  });
}

for (const [scenario, message] of [
  ['name-error', /thread\/name\/set: name could not be set/],
  ['wrong-name', /thread\/read did not return the matching name/],
  ['wrong-named-thread', /thread\/read did not return the matching name/],
  ['not-saved', /Codex did not save the rollout/],
  ['bad-exit', /Codex app-server exited with 3/],
]) {
  test(`name-only mode fails without printing a thread: ${scenario}`, async t => {
    const { root, launch } = await nameOnly(t, scenario);
    await assert.rejects(launch, error => {
      assert.equal(error.code, 1);
      assert.equal(error.stdout, '');
      assert.match(error.stderr, message);
      return true;
    });
    await assert.rejects(readFile(join(root, 'resumed')), { code: 'ENOENT' });
  });
}

for (const [scenario, message] of [
  ['rpc-error', /thread\/goal\/set: goals feature is disabled/],
  ['mismatch', /thread\/goal\/get did not return the matching active goal/],
  ['not-saved', /Codex did not save the rollout/],
  ['bootstrap-turn', /unexpectedly started work before the TUI resumed/],
  ['resume-exited', /Codex TUI .* exited with 17/],
]) {
  test(`reports a startup error: ${scenario}`, async t => {
    const { root, startup, exit } = await withFake(t, scenario);
    const result = await waitForFile(join(startup, 'result'));
    assert.match(result, /^error /);
    assert.match(result, message);
    assert.deepEqual(await exit, [1, null]);
    if (scenario !== 'resume-exited') await assert.rejects(readFile(join(root, 'resumed')), { code: 'ENOENT' });
  });
}

test('spawn.sh uses the built-in native launcher and waits for each lane to pursue its goal', async t => {
  const { root, brief, env } = await fixture(t);
  await executable(join(root, 'codex'), fakeCodex);
  await executable(join(root, 'setsid'), '#!/bin/sh\nexit 0\n'); // Skip the unrelated lane watcher.
  await executable(join(root, 'herdr'), `#!/usr/bin/env node
const assert = require('node:assert/strict');
const { spawn } = require('node:child_process');
const { readFileSync, writeFileSync } = require('node:fs');
const { join } = require('node:path');
const [noun, verb, arg, line] = process.argv.slice(2);
const cwd = join(process.env.FAKE_HERDR_ROOT, arg?.slice(2) ?? '');
switch (noun + ' ' + verb) {
  case 'agent get':
    if (!arg?.startsWith('p-')) process.exit(1);
    // Claim Codex is already present, even before its goal turn is ready.
    console.log(JSON.stringify({ result: { agent: { pane_id: arg, agent: 'codex', agent_status: 'working', agent_session: { value: 'codex-session' } } } }));
    break;
  case 'tab create':
    assert.ok(process.argv.includes('--no-focus'));
    console.log(JSON.stringify({ result: { root_pane: { pane_id: 'p-' + process.argv[process.argv.indexOf('--label') + 1] } } }));
    break;
  case 'pane report-metadata':
    if (process.argv.includes('goal_startup=ready')) {
      assert.ok(process.argv.includes('goal_mode=native'));
      assert.equal(readFileSync(join(cwd, 'turn'), 'utf8'), 'goal');
    }
    break;
  case 'pane run': {
    const child = spawn('bash', ['-c', line], {
      cwd, env: { ...process.env, HERDR_PANE_ID: 'child' }, detached: true, stdio: 'ignore',
    });
    writeFileSync(join(cwd, 'pane-pid'), String(child.pid));
    child.unref();
    break;
  }
  case 'agent rename':
    assert.equal(readFileSync(join(cwd, 'turn'), 'utf8'), 'goal');
    break;
  default:
    assert.fail(noun + ' ' + verb);
}
`);
  for (const [index, name] of ['lane-one', 'lane-two'].entries()) {
    const lane = join(root, name);
    const threadId = id.slice(0, -1) + index;
    const objective = `${goal}\nLane: ${name}`;
    await mkdir(lane);
    try {
      const model = index === 0 ? 'gpt-6.1-terra' : '';
      const launching = run('bash', [spawnScript, '--tab', lane, '--lane', 'unit',
        '--goal', objective, ...(index === 0 ? [] : ['--model', 'default']), 'codex', name, brief], {
        cwd: root, timeout: 10_000,
        env: {
          ...env, PATH: `${root}:${env.PATH}`, HERDR_ENV: '1', HERDR_PANE_ID: 'parent',
          XDG_STATE_HOME: join(root, 'state'), HERDR_SPAWN_CONFIG: join(root, 'no-override'),
          FAKE_HERDR_ROOT: root, FAKE_THREAD_ID: threadId, FAKE_THREAD_NAME: name, FAKE: 'ok', FAKE_MODEL: model,
        },
      });
      const [{ stdout }] = await Promise.all([launching, (async () => {
        assert.equal(await waitForFile(join(lane, 'resumed')), threadId);
        await delay(600); // Give spawn a full poll while the fake TUI has no goal turn.
        await writeFile(join(lane, 'finish'), '');
      })()]);
      assert.equal(stdout.trim(), `p-${name} ${name} codex working`);
      assert.equal(await readFile(join(lane, 'name-read'), 'utf8'), name);
      const goalEvent = JSON.parse((await readFile(join(lane, 'rollout.jsonl'), 'utf8')).split('\n')[0]).payload;
      assert.equal(goalEvent.goal.threadId, threadId);
      assert.ok(goalEvent.goal.objective.startsWith(`${objective}\n\n`));
      assert.match(goalEvent.goal.objective, /\/goals\/g\.[a-z0-9]{12}\/brief\.md"\.$/i);
    } finally {
      const pid = Number(await readFile(join(lane, 'pane-pid'), 'utf8').catch(() => ''));
      if (pid > 1) {
        try { process.kill(-pid, 'SIGTERM'); } catch (error) {
          if (error.code !== 'ESRCH') throw error;
        }
      }
    }
  }
});

const real = process.env.TEST_REAL_CODEX === '1';
const syntheticKey = 'codex-lane-test-key';

async function realCodexEnv(root) {
  const dirs = Object.fromEntries(
    ['HOME', 'CODEX_HOME', 'XDG_CONFIG_HOME', 'XDG_CACHE_HOME', 'XDG_DATA_HOME', 'XDG_STATE_HOME', 'XDG_RUNTIME_DIR']
      .map(name => [name, join(root, name)]),
  );
  await Promise.all(Object.values(dirs).map(path => mkdir(path, { mode: 0o700 })));
  return {
    ...dirs,
    PATH: process.env.PATH,
    SHELL: '/bin/sh',
    TERM: 'xterm-256color',
    CODEX_LANE_TEST_API_KEY: syntheticKey,
    HERDR_PANE_ID: 'child',
    LANE_MODE: 'unit',
    LANE_COORDINATOR: 'parent',
  };
}

function localProvider(baseUrl) {
  return `model = "gpt-5.4"
model_provider = "local_test"
[model_providers.local_test]
name = "Local test"
base_url = "${baseUrl}"
wire_api = "responses"
env_key = "CODEX_LANE_TEST_API_KEY"
supports_websockets = false
`;
}

test('Codex 0.171.0 resumes in a real PTY and its first request pursues the saved goal', { skip: !real, timeout: 45_000 }, async t => {
  const { root, startup, brief } = await fixture(t);
  const env = await realCodexEnv(root);
  assert.equal(spawnSync('codex', ['--version'], { cwd: root, env, encoding: 'utf8' }).stdout.trim(), 'codex-cli 0.171.0');
  let modelRequest;
  let authorization;
  const server = createServer(async (req, res) => {
    if (req.method === 'POST' && req.url.endsWith('/responses')) {
      const body = [];
      for await (const chunk of req) body.push(chunk);
      modelRequest ??= JSON.parse(Buffer.concat(body).toString());
      authorization ??= req.headers.authorization;
      res.writeHead(200, { 'Content-Type': 'text/event-stream' });
      res.write(': hold this local response open\n\n');
    } else {
      res.writeHead(200, { 'Content-Type': 'application/json' }).end('{"data":[]}');
    }
  });
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  await writeFile(join(env.CODEX_HOME, 'config.toml'), `${localProvider(`http://127.0.0.1:${server.address().port}/v1`)}[features]
goals = true
plugins = false
shell_snapshot = false
[projects.${JSON.stringify(root)}]
trust_level = "trusted"
`);
  const shellQuote = arg => `'${arg.replaceAll("'", "'\\''")}'`;
  const requestedModel = 'gpt-5.4-mini';
  const command = [process.execPath, helper, startup, brief, goal, name, requestedModel].map(shellQuote).join(' ');
  const pidFile = join(root, 'pty-pid');
  const launch = `stty rows 40 cols 120; echo "$$" > ${shellQuote(pidFile)}; exec ${command}`;
  const pty = spawn('script', ['-q', '-e', '-c', launch, '/dev/null'], {
    cwd: root,
    env,
    stdio: ['pipe', 'pipe', 'ignore'],
  });
  const exit = once(pty, 'close');
  let output = '';
  pty.stdout.setEncoding('utf8').on('data', chunk => { output = (output + chunk).slice(-4000); });
  try {
    assert.match(await waitForFile(join(startup, 'result'), 30_000), /^ready [\da-f-]{36}$/);
    for (let attempt = 0; attempt < 100 && !modelRequest; attempt++) await delay(50);
    assert.ok(modelRequest, 'the TUI did not make a Responses request');
    assert.equal(authorization, `Bearer ${syntheticKey}`);
    assert.equal(modelRequest.model, requestedModel);
    const text = modelRequest.input.flatMap(item => item.content ?? []).map(content => content.text).join('\n');
    assert.match(text, /Continue working toward the active thread goal/);
    const input = JSON.stringify(modelRequest.input);
    assert.ok(input.includes(JSON.stringify(goal).slice(1, -1)), 'request is missing the objective');
    assert.match(input, /Before working, read and follow the lane protocol and brief/);
    assert.ok(input.includes(join(root, 'brief ')), 'request is missing the absolute brief path');
  } catch (error) {
    t.diagnostic(output.replace(/\x1b\[[0-?]*[ -/]*[@-~]/g, ''));
    throw error;
  } finally {
    if (pty.exitCode === null && pty.signalCode === null) {
      // util-linux script runs the command in a separate session. Kill the test
      // session as a group so the fake endpoint can never leave Codex behind.
      const group = Number(await readFile(pidFile, 'utf8').catch(() => ''));
      if (Number.isSafeInteger(group) && group > 1) {
        try {
          process.kill(-group, 'SIGKILL');
        } catch (error) {
          if (error.code !== 'ESRCH') throw error;
        }
      } else {
        pty.kill();
      }
    }
    server.close();
    server.closeAllConnections();
    await exit;
  }
});

test('Codex 0.171.0 saves a named thread in name-only mode', { skip: !real, timeout: 35_000 }, async t => {
  const { root } = await fixture(t);
  const env = await realCodexEnv(root);
  await writeFile(join(env.CODEX_HOME, 'config.toml'),
    `${localProvider('http://127.0.0.1:0/v1')}[features]\nplugins = false\n`);
  const { stdout } = await run(process.execPath, [helper, '--name-only', name], { cwd: root, env, timeout: 30_000 });
  assert.match(stdout, /^[\da-f-]{36}\n$/);
  const index = (await readFile(join(env.CODEX_HOME, 'session_index.jsonl'), 'utf8')).trimEnd()
    .split('\n').map(line => JSON.parse(line));
  assert.ok(index.some(entry => entry.id === stdout.trim() && entry.thread_name === name), 'the name was not saved');
});

test('Codex 0.171.0 refuses lane startup when the user disables goals', { skip: !real, timeout: 35_000 }, async t => {
  const { root, startup, brief } = await fixture(t);
  const env = await realCodexEnv(root);
  await writeFile(join(env.CODEX_HOME, 'config.toml'),
    `${localProvider('http://127.0.0.1:0/v1')}[features]\ngoals = false\nplugins = false\n`);
  const proc = spawn(process.execPath, [helper, startup, brief, goal, name], {
    cwd: root, env, detached: true, stdio: 'ignore',
  });
  const exit = once(proc, 'close');
  t.after(() => {
    if (proc.exitCode === null && proc.signalCode === null) process.kill(-proc.pid, 'SIGTERM');
  });
  assert.match(await waitForFile(join(startup, 'result'), 30_000), /^error thread\/goal\/set: goals feature is disabled$/);
  assert.deepEqual(await exit, [1, null]);
});
