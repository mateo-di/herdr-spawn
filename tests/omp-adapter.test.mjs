import assert from 'node:assert/strict';
import { mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';

const variable = 'HERDR_SPAWN_SESSION_NAME';
const skip = !process.features.typescript && 'this Node cannot import TypeScript';

// Loads the extension into a fake pi, with the launch variable set to `launchName` for this test only.
async function load(t, { launchName = 'child', reject } = {}) {
  const before = process.env[variable];
  t.after(() => {
    if (before === undefined) delete process.env[variable];
    else process.env[variable] = before;
  });
  if (launchName === null) delete process.env[variable];
  else process.env[variable] = launchName;

  const { default: extension } = await import('../adapters/omp/herdr-spawn.ts');
  const handlers = new Map();
  const names = [];
  const notices = [];
  extension({
    registerMessageRenderer: () => {},
    on: (event, handler) => handlers.set(event, handler),
    setSessionName: async name => {
      if (reject) throw new Error(reject);
      names.push(name);
    },
  });
  const start = ({ kind = 'main', file } = {}) => handlers.get('session_start')({}, {
    agent: { kind },
    sessionManager: { getSessionFile: () => file },
    ui: { notify: (...notice) => notices.push(notice) },
  });
  return { start, names, notices };
}

async function scratch(t) {
  const dir = await mkdtemp(join(tmpdir(), 'herdr-omp-'));
  t.after(() => rm(dir, { recursive: true, force: true }));
  return dir;
}

test('names a new main session once and consumes the variable', { skip }, async t => {
  const session = await load(t);
  // A session file that is not written yet belongs to a new session.
  await session.start({ file: join(await scratch(t), 'new.jsonl') });
  assert.equal(process.env[variable], undefined);
  await session.start();
  assert.deepEqual(session.names, ['child']);
  assert.deepEqual(session.notices, []);
});

test('skips a subagent and leaves the name for the main session', { skip }, async t => {
  const session = await load(t);
  await session.start({ kind: 'sub' });
  assert.deepEqual(session.names, []);
  assert.equal(process.env[variable], 'child');
  await session.start();
  assert.deepEqual(session.names, ['child']);
});

test('does nothing without the variable', { skip }, async t => {
  const session = await load(t, { launchName: null });
  await session.start();
  assert.deepEqual(session.names, []);
  assert.deepEqual(session.notices, []);
});

test('keeps the name of a saved session', { skip }, async t => {
  const file = join(await scratch(t), 'saved.jsonl');
  await writeFile(file, '');
  const session = await load(t);
  await session.start({ file });
  assert.deepEqual(session.names, []);
  assert.deepEqual(session.notices, []);
  assert.equal(process.env[variable], undefined);
});

test('warns when naming fails', { skip }, async t => {
  const session = await load(t, { reject: 'name refused' });
  await session.start();
  assert.equal(session.notices.length, 1);
  assert.match(session.notices[0][0], /could not name this session child: .*name refused/);
  assert.equal(session.notices[0][1], 'warning');
});
