#!/usr/bin/env bash
# Usage (in a lane):        lane.sh done "<one-line summary>" | escalate "<one-line summary>" | working
#       (in the coordinator): lane.sh reply <lane-name|pane> "<answer>" | goal <lane-name|pane-or-terminal> | restore
# A lane declares its state in the lane_state pane token (working, done, escalated) instead of the watcher
# guessing it, and only talks to herdr: it writes no files, so no harness sandbox can get in the way. done and
# escalate also set lane_note (the summary on one line, capped at 76 characters plus "..." because herdr cuts a
# token value at 79 silently); every call sets lane_report to a fresh stamp, which is how lanes-watch.sh sees a
# new declaration and queues the notice. reply sends the coordinator's answer to a lane, marks it working again
# and makes sure the coordinator's watcher runs. Needs HERDR_PANE_ID, LANE_COORDINATOR and LANE_MODE in a lane
# (spawn.sh --lane exports the last two). spawn.sh records each TUI lane in goals/<id>/lane.json with its Herdr
# agent_session; a Herdr restart drops the names, tokens and the lane's LANE_* exports, so restore re-applies them
# in the coordinator, and a lane without the exports reads its pane tokens or restores itself from that record.
# In the Herdr app (HERDR_ENV not 1, HC_TERMINAL_ID set) the same state lives in hc labels on the lane's terminal.
# No watcher runs there, so done and escalate send the notice to the coordinator themselves, and hc notes the
# parent when a child is blocked, errors or exits. Needs HC_TERMINAL_ID, LANE_COORDINATOR and LANE_MODE in a lane.
set -euo pipefail

