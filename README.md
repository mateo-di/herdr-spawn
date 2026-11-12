# herdr-spawn

A skill that lets a coding agent spawn another agent session (`claude`, `codex`, `opencode` or any CLI you name) in a sibling [Herdr](https://herdr.dev) pane with an initial prompt, keep the tab an even grid, and coordinate with the child afterwards. The caller can be Claude Code, Codex or OpenCode. It ships as a Claude Code plugin and as a plain skill folder.

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

A child that changes a repo gets its own worktree and its own tab: `spawn.sh --tab <worktree> --lane <unit|driver> <agent> <name> <prompt-file>` opens a tab labelled `<name>` at the worktree without taking focus (herdr TUI or Herdr UI). Its prompt sets `Lane mode: unit` (execute one unit, reviewed by the caller) or `Lane mode: driver` (own a whole task, delegate it to subagents, report the verified result); keep that line even with `--lane`, for harnesses without a gate. `--lane` also exports `LANE_MODE` and `LANE_COORDINATOR` to the lane and tags its pane (the `hierarchical-implementation` gate reads `LANE_MODE`). That gives a three-level hierarchy: the session you talk to, lanes in tabs, and each driver lane's subagents.

`--lane` also starts one `lanes-watch.sh` per coordinator pane. It posts `[lane <name>] done`, `blocked` or `exited` notices into the coordinator as a prompt while the coordinator is idle (a blocked lane also raises a Herdr notification at once). The live status table:

```bash
herdr agent list | jq '.result.agents[] | select(.tokens.lane_of == env.HERDR_PANE_ID) | {name, agent, agent_status, lane_mode: .tokens.lane_mode, cwd}'
```

## Coordination

A Claude Code caller with a `claude` child talks to it through SendMessage in both directions. Every other pair uses Herdr (`herdr agent prompt`, `wait`, `read`), as described by the built-in `herdr` skill, or in the Herdr app herdr-core (`hc send`, `wait`, `read`). A child that shows an approval or startup dialog waits for the user to answer it in its pane.

## Configuration

`spawn.sh` launches each agent from a template, with these built-in defaults:

| Agent | Template |
|---|---|
| `claude` | `claude -n {name} {prompt}` |
| `codex` | `codex {prompt}` |
| `opencode` | `opencode --prompt {prompt}` |

Override a default or add an agent in `${XDG_CONFIG_HOME:-~/.config}/herdr-spawn/agents.conf` (or the file named by `HERDR_SPAWN_CONFIG`). One entry per line, `<agent> <template>`; blank lines and full-line `#` comments are ignored. `{name}` becomes the child's name and `{prompt}` becomes `"$(cat <prompt-file>)"`.

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
