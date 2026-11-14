#!/usr/bin/env bash
# Usage: lane-stop-check.sh
# Each harness's stop hook runs this (hooks/ for Claude Code and Codex, adapters/ for OpenCode and oh-my-pi) and
# blocks the stop with what it prints; no output lets the session stop. Checking state in one script keeps the
# roles the same in every harness.
# A lane (LANE_MODE set) ends each stretch of work by reporting done or escalating, so it may not stop while its
# lane_state is still working. A coordinator may not stop while one of its lanes waits on its answer. Working
# lanes never hold a coordinator: waiting idle for notices is its normal state, and the watcher wakes it.
# After three blocks in a row the stop goes through and the watcher's stopped notice takes over, rather than
# spinning the agent. The count starts over when the lane's lane_report token changes (lane.sh, including a
# coordinator's reply, sets a fresh one), so this script keeps the only file and lanes write none.
set -uo pipefail

pane=${HERDR_PANE_ID:-}
{ [ "${HERDR_ENV:-}" = 1 ] && [ -n "$pane" ]; } || exit 0
{ command -v herdr && command -v jq; } >/dev/null || exit 0
dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
state=${XDG_STATE_HOME:-$HOME/.local/state}/herdr-spawn
count=$state/stopblock-${pane//[!A-Za-z0-9_-]/_}

reason='' report=-
if [ -n "${LANE_MODE:-}" ]; then
  read -r st report < <(herdr agent get "$pane" 2>/dev/null |
    jq -r '.result.agent.tokens | "\(.lane_state // "-") \(.lane_report // "-")"') || st=-
  [ "$st" != working ] ||
    reason="You are a lane and have not reported yet. If your goal's done criterion holds and you verified it, run: $dir/lane.sh done \"<result and where it is>\". If you are blocked on something only your coordinator can decide, run: $dir/lane.sh escalate \"<question, options, your recommendation>\". Otherwise keep working toward the goal."
else
  waiting=$(herdr agent list 2>/dev/null | jq -r --arg c "$pane" \
    '[.result.agents[] | select(.tokens.lane_of == $c and .tokens.lane_state == "escalated") | .name] | join(", ")')
  [ -z "$waiting" ] ||
    reason="Lanes waiting on your answer: $waiting. Answer each with: $dir/lane.sh reply <lane> \"<answer>\". Ask the human first only if the decision is critical and was never settled."
fi

if [ -z "$reason" ]; then rm -f "$count"; exit 0; fi
{ read -r n last <"$count"; } 2>/dev/null || n=0
[ "${last:-}" = "$report" ] || n=0
[ "$n" -lt 3 ] || exit 0
mkdir -p "$state"
echo "$((n + 1)) $report" >"$count"
printf '%s\n' "$reason"
