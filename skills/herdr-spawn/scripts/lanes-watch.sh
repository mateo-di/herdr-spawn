#!/usr/bin/env bash
# Usage: lanes-watch.sh <coordinator-pane-id>
# Started detached by `spawn.sh --lane` and by `lane.sh`. A coordinator that spawned lanes otherwise learns nothing
# until it reads their panes, so this polls `herdr agent list` for agents whose lane_of token is the coordinator's
# pane. Lanes declare their own state in a lane_state token (working, done, escalated) through lane.sh, which also
# queues the done and escalation notices; the watcher covers what a lane cannot say for itself:
#   stopped   a lane finished a turn while its state is still working, so it went quiet without reporting.
#   stalled   a lane has been working for ${HERDR_SPAWN_STALL_MINUTES:-30} minutes without finishing a turn; once per stretch.
#   blocked   a lane entered blocked (first seen blocked included); also raises a Herdr notification at once,
#             because a person may need to answer it. Blocked wins over stopped.
#   exited    a lane's pane vanished.
# A finished turn is herdr's completion_seq counter rising, not a status: the status after a turn is idle or done
# depending on whether anyone is looking at the pane, and a poll can miss a short working phase, but the counter
# cannot be missed. A lane first seen with a completion_seq finished before the first poll. The turn of a
# launch-line prompt may get no completion_seq, so a lane still without one finished when it goes from working,
# unknown or blocked to idle or done.
# The last snapshot, with the stall bookkeeping, persists per coordinator, so a restarted watcher does not
# re-announce what it reported.
# Notices queue in the state dir (lane.sh appends to the same file) and are posted to the coordinator with
# `herdr agent prompt` only while it is idle or done: some harnesses drop their in-progress reply when prompted
# mid-turn. Delivery moves the queue aside first, so a notice appended meanwhile is never lost; a failed prompt
# puts its lines back in front.
# One watcher runs per coordinator pane (a mkdir lock, portable to macOS bash 3.2). It exits when the
# coordinator's pane is gone, or when no lanes remain and the queue is empty. Poll interval:
# ${HERDR_SPAWN_WATCH_INTERVAL:-5} seconds.
set -euo pipefail

[ $# -eq 1 ] || { echo "usage: lanes-watch.sh <coordinator-pane-id>" >&2; exit 1; }
coord=$1
interval=${HERDR_SPAWN_WATCH_INTERVAL:-5}
stall=$(( ${HERDR_SPAWN_STALL_MINUTES:-30} * 60 ))
lanesh=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)/lane.sh

