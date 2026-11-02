#!/usr/bin/env bash
# Usage: spawn.sh <name> '<launch-command>' [<pane-id> <right|down>]
# Splits a sibling pane, types the launch command into its interactive shell (so wrappers, aliases and
# `$(cat file)` expand there), waits for Herdr to detect the agent, names it, and prints
# "<pane-id> <name> <agent-kind> <status>". Without the optional pane/direction, a picker keeps the tab an even
# grid (1 → 2 columns → 2×2 → 3×2 → 3×3 …):
#   1. A column with fewer panes than the tallest column is filled first: split its largest pane "down".
#   2. Otherwise every column has R panes. With C columns: C <= R adds a column ("right"), C > R a row ("down").
# Columns are panes grouped by left edge (rect.x). The caller's pane wins ties within 10% area.
set -euo pipefail

die() { echo "spawn.sh: $*" >&2; exit 1; }

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

[ $# -eq 2 ] || [ $# -eq 4 ] || die "usage: spawn.sh <name> '<launch-command>' [<pane-id> <right|down>]"
name=$1 launch=$2
[ "${HERDR_ENV:-}" = 1 ] || die "not inside Herdr (HERDR_ENV != 1)"
command -v jq >/dev/null || die "jq is required"
[[ $name =~ ^[a-z][a-z0-9_-]{0,31}$ ]] || die "name must match ^[a-z][a-z0-9_-]{0,31}\$"
if herdr agent get "$name" >/dev/null 2>&1; then die "agent name '$name' is already taken"; fi

if [ $# -eq 4 ]; then target=$3 dir=$4; else read -r target dir < <(pick); fi
[ -n "${target:-}" ] && [ -n "${dir:-}" ] || die "could not pick a pane to split; pass <pane-id> <right|down>"

pane=$(herdr pane split "$target" --direction "$dir" --cwd "$PWD" --no-focus | jq -r '.result.pane.pane_id')
herdr pane run "$pane" "$launch" >/dev/null

info=
for _ in $(seq 120); do
  if info=$(herdr agent get "$pane" 2>/dev/null); then break; fi
  info=
  sleep 0.5
done
[ -n "$info" ] || die "no agent detected in pane $pane after 60s; inspect with: herdr pane read $pane --source recent --lines 40"

herdr agent rename "$pane" "$name" >/dev/null
jq -r --arg name "$name" '.result.agent | "\(.pane_id) \($name) \(.agent) \(.agent_status)"' <<<"$info"
