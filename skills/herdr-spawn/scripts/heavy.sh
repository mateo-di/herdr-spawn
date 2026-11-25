#!/usr/bin/env bash
# Usage: heavy.sh <command> [args...]
# Runs a heavy check (a build, a type check, a wide test run) in one of a few slots that every lane on this
# machine shares, so parallel lanes take turns instead of loading the machine all at once. Slots, not a load
# threshold: lanes that wait for the load to drop all start together once it does.
# A slot is a symlink in a per-user directory under /tmp, because a sandboxed Codex lane may write /tmp but not
# the rest of the home directory; ln -s takes it atomically, also on macOS, which has no flock. Once it holds a
# slot, heavy.sh execs the command, so its signals, stdin and exit status are the command's own, and leaves a
# keeper process that refreshes the link's mtime while the command runs and removes the link within a fraction
# of a second after it ends. A link left unrefreshed for two to three minutes (find rounds the age to whole
# minutes) counts as abandoned: a sandbox can hide the owner's process from a pid check. A lost takeover race,
# or a machine asleep that long, lets extra checks run, and an unusable slot directory runs the command at once
# with a warning. Only a stopped (suspended) check keeps its slot for as long as it stays stopped. A heavy.sh
# call inside a check runs at once, because its caller already holds a slot and waiting could deadlock.
# HERDR_SPAWN_HEAVY_SLOTS (default 2) must be the same for every lane on the machine; HERDR_SPAWN_HEAVY_POLL is
# the wait between tries in seconds (default 10); HERDR_SPAWN_HEAVY_DIR moves the slot directory.
set -uo pipefail

[ $# -ge 1 ] || { echo "usage: heavy.sh <command> [args...]" >&2; exit 2; }
[ -z "${HERDR_SPAWN_HEAVY_HELD:-}" ] || exec "$@"
slots=${HERDR_SPAWN_HEAVY_SLOTS:-2}
poll=${HERDR_SPAWN_HEAVY_POLL:-10}
[[ $slots =~ ^[1-9][0-9]*$ ]] || { echo "heavy.sh: HERDR_SPAWN_HEAVY_SLOTS must be a whole number above 0" >&2; exit 2; }
[[ $poll =~ ^[0-9]+(\.[0-9]+)?$ && $poll =~ [1-9] ]] ||
  { echo "heavy.sh: HERDR_SPAWN_HEAVY_POLL must be a number of seconds above 0" >&2; exit 2; }
dir=${HERDR_SPAWN_HEAVY_DIR:-/tmp/herdr-spawn-heavy-$(id -u)}
me=$$.$RANDOM
held=

unslotted() { # <reason> <command...>
  echo "heavy.sh: $1; running without a slot" >&2
  shift
  exec "$@"
}

# Takes slot $1 if it is free or abandoned: 0 taken, 1 held by a live owner, 2 the directory refuses changes.
take() {
  local slot=$1
  if ln -s "$me" "$slot" 2>/dev/null; then held=$slot; return 0; fi
  if [ ! -L "$slot" ]; then
    # Freed between the two calls, or the directory refuses links: one more try tells them apart.
    if ln -s "$me" "$slot" 2>/dev/null; then held=$slot; return 0; fi
    if [ -L "$slot" ]; then return 1; fi
    return 2
  fi
  [ -n "$(find "$slot" -maxdepth 0 -mmin +2 2>/dev/null)" ] || return 1
  rm -f "$slot" 2>/dev/null || return 2
  if ln -s "$me" "$slot" 2>/dev/null; then held=$slot; return 0; fi
  return 1
}

mkdir -m 700 "$dir" 2>/dev/null
if ! { [ -d "$dir" ] && [ ! -L "$dir" ] && [ -O "$dir" ]; }; then
  unslotted "$dir is missing or not owned by this user" "$@"
fi
if [ -n "$(find "$dir" -maxdepth 0 \( -perm -020 -o -perm -002 \) 2>/dev/null)" ]; then
  unslotted "$dir is writable by other users" "$@"
fi

waited=
while :; do
  for ((i = 1; i <= slots; i++)); do
    take "$dir/slot-$i"
    case $? in
      0) break 2 ;;
      2) unslotted "cannot create slots in $dir" "$@" ;;
    esac
  done
  if [ -n "$waited" ]; then
    sleep "$poll"
  else
    # The first retry comes soon: a check that just ended frees its slot a moment later.
    echo "heavy.sh: all $slots slots are busy; waiting" >&2
    waited=1
    sleep 1
  fi
done

# The keeper is forked twice, so the command never sees it as a child of its own to wait for. It ignores the
# signals that end the command, refreshes the lease every 2 seconds while this pid (the command, after exec)
# lives and the slot is still ours, then frees the slot if it is still ours. Its stdio is detached so it holds
# no caller's pipe open.
( (
  trap '' HUP INT TERM
  n=0
  while kill -0 $$ 2>/dev/null; do
    if [ $((n++ % 10)) = 0 ]; then
      [ "$(readlink "$held" 2>/dev/null)" = "$me" ] || exit 0
      touch -c -h "$held" 2>/dev/null
    fi
    sleep 0.2
  done
  if [ "$(readlink "$held" 2>/dev/null)" = "$me" ]; then rm -f "$held"; fi
) </dev/null >/dev/null 2>&1 & )
export HERDR_SPAWN_HEAVY_HELD=1
exec "$@"
