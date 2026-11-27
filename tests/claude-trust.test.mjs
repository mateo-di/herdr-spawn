import assert from 'node:assert/strict';
import { execFile, spawn } from 'node:child_process';
import { access, chmod, lstat, mkdir, mkdtemp, readFile, realpath, rm, stat, symlink, utimes, writeFile } from 'node:fs/promises';
import { constants } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { test } from 'node:test';
import { setTimeout as delay } from 'node:timers/promises';
import { promisify } from 'node:util';

const run = promisify(execFile);
const script = fileURLToPath(new URL('../skills/herdr-spawn/scripts/claude-trust.sh', import.meta.url));
const BASE_TOOLS = ['bash', 'env', 'git', 'cksum', 'mktemp', 'stat', 'chmod', 'mv', 'rm', 'mkdir', 'dirname', 'readlink'];

const gitEnv = {
  ...process.env,
  GIT_AUTHOR_NAME: 'test', GIT_AUTHOR_EMAIL: 'test@example.com',
  GIT_COMMITTER_NAME: 'test', GIT_COMMITTER_EMAIL: 'test@example.com',
};
const git = (cwd, args) => run('git', args, { cwd, env: gitEnv, timeout: 10_000 });

async function available(cmd, args) {
  try {
    await run(cmd, args, { timeout: 5_000 });
    return true;
  } catch {
    return false;
  }
}

async function resolveBin(name) {
  for (const dir of (process.env.PATH || '').split(':')) {
    const candidate = join(resolve(dir), name);
    try {
      await access(candidate, constants.X_OK);
      if ((await stat(candidate)).isFile()) return candidate;
    } catch {
      // Keep looking.
    }
  }
  throw new Error(`cannot find ${name} on PATH`);
}

async function toolBin(root, names) {
  const dir = join(root, 'bin');
  await mkdir(dir);
  for (const name of names) await symlink(await resolveBin(name), join(dir, name));
  return dir;
}

async function exists(path) {
  try {
    await access(path);
    return true;
  } catch {
    return false;
  }
}

async function runWithBin(f, bin, dir, extraEnv = {}, timeout = 12_000) {
  return run(await resolveBin('bash'), [script, dir], {
    cwd: f.root,
    env: { ...f.env, ...extraEnv, PATH: bin },
    timeout,
  });
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
    await delay(25);
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
  await Promise.race([exited, delay(2_000)]);
}

async function fixture(t) {
  const root = await mkdtemp(join(tmpdir(), 'herdr-claude-trust-'));
  t.after(() => rm(root, { recursive: true, force: true }));
  const configDir = join(root, 'claude');
  const home = join(root, 'home');
  const lock = join(root, 'state', 'herdr-spawn', 'claude-trust.lock');
  await mkdir(configDir);
  await mkdir(home);
  await mkdir(dirname(lock), { recursive: true });
  const env = {
    ...process.env, CLAUDE_CONFIG_DIR: configDir, HOME: home, XDG_STATE_HOME: join(root, 'state'),
  };
  const runTrust = (dir, extraEnv = {}, timeout = 10_000) =>
    run('bash', [script, dir], { cwd: root, env: { ...env, ...extraEnv }, timeout });
  return { root, configDir, config: join(configDir, '.claude.json'), env, lock, runTrust };
}

async function readConfig(f) {
  return JSON.parse(await readFile(f.config, 'utf8'));
}

async function assertTrusted(f, dir) {
  assert.equal((await readConfig(f)).projects[await realpath(dir)].hasTrustDialogAccepted, true);
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
  const data = await readConfig(f);
  await assertTrusted(f, repo);
  assert.equal(data.projects[worktreeKey], undefined);
  assert.equal(data.numStartups, 7);
  assert.deepEqual(data.projects['/somewhere/else'], { allowedTools: ['Bash'] });
  assert.ok(stderr.startsWith(`spawn.sh: trusted ${repoKey} for Claude Code in `), stderr);
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
  await assertTrusted(f, repo);
  const data = await readConfig(f);
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
    const data = await readConfig(f);
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
  await assertTrusted(f, dir);
});

test('follows a symlinked config and keeps the link', async t => {
  const f = await fixture(t);
  const repo = await initRepo(f.root);
  const shared = join(f.root, 'shared.json');
  await writeFile(shared, '{}');
  await symlink(shared, f.config);
  await f.runTrust(repo);
  await assertTrusted(f, repo);
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
  if (!(await available('flock', ['--version']))) return t.skip('flock is not installed');
  const f = await fixture(t);
  const repo = await initRepo(f.root);
  const key = await realpath(repo);
  await writeFile(f.config, '{}');
  const holder = holdLock(f.lock, 3);
  try {
    await waitForLock(f.lock);
    const pending = f.runTrust(repo);
    await delay(1000);
    const trusted = JSON.stringify({ projects: { [key]: { hasTrustDialogAccepted: true } }, keep: 1 });
    await writeFile(f.config, trusted);
    await stopHolder(holder);
    await pending;
    assert.equal(await readFile(f.config, 'utf8'), trusted);
  } finally {
    await stopHolder(holder);
  }
});

