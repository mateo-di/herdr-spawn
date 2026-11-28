import assert from 'node:assert/strict';
import { test } from 'node:test';
import { register } from '../hooks/coordinator-identity.mjs';

const id = '11111111-2222-4333-8444-abcdefabcdef';
const other = '99999999-8888-4777-8666-555555555555';
const chunk = 4 * 1024 * 1024;
const transcriptPath = '/transcripts/session.jsonl';
const requestPath = `/state/herdr-spawn/identity/${id}.json`;
const request = { sessionId: id, name: 'coord-repo', color: 'cyan', done: false };
const both = [{ command: 'rename', args: 'coord-repo' }, { command: 'color', args: 'cyan' }];

const row = value => `${JSON.stringify(value)}\n`;
const message = text => row({ type: 'user', sessionId: id, message: text });
const title = row({ type: 'custom-title', customTitle: 'mine', sessionId: id });
const color = row({ type: 'agent-color', agentColor: 'red', sessionId: id });
// The row each command leaves in the transcript.
const recordOf = {
  rename: customTitle => row({ type: 'custom-title', customTitle, sessionId: id }),
  color: agentColor => row({ type: 'agent-color', agentColor, sessionId: id }),
};

function host({ transcript = message('hello'), stored = request, path = requestPath,
  env = { XDG_STATE_HOME: '/state', HOME: '/home/someone' }, surfaces = ['terminal'], reject, refuse = [],
  turnDuring, clearDuring, typedDuring = {} } = {}) {
  // Each happens once: a command that rejects, and a turn that starts or a session switch while the mod waits on the
  // named host call.
  let rejecting = reject;
  let interrupting = turnDuring;
  let switching = clearDuring;
  const during = async call => {
    if (call === switching?.call) {
      clear(switching.next, switching.transcript);
      switching = undefined;
    }
    if (call !== interrupting) return;
    interrupting = undefined;
    await fire('turn.start');
  };
  const files = new Map();
  if (stored) files.set(path, Buffer.from(row(stored)));
  if (transcript !== null) files.set(transcriptPath, Buffer.from(transcript));
  const handlers = new Map();
  const timers = [];
  const commands = [];
  const writes = [];
  const logs = [];
  const file = name => {
    if (!files.has(name)) throw new Error(`no such file: ${name}`);
    return files.get(name);
  };
  let current = { id, transcriptPath, path };
  const append = text =>
    files.set(current.transcriptPath, Buffer.concat([file(current.transcriptPath), Buffer.from(text)]));
  // As /clear or /resume does: the module stays, under another session ID with its own transcript and request.
  function clear(next, transcript = message('cleared')) {
    current = { id: next.sessionId, transcriptPath: `/transcripts/${next.sessionId}.jsonl`,
      path: `/state/herdr-spawn/identity/${next.sessionId}.json` };
    files.set(current.transcriptPath, Buffer.from(transcript));
    files.set(current.path, Buffer.from(row(next)));
  }
  const $ = {
    clock: { after: (ms, callback) => { timers.push(callback); } },
    env: { get: async name => env[name] },
    session: {
      id: async () => current.id,
      info: async () => ({ transcriptPath: current.transcriptPath }),
      surfaces: async () => surfaces,
    },
    fs: {
      exists: async name => files.has(name),
      stat: async name => {
        await during('stat');
        return { size: file(name).length };
      },
      read: async (name, { offset = 0, length } = {}) => {
        const data = file(name);
        return data.subarray(offset, length === undefined ? data.length : offset + length).toString();
      },
      write: async (name, content) => {
        writes.push(name);
        files.set(name, Buffer.from(content));
      },
    },
    command: {
      // A refused command resolves like any other; only the transcript lacks its row.
      run: async call => {
        if (call.command === rejecting) {
          rejecting = undefined;
          throw new Error('command rejected');
        }
        commands.push(call);
        if (!refuse.includes(call.command)) append(recordOf[call.command](call.args));
        // What the user sets while this command is awaited.
        append(typedDuring[call.command] ?? '');
        await during(call.command);
      },
    },
    ui: { log: text => { logs.push(text); } },
  };
  register((event, handler) => handlers.set(event, handler));

  async function fire(event, e = {}) {
    const passed = {};
    assert.equal(await handlers.get(event)($, e, async () => passed), passed);
  }
  async function elapse() {
    for (const callback of timers.splice(0)) await callback();
  }
  async function start() {
    await fire('session.start');
    await elapse();
  }
  const saved = () => JSON.parse(files.get(current.path).toString());
  async function turn() {
    await fire('turn.complete');
    await elapse();
  }
  return { fire, elapse, start, turn, append, clear, saved, commands, writes, logs };
}

