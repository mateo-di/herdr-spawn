#!/usr/bin/env bash
# Stop hook for Claude Code and Codex, which read the same block decision: holds a lane or coordinator to its
# role with the reason lane-stop-check.sh prints, and stays silent (lets the stop through) otherwise.
# Claude Code lists in-flight background work in the Stop input (background_tasks). A lane that is waiting on a
# shell, subagent or workflow, or on more running teammates than lane-teammates.sh has marked idle, may stop: that
# work's report wakes it. LANE_PENDING tells lane-stop-check.sh so. Codex sends no such list, so its lanes are held
# as before.
input=$(cat)
pending=''
if [ -n "${LANE_MODE:-}" ] && command -v jq >/dev/null; then
  session=$(jq -r '.session_id // "-" | tostring | gsub("[^A-Za-z0-9_-]"; "_")' <<<"$input" 2>/dev/null) || session=-
  idle=$(find "${XDG_STATE_HOME:-$HOME/.local/state}/herdr-spawn/teammates-$session" -maxdepth 1 -type f 2>/dev/null | wc -l)
  pending=$(jq -r --argjson idle "$idle" '[.background_tasks // [] | arrays | .[] | objects
    | select(.status | IN("running", "pending")) | .type]
    | select(any(IN("shell", "subagent", "workflow")) or (map(select(. == "teammate")) | length) > $idle)
    | length' <<<"$input" 2>/dev/null) || pending=''
fi
reason=$(LANE_PENDING=$pending "$(dirname -- "$0")/../skills/herdr-spawn/scripts/lane-stop-check.sh")
[ -z "$reason" ] || jq -cn --arg r "$reason" '{decision: "block", reason: $r}'
