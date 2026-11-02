# herdr-spawn

A skill that lets a coding agent spawn another agent session (`claude`, `codex`, `opencode` or any CLI you name) in a sibling [Herdr](https://herdr.dev) pane with an initial prompt, keep the tab an even grid, and coordinate with the child afterwards. The caller can be Claude Code, Codex or OpenCode. It ships as a Claude Code plugin and as a plain skill folder.

## Requirements

- Herdr 0.9 or newer, with the caller running inside a Herdr pane
- `jq`

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

A Claude Code caller with a `claude` child talks to it through SendMessage in both directions. Every other pair uses Herdr: `herdr agent prompt` to send follow-ups, `herdr agent wait` to block until the child settles, `herdr agent read` to read its output. A child that shows an approval dialog reports status `blocked`; the user answers it in that pane.

## Wrappers

The child starts with `herdr pane run`, so the pane's shell resolves the command. If you launch agents through a wrapper, alias or shell function, tell the agent to use it in place of the bare executable.

## License

MIT, see [LICENSE](LICENSE).
