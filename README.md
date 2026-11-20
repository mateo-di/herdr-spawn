# herdr-spawn

A skill that lets a coding agent spawn another agent session (`claude`, `codex`, `opencode`, `omp` or any CLI you name) in a sibling [Herdr](https://herdr.dev) pane with an initial prompt, keep the tab an even grid, and coordinate with the child afterwards. The caller can be Claude Code, Codex, OpenCode or oh-my-pi. It ships as a Claude Code plugin and as a plain skill folder.

An Opus coordinator in the Herdr app runs two tickets as driver lanes, each in its own tab and worktree. Each lane hands the code to a Sonnet worker and reports done to the coordinator, which checks the work:

![An Opus coordinator spawns two Opus lanes in the Herdr app; each lane runs a Sonnet worker and reports done](docs/demo.gif)

## Requirements

- Herdr 0.9.1 or newer, with the caller running inside a Herdr pane; or the Herdr app, with `herdr-app` and `hc` (herdr-core) on `PATH`
- `jq`
- A bash- or zsh-compatible shell in the pane (the launch line uses `$(cat …)`)
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

In the Herdr app the lane is an `hc` terminal, a child of the coordinator, shown as a tab in its space or in the coordinator's tab without `--tab`; `spawn.sh` launches it through `hc run`. `lane.sh done|escalate` sends the notice straight to the coordinator with `hc send` (tagged `<hc from="tN name">`); `hc` itself notes blocked and exited lanes, a lane that stops without reporting gets a stopped notice from the stop hook, and the stalled notice is TUI-only. In the app, `hc ls` and `hc get <lane>` show lanes and their `lane_*` labels.

`--goal` is required with `--lane` and refused without it, so a lane always has a goal. `spawn.sh` composes the lane's prompt into `herdr-spawn`'s state dir as `lane-<name>.md`: the lane protocol, the goal, then your prompt file.

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

With `--lane`, the `lane:<agent>` template is used instead; each holds the harness to the lane's goal natively (Codex needs `inherit=all` so its shell keeps the `HERDR_*` and `LANE_*` variables `lane.sh` reads):

| Lane agent | Template |
|---|---|
| `lane:claude` | `claude -n {name} --append-system-prompt-file {promptfile} {slashgoal}` |
| `lane:codex` | `codex -c shell_environment_policy.inherit=all {slashgoal}` |
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

The line is typed into the pane's interactive shell with `herdr pane run`, which is why wrappers, aliases and functions apply (`herdr agent start` runs the bare executable instead). In the Herdr app the new pane runs it with `$SHELL -ic`, for the same reason.

## License

MIT, see [LICENSE](LICENSE).
