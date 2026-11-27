#!/usr/bin/env bash
# Usage: lane-stop-check.sh
# Each harness's stop hook runs this (hooks/ for Claude Code and Codex, adapters/ for OpenCode and oh-my-pi) and
# blocks the stop with what it prints; no output lets the session stop. Checking state in one script keeps the
# roles the same in every harness.
# A lane (LANE_MODE set, or in the herdr TUI a lane_mode token on its pane) ends each stretch of work by
# reporting done or escalating, so it may not stop while its lane_state is still working, unless the harness
# reports background work that will wake it (LANE_PENDING, set by hooks/lane-stop.sh): a lane that waits on its
# worker is not stopping. A coordinator may not stop while one of its lanes waits on its answer. Working lanes
# never hold a coordinator: waiting idle for notices is its normal state, and the watcher wakes it.
# After three blocks in a row the stop goes through and the watcher's stopped notice takes over, rather than
# spinning the agent. The count starts over when the lane's lane_report token changes (lane.sh, including a
# coordinator's reply, sets a fresh one), so the count file is the only state this script keeps.
# In the Herdr app (HERDR_ENV not 1, HC_TERMINAL_ID set) the state comes from hc labels. No watcher runs there,
# so the pass after three blocks sends the coordinator the stopped notice itself, once per stretch, and records
# that in the count file.
set -uo pipefail

app=0
if [ "${HERDR_ENV:-}" = 1 ] && [ -n "${HERDR_PANE_ID:-}" ]; then
  pane=$HERDR_PANE_ID
  { command -v herdr && command -v jq; } >/dev/null || exit 0
elif [ "${HERDR_ENV:-}" != 1 ] && [ -n "${HC_TERMINAL_ID:-}" ]; then
  app=1
  pane=$HC_TERMINAL_ID
  { command -v hc && command -v jq; } >/dev/null || exit 0
else
  exit 0
fi
dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
state=${XDG_STATE_HOME:-$HOME/.local/state}/herdr-spawn
count=$state/stopblock-${pane//[!A-Za-z0-9_-]/_}

reason='' report=-
lane=${LANE_MODE:-}
if [ -z "$lane" ] && [ "$app" = 0 ]; then
  # A Herdr restart drops the lane's LANE_MODE export; lane.sh restore puts its lane_mode token back. Any pane can
  # set tokens, so only a lane's own pair counts: a lane_of and a lane_mode that spawn.sh could have written.
  lane=$(herdr agent get "$pane" 2>/dev/null | jq -r '.result.agent.tokens
    | select((.lane_of // "" | test("^[A-Za-z0-9][A-Za-z0-9_:.-]*$")) and (.lane_mode == "unit" or .lane_mode == "driver"))
    | .lane_mode') || lane=''
fi
if [ -n "$lane" ]; then
  if [ "$app" = 1 ]; then
    read -r st report < <(hc get "$pane" --json 2>/dev/null |
      jq -r '.labels | "\(.lane_state // "-") \(.lane_report // "-")"') || st=-
  else
    read -r st report < <(herdr agent get "$pane" 2>/dev/null |
      jq -r '.result.agent.tokens | "\(.lane_state // "-") \(.lane_report // "-")"') || st=-
  fi
  [ "$st" != working ] || [ -n "${LANE_PENDING:-}" ] ||
    reason="You are a lane and have not reported yet. If your goal's done criterion holds and you verified it, write the full report to a file outside your repo, then run: $dir/lane.sh done \"<one-line summary>\" <report file>. If you are blocked on something only your coordinator can decide, write the full question with options and your recommendation to a file, then run: $dir/lane.sh escalate \"<one-line summary>\" <question file>. Otherwise keep working toward the goal."
elif [ -e "$state/asked-${pane//[!A-Za-z0-9_-]/_}" ]; then
  # hooks/coordinator-ask.sh turned this coordinator's question dialog into a plain-text question: it is
  # waiting on the human, so this one stop goes through.
  rm -f "$state/asked-${pane//[!A-Za-z0-9_-]/_}" "$count"
  exit 0
else
  # The waiting lanes' reports are the count's key, so a new escalation gets fresh blocks.
  if [ "$app" = 1 ]; then
    read -r report waiting < <(for t in $(hc ls --json 2>/dev/null | jq -r --arg c "$pane" '.terminals[] | select(.parent == $c) | .address'); do
      hc get "$t" --json 2>/dev/null
    done | jq -rs --arg c "$pane" '
      [.[] | select(.labels.lane_of == $c and .labels.lane_state == "escalated")]
      | "\(map("\(.name):\(.labels.lane_report // "-")") | join(",") | if . == "" then "-" else . end) \(map(.name) | join(", "))"') ||
      report=- waiting=''
  else
    read -r report waiting < <(herdr agent list 2>/dev/null | jq -r --arg c "$pane" '
      [.result.agents[] | select(.tokens.lane_of == $c and .tokens.lane_state == "escalated")]
      | "\(map("\(.name):\(.tokens.lane_report // "-")") | join(",") | if . == "" then "-" else . end) \(map(.name) | join(", "))"') ||
      report=- waiting=''
  fi
  [ -z "$waiting" ] ||
    reason="Lanes waiting on your answer: $waiting. Answer each with: $dir/lane.sh reply <lane> \"<answer>\". Ask the human first only if the decision is critical and was never settled."
fi

if [ -z "$reason" ]; then rm -f "$count"; exit 0; fi
{ read -r n last sent <"$count"; } 2>/dev/null || n=0
[ "${last:-}" = "$report" ] || { n=0; sent=; }
if [ "$n" -ge 3 ]; then
  if [ "$app" = 1 ] && [ -n "${LANE_MODE:-}" ] && [ -z "${sent:-}" ] && [ -n "${LANE_COORDINATOR:-}" ]; then
    echo "$n $report sent" >"$count"
    name=$(hc get "$pane" --json 2>/dev/null | jq -r '.name // empty') || name=''
    [ -n "$name" ] || name=$pane
    detach='nohup'
    if command -v setsid >/dev/null; then detach=setsid; fi
    "$detach" hc send "$LANE_COORDINATOR" -- "[lane $name] stopped without reporting done or escalating (mode $LANE_MODE, terminal $pane). Check it: hc read $name --lines 120; nudge it with: $dir/lane.sh reply $name \"<what to do next>\"" </dev/null >/dev/null 2>&1 &
  fi
  exit 0
fi
mkdir -p "$state"
echo "$((n + 1)) $report" >"$count"
printf '%s\n' "$reason"
