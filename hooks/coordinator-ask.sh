#!/usr/bin/env bash
# PreToolUse hook for AskUserQuestion: a coordinator may not open a question dialog while any of its lanes is
# still working or waiting on its answer. While the dialog is open the Herdr app refuses every hc send to this
# terminal, so lane notices queue and the lanes wait for as long as the human takes to answer; in the herdr TUI a
# notice would be typed into the dialog itself. Asking in plain text keeps the terminal free and costs the human
# nothing. Lanes are the terminals (Herdr app) or panes (herdr TUI) whose lane_of names this one, read through
# skills/herdr-spawn/scripts/lanes-of.sh; a done lane does not count, but one whose launch failed does, since an
# agent may still run in its pane. Outside Herdr, or without the CLIs, the question goes through.
# Any pane can set labels and tokens, so a lane must also carry a lane_mode spawn.sh could have written; that
# stops stray matches, not a pane that forges all three, which costs only a plain-text question.
# After a deny the coordinator ends its turn to wait on the human, so this leaves asked-<pane> for
# lane-stop-check.sh, which then lets that one stop through even while a lane waits on an answer.
set -uo pipefail
command -v jq >/dev/null || exit 0

if [ "${HERDR_ENV:-}" = 1 ] && [ -n "${HERDR_PANE_ID:-}" ]; then
  command -v herdr >/dev/null || exit 0
  mode=tui pane=$HERDR_PANE_ID
elif [ "${HERDR_ENV:-}" != 1 ] && [ -n "${HC_TERMINAL_ID:-}" ]; then
  command -v hc >/dev/null || exit 0
  mode=app pane=$HC_TERMINAL_ID
else
  exit 0
fi
lanes=$("$(dirname -- "$0")/../skills/herdr-spawn/scripts/lanes-of.sh" "$mode" "$pane" | jq -r '
  select((.l.lane_mode == "unit" or .l.lane_mode == "driver") and (.l.lane_state == "working" or .l.lane_state == "escalated"))
  | .shown') || exit 0
[ -n "$lanes" ] || exit 0

state=${XDG_STATE_HOME:-$HOME/.local/state}/herdr-spawn
mkdir -p "$state" 2>/dev/null && : >"$state/asked-${pane//[!A-Za-z0-9_-]/_}" 2>/dev/null
jq -cRn '[inputs | select(length > 0)] | (.[:5] | join(", ")) + (if length > 5 then " and \(length - 5) more" else "" end)
  | {hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny",
      permissionDecisionReason: "Lanes still active: \(.). A question dialog here blocks their notices until it is answered. Ask the human in plain text in your reply instead, then end your turn; the answer arrives as the next message."}}' <<<"$lanes"