test('sets both when the session has neither, then marks the request done', async () => {
  const session = host();
  await session.start();
  assert.deepEqual(session.commands, both);
  assert.deepEqual(session.saved(), { ...request, done: true });
  assert.deepEqual(session.writes, [requestPath]);
  assert.deepEqual(session.logs, []);
});

test('a name the session has is kept', async () => {
  const session = host({ transcript: title + message('hello') });
  await session.start();
  assert.deepEqual(session.commands, [both[1]]);
  assert.equal(session.saved().done, true);
});

test('a color the session has is kept', async () => {
  const session = host({ transcript: message('hello') + color });
  await session.start();
  assert.deepEqual(session.commands, [both[0]]);
  assert.equal(session.saved().done, true);
});

test('a session with both runs no command and is done', async () => {
  const session = host({ transcript: message('hello') + title + color });
  await session.start();
  assert.deepEqual(session.commands, []);
  assert.deepEqual(session.saved(), { ...request, done: true });
  assert.deepEqual(session.writes, [requestPath]);
});

test('a generated title is not a name', async () => {
  const session = host({ transcript: message('hello') + row({ type: 'ai-title', aiTitle: 'generated', sessionId: id }) });
  await session.start();
  assert.deepEqual(session.commands, both);
});

test('rows quoted inside a message do not count', async () => {
  const session = host({ transcript: message(`\n${title}${color}`) + message(title.trim()) });
  await session.start();
  assert.deepEqual(session.commands, both);
});

// A transcript whose marker row starts right after the newline at byte `at`.
const rowAt = (at, marker) => `${'x'.repeat(at)}\n${marker}${message('after')}`;
for (const [where, at] of [
  ['beyond the first chunk', chunk + 1000],
  ['across the first chunk boundary', chunk - 10],
  ['across the second chunk boundary', 2 * chunk - 256 - 10],
]) {
  test(`finds a row ${where}`, async () => {
    for (const [marker, expected] of [[title, [both[1]]], [color, [both[0]]]]) {
      const session = host({ transcript: rowAt(at, marker) });
      await session.start();
      assert.deepEqual(session.commands, expected);
    }
  });
}

for (const [label, options] of [
  ["another session's request", { stored: { ...request, sessionId: other } }],
  ['a request already done', { stored: { ...request, done: true } }],
  ['a session with nowhere to draw', { surfaces: [] }],
  ['a session with no request', { stored: null }],
]) {
  test(`ignores ${label}`, async () => {
    const session = host(options);
    await session.start();
    await session.turn();
    assert.deepEqual(session.commands, []);
    assert.deepEqual(session.writes, []);
    assert.deepEqual(session.logs, []);
  });
}

test('waits for the main turn to complete', async () => {
  const session = host();
  await session.fire('session.start');
  await session.fire('turn.start');
  await session.elapse();
  await session.fire('turn.complete', { agentId: 'worker' });
  await session.elapse();
  assert.deepEqual(session.commands, []);
  assert.deepEqual(session.writes, []);
  await session.fire('turn.complete');
  await session.elapse();
  assert.deepEqual(session.commands, both);
  assert.equal(session.saved().done, true);
});

test("a subagent's turn does not block", async () => {
  const session = host();
  await session.fire('session.start');
  await session.fire('turn.start', { agentId: 'worker' });
  await session.elapse();
  assert.deepEqual(session.commands, both);
});