test('warns and leaves the config alone when the lock is held too long', async t => {
  if (!(await available('flock', ['--version']))) return t.skip('flock is not installed');
  const f = await fixture(t);
  const repo = await initRepo(f.root);
  await writeFile(f.config, '{}');
  const holder = holdLock(f.lock, 7);
  try {
    await waitForLock(f.lock);
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

test('takes the lock with perl when flock is missing', async t => {
  if (!(await available('flock', ['--version'])) || !(await available('perl', ['-e', 'exit 0']))) {
    return t.skip('flock and perl are both required');
  }
  const f = await fixture(t);
  const repo = await initRepo(f.root);
  const bin = await toolBin(f.root, [...BASE_TOOLS, 'jq', 'perl']);
  await writeFile(f.config, '{}');
  const holder = holdLock(f.lock, 7);
  try {
    await waitForLock(f.lock);
    const started = Date.now();
    const { stderr } = await runWithBin(f, bin, repo);
    const elapsed = Date.now() - started;
    assert.match(stderr, /another claude-trust run holds/);
    assert.equal(await readFile(f.config, 'utf8'), '{}');
    assert.ok(elapsed < 6_500, `took ${elapsed}ms`);
  } finally {
    await stopHolder(holder);
  }
  await runWithBin(f, bin, repo);
  await assertTrusted(f, repo);
});

test('trusts without a lock when neither flock nor perl exists', async t => {
  const f = await fixture(t);
  const repo = await initRepo(f.root);
  const bin = await toolBin(f.root, [...BASE_TOOLS, 'jq']);
  await writeFile(f.config, '{}');
  const { stderr } = await runWithBin(f, bin, repo, {}, 10_000);
  assert.doesNotMatch(stderr, /lock/i);
  await assertTrusted(f, repo);
});

test('keeps the perl lock until the config is written', async t => {
  if (!(await available('flock', ['--version'])) || !(await available('perl', ['-e', 'exit 0']))) {
    return t.skip('flock and perl are both required');
  }
  const f = await fixture(t);
  const repo = await initRepo(f.root);
  const bin = await toolBin(f.root, [...BASE_TOOLS, 'perl']);
  const marker = join(f.root, 'lock-marker');
  const sh = path => `'${path}'`;
  const wrapper = [
    '#!/bin/sh',
    'case "$*" in',
    "  *'hasTrustDialogAccepted = true'*)",
    `    if ${sh(await resolveBin('flock'))} -n ${sh(f.lock)} ${sh(await resolveBin('true'))}; then`,
    `      printf free >> ${sh(marker)}`,
    '    else',
    `      printf held >> ${sh(marker)}`,
    '    fi',
    '    ;;',
    'esac',
    `exec ${sh(await resolveBin('jq'))} "$@"`,
    '',
  ].join('\n');
  const jq = join(bin, 'jq');
  await writeFile(jq, wrapper);
  await chmod(jq, 0o755);
  await writeFile(f.config, '{}');
  await runWithBin(f, bin, repo);
  assert.equal(await readFile(marker, 'utf8'), 'held');
  await assertTrusted(f, repo);
});

test('ignores a PERL5LIB that would load another Fcntl', async t => {
  if (!(await available('flock', ['--version'])) || !(await available('perl', ['-e', 'exit 0']))) {
    return t.skip('flock and perl are both required');
  }
  const f = await fixture(t);
  const repo = await initRepo(f.root);
  const bin = await toolBin(f.root, [...BASE_TOOLS, 'jq', 'perl']);
  const evil = join(f.root, 'evil');
  await mkdir(evil);
  const marker = join(f.root, 'evil-loaded');
  await writeFile(join(evil, 'Fcntl.pm'), [
    `open(my $fh, '>>', '${marker}') or die $!;`,
    'print $fh "loaded\\n";',
    'close $fh;',
    '1;',
    '',
  ].join('\n'));
  await writeFile(f.config, '{}');
  await runWithBin(f, bin, repo, { PERL5LIB: evil, PERL5OPT: undefined });
  assert.equal(await exists(marker), false);
  await assertTrusted(f, repo);
});

test('creates the lock file private', async t => {
  if (!(await available('flock', ['--version']))) return t.skip('flock is not installed');
  const f = await fixture(t);
  const repo = await initRepo(f.root);
  await writeFile(f.config, '{}');
  await f.runTrust(repo);
  const { mode } = await stat(f.lock);
  assert.equal(mode & 0o077, 0);
});
