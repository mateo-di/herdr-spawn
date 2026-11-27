import assert from 'node:assert/strict';
import { execFile, spawn } from 'node:child_process';
import { chmod, lstat, mkdir, mkdtemp, readFile, realpath, rm, stat, symlink, utimes, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { test } from 'node:test';
import { promisify } from 'node:util';

const run = promisify(execFile);
const script = fileURLToPath(new URL('../skills/herdr-spawn/scripts/claude-trust.sh', import.meta.url));

const gitEnv = {
  ...process.env,
  GIT_AUTHOR_NAME: 'test', GIT_AUTHOR_EMAIL: 'test@example.com',
  GIT_COMMITTER_NAME: 'test', GIT_COMMITTER_EMAIL: 'test@example.com',
};
const git = (cwd, args) => run('git', args, { cwd, env: gitEnv, timeout: 10_000 });

const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));

async function flockAvailable() {
  try {
    await run('flock', ['--version'], { timeout: 5_000 });
    return true;
  } catch {
    return false;
  }
}

function holdLock(lock, seconds) {
  const holder = spawn('flock', [lock, 'sleep', String(seconds)], { stdio: 'ignore', detached: true });
  holder.on('error', () => {});
  return holder;
}

async function waitForLock(lock, timeoutMs = 3_000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    try {
      await run('flock', ['-n', lock, 'true'], { timeout: 2_000 });
    } catch {
      return;
    }
    await sleep(25);
  }
  throw new Error(`lock ${lock} was never taken`);
}

async function stopHolder(holder) {
  if (holder.exitCode !== null || holder.signalCode !== null) return;
  const exited = new Promise(resolve => holder.once('exit', resolve));
  try {
    process.kill(-holder.pid, 'SIGKILL');
  } catch {
    holder.kill('SIGKILL');
  }
  await Promise.race([exited, sleep(2_000)]);
}

async function fixture(t) {
  const root = await mkdtemp(join(tmpdir(), 'herdr-claude-trust-'));
  t.after(() => rm(root, { recursive: true, force: true }));
  const configDir = join(root, 'claude');
  const home = join(root, 'home');
  await mkdir(configDir);
  await mkdir(home);
  const env = {
    ...process.env, CLAUDE_CONFIG_DIR: configDir, HOME: home, XDG_STATE_HOME: join(root, 'state'),
  };
  const runTrust = (dir, extraEnv = {}, timeout = 10_000) =>
    run('bash', [script, dir], { cwd: root, env: { ...env, ...extraEnv }, timeout });
  return { root, configDir, config: join(configDir, '.claude.json'), env, runTrust };
}

async function initRepo(root, name = 'repo') {
  const repo = join(root, name);
  await mkdir(repo);
  await git(repo, ['init', '-q']);
  await git(repo, ['commit', '-q', '--allow-empty', '-m', 'init']);
  return repo;
}

test('marks a linked worktree\'s main checkout trusted and keeps other fields', async t => {
  const f = await fixture(t);
  const repo = await initRepo(f.root);
  const worktree = join(f.root, 'worktree');
  await git(repo, ['worktree', 'add', '-q', worktree, '-b', 'wt']);
  const repoKey = await realpath(repo);
  const worktreeKey = await realpath(worktree);
  await writeFile(f.config, JSON.stringify({
    numStartups: 7,
    projects: { '/somewhere/else': { allowedTools: ['Bash'] } },
  }, null, 2));
  const { stderr } = await f.runTrust(worktree);
  const data = JSON.parse(await readFile(f.config, 'utf8'));
  assert.equal(data.projects[repoKey].hasTrustDialogAccepted, true);
  assert.equal(data.projects[worktreeKey], undefined);
  assert.equal(data.numStartups, 7);
  assert.deepEqual(data.projects['/somewhere/else'], { allowedTools: ['Bash'] });
  assert.ok(stderr.startsWith(`spawn.sh: trusted ${repoKey} for Claude Code in `), stderr);
});

test('keys a linked worktree outside the repo by the main checkout\'s physical path', async t => {
  const f = await fixture(t);
  const repo = await initRepo(f.root);
  const worktree = join(f.root, 'wt');
  await git(repo, ['worktree', 'add', '-q', worktree, '-b', 'wt']);
  await writeFile(f.config, '{}');
  await f.runTrust(worktree);
  const data = JSON.parse(await readFile(f.config, 'utf8'));
  assert.equal(data.projects[await realpath(repo)].hasTrustDialogAccepted, true);
  assert.equal(data.projects[await realpath(worktree)], undefined);
});

