#!/usr/bin/env bash
# PreToolUse hook for AskUserQuestion: a coordinator may not open a question dialog while any of its lanes is
# still working or waiting on its answer. While the dialog is open the Herdr app refuses every hc send to this
# terminal, so lane notices queue and the lanes wait for as long as the human takes to answer; in the herdr TUI a
# notice would be typed into the dialog itself. Asking in plain text keeps the terminal free and costs the human
# nothing. Lanes are the terminals (Herdr app) or panes (herdr TUI) whose lane_of names this one, as in
# lane-stop-check.sh; a done lane does not count. Outside Herdr, or without the CLIs, the question goes through.
set -uo pipefail
command -v jq >/dev/null || exit 0

if [ "${HERDR_ENV:-}" = 1 ] && [ -n "${HERDR_PANE_ID:-}" ]; then
  command -v herdr >/dev/null || exit 0
  lanes=$(herdr agent list 2>/dev/null | jq -r --arg c "$HERDR_PANE_ID" '
    [.result.agents[] | select(.tokens.lane_of == $c and (.tokens.lane_state == "working" or .tokens.lane_state == "escalated")) | .name]
    | join(", ")') || exit 0
elif [ "${HERDR_ENV:-}" != 1 ] && [ -n "${HC_TERMINAL_ID:-}" ]; then
  command -v hc >/dev/null || exit 0
  lanes=$(for t in $(hc ls --json 2>/dev/null | jq -r --arg c "$HC_TERMINAL_ID" '.terminals[] | select(.parent == $c) | .address'); do
    hc get "$t" --json 2>/dev/null || : # a lane that ended since hc ls must not hide the others
  done | jq -rs --arg c "$HC_TERMINAL_ID" '
    [.[] | select(.labels.lane_of == $c and (.labels.lane_state == "working" or .labels.lane_state == "escalated")) | .name]
    | join(", ")') || exit 0
else
  exit 0
fi
[ -n "$lanes" ] || exit 0

jq -cn --arg r "Lanes still active: $lanes. A question dialog here blocks their notices until it is answered. Ask the human in plain text in your reply instead, then end your turn; the answer arrives as the next message." \
  '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $r}}'
