import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { chmod, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { test } from 'node:test';

const watcher = fileURLToPath(new URL('../skills/herdr-spawn/scripts/lanes-watch.sh', import.meta.url));

// A herdr that serves a fixed lane list and an idle coordinator, and records the prompt it is given.
const herdr = `#!/usr/bin/env node
const fs = require('node:fs');
const [a, b] = process.argv.slice(2);
switch (a + ' ' + b) {
  case 'pane get': break;
  case 'agent get': console.log(JSON.stringify({ result: { agent: { agent_status: 'idle' } } })); break;
  case 'agent list': process.stdout.write(fs.readFileSync(process.env.WATCH_LANES, 'utf8')); break;
  case 'agent prompt': fs.writeFileSync(process.env.WATCH_PROMPT, process.argv[5]); break;
}
`;

const lane = (name, state, report) => ({
  name, pane_id: name, agent: 'claude', agent_status: 'idle', completion_seq: 1,
  tokens: { lane_of: 'coord', lane_mode: 'unit', lane_state: state, lane_note: `${name} note`, lane_report: report },
});

test('the watcher notice names the stored copy, or reads the pane for an older lane.sh', async t => {
  const root = await mkdtemp(join(tmpdir(), 'herdr-lane-report-'));
  t.after(() => rm(root, { recursive: true, force: true }));
  const prompt = join(root, 'prompt');
  await writeFile(join(root, 'herdr'), herdr);
  await chmod(join(root, 'herdr'), 0o700);
  await writeFile(join(root, 'lanes'), JSON.stringify({ result: { agents: [
    lane('newdone', 'done', '/tmp/reports/1.md'),
    lane('newask', 'escalated', '/tmp/reports/2.md'),
    lane('olddone', 'done', '1700000000-1-2'),
    lane('oldask', 'escalated', '1700000000-3-4'),
  ] } }));
  const child = spawn('bash', [watcher, 'coord'], {
    stdio: 'ignore',
    env: {
      ...process.env, PATH: `${root}:${process.env.PATH}`, XDG_STATE_HOME: join(root, 'state'),
      HERDR_SPAWN_WATCH_INTERVAL: '1', WATCH_LANES: join(root, 'lanes'), WATCH_PROMPT: prompt,
    },
  });
  t.after(() => child.kill());
  let text;
  for (let i = 0; i < 100 && text === undefined; i++) {
    text = await readFile(prompt, 'utf8').catch(() => undefined);
    if (text === undefined) await new Promise(r => setTimeout(r, 100));
  }
  assert.ok(text, 'the watcher posted no prompt');
  assert.match(text, /\[lane newdone\] done: newdone note\. Read its report: \/tmp\/reports\/1\.md/);
  assert.match(text, /\[lane newask\] escalation: newask note\. Read the full question: \/tmp\/reports\/2\.md; answer with:/);
  assert.match(text, /\[lane olddone\] done: olddone note\. Read its report: herdr agent read olddone /);
  assert.match(text, /\[lane oldask\] escalation: oldask note\. Read the full question: herdr agent read oldask /);
});