test('refuses a .git file that points at another repository', async t => {
  const f = await fixture(t);
  const victim = await initRepo(f.root, 'victim');
  const crafted = join(f.root, 'crafted');
  await mkdir(crafted);
  await writeFile(join(crafted, '.git'), `gitdir: ${join(victim, '.git')}\n`);
  await writeFile(f.config, '{}');
  const { stderr } = await f.runTrust(crafted);
  assert.match(stderr, /not a worktree/);
  assert.equal(await readFile(f.config, 'utf8'), '{}');
});

test('ignores an inherited GIT_DIR that points at another repository', async t => {
  const f = await fixture(t);
  const repo = await initRepo(f.root);
  const other = await initRepo(f.root, 'other');
  await writeFile(f.config, '{}');
  await f.runTrust(repo, { GIT_DIR: join(other, '.git') });
  const data = JSON.parse(await readFile(f.config, 'utf8'));
  assert.equal(data.projects[await realpath(repo)].hasTrustDialogAccepted, true);
  assert.equal(data.projects[await realpath(other)], undefined);
});

test('warns instead of reading a FIFO config', async t => {
  const f = await fixture(t);
  const repo = await initRepo(f.root);
  await run('mkfifo', [f.config]);
  const { stderr } = await f.runTrust(repo, {}, 5_000);
  assert.match(stderr, /not a regular file/);
  assert.equal((await lstat(f.config)).isFIFO(), true);
});

test('leaves empty or concatenated configs alone', async t => {
  const f = await fixture(t);
  const repo = await initRepo(f.root);
  for (const bytes of ['', '{"a":1}{"b":2}']) {
    await writeFile(f.config, bytes);
    const { stderr } = await f.runTrust(repo);
    assert.match(stderr, /not one JSON object/);
    assert.equal(await readFile(f.config, 'utf8'), bytes);
  }
});

test('parallel runs for different repositories keep both keys', async t => {
  const f = await fixture(t);
  const a = await initRepo(f.root, 'a');
  const b = await initRepo(f.root, 'b');
  const keys = [await realpath(a), await realpath(b)];
  for (let round = 1; round <= 10; round++) {
    await writeFile(f.config, '{}');
    await Promise.all([f.runTrust(a), f.runTrust(b)]);
    const data = JSON.parse(await readFile(f.config, 'utf8'));
    for (const key of keys) {
      assert.equal(data.projects[key]?.hasTrustDialogAccepted, true, `round ${round}: ${key}`);
    }
  }
});

test('leaves an already trusted config byte-identical', async t => {
  const f = await fixture(t);
  const repo = await initRepo(f.root);
  const repoKey = await realpath(repo);
  const bytes = JSON.stringify({ projects: { [repoKey]: { hasTrustDialogAccepted: true, note: 'keep' } } });
  await writeFile(f.config, bytes);
  const old = new Date('2001-02-03T04:05:06Z');
  await utimes(f.config, old, old);
  const before = await stat(f.config);
  const { stderr } = await f.runTrust(repo);
  const after = await stat(f.config);
  assert.equal(await readFile(f.config, 'utf8'), bytes);
  assert.equal(after.mtimeMs, before.mtimeMs);
  assert.equal(stderr, '');
});

test('keys a non-git directory by its own physical path', async t => {
  const f = await fixture(t);
  const dir = join(f.root, 'plain');
  await mkdir(dir);
  await writeFile(f.config, '{}');
  await f.runTrust(dir);
  const key = await realpath(dir);
  const data = JSON.parse(await readFile(f.config, 'utf8'));
  assert.equal(data.projects[key].hasTrustDialogAccepted, true);
});

test('follows a symlinked config and keeps the link', async t => {
  const f = await fixture(t);
  const repo = await initRepo(f.root);
  const shared = join(f.root, 'shared.json');
  await writeFile(shared, '{}');
  await symlink(shared, f.config);
  await f.runTrust(repo);
  const data = JSON.parse(await readFile(shared, 'utf8'));
  assert.equal(data.projects[await realpath(repo)].hasTrustDialogAccepted, true);
  assert.equal((await lstat(f.config)).isSymbolicLink(), true);
});

test('warns and creates nothing when the config is missing', async t => {
  const f = await fixture(t);
  const repo = await initRepo(f.root);
  const { stderr } = await f.runTrust(repo);
  assert.match(stderr, /no Claude Code config/);
  await assert.rejects(stat(f.config), { code: 'ENOENT' });
});

