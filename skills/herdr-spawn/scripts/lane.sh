#!/usr/bin/env bash
# Usage (in a lane):        lane.sh done "<summary>" | escalate "<question, options, your recommendation>" | working
#       (in the coordinator): lane.sh reply <lane-name|pane> "<answer>"
# A lane declares its state in the lane_state pane token (working, done, escalated) instead of the watcher
# guessing it, and only talks to herdr: it writes no files, so no harness sandbox can get in the way. done and
# escalate also set lane_note (the text, on one line); every call sets lane_report to a fresh stamp, which is how
# lanes-watch.sh sees a new declaration and queues the notice. reply sends the coordinator's answer to a lane,
# marks it working again and makes sure the coordinator's watcher runs. Needs HERDR_PANE_ID, LANE_COORDINATOR and
# LANE_MODE in a lane (spawn.sh --lane exports the last two).
set -euo pipefail

die() { echo "lane.sh: $*" >&2; exit 1; }
usage="usage: lane.sh done \"<summary>\" | escalate \"<question>\" | working | reply <lane> \"<answer>\""
[ $# -ge 1 ] || die "$usage"
cmd=$1
command -v jq >/dev/null || die "jq is required"

# One report that re-sends lane_of and lane_mode with the state, so it is correct whether a report merges or
# replaces a source's tokens. Further tokens (lane_note) follow as extra arguments.
set_state() { # <pane> <coordinator> <mode> <state> [--token k=v ...]
  local pane=$1 of=$2 mode=$3 state=$4
  shift 4
  herdr pane report-metadata "$pane" --source herdr-spawn --token "lane_of=$of" --token "lane_mode=$mode" \
    --token "lane_state=$state" --token "lane_report=$(date +%s)-$$-$RANDOM" "$@" >/dev/null ||
    die "could not record lane_state=$state on $pane"
}

case $cmd in
  done|escalate)
    [ $# -eq 2 ] && [ -n "$2" ] || die "$usage"
    ;;
  working) [ $# -eq 1 ] || die "$usage" ;;
  reply) [ $# -eq 3 ] && [ -n "$3" ] || die "$usage" ;;
  *) die "$usage" ;;
esac

if [ "$cmd" = reply ]; then
  lane=$2
  info=$(herdr agent get "$lane") || die "no agent $lane"
  read -r pane of mode < <(jq -r '.result.agent | "\(.pane_id) \(.tokens.lane_of // "-") \(.tokens.lane_mode // "-")"' <<<"$info")
  [ "$of" != - ] || die "$lane is not a lane (no lane_of token)"
  herdr agent prompt "$lane" "$3" >/dev/null || die "prompt to $lane was rejected (blocked?)"
  set_state "$pane" "$of" "$mode" working
  statedir=${XDG_STATE_HOME:-$HOME/.local/state}/herdr-spawn
  mkdir -p "$statedir"
  # Detached so the watcher outlives this script; it exits at once if one already runs.
  detach='nohup'
  if command -v setsid >/dev/null; then detach=setsid; fi
  "$detach" "$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)/lanes-watch.sh" "$of" \
    >>"$statedir/watch-${of//[!A-Za-z0-9_-]/_}.log" 2>&1 </dev/null &
  exit 0
fi

: "${HERDR_PANE_ID:?lane.sh $cmd runs inside a lane: HERDR_PANE_ID is not set}"
: "${LANE_COORDINATOR:?lane.sh $cmd runs inside a lane: LANE_COORDINATOR is not set (spawn with --lane)}"
: "${LANE_MODE:?lane.sh $cmd runs inside a lane: LANE_MODE is not set (spawn with --lane)}"

case $cmd in
  working) set_state "$HERDR_PANE_ID" "$LANE_COORDINATOR" "$LANE_MODE" working ;;
  "done") set_state "$HERDR_PANE_ID" "$LANE_COORDINATOR" "$LANE_MODE" "done" --token "lane_note=$(printf '%s' "$2" | tr '\r\n' '  ')" ;;
  escalate) set_state "$HERDR_PANE_ID" "$LANE_COORDINATOR" "$LANE_MODE" escalated --token "lane_note=$(printf '%s' "$2" | tr '\r\n' '  ')" ;;
esac
