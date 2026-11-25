#!/usr/bin/env bash
# Usage (in a lane):        lane.sh done "<one-line summary>" <report-file>
#                           lane.sh escalate "<one-line summary>" <question-file> | working
#       (in the coordinator): lane.sh reply <lane-name|pane> "<answer>" | goal <lane-name|pane-or-terminal>
# A lane declares its state in the lane_state pane token (working, done, escalated) instead of the watcher
# guessing it, and otherwise only talks to herdr. done and escalate copy the lane's report file into a private
# per-user directory under /tmp before setting any token, so the report outlives its pane and lane_report carries
# the copy's path. Most lane sandboxes can write there (Codex workspace-write includes /tmp); a read-only one
# cannot, and such a lane cannot report done. Both also set lane_note (the summary on one line, capped at 76
# characters plus "..." because herdr cuts a token value at 79 silently); every call sets lane_report afresh (a
# stamp, or that copy's path for done and escalate), which is how lanes-watch.sh sees a new declaration and queues
# the notice. reply sends the coordinator's answer to a lane, marks it working again and makes sure the
# coordinator's watcher runs. Needs HERDR_PANE_ID, LANE_COORDINATOR and LANE_MODE in a lane (spawn.sh --lane
# exports the last two).
# In the Herdr app (HERDR_ENV not 1, HC_TERMINAL_ID set) the same state lives in hc labels on the lane's terminal.
# No watcher runs there, so done and escalate send the notice to the coordinator themselves, and hc notes the
# parent when a child is blocked, errors or exits. Needs HC_TERMINAL_ID, LANE_COORDINATOR and LANE_MODE in a lane.
set -euo pipefail

die() { echo "lane.sh: $*" >&2; exit 1; }
usage="usage: lane.sh done \"<one-line summary>\" <report-file> | escalate \"<one-line summary>\" <question-file> | working | reply <lane> \"<answer>\" | goal <lane-name|pane-or-terminal>"
[ $# -ge 1 ] || die "$usage"
cmd=$1
command -v jq >/dev/null || die "jq is required"
app=0
if [ "${HERDR_ENV:-}" != 1 ] && [ -n "${HC_TERMINAL_ID:-}" ]; then
  app=1
  command -v hc >/dev/null || die "hc is required"
fi
here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)

# One stamp per call. reply and working report it plainly; done and escalate replace it with their report copy.
stamp=$(date +%s)-$$-$RANDOM
report=$stamp

