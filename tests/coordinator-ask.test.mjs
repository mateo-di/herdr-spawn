import assert from 'node:assert/strict';
import { execFile } from 'node:child_process';
import { mkdtemp, readFile, rm, symlink, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { test } from 'node:test';

const hook = fileURLToPath(new URL('../hooks/coordinator-ask.sh', import.meta.url));

const cli = `#!/usr/bin/env node
const fs = require('node:fs');
const [a, b] = process.argv.slice(2);
const db = JSON.parse(fs.readFileSync(process.env.ASK_MOCK, 'utf8'));
const out = x => console.log(JSON.stringify(x));
if (a === 'agent' && b === 'list') {
  out({ result: { agents: db.agents || [] } });
} else if (a === 'ls') {
  if (db.failLs) process.exit(1);
  out({ terminals: db.terminals || [] });
} else if (a === 'get') {
  fs.appendFileSync(process.env.ASK_GETS, b + '\\n');
  if ((db.failGet || []).includes(b)) process.exit(1);
  const t = (db.terminals || []).find(t => t.address === b);
  if (!t) process.exit(1);
  out({ name: t.name, labels: t.labels || {} });
} else {
  process.exit(1);
}
`;

async function fixture(t) {
  const root = await mkdtemp(join(tmpdir(), 'herdr-coordinator-ask-'));
  t.after(() => rm(root, { recursive: true, force: true }));
  const db = join(root, 'db');
  const gets = join(root, 'gets');
  await writeFile(db, JSON.stringify({ agents: [], terminals: [] }));
  await writeFile(gets, '');
  await writeFile(join(root, 'cli'), cli, { mode: 0o700 });
  await symlink('cli', join(root, 'herdr'));
  await symlink('cli', join(root, 'hc'));
  const env = {
    ...process.env, PATH: `${root}:${process.env.PATH}`, ASK_MOCK: db, ASK_GETS: gets,
    HERDR_ENV: '1', HERDR_PANE_ID: 'coord', HC_TERMINAL_ID: '',
  };
  delete env.LANE_MODE;
  delete env.LANE_PENDING;
  delete env.LANE_COORDINATOR;
  const runHook = (extra = {}, input = '{}') => new Promise(resolve => {
    const child = execFile('bash', [hook], { cwd: root, env: { ...env, ...extra }, timeout: 10_000 },
      (error, stdout) => resolve({ stdout, code: error ? error.code : 0, error }));
    child.stdin.end(input);
  });
  return {
    setDb: value => writeFile(db, JSON.stringify(value)),
    gets: async () => (await readFile(gets, 'utf8')).trim().split('\n').filter(Boolean),
    runHook,
  };
}

async function expectDeny(f, names, extra, input) {
  const { stdout, code, error } = await f.runHook(extra, input);
  assert.equal(code, 0, error?.message);
  const lines = stdout.trim().split('\n');
  assert.equal(lines.length, 1, stdout);
  const output = JSON.parse(lines[0]).hookSpecificOutput;
  assert.equal(output.hookEventName, 'PreToolUse');
  assert.equal(output.permissionDecision, 'deny');
  const reason = output.permissionDecisionReason;
  assert.ok(reason.startsWith(`Lanes still active: ${names.join(', ')}. `), reason);
  return reason;
}

async function expectSilent(f, extra, input) {
  const { stdout, code, error } = await f.runHook(extra, input);
  assert.equal(code, 0, error?.message);
  assert.equal(stdout, '');
}

test('coordinator-ask denies AskUserQuestion for a TUI coordinator with a working lane', async t => {
  const f = await fixture(t);
  await f.setDb({ agents: [{ name: 'w1', tokens: { lane_of: 'coord', lane_state: 'working' } }] });
  const question = JSON.stringify({ tool_name: 'AskUserQuestion', tool_input: { questions: [
    { question: 'Proceed?', header: 'Choice', options: [{ label: 'Yes' }, { label: 'No' }] },
  ] } });
  const reason = await expectDeny(f, ['w1'], {}, question);
  assert.match(reason, /plain text/);
});

test('coordinator-ask names an escalated TUI lane but not a done one', async t => {
  const f = await fixture(t);
  await f.setDb({ agents: [
    { name: 'escalated-lane', tokens: { lane_of: 'coord', lane_state: 'escalated' } },
    { name: 'done-lane', tokens: { lane_of: 'coord', lane_state: 'done' } },
  ] });
  const reason = await expectDeny(f, ['escalated-lane']);
  assert.doesNotMatch(reason, /done-lane/);
});

test('coordinator-ask stays silent when TUI lanes are done or belong to another pane', async t => {
  const f = await fixture(t);
  await f.setDb({ agents: [{ name: 'done-lane', tokens: { lane_of: 'coord', lane_state: 'done' } }] });
  await expectSilent(f);
  await f.setDb({ agents: [
    { name: 'other-working', tokens: { lane_of: 'other-pane', lane_state: 'working' } },
    { name: 'other-escalated', tokens: { lane_of: 'other-pane', lane_state: 'escalated' } },
  ] });
  await expectSilent(f);
});

test('coordinator-ask denies for an app coordinator with a working child lane', async t => {
  const f = await fixture(t);
  await f.setDb({ terminals: [
    { address: 'coord', name: 'coord' },
    { address: 'w1:p2', parent: 'coord', name: 'app-working', labels: { lane_of: 'coord', lane_state: 'working' } },
    { address: 'w1:p3', parent: 'coord', name: 'app-done', labels: { lane_of: 'coord', lane_state: 'done' } },
    { address: 'w2:p1', parent: 'other-coord', name: 'foreign-lane', labels: { lane_of: 'coord', lane_state: 'working' } },
  ] });
  const reason = await expectDeny(f, ['app-working'], { HERDR_ENV: '0', HC_TERMINAL_ID: 'coord' });
  assert.doesNotMatch(reason, /app-done|foreign-lane/);
  assert.deepEqual(await f.gets(), ['w1:p2', 'w1:p3']);
});

test('coordinator-ask still denies when a later app child fails hc get', async t => {
  const f = await fixture(t);
  await f.setDb({ failGet: ['w1:p3'], terminals: [
    { address: 'coord', name: 'coord' },
    { address: 'w1:p2', parent: 'coord', name: 'app-working', labels: { lane_of: 'coord', lane_state: 'working' } },
    { address: 'w1:p3', parent: 'coord', name: 'app-ended', labels: { lane_of: 'coord', lane_state: 'working' } },
  ] });
  const reason = await expectDeny(f, ['app-working'], { HERDR_ENV: '0', HC_TERMINAL_ID: 'coord' });
  assert.doesNotMatch(reason, /app-ended/);
  assert.deepEqual(await f.gets(), ['w1:p2', 'w1:p3']);
});

test('coordinator-ask stays silent for an app coordinator with no children', async t => {
  const f = await fixture(t);
  await f.setDb({ terminals: [
    { address: 'coord', name: 'coord' },
    { address: 'w2:p1', parent: 'other-coord', name: 'foreign-lane', labels: { lane_of: 'coord', lane_state: 'working' } },
  ] });
  await expectSilent(f, { HERDR_ENV: '0', HC_TERMINAL_ID: 'coord' });
  assert.deepEqual(await f.gets(), []);
});

test('coordinator-ask stays silent outside Herdr', async t => {
  const f = await fixture(t);
  await f.setDb({ agents: [{ name: 'w1', tokens: { lane_of: 'coord', lane_state: 'working' } }] });
  await expectSilent(f, { HERDR_ENV: '', HC_TERMINAL_ID: '' });
});

test('coordinator-ask stays silent when hc fails', async t => {
  const f = await fixture(t);
  await f.setDb({ failLs: true, terminals: [
    { address: 'w1:p2', parent: 'coord', name: 'app-working', labels: { lane_of: 'coord', lane_state: 'working' } },
  ] });
  await expectSilent(f, { HERDR_ENV: '0', HC_TERMINAL_ID: 'coord' });
});
