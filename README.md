# herdr-spawn

A skill that lets a coding agent spawn another agent session (`claude`, `codex`, `opencode`, `omp` or any CLI you name) in a sibling [Herdr](https://herdr.dev) pane with an initial prompt, keep the tab an even grid, and coordinate with the child afterwards. The caller can be Claude Code, Codex, OpenCode or oh-my-pi. It ships as a Claude Code plugin and as a plain skill folder.

An Opus coordinator in the Herdr app runs two tickets as driver lanes, each in its own tab and worktree. Each lane hands the code to a Sonnet worker and reports done to the coordinator, which checks the work:

![An Opus coordinator spawns two Opus lanes in the Herdr app; each lane runs a Sonnet worker and reports done](docs/demo.gif)

## Requirements

- Herdr 0.9.1 or newer, with the caller running inside a Herdr pane; or the Herdr app, with `hc` (herdr-core) on the caller's `PATH`. To split an explicit pane by ID in the app (without `--lane`), run the command on the window's host with `herdr-app` on `PATH`. The same `herdr-app` lets `--tab` name the new app tab after the child; without it the tab keeps its number.
- `jq`
- A bash- or zsh-compatible shell in the pane (the launch line uses `$(cat …)`)
- For built-in Codex lanes: Codex CLI 0.171.0 (native goal startup verified on this version) and Node.js 18+ on the child shell's `PATH`. Ordinary Codex launches use the same Node.js to name the session and start unnamed without it
- Optional, for a Claude child's color: `uuidgen` or `/proc/sys/kernel/random/uuid` on the caller's host
- Optional, for a Claude child's color and a titled OpenCode session: `claude` or `opencode` as an executable on the child shell's `PATH`, and `timeout`, or `perl` when the caller's host has no `timeout`
- Optional, for a Claude coordinator's own name and color: Claude Code 2.1.326 or newer with mods on, and this plugin installed at 3.2.0 or newer
- Recommended: the built-in Herdr skill, which covers prompting, waiting, reading and dialogs: `npx skills add herdrdev/herdr --skill herdr -g`

## Install

Claude Code:

```bash
claude plugin marketplace add mateo-di/herdr-spawn
claude plugin install herdr-spawn@herdr-spawn
```

A Claude Code session started before a plugin update keeps the skill it loaded until it is restarted, so restart open sessions after updating. `spawn.sh` warns on stderr when it runs from a copy other than the one `installed_plugins.json` records, but only versions that contain that check can warn, so the restart is still needed.

Codex:

```bash
git clone https://github.com/mateo-di/herdr-spawn
ln -s "$PWD/herdr-spawn/skills/herdr-spawn" ~/.codex/skills/herdr-spawn
```

OpenCode:

```bash
git clone https://github.com/mateo-di/herdr-spawn
ln -s "$PWD/herdr-spawn/skills/herdr-spawn" ~/.config/opencode/skills/herdr-spawn
```

## Usage

Ask in natural language:

- "Spawn a codex session next to me to review this branch."
- "Open an opencode pane and have it write the migration tests."
- "Hand this investigation to a new claude session." (writes a handoff doc first)
- "Start three parallel workers, one per package." (writes a lanes doc first)
- "Run these two tickets as driver lanes." (one tab and worktree per ticket; visible subtasks share their ticket's tab)

## Session names and colors

Besides the Herdr name, a child gets `<name>` as its harness's own session name, for ordinary launches and lanes. A failure to name or color never fails the spawn: when herdr-spawn detects it, it warns, and the child starts with its plain launch (a built-in Codex lane continues unnamed instead). The warning is one line; other messages can appear beside it, such as those of the Codex helper and app-server.

| Agent | How it is named | If that fails |
|---|---|---|
| Claude Code | `-n {name}`; a color also needs the print-mode step below | Starts without a color |
| Codex | The thread's name, saved through the app-server before the TUI resumes that thread. Ordinary launches do this only when the shell's `codex` is a plain executable, because an alias or function may use another `CODEX_HOME`. An ordinary launch starts that thread read-only, so naming never trusts the folder, and the resumed TUI handles trust and your sandbox as usual | An ordinary launch starts unnamed; a lane keeps its goal checks and continues unnamed, waiting at most 5 seconds for the name and, after a failed naming, at most 5 more for the app-server to exit |
| OpenCode | A titled session created with `opencode api session.create` (`--standalone` when the TUI uses it) in the child's physical working directory, opened with `--session` when the response has that title and directory. The API call runs the executable, so a shell wrapper's flags apply to the TUI only. A wrapper that switches OpenCode's data directory therefore gets an untitled new session, with no warning | Starts with the default title |
| oh-my-pi | The bundled `adapters/omp/herdr-spawn.ts` extension. Ordinary launches also turn auto-resume off for that launch, so an earlier session is not reopened | Starts unnamed |

Only Claude children get a prompt-bar color; herdr-spawn sets none for Codex, OpenCode or oh-my-pi. `spawn.sh` creates a session ID, sets `/color` on it with `claude -p --safe-mode --setting-sources user` in the child shell, and the TUI resumes that session with `--resume`. This needs the shell's `claude` to be a plain executable: a function or alias cannot be time-limited, so it starts without a color. A session whose transcript is not saved (as with `CLAUDE_CODE_SKIP_PROMPT_HISTORY=1`) starts without a color too, since there is nothing to resume: the child shell looks for it under `${CLAUDE_CONFIG_DIR:-~/.claude}/projects/` first. The color is random and differs from the coordinator's when that is known: the coordinator is Claude Code (`CLAUDE_CODE_SESSION_ID`) and its transcript records one or, failing that, a coordinator request (below) holds one.

A colored Claude child (including a custom `claude ` template that gets a color) and a named Codex child open their session by resuming it, so `SessionStart` hooks that match only `startup` do not run in them, and hooks that match `resume` do. Context a `startup` hook would add is therefore missing from the child's first request. A colored Claude child's history also begins with the `/color` command and its output. A Claude or ordinary Codex child that starts with its plain launch is a new session. A built-in Codex lane is different: it resumes its saved thread whether or not it was named.

The color call and the OpenCode API call are cut off after 20 seconds by `timeout`, which kills a call still running 5 seconds later, or by a `perl` alarm when the caller's host has no `timeout`; where the chosen one cannot run, the child starts with its plain launch. Each call writes to a file in the private startup directory, so a process it leaves running does not keep the launch waiting. The `perl` alarm signals only the process it started: a launcher's hung child can be left running, and a process that ignores the signal is not cut off.

A custom template of any agent gets a color too when it starts with `claude `, the next word does not start with a letter (as in the subcommands `claude agents` or `claude mcp`) and none of its words is `-r`, `--resume`, `-c`, `--continue`, `--session-id`, `--fork-session`, `-p`, `--print`, `--bg`, `--background`, `--cloud`, `--teleport`, `--from-pr`, `-w`, `--worktree`, `--no-session-persistence`, `--environment` or `--desktop` (also as `--flag=value`). Other custom templates run as written, and naming is up to them.

### The coordinator

A Claude Code session that spawns a lane gets a name and a color too; coordinators on other harnesses get neither. Its first lane (`--lane` or `--subtask-of`) requests the name `coord-<repo>`, after the main repository of the caller's directory (the directory's own name outside git), and a color: the one its transcript records if `/color` takes it, otherwise a random one. Lane children avoid the coordinator's color as described above. Ordinary spawns request nothing.

Only the session itself can apply these, so the plugin's mod (`hooks/coordinator-identity.mjs`) does it once the session is idle, running `/rename` and `/color` only for what the session does not have yet; a title Claude Code generates on its own does not count as a name. A request made during a turn is applied after the turn ends (after an interrupted turn, Esc, it was observed still pending), and an unsent draft is left alone.

This needs Claude Code 2.1.326 or newer with mods on and this plugin installed at 3.2.0 or newer; the plain skill folder has no mod. Claude Code 2.1.200 was tested to ignore the mod and still load the plugin's hooks. On 2.1.332, installing or updating the plugin (`claude plugin install` or `update`, and the `/plugin` screen) asked for no approval specific to the mod, only the generic plugin trust warning. A session that is already running gets the mod after the plugin is updated and the session reloads its plugins or restarts.

The request is `herdr-spawn/identity/<session-id>.json` in the state directory (`${XDG_STATE_HOME:-~/.local/state}`), a private file that `spawn.sh` writes once per session and the mod marks `done`. Until then each lane spawn prints the requested name and color on stderr. The coordinator cannot tell from inside whether the mod will run, so it tells you once: if the session's name and color have not changed when the turn ends, you can type `/rename <name>` and `/color <color>`, whichever it lacks. A request that cannot be written or read warns in one line, which has the coordinator tell you that you can type `/rename` and `/color` to set the session's name and color, and never fails the spawn.

## Lanes

A root lane gets a worktree and a new tab of its own:

```bash
spawn.sh --tab /path/to/worktree --lane driver --goal 'Land the migration with verified tests' claude migration root.md
spawn.sh --subtask-of migration --goal 'Add migration test cases' --task simple codex migration-tests tests.md
spawn.sh --subtask-of migration --goal 'Check claims against upstream docs' --task fact-check opencode migration-check check.md
```

`--lane` requires `--tab`; it opens a new tab labelled with the lane name without taking focus. `unit` executes one unit, reviewed by the caller; `driver` owns the overall result and integrates it. A subtask is a `unit` in a separate pane in the root's tab, in the root's original workdir. The original coordinator starts and receives reports from all panes; the root is a placement target, not a new reporting parent. `--subtask-of` accepts a ready, registered root lane's name, pane ID, or hc terminal ID and cannot be combined with `--tab`, `--lane`, or an explicit split. Nested subtasks are rejected.

Upgrading from 1.x: pass `--tab <worktree>` to existing root lane commands. Older lanes keep running, but only roots started with 2.x can host `--subtask-of` panes.

Classify each pane independently. Run work in parallel only when scopes do not overlap and neither task needs the other's result. Serialize writers to shared files or state, and start dependent panes only when their inputs are ready. Do not assign a visible subtask to an invisible background agent as well.

In the Herdr app, `hc` gives a root lane a new tab ID in the coordinator's space. For subtasks it uses the root's `herdr.space` and `herdr.tab` labels, but still uses the original coordinator as `hc --parent`. No GUI command is needed to place the child, even when the window is on another machine. `spawn.sh` then names the new tab after the child with `herdr-app` when `herdr-app` on the same host shows that tab; otherwise the tab keeps its number. `lane.sh done|escalate` sends the notice straight to the coordinator with `hc send` (tagged `<hc from="tN name">`); if the coordinator is busy (a dialog is open), it keeps the new labels, queues the notice in the state dir, and a detached deliverer sends it once the coordinator can take it. `hc` itself notes blocked and exited lanes, a lane that stops without reporting gets a stopped notice from the stop hook, and the stalled notice is TUI-only. In the app, `hc ls` and `hc get <lane>` show lanes and their `lane_*` labels.

Both `--lane` and `--subtask-of` require a non-blank `--goal`. `spawn.sh` exports `LANE_MODE` and `LANE_COORDINATOR` and writes the lane protocol, goal, and caller's brief to `brief.md` in that launch's private `herdr-spawn/goals/<goal_id>/` state directory. Any generated OpenCode lane config lives there too, so reusing a lane name cannot overwrite either file.

The built-in Codex lane starts a new saved thread from the child shell, sets and reads back an active native goal through the Codex app-server, then resumes **that thread** in the pane. The objective is your `--goal` with an instruction to read the absolute path of the composed brief. Codex starts a native goal turn on resume; no positional `/goal` prompt is sent. If goals are disabled in Codex, the goal cannot be verified, or the TUI does not begin pursuing it, startup reports an error and leaves the pane open for inspection. This does not change the coordinator's goal. To set a goal in its own thread, a Codex coordinator can use `create_goal` when explicitly directed by the user, or the user can enter `/goal` in that TUI.

Inspect a lane's original objective and current status with `scripts/lane.sh goal <lane-name|pane-or-terminal>`. It prints JSON and does not send messages or change the lane. Spawn saves the exact `--goal` text in a private, write-once manifest under `herdr-spawn/goals/` in the state directory. Each launch gets a new `goal_id`, even if a lane name is reused; pane tokens and hc labels contain no objective text. Older lanes without a manifest still support the original commands, but `goal` reports that no manifest is available.

```json
{
  "goal_id": "g.AbCdEf012345",
  "objective": "Run the migration tests.\nDone when the results are recorded.",
  "goal_mode": "managed",
  "agent": "opencode",
  "lane_mode": "unit",
  "parent_lane": null,
  "workdir": "/path/to/worktree",
  "task_class": "simple",
  "model": "openai/gpt-6.1-terra",
  "goal_startup": "ready",
  "goal_verification": "not_applicable",
  "goal_status": "active"
}
```

Built-in OpenCode is `managed`; built-in Codex, Claude, and oh-my-pi are `native`; any overridden template is `custom`. `goal_status` follows lane state (`active`, `escalated`, `done`) and can also show `pending`, `failed`, or `blocked` during startup, before the lane explicitly reports. `blocked` means the lane's agent came up waiting on a dialog (such as a folder-trust prompt) that the user must answer in its terminal or pane; `spawn.sh` then prints its usual line, leaves the lane open and exits 3. Only built-in Codex currently verifies native goal startup. For Claude, oh-my-pi, and custom templates, `goal_verification` is `unverified`: `active` describes the lane lifecycle, not proof that the harness accepted a native goal.

A lane declares its state with `scripts/lane.sh`, which sets a `lane_state` pane token (`--lane` starts it at `working`):

- In the lane: `lane.sh done "<one-line summary>" <report file>` when finished (the full report goes in the file), `lane.sh escalate "<one-line summary>" <question file>` to ask its coordinator (the full question, options and recommendation go in the file), `lane.sh working` to resume by itself. `lane.sh` talks to herdr and copies the report file into a private per-user directory under /tmp (mode 600) before setting any state, so a lane whose sandbox cannot write /tmp (Codex read-only) cannot report done; the coordinator's notice names the stored copy, and `done` and `escalate` set the notice text as a `lane_note` token and the watcher announces it.
- In the coordinator: `lane.sh reply <lane> "<answer>"` sends the answer to the lane and sets it back to `working`; after a Herdr server restart, `lane.sh restore` puts back the names and tokens `spawn.sh` recorded for each TUI lane (a lane that calls `lane.sh` first restores itself).

Lanes run heavy checks (builds, type checks, full test suites) through `scripts/heavy.sh <command>`, as the lane protocol tells them. It caps how many run at once across the machine: `HERDR_SPAWN_HEAVY_SLOTS` (default 2) is the same for every lane, and a lane that finds all slots taken waits its turn. Slots live under `/tmp/herdr-spawn-heavy-<uid>`, because a sandboxed Codex lane can write `/tmp`. A slot whose owner stopped refreshing it for two to three minutes is taken over, and if the directory cannot be used the check runs anyway with a warning. A `heavy.sh` call inside a heavy check runs at once, because its caller already holds a slot.

`--lane` also starts one `lanes-watch.sh` per coordinator pane (`lane.sh reply` starts it too if needed). It posts the queued notices into the coordinator as a prompt while the coordinator is idle, and adds `[lane <name>] stopped` (the lane is still `working` but its agent has been idle for `HERDR_SPAWN_STOP_GRACE` seconds, default 60, so it went quiet without reporting), `stalled` (working for `HERDR_SPAWN_STALL_MINUTES`, default 30, without finishing a turn; once per stretch), `blocked` (also a Herdr notification at once), `exited`, and `lost` (the lane's pane still runs its agent but its name and tokens are gone, as after a Herdr restart; run `lane.sh restore`). The live status table:

```bash
herdr agent list | jq '.result.agents[] | select(.tokens.lane_of == env.HERDR_PANE_ID) | {name, agent, agent_status, lane_mode: .tokens.lane_mode, cwd}'
```

### Roles

The skill gives the coordinator its role: keep every lane moving to `done`, answer escalations from what the user already decided, pick the simplest reversible option when nothing does, and go to the user only for decisions that are irreversible, high-impact or never settled. The lane protocol gives each lane its role: work to the goal, report done or escalate, never stop silently, never ask the user directly.

Stop hooks enforce both roles. Each one calls `scripts/lane-stop-check.sh`, which blocks a lane's stop while it is still `working` and a coordinator's while a lane waits on its answer. In Claude Code a working lane may stop while its own background work runs (a shell, a subagent, or a teammate that has not gone idle), since that work's report wakes it. After three blocks in a row it lets the stop through. In Herdr only, and silent otherwise:

| Harness | Hook | Lanes | Coordinators |
|---|---|---|---|
| Claude Code | `hooks/hooks.json` (PreToolUse AskUserQuestion via `hooks/coordinator-ask.sh`, Stop, plus PostToolUse and TeammateIdle to track busy teammates) | with the plugin | with the plugin |
| Codex | `hooks/lane-stop.sh` | add it as a Stop hook in `~/.codex/hooks.json` | same entry |
| OpenCode | `adapters/opencode/herdr-lanes` | loaded by the lane template | add the directory's absolute path to `plugins` in your config |
| oh-my-pi | `adapters/omp/herdr-lanes.ts` | loaded by the lane template | start it with `omp -e <path>` (it finds the check by its own path, so don't copy it) |

In Claude Code, `hooks/coordinator-ask.sh` denies AskUserQuestion while one of the coordinator's lanes is working or escalated, because an open dialog blocks every lane notice; the coordinator asks in plain text instead.

## Coordination

A Claude Code caller with a `claude` child talks to it through SendMessage in both directions. Every other pair uses Herdr (`herdr agent prompt`, `wait`, `read`), as described by the built-in `herdr` skill, or in the Herdr app herdr-core (`hc send`, `wait`, `read`). A child that shows an approval or startup dialog waits for the user to answer it in its pane.

## Configuration

`spawn.sh` launches each agent from a template, with these built-in defaults:

| Agent | Template |
|---|---|
| `claude` | `claude -n {name} {prompt}`, with `--resume <id>` of the colored session |
| `codex` | `codex {prompt}`, or `codex resume` of the named thread with `{prompt}` |
| `opencode` | `opencode --prompt {prompt}`, with `--session <id>` of the titled session |
| `omp` | `HERDR_SPAWN_SESSION_NAME={name} omp --no-title -e {adapters}/omp/herdr-spawn.ts --config {adapters}/omp/herdr-spawn.yml {prompt}` |

For root lanes and subtasks, the `lane:<agent>` template is used instead:

| Lane agent | Template |
|---|---|
| `lane:claude` | `claude -n {name} --append-system-prompt-file {promptfile} {slashgoal}`, with `--resume <id>` of the colored session |
| `lane:codex` | Built-in native goal adapter; resumes the saved thread with `--no-daemon` and `shell_environment_policy.inherit=all` so commands run with the child's `HERDR_*` or `HC_*` variables and `LANE_*` variables |
| `lane:opencode` | `export OPENCODE_CONFIG={occonfig}; opencode --standalone --prompt {prompt}`, with `--session <id>` of the titled session |
| `lane:omp` | `HERDR_SPAWN_SESSION_NAME={name} omp --no-title -e {adapters}/omp/herdr-spawn.ts --goal {goal} --append-system-prompt {promptfile} -e {adapters}/omp/herdr-lanes.ts` |

Override a default or add an agent in `${XDG_CONFIG_HOME:-~/.config}/herdr-spawn/agents.conf` (or the file named by `HERDR_SPAWN_CONFIG`). One entry per line, `<agent> <template>`; blank lines and full-line `#` comments are ignored. `{name}` becomes the child's name and `{prompt}` becomes `"$(cat <prompt-file>)"`. Lane entries use the key `lane:<agent>` and also take `{promptfile}` (its absolute path), `{goal}`, `{slashgoal}` (`/goal <goal> (brief: <promptfile>)`), `{adapters}` (the repo's `adapters/` directory) and `{occonfig}` (an OpenCode config file that loads the lane plugin, written only when the template uses it); each is shell-quoted.

```
# a wrapper script
claude  my-claude-wrapper -n {name} {prompt}
# a shell alias or function works too: the pane's interactive shell resolves it
codex   my-codex-alias {prompt}
# a new agent
gemini  gemini -i {prompt}
```

The line is typed into the pane's interactive shell with `herdr pane run`, which is why wrappers, aliases and functions apply (`herdr agent start` runs the bare executable instead). In the Herdr app the new pane runs it with `$SHELL -ic`, for the same reason. The built-in Codex lane adapter uses the `codex` executable on that shell's `PATH` for both steps. To use a shell alias, function, or custom launch flow instead, set a `lane:codex` entry; that fully replaces the adapter and is responsible for naming and native goal setup. An ordinary launch through an alias or function needs no entry: it starts as `codex {prompt}`, unnamed. Codex treats a positional `/goal …` argument as ordinary text.

### Model routing

`--task <class>` selects a tier per launch. Root drivers default to `complex`; root units and subtasks default to `simple`. Ordinary launches without either routing flag keep their existing model. An explicit `--model <id>` wins over the task class; `--model default` opts out of routing and leaves model choice to the harness or custom launcher.

| Class | Use | Tier | Claude Code | Codex |
|---|---|---|---|---|
| `mechanical` | Unambiguous, repeatable work | `small` | `haiku` | `gpt-6-luna` |
| `simple` | Bounded work with clear tests | `standard` | `sonnet` | `gpt-6.1-terra` |
| `complex` | Cross-cutting work or integration | `strong` | `opus` | `gpt-6.2-sol` |
| `exceptional` | Especially difficult or high-stakes judgment | `frontier` | `fable` | `gpt-6.2-astra` |
| `fact-check` | Independently verify claims and sources | `frontier` | `fable` | `gpt-6.2-astra` |

OpenCode uses the Codex IDs with `openai/` prepended; oh-my-pi uses `openai-codex/`. Herdr Spawn passes the selected model to the harness; it does not verify account access or pick a fallback. Built-in routed OpenCode launches use a private server and merge the selected model into the child shell's `OPENCODE_CONFIG_CONTENT`, keeping the other inline settings; malformed inline JSON aborts the launch.

Override a tier in `agents.conf` with `model:<agent>:<tier> <id>`. Claude aliases depend on the host: on Anthropic, `sonnet` and `opus` resolve to Sonnet 5.5 and Opus 5.5; other hosts may resolve to older versions. Pin a supported ID if the version matters:

```text
model:claude:standard claude-sonnet-5-5
model:claude:strong claude-opus-5-5
model:custom:frontier vendor/model-id
lane:custom my-custom-wrapper {modelarg} --goal {goal} {prompt}
```

Custom templates receive a shell-quoted `{model}` value or an optional `{modelarg}` (`--model <id>`, or no arguments when routing is off). An explicit task or model requires a template that accepts it and, for task routing, a tier mapping. An older wrapper that hard-codes `--model` or picks it itself from `LANE_MODE` keeps its behavior for an implicit class and emits a warning. To migrate, remove the override and use the built-in template, or replace the wrapper's whole fixed or conditional `--model …` pair with `{modelarg}`. If a tool takes a different flag, use its flag with `{model}`.

## Testing lanes

Run `node --test tests/*.test.mjs` and `bash tests/spawn-hc.sh` for startup, placement, model routing, session naming, coordinator identity, and goal lifecycle checks; they use fake agent CLIs, a fake mod host for the coordinator mod and a fake `pi` for the oh-my-pi naming extension, whose tests are skipped where Node cannot import TypeScript. `spawn-hc.sh` needs `perl` and also runs launch lines under zsh when it is installed. With the Codex CLI 0.171.0 executable and util-linux `script` on `PATH`, set `TEST_REAL_CODEX=1` to also test the real app-server and TUI against a loopback model endpoint and verify that disabling goals prevents lane startup. Put the Codex executable ahead of any version-manager shim; the tests use an isolated home and synthetic credentials.

## License

MIT, see [LICENSE](LICENSE).
