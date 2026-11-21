# herdr-spawn

A skill that lets a coding agent spawn another agent session (`claude`, `codex`, `opencode`, `omp` or any CLI you name) in a sibling [Herdr](https://herdr.dev) pane with an initial prompt, keep the tab an even grid, and coordinate with the child afterwards. The caller can be Claude Code, Codex, OpenCode or oh-my-pi. It ships as a Claude Code plugin and as a plain skill folder.

An Opus coordinator in the Herdr app runs two tickets as driver lanes, each in its own tab and worktree. Each lane hands the code to a Sonnet worker and reports done to the coordinator, which checks the work:

![An Opus coordinator spawns two Opus lanes in the Herdr app; each lane runs a Sonnet worker and reports done](docs/demo.gif)

## Requirements

- Herdr 0.9.1 or newer, with the caller running inside a Herdr pane; or the Herdr app, with `hc` (herdr-core) on the caller's `PATH`. To split an explicit pane by ID in the app (without `--lane`), run the command on the window's host with `herdr-app` on `PATH`.
- `jq`
- A bash- or zsh-compatible shell in the pane (the launch line uses `$(cat …)`)
- For built-in Codex lanes only: Codex CLI 0.171.0 (native goal startup verified on this version) and Node.js 18+ on the child shell's `PATH`
- Recommended: the built-in Herdr skill, which covers prompting, waiting, reading and dialogs: `npx skills add herdrdev/herdr --skill herdr -g`

## Install

Claude Code:

```bash
claude plugin marketplace add mateo-di/herdr-spawn
claude plugin install herdr-spawn@herdr-spawn
```

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
- "Run these two tickets as driver lanes." (one tab and worktree per lane; each lane runs its task through subagents with `hierarchical-implementation` and reports its integrated result back)

## Lanes

A child that changes a repo gets its own worktree and its own tab: `spawn.sh --tab <worktree> --lane <unit|driver> --goal "<objective and done criterion>" <agent> <name> <prompt-file>` opens a tab labelled `<name>` at the worktree without taking focus. Its prompt sets `Lane mode: unit` (execute one unit, reviewed by the caller) or `Lane mode: driver` (own a whole task, delegate it to subagents, report the verified result); keep that line even with `--lane`, for harnesses without a gate. `--lane` also exports `LANE_MODE` and `LANE_COORDINATOR` to the lane and tags its pane (the `hierarchical-implementation` gate reads `LANE_MODE`). That gives a three-level hierarchy: the session you talk to, lanes in tabs, and each driver lane's subagents.

In the Herdr app the lane is an `hc` terminal, a child of the coordinator, shown as a tab in its space or in the coordinator's tab without `--tab`. `spawn.sh` reads the coordinator's `herdr.space` label from `hc` and either reuses `herdr.tab` or assigns a new tab ID with `--tab`. It launches on the coordinator's host, even when the window is on another machine. `lane.sh done|escalate` sends the notice straight to the coordinator with `hc send` (tagged `<hc from="tN name">`); `hc` itself notes blocked and exited lanes, a lane that stops without reporting gets a stopped notice from the stop hook, and the stalled notice is TUI-only. In the app, `hc ls` and `hc get <lane>` show lanes and their `lane_*` labels.

`--goal` requires a non-blank objective and is only accepted with `--lane`. `spawn.sh` writes the lane protocol, goal, and your prompt file to `brief.md` in that launch's private `herdr-spawn/goals/<goal_id>/` state directory. Any generated OpenCode config lives there too, so reusing a lane name cannot overwrite either file.

The built-in Codex lane starts a new saved thread from the child shell, sets and reads back an active native goal through the Codex app-server, then resumes **that thread** in the pane. The objective is your `--goal` with an instruction to read the absolute path of the composed brief. Codex starts a native goal turn on resume; no positional `/goal` prompt is sent. If goals are disabled in Codex, the goal cannot be verified, or the TUI does not begin pursuing it, startup reports an error and leaves the pane open for inspection. This does not change the coordinator's goal. To set a goal in its own thread, a Codex coordinator can use `create_goal` when explicitly directed by the user, or the user can enter `/goal` in that TUI.

Inspect a lane's original objective and current status with `scripts/lane.sh goal <lane-name|pane-or-terminal>`. It prints JSON and does not send messages or change the lane. Spawn saves the exact `--goal` text in a private, write-once manifest under `herdr-spawn/goals/` in the state directory. Each launch gets a new `goal_id`, even if a lane name is reused; pane tokens and hc labels contain no objective text. Older lanes without a manifest still support the original commands, but `goal` reports that no manifest is available.

```json
{
  "goal_id": "g.AbCdEf012345",
  "objective": "Run the migration tests.\nDone when the results are recorded.",
  "goal_mode": "managed",
  "agent": "opencode",
  "lane_mode": "unit",
  "goal_startup": "ready",
  "goal_verification": "not_applicable",
  "goal_status": "active"
}
```

Built-in OpenCode is `managed`; built-in Codex, Claude, and oh-my-pi are `native`; any overridden template is `custom`. `goal_status` follows lane state (`active`, `escalated`, `done`) and can also show `pending` or `failed` during startup, before the lane explicitly reports. Only built-in Codex currently verifies native goal startup. For Claude, oh-my-pi, and custom templates, `goal_verification` is `unverified`: `active` describes the lane lifecycle, not proof that the harness accepted a native goal.

A lane declares its state with `scripts/lane.sh`, which sets a `lane_state` pane token (`--lane` starts it at `working`):

- In the lane: `lane.sh done "<one-line summary>"` when finished (the full report goes in the lane's reply), `lane.sh escalate "<one-line summary>"` to ask its coordinator (the full question, options and recommendation go in the reply), `lane.sh working` to resume by itself. `lane.sh` only talks to herdr and writes no files, so no harness sandbox blocks it; `done` and `escalate` set the notice text as a `lane_note` token and the watcher announces it.
- In the coordinator: `lane.sh reply <lane> "<answer>"` sends the answer to the lane and sets it back to `working`.

`--lane` also starts one `lanes-watch.sh` per coordinator pane (`lane.sh reply` starts it too if needed). It posts the queued notices into the coordinator as a prompt while the coordinator is idle, and adds `[lane <name>] stopped` (the lane is still `working` but its agent has been idle for `HERDR_SPAWN_STOP_GRACE` seconds, default 60, so it went quiet without reporting), `stalled` (working for `HERDR_SPAWN_STALL_MINUTES`, default 30, without finishing a turn; once per stretch), `blocked` (also a Herdr notification at once) and `exited`. The live status table:

```bash
herdr agent list | jq '.result.agents[] | select(.tokens.lane_of == env.HERDR_PANE_ID) | {name, agent, agent_status, lane_mode: .tokens.lane_mode, cwd}'
```

### Roles

The skill gives the coordinator its role: keep every lane moving to `done`, answer escalations from what the user already decided, pick the simplest reversible option when nothing does, and go to the user only for decisions that are irreversible, high-impact or never settled. The lane protocol gives each lane its role: work to the goal, report done or escalate, never stop silently, never ask the user directly.

Stop hooks enforce both roles. Each one calls `scripts/lane-stop-check.sh`, which blocks a lane's stop while it is still `working` and a coordinator's while a lane waits on its answer. In Claude Code a working lane may stop while its own background work runs (a shell, a subagent, or a teammate that has not gone idle), since that work's report wakes it. After three blocks in a row it lets the stop through. In Herdr only, and silent otherwise:

| Harness | Hook | Lanes | Coordinators |
|---|---|---|---|
| Claude Code | `hooks/hooks.json` (Stop, plus PostToolUse and TeammateIdle to track busy teammates) | with the plugin | with the plugin |
| Codex | `hooks/lane-stop.sh` | add it as a Stop hook in `~/.codex/hooks.json` | same entry |
| OpenCode | `adapters/opencode/herdr-lanes` | loaded by the lane template | add the directory's absolute path to `plugins` in your config |
| oh-my-pi | `adapters/omp/herdr-lanes.ts` | loaded by the lane template | start it with `omp -e <path>` (it finds the check by its own path, so don't copy it) |

## Coordination

A Claude Code caller with a `claude` child talks to it through SendMessage in both directions. Every other pair uses Herdr (`herdr agent prompt`, `wait`, `read`), as described by the built-in `herdr` skill, or in the Herdr app herdr-core (`hc send`, `wait`, `read`). A child that shows an approval or startup dialog waits for the user to answer it in its pane.

## Configuration

`spawn.sh` launches each agent from a template, with these built-in defaults:

| Agent | Template |
|---|---|
| `claude` | `claude -n {name} {prompt}` |
| `codex` | `codex {prompt}` |
| `opencode` | `opencode --prompt {prompt}` |
| `omp` | `omp {prompt}` |

With `--lane`, the `lane:<agent>` template is used instead:

| Lane agent | Template |
|---|---|
| `lane:claude` | `claude -n {name} --append-system-prompt-file {promptfile} {slashgoal}` |
| `lane:codex` | Built-in native goal adapter; resumes the saved thread with `--no-daemon` and `shell_environment_policy.inherit=all` so commands run with the child's `HERDR_*` or `HC_*` variables and `LANE_*` variables |
| `lane:opencode` | `export OPENCODE_CONFIG={occonfig}; opencode --standalone --prompt {prompt}` |
| `lane:omp` | `omp --goal {goal} --append-system-prompt {promptfile} -e {adapters}/omp/herdr-lanes.ts` |

Override a default or add an agent in `${XDG_CONFIG_HOME:-~/.config}/herdr-spawn/agents.conf` (or the file named by `HERDR_SPAWN_CONFIG`). One entry per line, `<agent> <template>`; blank lines and full-line `#` comments are ignored. `{name}` becomes the child's name and `{prompt}` becomes `"$(cat <prompt-file>)"`. Lane entries use the key `lane:<agent>` and also take `{promptfile}` (its absolute path), `{goal}`, `{slashgoal}` (`/goal <goal> (brief: <promptfile>)`), `{adapters}` (the repo's `adapters/` directory) and `{occonfig}` (an OpenCode config file that loads the lane plugin, written only when the template uses it); each is shell-quoted.

```
# a wrapper script
claude  my-claude-wrapper -n {name} {prompt}
# a shell alias or function works too: the pane's interactive shell resolves it
codex   my-codex-alias {prompt}
# a new agent
gemini  gemini -i {prompt}
```

The line is typed into the pane's interactive shell with `herdr pane run`, which is why wrappers, aliases and functions apply (`herdr agent start` runs the bare executable instead). In the Herdr app the new pane runs it with `$SHELL -ic`, for the same reason. The built-in Codex lane adapter uses the `codex` executable on that shell's `PATH` for both steps. To use a shell alias, function, or custom launch flow instead, set a `lane:codex` entry; that fully replaces the adapter and is responsible for native goal setup. Codex treats a positional `/goal …` argument as ordinary text.

## Testing lanes

Run `node --test tests/*.test.mjs` for the startup and goal lifecycle checks. With the Codex CLI 0.171.0 executable and util-linux `script` on `PATH`, set `TEST_REAL_CODEX=1` to also test the real TUI against a loopback model endpoint and verify that disabling goals prevents startup. Put the Codex executable ahead of any version-manager shim; the tests use an isolated home and synthetic credentials.

## License

MIT, see [LICENSE](LICENSE).
