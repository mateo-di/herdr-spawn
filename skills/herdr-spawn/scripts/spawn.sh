#!/usr/bin/env bash
# Usage: spawn.sh <agent> <name> <prompt-file> [<pane-id> <right|down>]
# Splits a sibling pane, types the agent's launch line into its interactive shell (so wrappers, aliases and
# functions apply, and `$(cat file)` expands there), waits for Herdr to detect the agent, names it, and prints
# "<pane-id> <name> <agent-kind> <status>". Without the optional pane/direction, a picker keeps the tab an even
# grid (1 → 2 columns → 2×2 → 3×2 → 3×3 …):
#   1. A column with fewer panes than the tallest column is filled first: split its largest pane "down".
#   2. Otherwise every column has R panes. With C columns: C <= R adds a column ("right"), C > R a row ("down").
# Columns are panes grouped by left edge (rect.x). The caller's pane wins ties within 10% area.
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

[ $# -eq 3 ] || [ $# -eq 5 ] || die "usage: spawn.sh <agent> <name> <prompt-file> [<pane-id> <right|down>]"
agent=$1 name=$2 promptfile=$3
[[ $name =~ ^[a-z][a-z0-9_-]{0,31}$ ]] || die "name must match ^[a-z][a-z0-9_-]{0,31}\$"
[ -r "$promptfile" ] || die "prompt file not readable: $promptfile"

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
if herdr agent get "$name" >/dev/null 2>&1; then die "agent name '$name' is already taken"; fi

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
jq -r --arg name "$name" '.result.agent | "\(.pane_id) \($name) \(.agent) \(.agent_status)"' <<<"$info"