state=${XDG_STATE_HOME:-$HOME/.local/state}/herdr-spawn
key=${coord//[!A-Za-z0-9_-]/_}
lock=$state/watch-$key.lock
queue=$state/queue-$key.txt
sending=$queue.sending
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

# Adds the stall bookkeeping to a current snapshot: since (epoch the lane's working stretch began, null outside
# one) and notified (the stretch has reached the stall threshold). A stretch is a lane whose state is working and
# whose agent is working with an unchanged completion_seq. Args: previous snapshot, current snapshot, now.
track() {
  jq -c --argjson prev "$1" --argjson now "$3" --argjson stall "$stall" '
    ($prev | map({key: .pane_id, value: .}) | from_entries) as $p
    | map($p[.pane_id] as $o
      | (.state == "working" and (.agent_status | IN("working", "unknown"))) as $on
      | (if $on then (if $o.since != null and $o.completion_seq == .completion_seq then $o.since else $now end)
         else null end) as $since
      | . + {since: $since, notified: ($on and ($now - $since >= $stall))})' <<<"$2"
}

# Reads the previous and current (tracked) snapshots; prints "<kind><TAB><name><TAB><notice>" per transition.
events() {
  jq -nr --argjson prev "$1" --argjson cur "$2" --argjson stall "$stall" --arg lanesh "$lanesh" '
    def where: "(\(.agent), pane \(.pane_id), mode \(.mode // "unit"))";
    def read: "herdr agent read \(.name) --source recent-unwrapped --lines 120";
    ($prev | map({key: .pane_id, value: .}) | from_entries) as $p
    | ($cur | map(.pane_id)) as $alive
    | ($cur[]
       # blocked wins over stopped: a lane that finished a turn and is now waiting needs a person more than a reader
       | if .agent_status == "blocked" and $p[.pane_id].agent_status != "blocked" then
           "blocked\t\(.name)\t[lane \(.name)] blocked on an approval or question \(where). Inspect: herdr agent read \(.name) --source recent-unwrapped --lines 60; ask the user before answering it."
         elif (.completion_seq // 0) > ($p[.pane_id].completion_seq // 0)
            or ((.completion_seq // 0) == 0 and ($p[.pane_id].agent_status | IN("working", "unknown", "blocked"))
                and (.agent_status | IN("idle", "done"))) then
           # a lane that reported done or escalated already queued its own notice
           if .state == "working" then
             "stopped\t\(.name)\t[lane \(.name)] stopped without reporting done or escalating \(where). Check it: \(read); nudge it with: \($lanesh) reply \(.name) \"<what to do next>\""
           else empty end
         elif .notified and ($p[.pane_id].notified | not) then
           "stalled\t\(.name)\t[lane \(.name)] working for \(($stall / 60) | floor) min without finishing a turn \(where). Check it: \(read)"
         else empty end),
      ($prev[] | select(.pane_id as $id | $alive | index($id) | not)
       | "exited\t\(.name)\t[lane \(.name)] exited \(where).")'
}

# Puts a moved-aside queue back in front of anything appended since.
requeue() {
  { cat "$sending"; cat "$queue" 2>/dev/null || true; } >"$sending.merge"
  mv "$sending.merge" "$queue"
  rm -f "$sending"
}

# Posts the queue as one prompt when the coordinator is between turns; keeps it on any failure. The queue is
# moved aside first because lane.sh appends to it at any time.
deliver() {
  [ -s "$queue" ] || return 0
  local st line text=
  st=$(herdr agent get "$coord" 2>/dev/null | jq -r '.result.agent.agent_status // empty') || return 0
  case $st in idle|done) ;; *) return 0 ;; esac
  mv "$queue" "$sending"
  while IFS= read -r line; do
    text=${text:+$text | }$line
  done <"$sending"
  if herdr agent prompt "$coord" "$text" >/dev/null 2>&1; then
    rm -f "$sending"
    log "delivered: $text"
  else
    requeue
    log "prompt to $coord failed, queue kept"
  fi
}

[ ! -f "$sending" ] || requeue

prev=$(cat "$seen" 2>/dev/null || true)
[ -n "$prev" ] || prev='[]'
failures=0
while :; do
  # pane_not_found ends the watcher at once; any other failure (a server reload, a busy socket) is retried for
  # about five minutes, so a stopped server does not leave it running forever.
  if ! err=$(herdr pane get "$coord" 2>&1 >/dev/null); then
    case $err in *pane_not_found*) log "coordinator pane $coord is gone"; rm -f "$seen"; exit 0 ;; esac
    failures=$((failures + 1))
    log "herdr call failed ($failures), retrying: $err"
    if [ $((failures * interval)) -ge 300 ]; then log "giving up after $failures failures"; exit 1; fi
    sleep "$interval" & wait $!
    continue
  fi
  failures=0
  if cur=$(herdr agent list 2>/dev/null | jq -c --arg c "$coord" '
      [.result.agents[] | select(.tokens.lane_of == $c)
       | {name, pane_id, agent, agent_status, completion_seq, mode: .tokens.lane_mode, state: .tokens.lane_state}]') &&
     [ -n "$cur" ] && cur=$(track "$prev" "$cur" "$(date +%s)"); then
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
