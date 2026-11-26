#!/usr/bin/env bash
# Usage: lanes-deliver.sh <coordinator-terminal>
# App mode only. Delivers queued lane notices to a coordinator terminal once it can take them:
# a blocked coordinator (a dialog is open) cannot receive `hc send`, so lane.sh stores the notice
# in app-queue-<key>.txt and starts this deliverer detached; it polls until the coordinator is
# no longer blocked, then sends each queued notice with the lane as sender. Exits when the queue
# drains or the coordinator is gone.
set -euo pipefail

[ $# -eq 1 ] || { echo "usage: lanes-deliver.sh <coordinator-terminal>" >&2; exit 1; }
command -v jq >/dev/null || { echo "lanes-deliver.sh: jq is required" >&2; exit 1; }
command -v hc >/dev/null || { echo "lanes-deliver.sh: hc is required" >&2; exit 1; }

coord=$1
interval=${HERDR_SPAWN_WATCH_INTERVAL:-5}
state=${XDG_STATE_HOME:-$HOME/.local/state}/herdr-spawn
key=${coord//[!A-Za-z0-9_-]/_}
lock=$state/deliver-$key.lock
queue=$state/app-queue-$key.txt
logfile=$state/deliver-$key.log
umask 077
mkdir -p "$state"

# A live pid in the lock means another deliverer owns this coordinator.
if ! mkdir "$lock" 2>/dev/null; then
  sleep 1
  pid=$(cat "$lock/pid" 2>/dev/null || true)
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then exit 0; fi
  if [ "$(cat "$lock/pid" 2>/dev/null || true)" = "$pid" ] && mv "$lock" "$lock.stale.$$" 2>/dev/null; then
    rm -rf "$lock.stale.$$"
  fi
  mkdir "$lock" 2>/dev/null || exit 0
fi
echo $$ >"$lock/pid"
trap 'rm -rf "$lock"' EXIT
trap 'exit 0' INT TERM

# This deliverer now holds the lock, so any in-flight file left behind by a deliverer that died mid-send is orphaned.
for f in "$state"/app-queue-"$key".txt.sending.*; do
  [ -e "$f" ] || continue
  cat "$f" >>"$queue"
  rm -f "$f"
done

log() { printf '%s %s\n' "$(date '+%F %T')" "$*" >>"$logfile"; }

failures=0 sendfails=0
while :; do
  # A queue that is missing or empty: release the lock, then check once more in case a lane
  # appended and started a deliverer while this one was exiting.
  # The EXIT trap is dropped first so it cannot remove a lock a newer deliverer has taken.
  if [ ! -s "$queue" ]; then
    trap - EXIT
    rm -rf "$lock"
    { [ -s "$queue" ] && mkdir "$lock" 2>/dev/null; } || exit 0
    echo $$ >"$lock/pid"
    trap 'rm -rf "$lock"' EXIT
    continue
  fi

  rc=0
  info=$(hc get "$coord" --json 2>/dev/null) || rc=$?

  gone=0
  if [ $rc -eq 3 ]; then
    gone=1
  elif [ $rc -ne 0 ]; then
    failures=$((failures + 1))
    log "hc get $coord failed ($failures)"
    if [ $((failures * interval)) -ge 300 ]; then log "giving up after $failures failures"; exit 1; fi
    sleep "$interval" & wait $!
    continue
  else
    st=$(printf '%s' "$info" | jq -r '.state // empty' 2>/dev/null || true)
    if [ "$st" = "finished" ]; then
      gone=1
    elif [ "$st" != "live" ]; then
      failures=$((failures + 1))
      log "hc get $coord failed ($failures)"
      if [ $((failures * interval)) -ge 300 ]; then log "giving up after $failures failures"; exit 1; fi
      sleep "$interval" & wait $!
      continue
    fi
  fi

  failures=0

  if [ $gone -eq 1 ]; then
    log "coordinator $coord is gone or not live"
    rm -f "$queue"
    exit 0
  fi

  status_state=$(printf '%s' "$info" | jq -r '.status.state // empty' 2>/dev/null || true)
  if [ "$status_state" = "blocked" ]; then
    sleep "$interval" & wait $!
    continue
  fi

  # Take the queue atomically; appends that arrive afterwards land in a fresh queue file.
  sending="$queue.sending.$$"
  if ! mv "$queue" "$sending" 2>/dev/null; then
    sleep "$interval" & wait $!
    continue
  fi

  lines=()
  while IFS= read -r l || [ -n "$l" ]; do
    [ -n "$l" ] && lines+=("$l")
  done <"$sending"

  i=0
  while [ $i -lt ${#lines[@]} ]; do
    line=${lines[$i]}
    IFS=$'\t' read -r kind lane report msg <<<"$line"
    if [ "$kind" = "escalation" ]; then
      lrc=0
      laneinfo=$(hc get "$lane" --json 2>/dev/null) || lrc=$?
      if [ $lrc -eq 3 ]; then
        # The lane is gone; nobody waits for its escalation.
        log "lane $lane is gone for queued escalation"
        i=$((i + 1))
        continue
      fi
      if [ $lrc -ne 0 ]; then
        # Retryable: put this line and every unsent line back on the queue.
        j=$i
        while [ $j -lt ${#lines[@]} ]; do
          printf '%s\n' "${lines[$j]}" >>"$queue"
          j=$((j + 1))
        done
        break
      fi
      ls_state=$(printf '%s' "$laneinfo" | jq -r '.labels.lane_state // empty' 2>/dev/null || true)
      ls_report=$(printf '%s' "$laneinfo" | jq -r '.labels.lane_report // empty' 2>/dev/null || true)
      if [ "$ls_state" != "escalated" ] || [ "$ls_report" != "$report" ]; then
        # Stale: the coordinator already answered, or the lane moved on.
        log "dropped stale escalation on $lane"
        i=$((i + 1))
        continue
      fi
    fi
    sendrc=0
    senderr=$(HC_TERMINAL_ID="$lane" hc send "$coord" -- "$msg" 2>&1 >/dev/null) || sendrc=$?
    if [ "$sendrc" -eq 0 ]; then
      sendfails=0
      log "delivered: $msg"
      i=$((i + 1))
    else
      if [ "$sendrc" -ne 9 ]; then
        sendfails=$((sendfails + 1))
      fi
      log "send to $coord failed ($sendrc): $senderr"
      # Put this line and every line not yet sent back on the queue.
      j=$i
      while [ $j -lt ${#lines[@]} ]; do
        printf '%s\n' "${lines[$j]}" >>"$queue"
        j=$((j + 1))
      done
      break
    fi
  done

  rm -f "$sending"
  if [ $((sendfails * interval)) -ge 300 ]; then log "giving up after $sendfails failed sends"; exit 1; fi

  sleep "$interval" & wait $!
done