# Copies the lane's report file into a private per-user directory and prints the copy's path. The directory is
# made on every call (age-based /tmp cleaning removes it) and must be ours, a real directory and mode 0700.
store_report() { # <file>
  local src=$1 dir=${HERDR_SPAWN_REPORT_DIR:-/tmp/herdr-spawn-reports-$(id -u)} path size
  [ -f "$src" ] && [ -r "$src" ] || die "report file is not a readable regular file: $src"
  [ -s "$src" ] || die "report file is empty: $src"
  size=$(wc -c <"$src") || die "could not read the report file: $src"
  size=$(printf '%s' "$size" | tr -d '[:space:]')
  [ "$size" -le 262144 ] || die "report file is larger than 262144 bytes: $src"
  # shellcheck disable=SC2174 # only the deepest directory is ours; the check below rejects a wrong mode
  [ -L "$dir" ] || mkdir -p -m 700 "$dir" 2>/dev/null || die "could not create the report directory $dir"
  [ -d "$dir" ] && [ ! -L "$dir" ] && [ -O "$dir" ] &&
    [ -n "$(find "$dir" -prune -perm 0700 -print)" ] ||
    die "the report directory $dir is not private; it must be a real directory owned by you with mode 0700"
  path=$dir/$stamp.md
  [ ${#path} -le 79 ] ||
    die "the report path is ${#path} characters and herdr cuts token values at 79; set HERDR_SPAWN_REPORT_DIR to a shorter directory"
  (umask 077; cp -- "$src" "$path") 2>/dev/null || die "could not copy the report file to $path"
  chmod 600 -- "$path" 2>/dev/null || die "could not restrict the report copy to mode 600: $path"
  printf '%s\n' "$path"
}

# One report that re-sends lane_of and lane_mode with the state, so it is correct whether a report merges or
# replaces a source's tokens. Further tokens (lane_note) follow as extra arguments.
set_state() { # <pane> <coordinator> <mode> <state> [--token k=v ...]
  local pane=$1 of=$2 mode=$3 state=$4
  shift 4
  herdr pane report-metadata "$pane" --source herdr-spawn --token "lane_of=$of" --token "lane_mode=$mode" \
    --token "lane_state=$state" --token "lane_report=$report" "$@" >/dev/null ||
    die "could not record lane_state=$state on $pane"
}

# App-mode twin of set_state: the same labels in one hc call.
app_state() { # <terminal> <coordinator> <mode> <state> [k=v ...]
  local term=$1 of=$2 mode=$3 state=$4
  shift 4
  hc label "$term" "lane_of=$of" "lane_mode=$mode" "lane_state=$state" "lane_report=$report" "$@" >/dev/null ||
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
    [ $# -eq 3 ] && [ -n "$2" ] && [ -n "$3" ] || die "$usage"
    ;;
  working) [ $# -eq 1 ] || die "$usage" ;;
  reply) [ $# -eq 3 ] && [ -n "$3" ] || die "$usage" ;;
  goal) [ $# -eq 2 ] && [ -n "$2" ] || die "$usage" ;;
  *) die "$usage" ;;
esac

if [ "$cmd" = goal ]; then
  lane=$2
  if [ "$app" = 1 ]; then
    # Without the caller address, hc cannot acknowledge the coordinator's child news.
    info=$(unset HC_TERMINAL_ID; hc get "$lane" --json) || die "no terminal $lane"
    metadata=$(jq -c '.labels // {}' <<<"$info")
  elif [[ "$lane" == *:* ]]; then
    info=$(herdr pane get "$lane") || die "no pane $lane"
    metadata=$(jq -c '.result.pane.tokens // {}' <<<"$info")
  else
    info=$(herdr agent get "$lane") || die "no agent $lane"
    metadata=$(jq -c '.result.agent.tokens // {}' <<<"$info")
  fi
  ref=$(jq -r '.goal_id // empty' <<<"$metadata")
  [ -n "$ref" ] || die "$lane has no goal manifest (older lane or not a lane)"
  [[ "$ref" =~ ^g\.[[:alnum:]]{12}$ ]] || die "invalid goal manifest reference on $lane"
  manifest=${XDG_STATE_HOME:-$HOME/.local/state}/herdr-spawn/goals/$ref/goal.json
  [ -r "$manifest" ] || die "goal manifest $ref is not readable for $lane"
  # Startup status only outranks the initial "working" state, not a lane's own report.
  jq -e --argjson meta "$metadata" '
    select(.goal_id == $meta.goal_id and .goal_mode == $meta.goal_mode and (.objective | type) == "string")
    | .goal_startup = ($meta.goal_startup // "unknown")
    | .goal_verification = (if .goal_mode == "managed" then "not_applicable"
        elif .goal_mode == "native" and .agent == "codex" and .goal_startup == "ready" then "verified"
        else "unverified" end)
    | .goal_status = (if $meta.lane_state == "done" or $meta.lane_state == "escalated" then $meta.lane_state
        elif (.goal_startup == "pending" or .goal_startup == "failed")
          and ($meta.lane_report == ("start-" + .goal_id) or $meta.lane_report == null) then .goal_startup
        elif $meta.lane_state == "working" then "active"
        else "unknown" end)
  ' "$manifest" || die "invalid goal manifest $ref for $lane"
  exit 0
fi

if [ "$cmd" = reply ] && [ "$app" = 1 ]; then
  lane=$2
  info=$(hc get "$lane" --json) || die "no terminal $lane"
  read -r term of mode < <(jq -r '"\(.address) \(.labels.lane_of // "-") \(.labels.lane_mode // "-")"' <<<"$info")
  [ "$of" != - ] || die "$lane is not a lane (no lane_of label)"
  app_state "$term" "$of" "$mode" working
  if ! hc send "$term" -- "$3" >/dev/null; then
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
  report=$(store_report "$3") || exit 1
  n=$(note "$2" | tr -d '[:cntrl:]')
  info=$(hc get "$HC_TERMINAL_ID" --json 2>/dev/null) || info='{}'
  name=$(jq -r '.name // empty' <<<"$info" 2>/dev/null) || name=''
  [ -n "$name" ] || name=$HC_TERMINAL_ID
  app_state "$HC_TERMINAL_ID" "$LANE_COORDINATOR" "$LANE_MODE" "$state" "lane_note=$n"
  if [ "$cmd" = "done" ]; then
    msg="[lane $name] done: $n. Read its report: $report"
  else
    msg="[lane $name] escalation: $n. Read the full question: $report; answer with: $here/lane.sh reply $name \"<answer>\""
  fi
  if ! hc send "$LANE_COORDINATOR" -- "$msg" >/dev/null; then
    hc label "$HC_TERMINAL_ID" "lane_state=$(jq -r '.labels.lane_state // "working"' <<<"$info")" \
      "lane_report=$(jq -r '.labels.lane_report // ""' <<<"$info")" \
      "lane_note=$(jq -r '.labels.lane_note // ""' <<<"$info")" >/dev/null || true
    die "the coordinator $LANE_COORDINATOR did not take the notice (blocked or gone?); lane_state is unchanged, run lane.sh $cmd again"
  fi
  exit 0
fi

: "${HERDR_PANE_ID:?lane.sh $cmd runs inside a lane: HERDR_PANE_ID is not set}"
: "${LANE_COORDINATOR:?lane.sh $cmd runs inside a lane: LANE_COORDINATOR is not set (spawn with --lane)}"
: "${LANE_MODE:?lane.sh $cmd runs inside a lane: LANE_MODE is not set (spawn with --lane)}"

if [ "$cmd" != working ]; then
  report=$(store_report "$3") || exit 1
fi

case $cmd in
  working) set_state "$HERDR_PANE_ID" "$LANE_COORDINATOR" "$LANE_MODE" working ;;
  "done") set_state "$HERDR_PANE_ID" "$LANE_COORDINATOR" "$LANE_MODE" "done" --token "lane_note=$(note "$2")" ;;
  escalate) set_state "$HERDR_PANE_ID" "$LANE_COORDINATOR" "$LANE_MODE" escalated --token "lane_note=$(note "$2")" ;;
esac
