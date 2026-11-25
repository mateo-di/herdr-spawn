#!/usr/bin/env bash
# Usage: lanes-watch.sh <coordinator-pane-id>
# Started detached by `spawn.sh --lane` and by `lane.sh reply`. A coordinator that spawned lanes otherwise learns nothing
# until it reads their panes, so this polls `herdr agent list` for agents whose lane_of token is the coordinator's
# pane. Lanes declare their own state in a lane_state token (working, done, escalated) through lane.sh, which only
# talks to herdr, so no harness sandbox gets in its way. A new lane_report stamp on a lane that is done or
# escalated is a declaration, announced with the lane's lane_note (a lane first seen with one counts as new). The
# watcher also covers what a lane cannot say for itself:
#   stopped   a lane whose state is still working has had an idle or done agent for ${HERDR_SPAWN_STOP_GRACE:-60}
#             seconds: it went quiet without reporting. The grace absorbs a stop hook, goal judge or plugin that
#             re-prompts the lane at the end of a turn; once per idle stretch, and a lane first seen idle counts.
#   stalled   a lane has been working for ${HERDR_SPAWN_STALL_MINUTES:-30} minutes without finishing a turn (herdr's
#             completion_seq counter not rising); once per stretch.
#   blocked   a lane entered blocked (first seen blocked included).
#   exited    a lane's pane vanished.
#   lost      a lane's name and lane tokens vanished but its pane still runs an agent (a Herdr restart); restore it.
# The last snapshot, with the stall and idle bookkeeping, persists per coordinator, so a restarted watcher does not
# re-announce what it reported.
# Notices queue in the state dir and are posted to the coordinator with `herdr agent prompt` only while it is
# idle or done: some harnesses drop their in-progress reply when prompted mid-turn. A queued line carries its
# lane, kind and report, and delivery drops what went stale while the coordinator was busy: an escalation the
# coordinator already answered, a stopped or stalled lane that is working again. A failed prompt keeps the queue.
# A blocked lane also raises a Herdr notification at once, because a person may need to answer it.
# One watcher runs per coordinator pane (a mkdir lock, portable to macOS bash 3.2). It exits when the
# coordinator's pane is gone, or when no lanes remain and the queue is empty. Poll interval:
# ${HERDR_SPAWN_WATCH_INTERVAL:-5} seconds.
set -euo pipefail

[ $# -eq 1 ] || { echo "usage: lanes-watch.sh <coordinator-pane-id>" >&2; exit 1; }
coord=$1
interval=${HERDR_SPAWN_WATCH_INTERVAL:-5}
stall=$(( ${HERDR_SPAWN_STALL_MINUTES:-30} * 60 ))
grace=${HERDR_SPAWN_STOP_GRACE:-60}
lanesh=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)/lane.sh

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
  # Two launches can read the same dead pid: only one may move the lock away, and only while it still holds
  # that pid, so the loser cannot remove the winner's fresh lock; a failed mkdir then exits.
  if [ "$(cat "$lock/pid" 2>/dev/null || true)" = "$pid" ] && mv "$lock" "$lock.stale.$$" 2>/dev/null; then
    rm -rf "$lock.stale.$$"
  fi
  mkdir "$lock" 2>/dev/null || exit 0
fi
echo $$ >"$lock/pid"
trap 'rm -rf "$lock"; [ -s "$queue" ] || rm -f "$queue"' EXIT
# The poll sleep runs in the background and is waited on, so a signal ends the watcher at once.
trap 'exit 0' INT TERM

log() { printf '%s %s\n' "$(date '+%F %T')" "$*"; }