die() { echo "lane.sh: $*" >&2; exit 1; }
usage="usage: lane.sh done \"<one-line summary>\" | escalate \"<one-line summary>\" | working | reply <lane> \"<answer>\" | goal <lane-name|pane-or-terminal> | restore"
[ $# -ge 1 ] || die "$usage"
cmd=$1
command -v jq >/dev/null || die "jq is required"
app=0
touched=0
if [ "${HERDR_ENV:-}" != 1 ] && [ -n "${HC_TERMINAL_ID:-}" ]; then
  app=1
  command -v hc >/dev/null || die "hc is required"
fi
here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
statedir=${XDG_STATE_HOME:-$HOME/.local/state}/herdr-spawn

# One report that re-sends lane_of and lane_mode with the state, so it is correct whether a report merges or
# replaces a source's tokens. Further tokens (lane_note) follow as extra arguments.
set_state() { # <pane> <coordinator> <mode> <state> [--token k=v ...]
  local pane=$1 of=$2 mode=$3 state=$4
  shift 4
  herdr pane report-metadata "$pane" --source herdr-spawn --token "lane_of=$of" --token "lane_mode=$mode" \
    --token "lane_state=$state" --token "lane_report=$(date +%s)-$$-$RANDOM" "$@" >/dev/null ||
    die "could not record lane_state=$state on $pane"
}

# One watcher per coordinator pane: detached so it outlives this script, and a no-op if one already runs.
start_watcher() { # <coordinator>
  local of=$1 detach=nohup
  mkdir -p "$statedir"
  if command -v setsid >/dev/null; then detach=setsid; fi
  "$detach" "$here/lanes-watch.sh" "$of" \
    >>"$statedir/watch-${of//[!A-Za-z0-9_-]/_}.log" 2>&1 </dev/null &
}

# Re-apply a recorded lane's name and tokens to its surviving pane, using one `herdr agent list` snapshot.
restore_one() { # <lane.json> <agents-json>
  local record_file=$1 agents=$2 dir record name session count pane goal_mode of mode
  dir=${record_file%/*}
  # A lane record is a private, write-once file in a private goal directory.
  [[ ${dir##*/} =~ ^g\.[[:alnum:]]{12}$ ]] || return 0
  [ ! -L "$dir" ] && [ -O "$dir" ] && [ ! -L "$record_file" ] && [ -O "$record_file" ] || return 0
  record=$(jq -c 'select((.name | type) == "string" and (.lane_of | type) == "string"
    and (.lane_mode | type) == "string" and (.lane_mode == "unit" or .lane_mode == "driver"))' \
    "$record_file" 2>/dev/null) || record=
  [ -n "$record" ] || return 0
  name=$(jq -r '.name' <<<"$record")
  if jq -e --arg name "$name" 'any(.result.agents[]?; .name == $name)' <<<"$agents" >/dev/null; then
    echo "$name: present"
    touched=1
    return 0
  fi
  session=$(jq -r '.agent_session // empty' <<<"$record")
  if [ -z "$session" ]; then
    echo "$name: cannot restore, no agent_session recorded"
    return 0
  fi
  count=$(jq -r --arg s "$session" '[.result.agents[]? | select(.agent_session.value == $s)] | length' <<<"$agents")
  case $count in
    0) echo "$name: not running"; return 0 ;;
    1) pane=$(jq -r --arg s "$session" '.result.agents[]? | select(.agent_session.value == $s) | .pane_id' <<<"$agents") ;;
    *) echo "$name: ambiguous, $count panes share its session"; return 0 ;;
  esac
  [ -n "$pane" ] || return 0
  goal_mode=$(jq -r '.goal_mode // empty' "$dir/goal.json" 2>/dev/null) || goal_mode=
  [ -n "$goal_mode" ] || return 0
  of=$(jq -r '.lane_of' <<<"$record")
  mode=$(jq -r '.lane_mode' <<<"$record")
  herdr agent rename "$pane" "$name" >/dev/null || die "could not rename $pane to $name"
  herdr pane report-metadata "$pane" --source herdr-spawn-goal --token "goal_id=${dir##*/}" \
    --token "goal_mode=$goal_mode" --token goal_startup=ready >/dev/null ||
    die "could not record goal metadata on $pane"
  set_state "$pane" "$of" "$mode" working
  echo "$name: restored on $pane"
  touched=1
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
  goal) [ $# -eq 2 ] && [ -n "$2" ] || die "$usage" ;;
  restore) [ $# -eq 1 ] || die "$usage" ;;
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
  start_watcher "$of"
  exit 0
fi

if [ "$cmd" = restore ]; then
  [ "$app" = 0 ] || die "lane.sh restore works in the herdr TUI only"
  : "${HERDR_PANE_ID:?lane.sh restore needs HERDR_PANE_ID, the coordinator pane}"
  agents=$(herdr agent list) || die "could not list agents"
  for record in "$statedir"/goals/g.*/lane.json; do
    [ -f "$record" ] || continue
    of=$(jq -r '.lane_of // empty' "$record" 2>/dev/null) || of=
    [ "$of" = "$HERDR_PANE_ID" ] || continue
    restore_one "$record" "$agents"
  done
  [ "$touched" = 0 ] || start_watcher "$HERDR_PANE_ID"
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
  n=$(note "$2" | tr -d '[:cntrl:]')
  info=$(hc get "$HC_TERMINAL_ID" --json 2>/dev/null) || info='{}'
  name=$(jq -r '.name // empty' <<<"$info" 2>/dev/null) || name=''
  [ -n "$name" ] || name=$HC_TERMINAL_ID
  app_state "$HC_TERMINAL_ID" "$LANE_COORDINATOR" "$LANE_MODE" "$state" "lane_note=$n"
  if [ "$cmd" = "done" ]; then
    msg="[lane $name] done: $n. Read its report: hc read $name --lines 120"
  else
    msg="[lane $name] escalation: $n. Read the full question: hc read $name --lines 80; answer with: $here/lane.sh reply $name \"<answer>\""
  fi
  if ! hc send "$LANE_COORDINATOR" -- "$msg" >/dev/null; then
    hc label "$HC_TERMINAL_ID" "lane_state=$(jq -r '.labels.lane_state // "working"' <<<"$info")" \
      "lane_report=$(jq -r '.labels.lane_report // ""' <<<"$info")" \
      "lane_note=$(jq -r '.labels.lane_note // ""' <<<"$info")" >/dev/null || true
    die "the coordinator $LANE_COORDINATOR did not take the notice (blocked or gone?); lane_state is unchanged, run lane.sh $cmd again"
  fi
  exit 0
fi

# A Herdr restart drops the lane's LANE_* exports but keeps HERDR_PANE_ID and the agent_session. Read the tokens
# from this pane, or restore them from the record spawn.sh left, before the usual "is not set" checks. A lane with
# both exports set never calls herdr here.
if [ "$cmd" = "done" ] || [ "$cmd" = escalate ] || [ "$cmd" = working ]; then
  if { [ -z "${LANE_COORDINATOR:-}" ] || [ -z "${LANE_MODE:-}" ]; } && [ -n "${HERDR_PANE_ID:-}" ]; then
    info=$(herdr agent get "$HERDR_PANE_ID" 2>/dev/null) || info=
    if [ -n "$info" ]; then
      read -r of mode < <(jq -r '.result.agent | "\(.tokens.lane_of // "-") \(.tokens.lane_mode // "-")"' <<<"$info") || of=-
      if [ "$of" != - ] && [ "$mode" != - ]; then
        LANE_COORDINATOR=$of LANE_MODE=$mode
      else
        session=$(jq -r '.result.agent.agent_session.value // empty' <<<"$info")
        if [ -n "$session" ]; then
          match=
          count=0
          for record in "$statedir"/goals/g.*/lane.json; do
            [ -f "$record" ] || continue
            rs=$(jq -r '.agent_session // empty' "$record" 2>/dev/null) || rs=
            [ "$rs" = "$session" ] || continue
            match=$record
            count=$((count + 1))
          done
          if [ "$count" -eq 1 ]; then
            touched=0
            restore_one "$match" "$(jq -c '{result: {agents: [.result.agent]}}' <<<"$info")"
            if [ "$touched" = 1 ]; then
              of=$(jq -r '.lane_of // empty' "$match")
              mode=$(jq -r '.lane_mode // empty' "$match")
              if [ -n "$of" ] && [ -n "$mode" ]; then
                start_watcher "$of"
                LANE_COORDINATOR=$of LANE_MODE=$mode
              fi
            fi
          fi
        fi
      fi
    fi
  fi
fi

: "${HERDR_PANE_ID:?lane.sh $cmd runs inside a lane: HERDR_PANE_ID is not set}"
: "${LANE_COORDINATOR:?lane.sh $cmd runs inside a lane: LANE_COORDINATOR is not set (spawn with --lane)}"
: "${LANE_MODE:?lane.sh $cmd runs inside a lane: LANE_MODE is not set (spawn with --lane)}"

case $cmd in
  working) set_state "$HERDR_PANE_ID" "$LANE_COORDINATOR" "$LANE_MODE" working ;;
  "done") set_state "$HERDR_PANE_ID" "$LANE_COORDINATOR" "$LANE_MODE" "done" --token "lane_note=$(note "$2")" ;;
  escalate) set_state "$HERDR_PANE_ID" "$LANE_COORDINATOR" "$LANE_MODE" escalated --token "lane_note=$(note "$2")" ;;
esac
