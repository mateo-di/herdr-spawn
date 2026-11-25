import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { closeSync, openSync } from 'node:fs';
import { chmod, lstat, lutimes, mkdir, mkdtemp, readFile, readdir, readlink, rm, symlink, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { setTimeout as delay } from 'node:timers/promises';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';

const heavy = fileURLToPath(new URL('../skills/herdr-spawn/scripts/heavy.sh', import.meta.url));
let seq = 0;

// Stdio goes to files, so a test can still read it after killing the run's process group.
const startHeavy = (args, env) => {
  const outFile = join(dirname(env.HERDR_SPAWN_HEAVY_DIR), `heavy-out-${++seq}`);
  const errFile = join(dirname(env.HERDR_SPAWN_HEAVY_DIR), `heavy-err-${seq}`);
  const out = openSync(outFile, 'w');
  const err = openSync(errFile, 'w');
  let child;
  try {
    child = spawn('bash', [heavy, ...args], { env, detached: true, stdio: ['ignore', out, err] });
  } finally {
    closeSync(out);
    closeSync(err);
  }
  const run = { child, outFile, errFile, stdout: '', stderr: '', code: null, signal: null };
  run.done = new Promise(resolve => {
    child.on('exit', (code, signal) => {
      run.code = code;
      run.signal = signal;
      resolve(run);
    });
  });
  run.read = async () => {
    run.stdout = await readFile(outFile, 'utf8');
    run.stderr = await readFile(errFile, 'utf8');
    return run;
  };
  return run;
};

// Every wait is bounded: a stuck heavy.sh is killed with its process group.
const finish = async (run, timeout = 10_000) => {
  let timer;
  const expired = new Promise((_, reject) => {
    timer = setTimeout(() => {
      try { process.kill(-run.child.pid, 'SIGKILL'); } catch {}
      reject(new Error(`heavy.sh did not exit within ${timeout}ms\n${run.stderr}`));
    }, timeout);
  });
  try {
    return await Promise.race([run.done, expired]);
  } finally {
    clearTimeout(timer);
  }
};

const runHeavy = async (args, env) => (await finish(startHeavy(args, env))).read();

const waitFor = async (predicate, timeout = 5000) => {
  const deadline = Date.now() + timeout;
  while (Date.now() < deadline) {
    if (await predicate()) return;
    await delay(50);
  }
  throw new Error('condition was not met in time');
};

const exists = async path => {
  try {
    await lstat(path);
    return true;
  } catch {
    return false;
  }
};

// The keeper frees a slot shortly after its command ends, not at once.
const slotsFreed = dir => waitFor(async () => (await readdir(dir)).length === 0);

const setup = async t => {
  const root = await mkdtemp(join(tmpdir(), 'herdr-heavy-'));
  t.after(() => rm(root, { recursive: true, force: true }));
  const dir = join(root, 'slots');
  const env = { ...process.env, HERDR_SPAWN_HEAVY_DIR: dir, HERDR_SPAWN_HEAVY_POLL: '0.2' };
  delete env.HERDR_SPAWN_HEAVY_SLOTS;
  delete env.HERDR_SPAWN_HEAVY_HELD;
  return { root, dir, env };
};

test('passes arguments and the exit status through, then frees the slot', async t => {
  const { root, dir, env } = await setup(t);
  const mark = join(root, 'args');
  const run = await runHeavy(['bash', '-c', 'printf "%s\\n" "$@" > "$MARK"; exit 7', 'bash', 'one argument with spaces'],
    { ...env, MARK: mark });
  assert.equal(run.code, 7);
  assert.equal(await readFile(mark, 'utf8'), 'one argument with spaces\n');
  await slotsFreed(dir);
});

test('one slot serializes two runs, which wait once for each other', async t => {
  const { root, dir, env } = await setup(t);
  const firstStart = join(root, 'first-start');
  const firstEnd = join(root, 'first-end');
  const order = join(root, 'order');
  const first = startHeavy(['bash', '-c', 'echo start > "$1"; sleep 0.5; echo end > "$2"', 'bash', firstStart, firstEnd],
    { ...env, HERDR_SPAWN_HEAVY_SLOTS: '1' });
  await waitFor(() => exists(firstStart));
  const second = startHeavy(['bash', '-c', 'if [ -f "$1" ]; then echo after > "$2"; else echo before > "$2"; fi',
    'bash', firstEnd, order], { ...env, HERDR_SPAWN_HEAVY_SLOTS: '1' });
  await finish(first);
  await finish(second);
  await second.read();
  assert.equal(await readFile(order, 'utf8'), 'after\n');
  assert.equal(second.stderr.match(/all 1 slots are busy; waiting/g)?.length, 1);
  await slotsFreed(dir);
});

test('two slots let two runs overlap', async t => {
  const { root, env } = await setup(t);
  const script = [
    'echo start > "$1"',
    'n=0',
    'while [ "$n" -lt 40 ]; do',
    '  if [ -f "$2" ]; then echo saw > "$3"; exit 0; fi',
    '  n=$((n + 1))',
    '  sleep 0.1',
    'done',
    'exit 0',
  ].join('\n');
  const aStart = join(root, 'a-start');
  const bStart = join(root, 'b-start');
  const aSawB = join(root, 'a-saw-b');
  const bSawA = join(root, 'b-saw-a');
  const a = startHeavy(['bash', '-c', script, 'bash', aStart, bStart, aSawB], { ...env, HERDR_SPAWN_HEAVY_SLOTS: '2' });
  const b = startHeavy(['bash', '-c', script, 'bash', bStart, aStart, bSawA], { ...env, HERDR_SPAWN_HEAVY_SLOTS: '2' });
  await finish(a);
  await finish(b);
  await a.read();
  await b.read();
  assert.equal(await readFile(aSawB, 'utf8'), 'saw\n');
  assert.equal(await readFile(bSawA, 'utf8'), 'saw\n');
  assert.doesNotMatch(a.stderr, /waiting/);
  assert.doesNotMatch(b.stderr, /waiting/);
});

test('takes over an abandoned slot', async t => {
  const { root, dir, env } = await setup(t);
  await mkdir(dir, { mode: 0o700 });
  const slot = join(dir, 'slot-1');
  await symlink('999999.1', slot);
  const old = new Date(Date.now() - 5 * 60 * 1000);
  await lutimes(slot, old, old);
  const mark = join(root, 'ran');
  const run = await runHeavy(['bash', '-c', 'echo ran > "$1"', 'bash', mark], { ...env, HERDR_SPAWN_HEAVY_SLOTS: '1' });
  assert.equal(run.code, 0);
  assert.doesNotMatch(run.stderr, /waiting/);
  assert.equal(await readFile(mark, 'utf8'), 'ran\n');
  await slotsFreed(dir);
});

test('respects a live slot owned by someone else', async t => {
  const { root, dir, env } = await setup(t);
  await mkdir(dir, { mode: 0o700 });
  const slot = join(dir, 'slot-1');
  await symlink('999999.1', slot);
  const mark = join(root, 'ran');
  const run = startHeavy(['bash', '-c', 'echo ran > "$1"', 'bash', mark], { ...env, HERDR_SPAWN_HEAVY_SLOTS: '1' });
  await waitFor(async () => (await readFile(run.errFile, 'utf8')).includes('all 1 slots are busy; waiting'));
  process.kill(-run.child.pid, 'SIGTERM');
  await finish(run, 5000);
  await run.read();
  await assert.rejects(readFile(mark));
  assert.equal(await readlink(slot), '999999.1');
  assert.deepEqual(await readdir(dir), ['slot-1']);
});

test('a killed run frees its slot', async t => {
  const { dir, env } = await setup(t);
  const run = startHeavy(['bash', '-c', 'sleep 30'], { ...env, HERDR_SPAWN_HEAVY_SLOTS: '1' });
  await waitFor(() => exists(join(dir, 'slot-1')));
  process.kill(-run.child.pid, 'SIGTERM');
  await finish(run, 5000);
  await slotsFreed(dir);
});

for (const signal of ['SIGTERM', 'SIGKILL']) {
  test(`a ${signal} to heavy.sh alone ends the command at once and frees its slot`, async t => {
    const { root, dir, env } = await setup(t);
    const mark = join(root, 'started');
    const run = startHeavy(['bash', '-c', 'echo started > "$1"; exec sleep 30', 'bash', mark],
      { ...env, HERDR_SPAWN_HEAVY_SLOTS: '1' });
    await waitFor(() => exists(mark));
    process.kill(run.child.pid, signal);
    await finish(run, 3000);
    assert.equal(run.signal, signal);
    await slotsFreed(dir);
  });
}

test('a run right after another starts without waiting a full poll', async t => {
  const { env } = await setup(t);
  const slowPoll = { ...env, HERDR_SPAWN_HEAVY_SLOTS: '1', HERDR_SPAWN_HEAVY_POLL: '30' };
  await runHeavy(['true'], slowPoll);
  const second = startHeavy(['true'], slowPoll);
  await finish(second, 5000);
  assert.equal(second.code, 0);
});

test('a heavy.sh call inside a check runs at once', async t => {
  const { root, env } = await setup(t);
  const mark = join(root, 'inner');
  const run = startHeavy(['bash', heavy, 'bash', '-c', 'echo inner > "$1"', 'bash', mark],
    { ...env, HERDR_SPAWN_HEAVY_SLOTS: '1' });
  await finish(run, 5000);
  await run.read();
  assert.equal(run.code, 0);
  assert.equal(await readFile(mark, 'utf8'), 'inner\n');
  assert.doesNotMatch(run.stderr, /waiting/);
});

test('the keeper leaves alone a slot taken over by someone else', async t => {
  const { root, dir, env } = await setup(t);
  const mark = join(root, 'started');
  const run = startHeavy(['bash', '-c', 'echo started > "$1"; exec sleep 30', 'bash', mark],
    { ...env, HERDR_SPAWN_HEAVY_SLOTS: '1' });
  await waitFor(() => exists(mark));
  const slot = join(dir, 'slot-1');
  await rm(slot);
  await symlink('other.1', slot);
  const old = new Date(Date.now() - 5 * 60 * 1000);
  await lutimes(slot, old, old);
  await delay(2500);
  assert.equal(await readlink(slot), 'other.1');
  assert.ok((await lstat(slot)).mtimeMs < Date.now() - 4 * 60 * 1000);
  process.kill(run.child.pid, 'SIGKILL');
  await finish(run, 3000);
  await delay(500);
  assert.equal(await readlink(slot), 'other.1');
});

test('closes its output pipes when the command ends', async t => {
  const { env } = await setup(t);
  const child = spawn('bash', [heavy, 'bash', '-c', 'echo hi'],
    { env, detached: true, stdio: ['ignore', 'pipe', 'pipe'] });
  let stdout = '';
  child.stdout.setEncoding('utf8');
  child.stdout.on('data', chunk => { stdout += chunk; });
  let timer;
  const closed = new Promise((resolve, reject) => {
    timer = setTimeout(() => {
      try { process.kill(-child.pid, 'SIGKILL'); } catch {}
      reject(new Error('heavy.sh kept its output pipes open after the command ended'));
    }, 5000);
    child.on('close', code => resolve(code));
  });
  const code = await closed.finally(() => clearTimeout(timer));
  assert.equal(code, 0);
  assert.equal(stdout, 'hi\n');
});

test('runs at once with a warning when the directory is a symlink', async t => {
  const { root, dir, env } = await setup(t);
  const real = join(root, 'real');
  await mkdir(real);
  await writeFile(join(real, 'keep'), '');
  await symlink(real, dir);
  const mark = join(root, 'ran');
  const run = await runHeavy(['bash', '-c', 'echo ran > "$1"; exit 9', 'bash', mark], env);
  assert.equal(run.code, 9);
  assert.match(run.stderr, /heavy\.sh: /);
  assert.equal(await readFile(mark, 'utf8'), 'ran\n');
  assert.deepEqual(await readdir(real), ['keep']);
});

test('runs at once with a warning when the directory refuses links', async t => {
  if (process.getuid?.() === 0) return t.skip('root ignores directory modes');
  const { root, dir, env } = await setup(t);
  await mkdir(dir, { mode: 0o500 });
  const mark = join(root, 'ran');
  const run = await runHeavy(['bash', '-c', 'echo ran > "$1"; exit 9', 'bash', mark], env);
  await chmod(dir, 0o700);
  assert.equal(run.code, 9);
  assert.match(run.stderr, /heavy\.sh: /);
  assert.equal(await readFile(mark, 'utf8'), 'ran\n');
  assert.deepEqual(await readdir(dir), []);
});

for (const value of ['0', 'two']) {
  test(`refuses HERDR_SPAWN_HEAVY_SLOTS=${value} without running the command`, async t => {
    const { root, dir, env } = await setup(t);
    const mark = join(root, 'ran');
    const run = await runHeavy(['bash', '-c', 'echo ran > "$1"', 'bash', mark],
      { ...env, HERDR_SPAWN_HEAVY_SLOTS: value });
    assert.equal(run.code, 2);
    assert.match(run.stderr, /HERDR_SPAWN_HEAVY_SLOTS must be a whole number above 0/);
    await assert.rejects(readFile(mark));
    assert.equal(await exists(dir), false);
  });
}

for (const value of ['soon', '-1', '0', '0.0']) {
  test(`refuses HERDR_SPAWN_HEAVY_POLL=${value} without running the command`, async t => {
    const { root, dir, env } = await setup(t);
    const mark = join(root, 'ran');
    const run = await runHeavy(['bash', '-c', 'echo ran > "$1"', 'bash', mark],
      { ...env, HERDR_SPAWN_HEAVY_POLL: value });
    assert.equal(run.code, 2);
    assert.match(run.stderr, /HERDR_SPAWN_HEAVY_POLL must be a number of seconds/);
    await assert.rejects(readFile(mark));
    assert.equal(await exists(dir), false);
  });
}

test('runs at once with a warning when the directory is writable by other users', async t => {
  const { root, dir, env } = await setup(t);
  await mkdir(dir, { mode: 0o700 });
  await chmod(dir, 0o770);
  const mark = join(root, 'ran');
  const run = await runHeavy(['bash', '-c', 'echo ran > "$1"; exit 9', 'bash', mark], env);
  assert.equal(run.code, 9);
  assert.match(run.stderr, /writable by other users; running without a slot/);
  assert.equal(await readFile(mark, 'utf8'), 'ran\n');
  assert.deepEqual(await readdir(dir), []);
});