# Adds the bookkeeping to a current snapshot. since/notified: the stall stretch (a lane whose state is working
# and whose agent is working with an unchanged completion_seq; since is null outside one, notified once it has
# lasted the stall threshold). idle_since/stopped: the idle stretch (state working, agent idle or done; stopped
# once it has lasted the grace). Args: previous snapshot, current snapshot, now.
track() {
  jq -c --argjson prev "$1" --argjson now "$3" --argjson stall "$stall" --argjson grace "$grace" '
    ($prev | map({key: .pane_id, value: .}) | from_entries) as $p
    | map($p[.pane_id] as $o
      | (.state == "working" and (.agent_status | IN("working", "unknown"))) as $on
      | (.state == "working" and (.agent_status | IN("idle", "done"))) as $idle
      | (if $on then (if $o.since != null and $o.completion_seq == .completion_seq then $o.since else $now end)
         else null end) as $since
      | (if $idle then ($o.idle_since // $now) else null end) as $isince
      | . + {since: $since, notified: ($on and ($now - $since >= $stall)),
             idle_since: $isince, stopped: ($idle and ($now - $isince >= $grace))})' <<<"$2"
}

# Reads the previous and current (tracked) snapshots; prints "<kind> <name> <pane> <report or -> <notice>",
# tab-separated, per transition.
events() {
  jq -nr --argjson prev "$1" --argjson cur "$2" --argjson open "$3" --argjson stall "$stall" --arg lanesh "$lanesh" '
    def where: "(\(.agent), pane \(.pane_id), mode \(.mode // "unit"))";
    def read: "herdr agent read \(.name) --source recent-unwrapped --lines 120";
    def row($kind; $text): [$kind, .name, .pane_id, (.report // "-"), $text] | join("\t");
    ($prev | map({key: .pane_id, value: .}) | from_entries) as $p
    | ($cur | map(.pane_id)) as $alive
    | ($cur[]
       | (if .report != null and .report != $p[.pane_id].report and (.state | IN("done", "escalated")) then
            (.note // "" | gsub("[\r\n]+"; " ")) as $note
            | if .state == "done" then
                row("done"; "[lane \(.name)] done: \($note). Read its report: \(read)")
              else
                row("escalation"; "[lane \(.name)] escalation: \($note). Read the full question: herdr agent read \(.name) --source recent-unwrapped --lines 80; answer with: \($lanesh) reply \(.name) \"<answer>\"")
              end
          else empty end),
         (if .agent_status == "blocked" and $p[.pane_id].agent_status != "blocked" then
            row("blocked"; "[lane \(.name)] blocked on an approval or question \(where). Inspect: herdr agent read \(.name) --source recent-unwrapped --lines 60; ask the user before answering it.")
          elif .stopped and ($p[.pane_id].stopped | not) then
            row("stopped"; "[lane \(.name)] stopped without reporting done or escalating \(where). Check it: \(read); nudge it with: \($lanesh) reply \(.name) \"<what to do next>\"")
          elif .notified and ($p[.pane_id].notified | not) then
            row("stalled"; "[lane \(.name)] working for \(($stall / 60) | floor) min without finishing a turn \(where). Check it: \(read)")
          else empty end)),
      ($prev[] | select(.pane_id as $id | $alive | index($id) | not)
       | if (.pane_id as $id | $open | index($id)) then
           row("lost"; "[lane \(.name)] lost its name and lane tokens, but pane \(.pane_id) still runs an agent (a Herdr restart does this). Restore it with: \($lanesh) restore")
         else
           row("exited"; "[lane \(.name)] exited \(where).")
         end)'
}

# Queue lines are "<kind> <pane> <report> <text>", tab-separated. Prints the texts still worth sending, joined,
# judged against the current snapshot: an escalation is stale once its lane is no longer escalated under that
# report, a stopped or stalled lane once it is working again, a lost lane once its pane is back in the snapshot.
fresh_text() {
  jq -nrR --argjson cur "$prev" '
    [inputs | split("\t") as $f
     | ($cur | map(select(.pane_id == $f[1]))[0]) as $l
     | select(if $f[0] == "escalation" then $l != null and $l.state == "escalated" and $l.report == $f[2]
              elif $f[0] == "stopped" then $l != null and $l.state == "working" and ($l.agent_status | IN("idle", "done"))
              elif $f[0] == "stalled" then $l != null and $l.state == "working"
              elif $f[0] == "lost" then $l == null
              else true end)
     | $f[3:] | join("\t")] | join(" | ")' <"$queue"
}

# Posts the queue as one prompt when the coordinator is between turns; keeps it on any failure.
deliver() {
  [ -s "$queue" ] || return 0
  local st text
  st=$(herdr agent get "$coord" 2>/dev/null | jq -r '.result.agent.agent_status // empty') || return 0
  case $st in idle|done) ;; *) return 0 ;; esac
  text=$(fresh_text) || return 0
  if [ -z "$text" ]; then
    : >"$queue"
    log "dropped a stale queue"
  elif herdr agent prompt "$coord" "$text" >/dev/null 2>&1; then
    : >"$queue"
    log "delivered: $text"
  else
    log "prompt to $coord failed, queue kept"
  fi
}

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
  if raw=$(herdr agent list 2>/dev/null) && cur=$(jq -c --arg c "$coord" '
      [.result.agents[] | select(.tokens.lane_of == $c)
       | {name, pane_id, agent, agent_status, completion_seq, mode: .tokens.lane_mode, state: .tokens.lane_state, note: .tokens.lane_note, report: .tokens.lane_report}]' <<<"$raw") &&
     [ -n "$cur" ] && cur=$(track "$prev" "$cur" "$(date +%s)"); then
    # A lane missing from the snapshot whose pane still lists an agent only lost its name and tokens (a Herdr
    # restart resumes the agent); a pane left open by an agent that quit lists none, so that lane exited.
    open=$(jq -c '[.result.agents[].pane_id]' <<<"$raw")
    while IFS=$'\t' read -r kind name pane report notice; do
      [ -n "$kind" ] || continue
      printf '%s\t%s\t%s\t%s\n' "$kind" "$pane" "$report" "$notice" >>"$queue"
      log "queued: $notice"
      if [ "$kind" = blocked ]; then
        herdr notification show "Lane $name needs input" --body "$notice" --sound request >/dev/null 2>&1 || true
      fi
    done < <(events "$prev" "$cur" "$open")
    prev=$cur
    printf '%s\n' "$cur" >"$seen"
    deliver
    if [ "$cur" = '[]' ] && [ ! -s "$queue" ]; then log "no lanes left"; rm -f "$seen"; exit 0; fi
  fi
  sleep "$interval" & wait $!
done