test('a rejected command is retried after a later turn', async () => {
  for (const [reject, before] of [['rename', []], ['color', [both[0]]]]) {
    const session = host({ reject });
    await session.start();
    assert.deepEqual(session.commands, before);
    assert.deepEqual(session.saved(), request);
    assert.deepEqual(session.writes, []);
    assert.match(session.logs.join('\n'), /command rejected/);
    await session.turn();
    assert.deepEqual(session.commands, both);
    assert.equal(session.saved().done, true);
  }
});

for (const refuse of [['rename'], ['color'], ['rename', 'color']]) {
  test(`a refused command is not asked again and the request stays pending: ${refuse.join(' and ')}`, async () => {
    const session = host({ refuse });
    await session.start();
    await session.turn();
    for (const command of refuse) {
      await session.turn();
      assert.deepEqual(session.commands, both);
      assert.deepEqual(session.saved(), request);
      assert.deepEqual(session.writes, []);
      // The user types it.
      session.append(recordOf[command]('mine'));
    }
    await session.turn();
    assert.deepEqual(session.commands, both);
    assert.deepEqual(session.saved(), { ...request, done: true });
    assert.deepEqual(session.writes, [requestPath]);
    assert.deepEqual(session.logs, []);
  });
}

test('a new session in the same module is asked for both again', async () => {
  const session = host({ refuse: ['rename', 'color'] });
  await session.start();
  await session.turn();
  assert.deepEqual(session.commands, both);
  const next = { ...request, sessionId: other, name: 'coord-next', color: 'pink' };
  session.clear(next);
  await session.turn();
  await session.turn();
  assert.deepEqual(session.commands,
    [...both, { command: 'rename', args: 'coord-next' }, { command: 'color', args: 'pink' }]);
  assert.deepEqual(session.saved(), next);
  assert.deepEqual(session.writes, []);
});

// During the stat the user names the session in the new turn; during /rename the command itself has done so.
for (const [turnDuring, before, typed] of [['stat', [], title], ['rename', [both[0]], '']]) {
  test(`a turn that starts during ${turnDuring} stops the remaining commands`, async () => {
    const session = host({ turnDuring });
    await session.start();
    assert.deepEqual(session.commands, before);
    assert.deepEqual(session.writes, []);
    session.append(typed);
    await session.turn();
    assert.deepEqual(session.commands, [...before, both[1]]);
    assert.equal(session.saved().done, true);
  });
}

// A cleared session records neither; a resumed one may record both, which says nothing about the first.
for (const [how, transcript] of [['/clear', undefined], ['/resume', message('resumed') + title + color]]) {
  test(`a session switched by ${how} while /rename runs gets no color and leaves the request pending`, async () => {
    const next = { ...request, sessionId: other, done: true };
    const session = host({ clearDuring: { call: 'rename', next, transcript } });
    await session.start();
    assert.deepEqual(session.commands, [both[0]]);
    assert.deepEqual(session.writes, []);
    assert.deepEqual(session.logs, []);
  });
}

test('a color the user sets while /rename runs, with no turn, is kept', async () => {
  const session = host({ typedDuring: { rename: color } });
  await session.start();
  assert.deepEqual(session.commands, [both[0]]);
  assert.deepEqual(session.saved(), { ...request, done: true });
  assert.deepEqual(session.writes, [requestPath]);
});

test('an unreadable transcript runs no command', async () => {
  const session = host({ transcript: null });
  await session.start();
  assert.deepEqual(session.commands, []);
  assert.deepEqual(session.writes, []);
  assert.match(session.logs.join('\n'), /no such file/);
});

test('without XDG_STATE_HOME the request is under the home directory', async () => {
  const path = `/home/someone/.local/state/herdr-spawn/identity/${id}.json`;
  const session = host({ path, env: { HOME: '/home/someone' } });
  await session.start();
  assert.deepEqual(session.commands, both);
  assert.deepEqual(session.writes, [path]);
  assert.equal(session.saved().done, true);
});
