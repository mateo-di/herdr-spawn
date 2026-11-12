#!/usr/bin/env bash
# Usage: spawn.sh [--tab <dir>] [--lane <unit|driver>] <agent> <name> <prompt-file> [<pane-id> <right|down>]
# Splits a sibling pane, types the agent's launch line into its interactive shell (so wrappers, aliases and
# functions apply, and `$(cat file)` expands there), waits for Herdr to detect the agent, names it, and prints
# "<pane-id> <name> <agent-kind> <status>". Without the optional pane/direction, a picker keeps the tab an even
# grid (1 → 2 columns → 2×2 → 3×2 → 3×3 …):
#   1. A column with fewer panes than the tallest column is filled first: split its largest pane "down".
#   2. Otherwise every column has R panes. With C columns: C <= R adds a column ("right"), C > R a row ("down").
# Columns are panes grouped by left edge (rect.x). The caller's pane wins ties within 10% area.
# --tab <dir> (before the positionals, Herdr TUI/UI only, not with <pane-id> <right|down>) opens a new tab with cwd <dir> instead.
# --lane <unit|driver> (before the positionals, Herdr TUI/UI only, needs HERDR_PANE_ID) registers the child as a lane of
# the calling pane: LANE_MODE and LANE_COORDINATOR are exported in its shell, its pane gets lane_of and lane_mode
# metadata tokens, and lanes-watch.sh runs for the caller to post done/blocked/exited notices into it.
# In the Herdr app (HC_TERMINAL_ID set, no HERDR_ENV) it splits through herdr-app instead, leaves naming to the
# launch template, and prints "<terminal> <name> <app> <state>"; see the block below the jq check.
# Launch templates ({name}, {prompt}) come from built-in defaults, overridden or extended by the config file
# ${HERDR_SPAWN_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/herdr-spawn/agents.conf}: one "<agent> <template>" per
# line; blank lines and full-line # comments are ignored.
set -euo pipefail

die() { echo "spawn.sh: $*" >&2; exit 1; }

conf=${HERDR_SPAWN_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/herdr-spawn/agents.conf}

# Prints "<agent> <template>" lines: the config's entries first (they win), then the built-in defaults.
templates() {
  if [ -r "$conf" ]; then
    local a t
    while read -r a t || [ -n "$a" ]; do
      case $a in ''|'#'*) continue ;; esac
      printf '%s %s\n' "$a" "$t"
    done <"$conf"
  fi
  printf '%s\n' 'claude claude -n {name} {prompt}' 'codex codex {prompt}' 'opencode opencode --prompt {prompt}'
}

pick() {
  herdr pane layout --current | jq -r --arg caller "${HERDR_PANE_ID:-}" '
    def pick: (map(. + {area: (.rect.width * .rect.height)})
               | (map(.area) | max) as $max
               | map(select(.area >= $max * 0.9))
               | (map(select(.pane_id == $caller)) + sort_by(-.area))[0]);
    .result.layout.panes as $panes
    | ($panes | group_by(.rect.x)) as $cols
    | ($cols | map(length) | max) as $rows
    | ($cols | length) as $ncols
    | ($cols | map(select(length < $rows))) as $short
    | if ($short | length) > 0 then ($short | flatten | pick | "\(.pane_id) down")
      elif $ncols <= $rows then ($panes | pick | "\(.pane_id) right")
      else ($panes | pick | "\(.pane_id) down")
      end'
}

usage="usage: spawn.sh [--tab <dir>] [--lane <unit|driver>] <agent> <name> <prompt-file> [<pane-id> <right|down>]"
tabdir="" lane=""
while [ $# -gt 0 ]; do
  case $1 in
    --tab)
      [ $# -ge 5 ] || die "$usage"
      [ -d "$2" ] || die "--tab directory not found: $2"
      tabdir=$(CDPATH='' cd -- "$2" && pwd)
      shift 2 ;;
    --lane)
      [ $# -ge 5 ] || die "$usage"
      case $2 in unit|driver) lane=$2 ;; *) die "--lane mode must be unit or driver, got: $2" ;; esac
      shift 2 ;;
    *) break ;;
  esac
