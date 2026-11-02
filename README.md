# herdr-spawn

A skill that lets a coding agent spawn another agent session (`claude`, `codex`, `opencode` or any CLI you name) in a sibling [Herdr](https://herdr.dev) pane with an initial prompt, keep the tab an even grid, and coordinate with the child afterwards. The caller can be Claude Code, Codex or OpenCode. It ships as a Claude Code plugin and as a plain skill folder.

## Requirements

- Herdr 0.9.1 or newer, with the caller running inside a Herdr pane
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

## Coordination

A Claude Code caller with a `claude` child talks to it through SendMessage in both directions. Every other pair uses Herdr (`herdr agent prompt`, `wait`, `read`), as described by the built-in `herdr` skill. A child that shows an approval or startup dialog waits for the user to answer it in its pane.

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

The line is typed into the pane's interactive shell with `herdr pane run`, which is why wrappers, aliases and functions apply (`herdr agent start` runs the bare executable instead).

## License

MIT, see [LICENSE](LICENSE).
