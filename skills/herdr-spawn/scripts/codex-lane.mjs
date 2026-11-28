import { spawn } from 'node:child_process';
import { once } from 'node:events';
import { accessSync, existsSync, readFileSync, renameSync, writeFileSync } from 'node:fs';
import { isAbsolute, join } from 'node:path';
import { createInterface } from 'node:readline';
import { setTimeout as delay } from 'node:timers/promises';

// Usage: codex-lane.mjs <startup-dir> <brief> <goal> <name> [model]  runs a lane's TUI on a thread with its goal.
//        codex-lane.mjs --name-only <name> [model]  saves a named thread, prints its ID and starts no TUI.
const nameOnly = process.argv[2] === '--name-only';
const [startupDir, brief, goal, name, model] = nameOnly
  ? [undefined, undefined, undefined, ...process.argv.slice(3)] : process.argv.slice(2);
const inheritShell = 'shell_environment_policy.inherit=all';

function report(phase, detail) {
  const statusFile = join(startupDir, 'result');
  const temporary = `${statusFile}.tmp`;
  writeFileSync(temporary, `${phase} ${detail}\n`, { mode: 0o600 });
  renameSync(temporary, statusFile);
}

function closed(child) {
  return new Promise(resolve => child.once('close', (code, signal) => resolve({ code, signal })));
}

function matchesGoal(goal, threadId, objective) {
  return goal?.threadId === threadId && goal.objective === objective && goal.status === 'active';
}

function rolloutEvents(path) {
  // Ignore an incomplete trailing line while the TUI is writing to the rollout.
  return readFileSync(path, 'utf8').split('\n').slice(0, -1)
    .map(line => JSON.parse(line)).filter(row => row.type === 'event_msg').map(row => row.payload);
}

// Without an objective the thread only gets its name.
async function bootstrap(objective) {
  const lane = objective !== undefined;
  const server = spawn('codex', ['app-server', ...(lane ? ['-c', inheritShell] : []), '--listen', 'stdio://'], {
    stdio: ['pipe', 'pipe', 'inherit'],
  });
  const exit = closed(server);
  const output = createInterface({ input: server.stdout });
  const lines = output[Symbol.asyncIterator]();
  let nextId = 0;

  function send(message) {
    return new Promise((resolve, reject) => {
      server.stdin.write(`${JSON.stringify(message)}\n`, error => error ? reject(error) : resolve());
    });
  }
  // Failed writes are reported by send's callback as well as by the stream.
  server.stdin.on('error', () => {});

  async function request(method, params) {
    const id = ++nextId;
    await send({ id, method, params });
    while (true) {
      const { value, done } = await lines.next();
      if (done) throw new Error(`${method}: Codex app-server closed without a response`);
      let message;
      try {
        message = JSON.parse(value);
      } catch {
        throw new Error(`${method}: invalid JSON from Codex app-server`);
      }
      if (message?.id !== id || message.method) continue;
      if (message.error) throw new Error(`${method}: ${message.error.message}`);
      return message.result;
    }
  }

  async function setName(threadId) {
    await request('thread/name/set', { threadId, name });
    const { thread } = (await request('thread/read', { threadId, includeTurns: false })) ?? {};
    if (thread?.id !== threadId || thread.name !== name) {
      throw new Error(`thread/read did not return the matching name for ${threadId}`);
    }
  }

  let timer;
  try {
    return await Promise.race([
      (async () => {
        await once(server, 'spawn');
        await request('initialize', { clientInfo: { name: 'herdr-spawn', version: '1' } });
        await send({ method: 'initialized' });
        // Respect the server's configured feature setting. Disable goals only in
        // this temporary runtime so the resumed TUI owns the first turn.
        const cwd = process.cwd();
        // Starting a writable thread trusts the folder and runs its MCP servers before the user is asked.
        // Naming needs no write access, and the TUI applies the user's own sandbox on resume.
        const { thread } = (await request('thread/start', {
          cwd, ephemeral: false, ...(lane ? { config: { 'features.goals': false } } : { sandbox: 'read-only' }),
          ...(model === undefined ? {} : { model }),
        })) ?? {};
        if (!thread || thread.ephemeral !== false || thread.cwd !== cwd ||
            !/^[\da-f]{8}(?:-[\da-f]{4}){3}-[\da-f]{12}$/i.test(thread.id) ||
            typeof thread.path !== 'string' || !isAbsolute(thread.path)) {
          throw new Error('thread/start did not return a saved thread in the child cwd');
        }
        const threadId = thread.id;
        let namingFailed = false;
        if (lane) {
          await request('thread/goal/set', { threadId, objective, origin: 'automatic', status: 'active' });
          const { goal: saved } = (await request('thread/goal/get', { threadId })) ?? {};
          if (!matchesGoal(saved, threadId, objective)) {
            throw new Error(`thread/goal/get did not return the matching active goal for ${threadId}`);
          }
          // A lane's goal matters more than its name: name last, and give up before the startup deadline.
          // No request may follow, since an abandoned one would still consume the next response.
          try {
            await Promise.race([setName(threadId), delay(5_000, undefined, { ref: false }).then(() => {
              throw new Error('naming timed out after 5s');
            })]);
          } catch (error) {
            namingFailed = true;
            console.error(`codex-lane: could not name thread ${threadId}, continuing: ${error.message}`);
          }
        } else await setName(threadId);
        server.stdin.end();
        // A server that failed to name may never exit, or exit nonzero for it: the saved goal decides instead.
        // A launcher's child can hold the pipe past the kill, which would keep the exit pending.
        const killer = namingFailed ? setTimeout(() => {
          server.kill('SIGKILL');
          server.stdout.destroy();
        }, 5_000) : undefined;
        const { code, signal } = await exit;
        clearTimeout(killer);
        if (!namingFailed && code !== 0) throw new Error(`Codex app-server exited with ${signal ?? code}`);
        if (!existsSync(thread.path)) throw new Error(`Codex did not save the rollout for ${threadId}`);
        if (!lane) return thread;
        const events = rolloutEvents(thread.path);
        if (!events.some(event => event.type === 'thread_goal_updated' && matchesGoal(event.goal, threadId, objective))) {
          throw new Error(`Codex did not persist the matching active goal for ${threadId}`);
        }
        if (events.some(event => event.type === 'task_started')) {
          throw new Error(`Codex unexpectedly started work before the TUI resumed ${threadId}`);
        }
        return thread;
      })(),
      new Promise((_, reject) => {
        timer = setTimeout(() => reject(new Error('Codex app-server startup timed out after 25s')), 25_000);
      }),
    ]);
  } finally {
    clearTimeout(timer);
    output.close();
    server.stdin.destroy();
    // A launcher's child outlives the kill and holds this pipe, which would keep the helper running.
    server.stdout.destroy();
    if (server.exitCode === null && server.signalCode === null) server.kill('SIGKILL');
  }
}

