import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { chmod, mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { test } from 'node:test';
import { setTimeout as delay } from 'node:timers/promises';

const watch = fileURLToPath(new URL('../skills/herdr-spawn/scripts/lanes-watch.sh', import.meta.url));

const fakeHerdr = `#!/usr/bin/env node
const { readFileSync, writeFileSync } = require('node:fs');
const [noun, verb] = process.argv.slice(2);
switch (noun + ' ' + verb) {
  case 'pane get':
    break;
  case 'agent get':
    console.log(JSON.stringify({ result: { agent: { agent_status: 'idle' } } }));
    break;
  case 'agent list':
    process.stdout.write(readFileSync(process.env.FAKE_AGENT_LIST, 'utf8'));
    break;
  case 'agent prompt':
    writeFileSync(process.env.FAKE_PROMPT_FILE, process.argv[5]);
    break;
  default:
    process.exit(1);
}
`;

const previous = [
  { name: 'kept', pane_id: 'w1:p2', agent: 'claude', agent_status: 'working', completion_seq: 0, mode: 'unit', state: 'working', note: null, report: null },
  { name: 'gone', pane_id: 'w1:p3', agent: 'claude', agent_status: 'working', completion_seq: 0, mode: 'unit', state: 'working', note: null, report: null },
];
// Case a: a resumed agent on w1:p2 without name or tokens, nothing on w1:p3. Case b: no agent on either pane.
const resumed = { result: { agents: [
  { pane_id: 'w1:p2', agent: 'claude', agent_status: 'idle', tokens: {} },
] } };
const none = { result: { agents: [{ pane_id: 'w1:p1', agent: 'claude', agent_status: 'idle', tokens: {} }] } };

async function waitForFile(path, timeout = 10_000) {
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

async function fixture(t, agents) {
  const root = await mkdtemp(join(tmpdir(), 'lanes-watch-test-'));
  t.after(() => rm(root, { recursive: true, force: true }));
  const herdr = join(root, 'herdr');
  await writeFile(herdr, fakeHerdr);
  await chmod(herdr, 0o700);
  const stateRoot = join(root, 'state');
  const state = join(stateRoot, 'herdr-spawn');
  await mkdir(state, { recursive: true });
  await writeFile(join(state, 'seen-coord.json'), JSON.stringify(previous));
  const agentList = join(root, 'agents.json');
  const prompt = join(root, 'prompt.txt');
  await writeFile(agentList, JSON.stringify(agents));
  const env = {
    ...process.env,
    PATH: `${root}:${process.env.PATH}`,
    XDG_STATE_HOME: stateRoot,
    HERDR_SPAWN_WATCH_INTERVAL: '1',
    FAKE_AGENT_LIST: agentList,
    FAKE_PROMPT_FILE: prompt,
  };
  const proc = spawn('bash', [watch, 'coord'], { cwd: root, env, stdio: 'ignore' });
  t.after(() => { if (proc.exitCode === null && proc.signalCode === null) proc.kill(); });
  return { prompt };
}

test('a lane whose pane still runs an agent is lost, a lane with no agent exited', async t => {
  const { prompt } = await fixture(t, resumed);
  const text = await waitForFile(prompt);
  assert.match(text, /\[lane kept\] lost its name and lane tokens, but pane w1:p2 still runs an agent/);
  assert.match(text, /lane\.sh restore/);
  assert.match(text, /\[lane gone\] exited/);
  assert.doesNotMatch(text, /\[lane gone\] lost/);
});

test('lanes whose agents exited are exited, not lost', async t => {
  const { prompt } = await fixture(t, none);
  const text = await waitForFile(prompt);
  assert.match(text, /\[lane kept\] exited/);
  assert.match(text, /\[lane gone\] exited/);
  assert.doesNotMatch(text, /lost its name/);
});
