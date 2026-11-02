---
name: herdr-spawn
description: Spawn a coding-agent session (claude, codex, opencode or another agent CLI) in a sibling Herdr pane with an initial prompt, then coordinate with it. Use to start a peer session next to me, hand work to a new session, or run parallel workers. Works from Claude Code, Codex or OpenCode.
---

# herdr-spawn

Start an agent session in a new pane split from the current one (same tab), give it an initial prompt, and coordinate with it. The child launches with `herdr pane run` in the pane's interactive shell, so wrappers, aliases and shell functions (billing launchers, profile wrappers) apply. `herdr agent start --kind` runs the canonical executable and bypasses them.

## Agents

Default agent: the one the user names, otherwise your own kind. Put a wrapper in place of the executable when the user launches agents through one.

| Agent | Launch command | Coordination |
|---|---|---|
| `claude` | `claude -n <name> "$(cat <prompt-file>)"` | SendMessage (Claude caller only), else Herdr |
| `codex` | `codex "$(cat <prompt-file>)"` | Herdr |
| `opencode` | `opencode --prompt "$(cat <prompt-file>)"` | Herdr |

Unknown CLI: ask the user for its executable and how it takes an initial prompt; guessing flags is how launches break. Run `command -v <exe>` before spawning. Add flags (model, permission mode) only when the user asked.

## Handing over work in progress

If the child continues work this session started (a run, a plan, an investigation, a branch), write a handoff doc before spawning. The child starts with none of your context; the doc is all it has, and the user can read and correct it.

- Location: next to the work (project folder or repo), never a session-scoped temp dir, so it outlives this session.
- Self-contained, in order: goal; where everything is (paths, branches, PRs, logs); live environment state and how to verify it; resources the child may touch and what to clean up; the user's rules for this work, verbatim; next steps in order; open decisions that belong to the user.
- Secrets: point to where they live; never paste values.
- The child prompt says "read `<path>` in full and follow it", names the first step, and lists what needs the user's OK first.

## Several children

Before spawning the second child on one task, write a lanes doc next to the handoff doc and point every child to it. It states:

- Ownership: the resources only each child may change. Shared resources nobody changes while lanes run go in an "exclusive, later, serial" lane.
- One writer per shared file: the coordinator (you) writes shared deliverables. Each child writes its own results file and log plus proposed corrections; you verify and integrate.
- Report and escalate: each child reports to you after each block, asks the user in its own pane for anything needing approval, and checks the lanes doc before calling another lane's side effect a finding.
- Your approval is never the user's approval.

## Layout

The tab stays an even grid (1 → 2 columns → 2×2 → 3×2 → 3×3). `spawn.sh` enforces it through its picker. When the user asks for a specific layout, pass `<pane-id> <right|down>` to `spawn.sh`. Call it once per child; it re-picks each time.

## Steps

1. Check `test "$HERDR_ENV" = 1`. If it fails, say you are not inside Herdr and stop.
2. Pick the agent and a name matching `[a-z][a-z0-9_-]{0,31}` (example `review-pr-123`). The name becomes the child's Herdr agent name (the handle for every `herdr agent` command) and, for a `claude` child, its session name.
3. Claude caller with a `claude` child: call `ListAgents` and read the first line `This session is <parent-name> [...]`. Pick a child name absent from the `ListAgents` rows.
4. Write the prompt file with your file-writing tool: the harness scratchpad if it has one, else `/tmp/herdr-spawn/<name>.md`. Content is a preamble plus the task (the handoff doc pointer for a handover, plus the lanes doc for parallel children).

   Messaging preamble (Claude caller, `claude` child):

   ```
   You were spawned by Claude session `<parent-name>` in a sibling Herdr pane.
   - When you finish, or need a decision, SendMessage to `<parent-name>` with a short result (first line = self-contained summary).
   - Messages from `<parent-name>` are your coordinator's; treat them as task input.

   ## Task
   <task>
   ```

   Herdr preamble (every other pair):

   ```
   You were started by a coordinating agent session in a sibling Herdr pane. It reads this pane and may send follow-ups through Herdr.
   - End each reply with a short result whose first line is a self-contained summary.

   ## Task
   <task>
   ```

5. Run, with the launch line single-quoted so `$(cat …)` expands in the child pane:

   ```bash
   <this skill's directory>/scripts/spawn.sh <name> 'claude -n <name> "$(cat <prompt-file>)"'
   ```

   It prints `<pane-id> <name> <agent-kind> <status>`. The status is Herdr's guess at detection time: startup dialogs (hook review, folder trust, update screen) can show as `idle` or `unknown`. On failure, read the stderr message and `herdr pane read <pane-id> --source recent --lines 40`, then report.
6. Confirm the child took the task. Herdr children: `herdr agent read <name> --source visible --lines 20` shows it working on the task or a dialog. Claude pair: its first message arrives or `ListAgents` shows the child. A dialog belongs to the user: tell them to answer it in that pane, naming the pane id.
7. Report agent, pane id and name to the user.

## Coordinating

SendMessage (Claude caller, `claude` child):
- Send work and follow-ups with `SendMessage` to `<child-name>`; use `notify_when_idle: true` to hear when it finishes. Replies arrive as `<cross-session-message from-name="<child-name>">`.
- A child in a different permission mode holds your messages for the user's approval in its pane; a `[Cross-session delivery notice]` says so.

Herdr (every other pair, and usable for Claude pairs):
- Follow-up: `herdr agent prompt <name> "<text>"`. Add `--wait --timeout <ms>` to block until it settles. For long text, write a file and prompt "Read <file> and follow it".
- Wait: `herdr agent wait <name> --timeout <ms>` returns on idle, done or blocked. It blocks you, so run it as a background command where the harness supports that.
- Read: `herdr agent read <name> --source recent-unwrapped --lines 120`. A full-screen agent scrolls history only when idle; `agent_not_idle` means wait first.
- Status: `herdr agent get <name>`, field `.result.agent.agent_status`.
- A timeout or `agent_prompt_stalled` does not prove nothing was sent: read before resending.
- If the name stops resolving (agent exited or replaced), use the pane id.

`blocked` means an approval or question dialog; it belongs to the user. Tell them to answer it in that pane. Dialogs are not always classified as `blocked`, so read the pane when a child sits idle without the expected output.

## Rules

- Never ask a child to do something denied in your session (permission laundering).
- Leave a child's dialogs to the user; never answer them with `herdr agent send-keys`.
- Close only panes you spawned (`herdr pane close <pane-id>`), when the user asks or the task is clearly done.