async function waitForGoalTurn(thread, tui) {
  const deadline = Date.now() + 30_000;
  do {
    if (tui.exitCode !== null || tui.signalCode !== null) {
      throw new Error(`Codex TUI for ${thread.id} exited with ${tui.signalCode ?? tui.exitCode}`);
    }
    // A detection signal may come from the transient app-server or from a TUI
    // still showing a trust dialog. Only the resumed TUI can write this event.
    if (rolloutEvents(thread.path).some(event =>
      event.type === 'task_started' && event.turn_attribution?.turn_trigger === 'goal')) return;
    await delay(250);
  } while (Date.now() < deadline);
  throw new Error(`Codex TUI did not start pursuing the native goal for ${thread.id} within 30s (check for login or trust prompts)`);
}

async function runLane() {
  accessSync(startupDir);
  accessSync(brief);
  if (!goal.trim()) throw new Error('the lane objective is empty');
  const objective = `${goal.trim()}\n\nBefore working, read and follow the lane protocol and brief at ${JSON.stringify(brief)}.`;
  const thread = await bootstrap(objective);
  accessSync(startupDir);
  // An embedded server keeps this shell's env, rather than a shared daemon's.
  // Resuming an active goal on 0.171.0 triggers native continuation without a positional prompt.
  const tui = spawn('codex', [
    'resume', '--no-daemon', '-c', inheritShell, ...(model === undefined ? [] : ['--model', model]), '--', thread.id,
  ], {
    stdio: 'inherit',
  });
  const exit = closed(tui);
  await once(tui, 'spawn');
  await waitForGoalTurn(thread, tui);
  report('ready', thread.id);
  const { code, signal } = await exit;
  if (code !== 0 || existsSync(startupDir)) {
    throw new Error(`Codex TUI for ${thread.id} exited with ${signal ?? code}`);
  }
}

try {
  if (!name) throw new Error('the Codex session name is empty');
  if (model !== undefined && !/^[A-Za-z0-9][A-Za-z0-9._+@:-]*(\/[A-Za-z0-9][A-Za-z0-9._+@:-]*)*$/.test(model)) {
    throw new Error('expected a safe model ID');
  }
  if (nameOnly) process.stdout.write(`${(await bootstrap()).id}\n`);
  else await runLane();
} catch (error) {
  const detail = error.message.replace(/\s+/g, ' ').slice(0, 1000);
  console.error(`codex-lane: ${detail}`);
  // Once spawn.sh has collected the result it removes the private startup directory.
  try {
    if (!nameOnly) report('error', detail);
  } catch (reportError) {
    if (reportError.code !== 'ENOENT') console.error(`codex-lane: could not report startup failure: ${reportError.message}`);
  }
  process.exitCode = 1;
}
