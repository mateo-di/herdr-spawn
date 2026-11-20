#!/usr/bin/env bash
# PostToolUse (SendMessage) and TeammateIdle hook for Claude Code lanes. A named background worker runs as an
# in-process teammate, and Claude Code lists it in the Stop input's background_tasks as running even after it goes
# idle, so lane-stop.sh cannot tell from that list alone whether the worker will still wake the lane. This keeps an
# idle marker per teammate for lane-stop.sh to count: TeammateIdle writes it, and a message to that teammate
# removes it. A spawn leaves markers alone, so an idle that lands before the spawn's own hook is never erased: a
# leftover marker can only hold the lane, never let it through.
[ -n "${LANE_MODE:-}" ] || exit 0
command -v jq >/dev/null || exit 0
read -r event session name < <(jq -r '[.hook_event_name, (.session_id // "-"), (.teammate_name // .tool_input.to // "")]
  | map(tostring | gsub("[^A-Za-z0-9_-]"; "_") | if . == "" then "-" else . end) | join(" ")') || exit 0
[ "$name" != - ] || exit 0
dir=${XDG_STATE_HOME:-$HOME/.local/state}/herdr-spawn/teammates-$session
case $event in
  TeammateIdle) mkdir -p "$dir" && touch "$dir/$name" ;;
  PostToolUse) rm -f "$dir/$name" ;;
esac
exit 0
