#!/usr/bin/env bash
# Usage: heavy.sh <command> [args...]
# Runs a heavy check (a build, a type check, a wide test run) in one of a few slots that every lane on this
# machine shares, so parallel lanes take turns instead of loading the machine all at once. Slots, not a load
# threshold: lanes that wait for the load to drop all start together once it does.
# A slot is a symlink in a per-user directory under /tmp, because a sandboxed Codex lane may write /tmp but not
# the rest of the home directory; ln -s takes it atomically, also on macOS, which has no flock. The owner
# refreshes the link's mtime while its command runs, and a link left unrefreshed for two to three minutes (find
# rounds the age to whole minutes) counts as abandoned: a sandbox can hide the owner's process, so a pid check
# could not tell. Losing a takeover race lets
# at most one extra check run. When the slot directory cannot be used, the command runs at once with a warning,
# so heavy.sh never blocks a check for good. Exits with the command's status.
# HERDR_SPAWN_HEAVY_SLOTS (default 2) must be the same for every lane on the machine; HERDR_SPAWN_HEAVY_POLL is
# the wait between tries in seconds (default 10); HERDR_SPAWN_HEAVY_DIR moves the slot directory.
set -uo pipefail

[ $# -ge 1 ] || { echo "usage: heavy.sh <command> [args...]" >&2; exit 2; }
slots=${HERDR_SPAWN_HEAVY_SLOTS:-2}
poll=${HERDR_SPAWN_HEAVY_POLL:-10}
[[ $slots =~ ^[1-9][0-9]*$ ]] || { echo "heavy.sh: HERDR_SPAWN_HEAVY_SLOTS must be a whole number above 0" >&2; exit 2; }
dir=${HERDR_SPAWN_HEAVY_DIR:-/tmp/herdr-spawn-heavy-$(id -u)}
me=$$.$RANDOM
held=
refresher=

# Removes the slot only while it is still ours: after a lost takeover race it belongs to someone else.
release() {
  if [ -n "$refresher" ]; then kill "$refresher" 2>/dev/null; fi
  if [ -n "$held" ] && [ "$(readlink "$held" 2>/dev/null)" = "$me" ]; then rm -f "$held"; fi
}
trap release EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

# Takes slot $1 if it is free or abandoned: 0 taken, 1 held by a live owner, 2 the directory refuses links.
take() {
  local slot=$1
  if ln -s "$me" "$slot" 2>/dev/null; then held=$slot; return 0; fi
  [ -L "$slot" ] || return 2
  [ -n "$(find "$slot" -maxdepth 0 -mmin +2 2>/dev/null)" ] || return 1
  rm -f "$slot"
  if ln -s "$me" "$slot" 2>/dev/null; then held=$slot; return 0; fi
  return 1
}

mkdir -m 700 "$dir" 2>/dev/null
if ! { [ -d "$dir" ] && [ ! -L "$dir" ] && [ -O "$dir" ]; }; then
  echo "heavy.sh: $dir is missing or not owned by this user; running without a slot" >&2
  "$@"
  exit
fi

waited=
while :; do
  for ((i = 1; i <= slots; i++)); do
    take "$dir/slot-$i"
    case $? in
      0) break 2 ;;
      2)
        echo "heavy.sh: cannot create slots in $dir; running without one" >&2
        "$@"
        exit
        ;;
    esac
  done
  [ -n "$waited" ] || echo "heavy.sh: all $slots slots are busy; waiting" >&2
  waited=1
  sleep "$poll"
done

# The lease: refreshed while this script lives, so a killed owner's slot goes stale on its own. Its stdio is
# detached: its last sleep outlives this script, and must not hold a caller's output pipe open.
(while sleep 30 && kill -0 $$ 2>/dev/null; do touch -h "$held" 2>/dev/null; done) </dev/null >/dev/null 2>&1 &
refresher=$!
"$@"