done
[ $# -eq 3 ] || { [ $# -eq 5 ] && [ -z "$tabdir" ]; } || die "$usage"
agent=$1 name=$2 promptfile=$3
[[ $name =~ ^[a-z][a-z0-9_-]{0,31}$ ]] || die "name must match ^[a-z][a-z0-9_-]{0,31}\$"
[ -r "$promptfile" ] || die "prompt file not readable: $promptfile"
# The child's shell may start in another directory (--tab), so it needs an absolute path.
promptfile=$(CDPATH='' cd -- "$(dirname -- "$promptfile")" && pwd)/${promptfile##*/}

template=$(templates | awk -v a="$agent" '!d && $1 == a { sub(/^[^ ]+ /, ""); print; d = 1 }')
if [ -z "$template" ]; then
  die "unknown agent '$agent'; known: $(templates | awk '{print $1}' | sort -u | paste -sd' ' -); add one to $conf"
fi
promptarg="\"\$(cat $(printf %q "$promptfile"))\""
launch=${template//"{name}"/"$name"}
launch=${launch//"{prompt}"/"$promptarg"}

command -v jq >/dev/null || die "jq is required"

# The Herdr app (herdr-core, `hc`) sets HC_TERMINAL_ID instead of HERDR_ENV. It shows no pane geometry, so
# without a pane/direction the child splits the caller's pane to the right. The launch line runs in an
# interactive instance of the user's shell (wrappers, aliases and functions apply), replaced by a plain
# shell once the agent exits. A split doesn't take the person's focus.
if [ "${HERDR_ENV:-}" != 1 ] && [ -n "${HC_TERMINAL_ID:-}" ]; then
  [ -z "$tabdir" ] || die "--tab needs the herdr TUI or Herdr UI (HERDR_ENV=1)"
  [ -z "$lane" ] || die "--lane needs the herdr TUI or Herdr UI (HERDR_ENV=1)"
  command -v herdr-app >/dev/null || die "herdr-app is required"
  command -v hc >/dev/null || die "hc (herdr-core) is required"
  if [ $# -eq 5 ]; then
    target=$4 dir=$5
  else
    target=$(herdr-app ls | jq -r --arg t "$HC_TERMINAL_ID" \
      '[.spaces[].tabs[].terminals[] | select(.terminal == $t) | .pane][0] // empty')
    dir=right
    [ -n "$target" ] || die "no pane shows terminal $HC_TERMINAL_ID; pass <pane-id> <right|down> (see herdr-app ls)"
  fi
  shell=${SHELL:-/bin/sh}
  line="cd $(printf %q "$PWD") && $launch; exec $(printf %q "$shell")"
  split=$(herdr-app do pane.split --pane "$target" --direction "$dir" \
    --argv "$(jq -cn --arg sh "$shell" --arg line "$line" '[$sh, "-ic", $line]')") ||
    die "split of $target failed: $split"
  term=$(jq -r '.terminal // empty' <<<"$split")
  [ -n "$term" ] || die "split of $target returned no terminal: $split"

  status=
  for _ in $(seq 120); do
    status=$(hc get "$term" --json | jq -r 'select(.status.app) | "\(.status.app) \(.status.state)"') || true
    [ -n "$status" ] && break
    sleep 0.5
  done
  [ -n "$status" ] || die "no agent detected in terminal $term after 60s, left open; inspect with: hc read $term --lines 40"
  echo "$term $name $status"
  exit 0
fi

[ "${HERDR_ENV:-}" = 1 ] || die "not inside Herdr (neither HERDR_ENV=1 nor HC_TERMINAL_ID)"
[ -z "$lane" ] || [ -n "${HERDR_PANE_ID:-}" ] || die "--lane needs HERDR_PANE_ID, the coordinator's pane"
if herdr agent get "$name" >/dev/null 2>&1; then die "agent name '$name' is already taken"; fi

if [ -n "$tabdir" ]; then
  tabcmd=(herdr tab create)
  [ -z "${HERDR_WORKSPACE_ID:-}" ] || tabcmd+=(--workspace "$HERDR_WORKSPACE_ID")
  pane=$("${tabcmd[@]}" --cwd "$tabdir" --label "$name" --no-focus | jq -r '.result.root_pane.pane_id')
  { [ -n "$pane" ] && [ "$pane" != null ]; } || die "tab create returned no pane id"
else
  if [ $# -eq 5 ]; then
    target=$4 dir=$5
  else
    picked=$(pick) || die "could not pick a pane to split; pass <pane-id> <right|down>"
    read -r target dir <<<"$picked"
  fi
  { [ -n "${target:-}" ] && [ "$target" != null ] && [ -n "${dir:-}" ] && [ "$dir" != null ]; } ||
    die "could not pick a pane to split; pass <pane-id> <right|down>"

  pane=$(herdr pane split "$target" --direction "$dir" --cwd "$PWD" --no-focus | jq -r '.result.pane.pane_id')
  { [ -n "$pane" ] && [ "$pane" != null ]; } || die "split of $target returned no pane id"
fi
if [ -n "$lane" ]; then
  launch="export LANE_MODE=$(printf %q "$lane"); export LANE_COORDINATOR=$(printf %q "$HERDR_PANE_ID"); $launch"
fi
herdr pane run "$pane" "$launch" >/dev/null || die "launch failed; pane $pane left open"

info=
for _ in $(seq 120); do
  if info=$(herdr agent get "$pane" 2>/dev/null); then break; fi
  info=
  sleep 0.5
done
[ -n "$info" ] || die "no agent detected in pane $pane after 60s, pane left open; inspect with: herdr pane read $pane --source recent --lines 40"

herdr agent rename "$pane" "$name" >/dev/null ||
  die "agent running in $pane but rename to $name failed (name taken?)"
if [ -n "$lane" ]; then
  herdr pane report-metadata "$pane" --source herdr-spawn --token "lane_of=$HERDR_PANE_ID" --token "lane_mode=$lane" >/dev/null ||
    die "agent $name running in $pane but recording its lane tokens failed"
  statedir=${XDG_STATE_HOME:-$HOME/.local/state}/herdr-spawn
  mkdir -p "$statedir"
  watchlog=$statedir/watch-${HERDR_PANE_ID//[!A-Za-z0-9_-]/_}.log
  watch=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)/lanes-watch.sh
  # Detached so the watcher outlives this script and the caller's tool call; it exits at once if one already runs.
  detach='nohup'
  if command -v setsid >/dev/null; then detach=setsid; fi
  "$detach" "$watch" "$HERDR_PANE_ID" >>"$watchlog" 2>&1 </dev/null &
fi
jq -r --arg name "$name" '.result.agent | "\(.pane_id) \($name) \(.agent) \(.agent_status)"' <<<"$info"
