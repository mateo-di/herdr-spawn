#!/usr/bin/env bash
# Usage: lanes-watch.sh <coordinator-pane-id>
# Started detached by `spawn.sh --lane`. A coordinator that spawned lanes otherwise learns nothing until it
# reads their panes, so this polls `herdr agent list` for agents whose lane_of token is the coordinator's pane
# and turns each transition into one notice: a lane finishing a turn (done), becoming blocked, or vanishing
# (exited). Done is herdr's completion_seq counter rising, not a status: the status after a turn is idle or done
# depending on whether anyone is looking at the pane, and a poll can miss a short working phase, but the counter
# cannot be missed. A lane first seen with a completion_seq finished before the first poll and counts as done.
# The last snapshot persists per coordinator, so a restarted watcher does not re-announce what it reported.
# Notices queue in the state dir and are posted to the coordinator with `herdr agent prompt` only while it is
# idle or done: some harnesses drop their in-progress reply when prompted mid-turn. A failed prompt keeps the
# queue. A blocked lane also raises a Herdr notification at once, because a person may need to answer it.
# One watcher runs per coordinator pane (a mkdir lock, portable to macOS bash 3.2). It exits when the
# coordinator's pane is gone, or when no lanes remain and the queue is empty. Poll interval:
# ${HERDR_SPAWN_WATCH_INTERVAL:-5} seconds.
set -euo pipefail

[ $# -eq 1 ] || { echo "usage: lanes-watch.sh <coordinator-pane-id>" >&2; exit 1; }
coord=$1
interval=${HERDR_SPAWN_WATCH_INTERVAL:-5}

state=${XDG_STATE_HOME:-$HOME/.local/state}/herdr-spawn
key=${coord//[!A-Za-z0-9_-]/_}
lock=$state/watch-$key.lock
queue=$state/queue-$key.txt
seen=$state/seen-$key.json
mkdir -p "$state"

# A live pid in the lock means another watcher owns this coordinator. A lock without a pid file may be a
# watcher between mkdir and writing its pid, so it gets a moment before it counts as stale.
if ! mkdir "$lock" 2>/dev/null; then
  sleep 1
  pid=$(cat "$lock/pid" 2>/dev/null || true)
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then exit 0; fi
  rm -rf "$lock"
  mkdir "$lock" 2>/dev/null || exit 0
fi
echo $$ >"$lock/pid"
trap 'rm -rf "$lock"; [ -s "$queue" ] || rm -f "$queue"' EXIT
# The poll sleep runs in the background and is waited on, so a signal ends the watcher at once.
trap 'exit 0' INT TERM

log() { printf '%s %s\n' "$(date '+%F %T')" "$*"; }

# Reads the previous and current snapshots; prints "<kind><TAB><name><TAB><notice>" per transition.
events() {
  jq -nr --argjson prev "$1" --argjson cur "$2" '
    def where: "(\(.agent), pane \(.pane_id), mode \(.mode // "unit"))";
    ($prev | map({key: .pane_id, value: .}) | from_entries) as $p
    | ($cur | map(.pane_id)) as $alive
    | ($cur[] | select((.completion_seq // 0) > ($p[.pane_id].completion_seq // 0)
                       or ($p[.pane_id] != null and $p[.pane_id].agent_status != .agent_status))
       | if (.completion_seq // 0) > ($p[.pane_id].completion_seq // 0) then
           "done\t\(.name)\t[lane \(.name)] done \(where). Read its report: herdr agent read \(.name) --source recent-unwrapped --lines 120"
         elif .agent_status == "blocked" and $p[.pane_id] != null then
           "blocked\t\(.name)\t[lane \(.name)] blocked on an approval or question \(where). Inspect: herdr agent read \(.name) --source recent-unwrapped --lines 60; ask the user before answering it."
         else empty end),
      ($prev[] | select(.pane_id as $id | $alive | index($id) | not)
       | "exited\t\(.name)\t[lane \(.name)] exited \(where).")'
}

# Posts the queue as one prompt when the coordinator is between turns; keeps it on any failure.
deliver() {
  [ -s "$queue" ] || return 0
  local st line text=
  st=$(herdr agent get "$coord" 2>/dev/null | jq -r '.result.agent.agent_status // empty') || return 0
  case $st in idle|done) ;; *) return 0 ;; esac
  while IFS= read -r line; do
    text=${text:+$text | }$line
  done <"$queue"
  if herdr agent prompt "$coord" "$text" >/dev/null 2>&1; then
    : >"$queue"
    log "delivered: $text"
  else
    log "prompt to $coord failed, queue kept"
  fi
}

prev=$(cat "$seen" 2>/dev/null || true)
[ -n "$prev" ] || prev='[]'
while :; do
  herdr pane get "$coord" >/dev/null 2>&1 || { log "coordinator pane $coord is gone"; rm -f "$seen"; exit 0; }
  if cur=$(herdr agent list 2>/dev/null | jq -c --arg c "$coord" '
      [.result.agents[] | select(.tokens.lane_of == $c)
       | {name, pane_id, agent, agent_status, completion_seq, mode: .tokens.lane_mode}]') && [ -n "$cur" ]; then
    while IFS=$'\t' read -r kind name notice; do
      [ -n "$kind" ] || continue
      printf '%s\n' "$notice" >>"$queue"
      log "queued: $notice"
      if [ "$kind" = blocked ]; then
        herdr notification show "Lane $name needs input" --body "$notice" --sound request >/dev/null 2>&1 || true
      fi
    done < <(events "$prev" "$cur")
    prev=$cur
    printf '%s\n' "$cur" >"$seen"
    deliver
    if [ "$cur" = '[]' ] && [ ! -s "$queue" ]; then log "no lanes left"; rm -f "$seen"; exit 0; fi
  fi
  sleep "$interval" & wait $!
done
