#!/usr/bin/env bash
# Usage (in a lane):        lane.sh done "<one-line summary>" | escalate "<one-line summary>" | working
#       (in the coordinator): lane.sh reply <lane-name|pane> "<answer>"
# A lane declares its state in the lane_state pane token (working, done, escalated) instead of the watcher
# guessing it, and only talks to herdr: it writes no files, so no harness sandbox can get in the way. done and
# escalate also set lane_note (the summary on one line, capped at 76 characters plus "..." because herdr cuts a
# token value at 79 silently); every call sets lane_report to a fresh stamp, which is how lanes-watch.sh sees a
# new declaration and queues the notice. reply sends the coordinator's answer to a lane, marks it working again
# and makes sure the coordinator's watcher runs. Needs HERDR_PANE_ID, LANE_COORDINATOR and LANE_MODE in a lane
# (spawn.sh --lane exports the last two).
# In the Herdr app (HERDR_ENV not 1, HC_TERMINAL_ID set) the same state lives in hc labels on the lane's terminal.
# No watcher runs there, so done and escalate send the notice to the coordinator themselves, and hc notes the
# parent when a child is blocked, errors or exits. Needs HC_TERMINAL_ID, LANE_COORDINATOR and LANE_MODE in a lane.
set -euo pipefail

die() { echo "lane.sh: $*" >&2; exit 1; }
usage="usage: lane.sh done \"<one-line summary>\" | escalate \"<one-line summary>\" | working | reply <lane> \"<answer>\""
[ $# -ge 1 ] || die "$usage"
cmd=$1
command -v jq >/dev/null || die "jq is required"
app=0
if [ "${HERDR_ENV:-}" != 1 ] && [ -n "${HC_TERMINAL_ID:-}" ]; then
  app=1
  command -v hc >/dev/null || die "hc is required"
fi
here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)

# One report that re-sends lane_of and lane_mode with the state, so it is correct whether a report merges or
# replaces a source's tokens. Further tokens (lane_note) follow as extra arguments.
set_state() { # <pane> <coordinator> <mode> <state> [--token k=v ...]
  local pane=$1 of=$2 mode=$3 state=$4
  shift 4
  herdr pane report-metadata "$pane" --source herdr-spawn --token "lane_of=$of" --token "lane_mode=$mode" \
    --token "lane_state=$state" --token "lane_report=$(date +%s)-$$-$RANDOM" "$@" >/dev/null ||
    die "could not record lane_state=$state on $pane"
}

# App-mode twin of set_state: the same labels in one hc call.
app_state() { # <terminal> <coordinator> <mode> <state> [k=v ...]
  local term=$1 of=$2 mode=$3 state=$4
  shift 4
  hc label "$term" "lane_of=$of" "lane_mode=$mode" "lane_state=$state" "lane_report=$(date +%s)-$$-$RANDOM" "$@" >/dev/null ||
    die "could not record lane_state=$state on $term"
}

