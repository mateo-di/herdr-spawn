#!/usr/bin/env bash
# Usage (in a lane):        lane.sh done "<summary>" | escalate "<question, options, your recommendation>" | working
#       (in the coordinator): lane.sh reply <lane-name|pane> "<answer>"
# A lane declares its state in the lane_state pane token (working, done, escalated) instead of the watcher
# guessing it. done and escalate also queue one notice for the coordinator, in the file lanes-watch.sh delivers
# while the coordinator is idle, and make sure that watcher runs. reply sends the coordinator's answer to a lane
# and marks it working again. Needs HERDR_PANE_ID, LANE_COORDINATOR and LANE_MODE in a lane (spawn.sh --lane
# exports the last two).
set -euo pipefail

die() { echo "lane.sh: $*" >&2; exit 1; }
usage="usage: lane.sh done \"<summary>\" | escalate \"<question>\" | working | reply <lane> \"<answer>\""
[ $# -ge 1 ] || die "$usage"
cmd=$1
command -v jq >/dev/null || die "jq is required"

# Re-sends all three tokens: correct whether a report merges or replaces a source's tokens.
set_state() { # <pane> <coordinator> <mode> <state>
  herdr pane report-metadata "$1" --source herdr-spawn --token "lane_of=$2" --token "lane_mode=$3" \
    --token "lane_state=$4" >/dev/null || die "could not record lane_state=$4 on $1"
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
  exit 0
fi

: "${HERDR_PANE_ID:?lane.sh $cmd runs inside a lane: HERDR_PANE_ID is not set}"
: "${LANE_COORDINATOR:?lane.sh $cmd runs inside a lane: LANE_COORDINATOR is not set (spawn with --lane)}"
: "${LANE_MODE:?lane.sh $cmd runs inside a lane: LANE_MODE is not set (spawn with --lane)}"

case $cmd in
  working) state=working ;;
  "done") state="done" ;;
  escalate) state=escalated ;;
esac
set_state "$HERDR_PANE_ID" "$LANE_COORDINATOR" "$LANE_MODE" "$state"
[ "$cmd" != working ] || exit 0

name=$(herdr agent get "$HERDR_PANE_ID" | jq -r '.result.agent.name // empty')
[ -n "$name" ] || die "this pane has no agent name; was it spawned by spawn.sh?"
text=$(printf '%s' "$2" | tr '\n' ' ')
statedir=${XDG_STATE_HOME:-$HOME/.local/state}/herdr-spawn
mkdir -p "$statedir"
key=${LANE_COORDINATOR//[!A-Za-z0-9_-]/_}
if [ "$cmd" = "done" ]; then
  printf '[lane %s] done: %s. Read its report: herdr agent read %s --source recent-unwrapped --lines 120\n' "$name" "$text" "$name"
else
  printf '[lane %s] escalation: %s. Answer with: lane.sh reply %s "<answer>"\n' "$name" "$text" "$name"
fi >>"$statedir/queue-$key.txt"

watch=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)/lanes-watch.sh
detach='nohup'
if command -v setsid >/dev/null; then detach=setsid; fi
"$detach" "$watch" "$LANE_COORDINATOR" >>"$statedir/watch-$key.log" 2>&1 </dev/null &