test('keeps the config mode 600', async t => {
  const f = await fixture(t);
  const repo = await initRepo(f.root);
  await writeFile(f.config, '{}');
  await chmod(f.config, 0o600);
  await f.runTrust(repo);
  assert.equal((await stat(f.config)).mode & 0o777, 0o600);
});

test('does not trust a repository forged by a newline in a worktree path', async t => {
  const f = await fixture(t);
  const sibling = await initRepo(f.root, 'main');
  const lnk = join(f.root, 'lnk');
  const forged = join(f.root, `main\nworktree ${lnk}`);
  try {
    await mkdir(forged, { recursive: true });
    await git(forged, ['init', '-q']);
    await git(forged, ['commit', '-q', '--allow-empty', '-m', 'init']);
    await git(forged, ['worktree', 'add', '-q', lnk, '-b', 'wt']);
  } catch {
    return t.skip('git or the filesystem refuses a newline in a directory name');
  }
  await writeFile(f.config, '{}');
  const { stderr } = await f.runTrust(lnk);
  const bytes = await readFile(f.config, 'utf8');
  assert.match(stderr, /leaving folder trust/);
  assert.equal(bytes, '{}');
  assert.equal(JSON.parse(bytes).projects?.[await realpath(sibling)], undefined);
});

test('does not trust a sibling when the start directory name ends in a newline', async t => {
  const f = await fixture(t);
  const sibling = await initRepo(f.root, 'repo');
  const dir = join(f.root, 'repo\n');
  try {
    await mkdir(dir);
  } catch {
    return t.skip('this filesystem refuses a newline in a directory name');
  }
  await writeFile(f.config, '{}');
  const { stderr } = await f.runTrust(dir);
  const bytes = await readFile(f.config, 'utf8');
  assert.match(stderr, /cannot resolve/);
  assert.equal(bytes, '{}');
  assert.equal(JSON.parse(bytes).projects?.[await realpath(sibling)], undefined);
});

test('leaves a config whose projects is not an object alone', async t => {
  const f = await fixture(t);
  const repo = await initRepo(f.root);
  const bytes = '{"projects":[1]}';
  await writeFile(f.config, bytes);
  const { stderr } = await f.runTrust(repo);
  assert.match(stderr, /is not one JSON object/);
  assert.equal(await readFile(f.config, 'utf8'), bytes);
});

test('leaves a config whose projects entry is not an object alone', async t => {
  const f = await fixture(t);
  const repo = await initRepo(f.root);
  const bytes = JSON.stringify({ projects: { [await realpath(repo)]: 5 } });
  await writeFile(f.config, bytes);
  const { stderr } = await f.runTrust(repo);
  assert.match(stderr, /is not one JSON object/);
  assert.equal(await readFile(f.config, 'utf8'), bytes);
});

test('keeps a config that becomes trusted while the lock is held', async t => {
  if (!(await flockAvailable())) return t.skip('flock is not installed');
  const f = await fixture(t);
  const repo = await initRepo(f.root);
  const key = await realpath(repo);
  const lock = join(f.root, 'state', 'herdr-spawn', 'claude-trust.lock');
  await mkdir(dirname(lock), { recursive: true });
  await writeFile(f.config, '{}');
  const holder = holdLock(lock, 2);
  try {
    await waitForLock(lock);
    const pending = f.runTrust(repo);
    await sleep(200);
    const trusted = `${JSON.stringify({ projects: { [key]: { hasTrustDialogAccepted: true } } }, null, 2)}\n`;
    await writeFile(f.config, trusted);
    await pending;
    assert.equal(await readFile(f.config, 'utf8'), trusted);
  } finally {
    await stopHolder(holder);
  }
});

test('warns and leaves the config alone when the lock is held too long', async t => {
  if (!(await flockAvailable())) return t.skip('flock is not installed');
  const f = await fixture(t);
  const repo = await initRepo(f.root);
  const lock = join(f.root, 'state', 'herdr-spawn', 'claude-trust.lock');
  await mkdir(dirname(lock), { recursive: true });
  await writeFile(f.config, '{}');
  const holder = holdLock(lock, 7);
  try {
    await waitForLock(lock);
    const started = Date.now();
    const { stderr } = await f.runTrust(repo, {}, 12_000);
    const elapsed = Date.now() - started;
    assert.match(stderr, /another claude-trust run holds/);
    assert.equal(await readFile(f.config, 'utf8'), '{}');
    assert.ok(elapsed < 6_500, `took ${elapsed}ms`);
  } finally {
    await stopHolder(holder);
  }
});