# One line, capped so herdr's silent cut at 79 characters shows as "...".
note() {
  local t
  t=$(printf '%s' "$1" | tr '\r\n' '  ')
  if [ ${#t} -gt 79 ]; then t="${t:0:76}..."; fi
  printf '%s' "$t"
}

case $cmd in
  done|escalate)
    [ $# -eq 2 ] && [ -n "$2" ] || die "$usage"
    ;;
  working) [ $# -eq 1 ] || die "$usage" ;;
  reply) [ $# -eq 3 ] && [ -n "$3" ] || die "$usage" ;;
  *) die "$usage" ;;
esac

if [ "$cmd" = reply ] && [ "$app" = 1 ]; then
  lane=$2
  info=$(hc get "$lane" --json) || die "no terminal $lane"
  read -r term of mode < <(jq -r '"\(.address) \(.labels.lane_of // "-") \(.labels.lane_mode // "-")"' <<<"$info")
  [ "$of" != - ] || die "$lane is not a lane (no lane_of label)"
  app_state "$term" "$of" "$mode" working
  if ! hc send "$term" "$3" >/dev/null; then
    hc label "$term" "lane_state=$(jq -r '.labels.lane_state // ""' <<<"$info")" \
      "lane_report=$(jq -r '.labels.lane_report // ""' <<<"$info")" \
      "lane_note=$(jq -r '.labels.lane_note // ""' <<<"$info")" >/dev/null || true
    die "send to $lane was rejected (blocked?); its state is unchanged"
  fi
  exit 0
fi

if [ "$cmd" = reply ]; then
  lane=$2
  info=$(herdr agent get "$lane") || die "no agent $lane"
  read -r pane of mode < <(jq -r '.result.agent | "\(.pane_id) \(.tokens.lane_of // "-") \(.tokens.lane_mode // "-")"' <<<"$info")
  [ "$of" != - ] || die "$lane is not a lane (no lane_of token)"
  # Working first, so the watcher never sees the answered lane as still escalated or done; undone if the prompt fails.
  set_state "$pane" "$of" "$mode" working
  if ! herdr agent prompt "$lane" "$3" >/dev/null; then
    herdr pane report-metadata "$pane" --source herdr-spawn --token "lane_of=$of" --token "lane_mode=$mode" \
      --token "lane_state=$(jq -r '.result.agent.tokens.lane_state // ""' <<<"$info")" \
      --token "lane_report=$(jq -r '.result.agent.tokens.lane_report // ""' <<<"$info")" \
      --token "lane_note=$(jq -r '.result.agent.tokens.lane_note // ""' <<<"$info")" >/dev/null || true
    die "prompt to $lane was rejected (blocked?); its state is unchanged"
  fi
  statedir=${XDG_STATE_HOME:-$HOME/.local/state}/herdr-spawn
  mkdir -p "$statedir"
  # Detached so the watcher outlives this script; it exits at once if one already runs.
  detach='nohup'
  if command -v setsid >/dev/null; then detach=setsid; fi
  "$detach" "$here/lanes-watch.sh" "$of" \
    >>"$statedir/watch-${of//[!A-Za-z0-9_-]/_}.log" 2>&1 </dev/null &
  exit 0
fi

if [ "$app" = 1 ]; then
  : "${LANE_COORDINATOR:?lane.sh $cmd runs inside a lane: LANE_COORDINATOR is not set (spawn with --lane)}"
  : "${LANE_MODE:?lane.sh $cmd runs inside a lane: LANE_MODE is not set (spawn with --lane)}"
  if [ "$cmd" = working ]; then
    app_state "$HC_TERMINAL_ID" "$LANE_COORDINATOR" "$LANE_MODE" working
    exit 0
  fi
  state="done"
  if [ "$cmd" = escalate ]; then state=escalated; fi
  n=$(note "$2")
  app_state "$HC_TERMINAL_ID" "$LANE_COORDINATOR" "$LANE_MODE" "$state" "lane_note=$n"
  name=$(hc get "$HC_TERMINAL_ID" --json 2>/dev/null | jq -r '.name // empty' 2>/dev/null) || name=''
  [ -n "$name" ] || name=$HC_TERMINAL_ID
  n=$(printf '%s' "$2" | tr '\r\n' '  ')
  if [ "$cmd" = "done" ]; then
    msg="[lane $name] done: $n. Read its report: hc read $name --lines 120"
  else
    msg="[lane $name] escalation: $n. Read the full question: hc read $name --lines 80; answer with: $here/lane.sh reply $name \"<answer>\""
  fi
  hc send "$LANE_COORDINATOR" "$msg" >/dev/null ||
    die "lane_state=$state is recorded, but the coordinator $LANE_COORDINATOR was not told"
  exit 0
fi

: "${HERDR_PANE_ID:?lane.sh $cmd runs inside a lane: HERDR_PANE_ID is not set}"
: "${LANE_COORDINATOR:?lane.sh $cmd runs inside a lane: LANE_COORDINATOR is not set (spawn with --lane)}"
: "${LANE_MODE:?lane.sh $cmd runs inside a lane: LANE_MODE is not set (spawn with --lane)}"

case $cmd in
  working) set_state "$HERDR_PANE_ID" "$LANE_COORDINATOR" "$LANE_MODE" working ;;
  "done") set_state "$HERDR_PANE_ID" "$LANE_COORDINATOR" "$LANE_MODE" "done" --token "lane_note=$(note "$2")" ;;
  escalate) set_state "$HERDR_PANE_ID" "$LANE_COORDINATOR" "$LANE_MODE" escalated --token "lane_note=$(note "$2")" ;;
esac
