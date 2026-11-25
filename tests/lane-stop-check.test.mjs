import assert from 'node:assert/strict';
import { execFile } from 'node:child_process';
import { mkdir, mkdtemp, rm, symlink, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { test } from 'node:test';
import { promisify } from 'node:util';

const run = promisify(execFile);
const script = fileURLToPath(new URL('../skills/herdr-spawn/scripts/lane-stop-check.sh', import.meta.url));

const cli = `#!/usr/bin/env node
const assert = require('node:assert/strict');
const fs = require('node:fs');
const [a, b, c] = process.argv.slice(2);
const db = JSON.parse(fs.readFileSync(process.env.STOP_MOCK, 'utf8'));
const out = x => console.log(JSON.stringify(x));
if (a === 'agent' && b === 'get') {
  assert.equal(c, process.env.STOP_PANE);
  out({ result: { agent: { tokens: db.pane } } });
} else if (a === 'agent' && b === 'list') {
  out({ result: { agents: db.agents } });
} else {
  process.exit(1);
}
`;

async function fixture(t) {
  const root = await mkdtemp(join(tmpdir(), 'herdr-lane-stop-check-'));
  t.after(() => rm(root, { recursive: true, force: true }));
  const db = join(root, 'db');
  const state = join(root, 'state');
  await mkdir(state);
  await writeFile(db, JSON.stringify({ pane: {}, agents: [] }));
  await writeFile(join(root, 'cli'), cli, { mode: 0o700 });
  await symlink('cli', join(root, 'herdr'));
  const env = {
    ...process.env, PATH: `${root}:${process.env.PATH}`, STOP_MOCK: db, STOP_PANE: 'pane-1',
    HERDR_ENV: '1', HERDR_PANE_ID: 'pane-1', HC_TERMINAL_ID: '', XDG_STATE_HOME: state,
  };
  delete env.LANE_MODE;
  delete env.LANE_PENDING;
  delete env.LANE_COORDINATOR;
  const runCheck = extra => run('bash', [script], { cwd: root, env: { ...env, ...extra }, timeout: 10_000 });
  const setDb = async value => writeFile(db, JSON.stringify(value));
  return { root, state, setDb, runCheck };
}

test('lane-stop-check treats a TUI pane with a lane_mode token as a lane', async t => {
  const f = await fixture(t);
  await f.setDb({ pane: { lane_of: 'coord', lane_mode: 'unit', lane_state: 'working', lane_report: 'r1' }, agents: [] });
  const { stdout } = await f.runCheck();
  assert.match(stdout, /^You are a lane and have not reported yet\./);
});

test('lane-stop-check stays silent without a lane token and with no lanes waiting', async t => {
  const f = await fixture(t);
  await f.setDb({ pane: {}, agents: [] });
  const { stdout } = await f.runCheck();
  assert.equal(stdout, '');
});

test('lane-stop-check uses LANE_MODE when the pane has no lane_mode token', async t => {
  const f = await fixture(t);
  await f.setDb({ pane: { lane_state: 'working', lane_report: 'r1' }, agents: [] });
  const { stdout } = await f.runCheck({ LANE_MODE: 'unit' });
  assert.match(stdout, /^You are a lane and have not reported yet\./);
});

test('lane-stop-check ignores a TUI pane without lane_of or with an unknown lane_mode', async t => {
  const f = await fixture(t);
  await f.setDb({ pane: { lane_of: 'coord', lane_mode: 'x', lane_state: 'working' }, agents: [] });
  assert.equal((await f.runCheck()).stdout, '');
  await f.setDb({ pane: { lane_mode: 'unit', lane_state: 'working' }, agents: [] });
  assert.equal((await f.runCheck()).stdout, '');
});
