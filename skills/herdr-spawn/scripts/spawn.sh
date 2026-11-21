#!/usr/bin/env bash
# Usage: spawn.sh [--tab <dir>] [--lane <unit|driver> --goal "<objective>"] <agent> <name> <prompt-file> [<pane-id> <right|down>]
# Splits a sibling pane, types the agent's launch line into its interactive shell (so wrappers, aliases and
# functions apply, and `$(cat file)` expands there), waits for Herdr to detect the agent, names it, and prints
# "<pane-id> <name> <agent-kind> <status>". Without the optional pane/direction, a picker keeps the tab an even
# grid (1 → 2 columns → 2×2 → 3×2 → 3×3 …):
#   1. A column with fewer panes than the tallest column is filled first: split its largest pane "down".
#   2. Otherwise every column has R panes. With C columns: C <= R adds a column ("right"), C > R a row ("down").
# Columns are panes grouped by left edge (rect.x). The caller's pane wins ties within 10% area.
# --tab <dir> (before the positionals, not with <pane-id> <right|down>) opens a new tab with cwd <dir> instead.
# --lane <unit|driver> (before the positionals, needs HERDR_PANE_ID, or HC_TERMINAL_ID in the app) registers the
# child as a lane of the calling pane: LANE_MODE and LANE_COORDINATOR are exported in its shell, its pane gets
# lane_of, lane_mode and lane_state metadata tokens, and lanes-watch.sh runs for the caller (lane.sh is the lane's
# side of the protocol).
# --goal "<objective with its done criterion>" is required with --lane and refused without it: a lane always has a
# goal from its coordinator. The lane's prompt becomes a composed file in the state dir (lane protocol, goal, then
# the caller's brief), and the lane launches from a `lane:<agent>` template that holds the harness to the goal.
# In the Herdr app (HC_TERMINAL_ID set, no HERDR_ENV) it starts the child as an hc terminal of the caller (lane state
# in hc labels, no watcher), or with <pane-id> <right|down> and no --lane splits that pane through herdr-app, and
# prints "<terminal> <name> <app> <state>"; see the block below the jq check.
# Launch templates come from built-in defaults, overridden or extended by the config file
# ${HERDR_SPAWN_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/herdr-spawn/agents.conf}: one "<agent> <template>" per
# line; blank lines and full-line # comments are ignored. With --lane the key is `lane:<agent>`. Placeholders,
# each shell-quoted: {name}, {prompt} (reads the prompt file), {promptfile}, {goal}, {slashgoal} (a /goal line
# pointing at the prompt file), {adapters} (the repo's adapters dir), {occonfig} (an OpenCode config file that
# loads the lane plugin, written only when the template uses it).
set -euo pipefail
# bash 5.2 expands "&" in a ${var//pat/repl} replacement to the match; this script replaces text only where a path is inserted.
shopt -u patsub_replacement 2>/dev/null || true

die() { echo "spawn.sh: $*" >&2; exit 1; }

conf=${HERDR_SPAWN_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/herdr-spawn/agents.conf}

# Prints "<agent> <origin> <template>" lines: the config's entries first (they win).
templates() {
  if [ -r "$conf" ]; then
    local a t
    while read -r a t || [ -n "$a" ]; do
      case $a in ''|'#'*) continue ;; esac
      printf '%s custom %s\n' "$a" "$t"
    done <"$conf"
  fi
  printf '%s\n' 'claude builtin claude -n {name} {prompt}' 'codex builtin codex {prompt}' \
    'opencode builtin opencode --prompt {prompt}' 'omp builtin omp {prompt}' \
    'lane:claude builtin claude -n {name} --append-system-prompt-file {promptfile} {slashgoal}' \
    'lane:codex builtin {builtin-codex-lane}' \
    'lane:opencode builtin export OPENCODE_CONFIG={occonfig}; opencode --standalone --prompt {prompt}' \
    'lane:omp builtin omp --goal {goal} --append-system-prompt {promptfile} -e {adapters}/omp/herdr-lanes.ts'
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

usage="usage: spawn.sh [--tab <dir>] [--lane <unit|driver> --goal <objective>] <agent> <name> <prompt-file> [<pane-id> <right|down>]"
tabdir="" lane="" goal=""
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
    --goal)
      [ $# -ge 5 ] || die "$usage"
      [[ "$2" == *[![:space:]]* ]] || die "--goal needs a non-empty objective"
      goal=$2
      shift 2 ;;
    *) break ;;
  esac
done
[ -z "$goal" ] || [ -n "$lane" ] || die "--goal needs --lane"
[ -z "$lane" ] || [ -n "$goal" ] || die "--lane needs --goal \"<objective with its done criterion>\""
[ $# -eq 3 ] || { [ $# -eq 5 ] && [ -z "$tabdir" ]; } || die "$usage"
agent=$1 name=$2 promptfile=$3
[[ $name =~ ^[a-z][a-z0-9_-]{0,31}$ ]] || die "name must match ^[a-z][a-z0-9_-]{0,31}\$"
[ -r "$promptfile" ] || die "prompt file not readable: $promptfile"
# The child's shell may start in another directory (--tab), so it needs an absolute path.
promptfile=$(CDPATH='' cd -- "$(dirname -- "$promptfile")" && pwd)/${promptfile##*/}

statedir=${XDG_STATE_HOME:-$HOME/.local/state}/herdr-spawn
scriptdir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
adapters=$(CDPATH='' cd -- "$scriptdir/../../.." && pwd)/adapters
if [ -n "$lane" ]; then
  [[ $statedir = /* ]] || statedir=$PWD/$statedir
  callerprompt=$promptfile
  key=lane:$agent
else
  key=$agent
fi

entry=$(templates | awk -v a="$key" '!d && $1 == a { sub(/^[^ ]+ /, ""); print; d = 1 }')
origin=${entry%% *}
template=${entry#* }
if [ -z "$template" ]; then
  if [ -n "$lane" ]; then
    die "unknown lane agent '$agent'; known: $(templates | awk '/^lane:/ { sub(/^lane:/, "", $1); print $1 }' | sort -u | paste -sd' ' -); add lane:$agent to $conf"
  fi
  die "unknown agent '$agent'; known: $(templates | awk '$1 !~ /^lane:/ { print $1 }' | sort -u | paste -sd' ' -); add one to $conf"
fi
# Fills the template's placeholders in one pass, so substituted text (a goal that itself holds "{name}") is
# never scanned again and every inserted value is shell-quoted.
expand() {
  local rest=$1 out=
  while [[ $rest == *"{"* ]]; do
    out+=${rest%%"{"*}
    rest=${rest#*"{"}
    case $rest in
      "name}"*) out+=$name; rest=${rest#"name}"} ;;
      "prompt}"*) out+="\"\$(cat $(printf %q "$promptfile"))\""; rest=${rest#"prompt}"} ;;
      "promptfile}"*) out+=$(printf %q "$promptfile"); rest=${rest#"promptfile}"} ;;
      "goal}"*) out+=$(printf %q "$goal"); rest=${rest#"goal}"} ;;
      "slashgoal}"*) out+=$(printf %q "/goal $goal (brief: $promptfile)"); rest=${rest#"slashgoal}"} ;;
      "adapters}"*) out+=$(printf %q "$adapters"); rest=${rest#"adapters}"} ;;
      "occonfig}"*)
        local config=$statedir/lane-$name-opencode.json
        if [ -n "$lane" ]; then config=$goal_dir/opencode.json; else mkdir -p "$statedir" || return 1; fi
        jq -n --arg p "file://$adapters/opencode/herdr-lanes" '{plugins: [$p]}' >"$config" || return 1
        out+=$(printf %q "$config"); rest=${rest#"occonfig}"} ;;
      *) out+="{" ;;
    esac
  done
  printf '%s' "$out$rest"
}
command -v jq >/dev/null || die "jq is required"

codex_start='' goal_id='' goal_target='' goal_surface=herdr

create_goal_manifest() {
  case "$origin:$agent" in
    builtin:opencode) goal_mode=managed ;;
    builtin:codex|builtin:claude|builtin:omp) goal_mode=native ;;
    *) goal_mode=custom ;;
  esac
  goal_dir=$(
    umask 077
    mkdir -p "$statedir/goals" && mktemp -d "$statedir/goals/g.XXXXXXXXXXXX"
  ) || die "could not allocate a private lane goal manifest"
  goal_id=${goal_dir##*/}
  (
    umask 077
    jq -n --arg goal_id "$goal_id" --arg objective "$goal" --arg goal_mode "$goal_mode" \
      --arg agent "$agent" --arg lane_mode "$lane" '{ $goal_id, $objective, $goal_mode, $agent, $lane_mode }' >"$goal_dir/goal.json" &&
      chmod 400 "$goal_dir/goal.json"
  ) || die "could not write lane goal manifest $goal_id"
}

report_goal_startup() {
  if [ "$goal_surface" = hc ]; then
    hc label "$goal_target" "goal_startup=$1" >/dev/null
  else
    # lane.sh can replace the lifecycle source without losing the manifest reference.
    herdr pane report-metadata "$goal_target" --source herdr-spawn-goal --token "goal_id=$goal_id" \
      --token "goal_mode=$goal_mode" --token "goal_startup=$1" >/dev/null
  fi
}

finish_spawn() {
  if [ -n "$goal_target" ]; then
    report_goal_startup failed || echo "spawn.sh: could not record goal startup failure on $goal_target" >&2
  fi
  if [ -n "$codex_start" ]; then
    rm -f -- "$codex_start/result" "$codex_start/result.tmp"
    rmdir -- "$codex_start"
  fi
}
trap finish_spawn EXIT

codex_ready() {
  [ -n "$codex_start" ] || return 0
  local phase detail
  [ -s "$codex_start/result" ] || return 1
  read -r phase detail <"$codex_start/result" || return 1
  case $phase in
    ready) return 0 ;;
    error) die "Codex native goal startup failed in $1: $detail; left open, inspect with: $2" ;;
    *) return 1 ;;
  esac
}

prepare_launch() {
  if [ -n "$lane" ]; then
    create_goal_manifest
    # The same private, unique directory holds the brief and any generated config.
    promptfile=$goal_dir/brief.md
    local protocol
    protocol=$(cat "$scriptdir/../lane-protocol.md")
    (
      umask 077
      {
        printf '%s\n\n## Goal\n\n%s\n\n## Brief\n\n' "${protocol//LANE_SH/$scriptdir/lane.sh}" "$goal" &&
          cat "$callerprompt"
      } >"$promptfile" && chmod 400 "$promptfile"
    ) || die "could not write the brief for $goal_id"
  fi
  if [ "$key" = lane:codex ] && [ "$origin" = builtin ]; then
    local result
    codex_start=$(mktemp -d "$statedir/.codex-start.XXXXXXXX") || die "could not create Codex startup directory"
    launch=$(printf 'node %q %q %q %q' "$scriptdir/codex-lane.mjs" "$codex_start" "$promptfile" "$goal")
    result=$(printf %q "$codex_start/result")
    launch+=" || { if [ -d $(printf %q "$codex_start") ] && [ ! -s $result ]; then printf '%s\n' 'error Codex lane helper failed (Node.js 18+ is required in the child shell)' > $result; fi; }"
  else
    launch=$(expand "$template") || die "could not prepare the $key launch"
  fi
}

# The Herdr app (herdr-core, `hc`) sets HC_TERMINAL_ID instead of HERDR_ENV. The child launches through hc run
# as the caller's child, so the agents list nests it under the caller: a pane of the caller's tab, or with --tab
# a tab of its space. Only hc run records a parent, so a split (an explicit <pane-id> <right|down> without
# --lane) is the one spawn the list shows on its own. The launch line runs in an interactive instance of the
# user's shell (wrappers, aliases and functions apply), replaced by a plain shell once the agent exits. An hc run
# child doesn't take the person's focus; a split does.
if [ "${HERDR_ENV:-}" != 1 ] && [ -n "${HC_TERMINAL_ID:-}" ]; then
  command -v herdr-app >/dev/null || die "herdr-app is required"
  command -v hc >/dev/null || die "hc (herdr-core) is required"
  if [ $# -eq 3 ] || [ -n "$lane" ]; then
    if hc get "$name" >/dev/null 2>&1; then die "agent name '$name' is already taken"; fi
    where=$(herdr-app ls | jq -r --arg t "$HC_TERMINAL_ID" \
      '.spaces[] | .id as $sid | .tabs[]? | select((.terminals // []) | map(.terminal) | index($t) != null) | "\($sid) \(.id)"')
    [ -n "$where" ] || die "no space or tab shows terminal $HC_TERMINAL_ID; inspect with: herdr-app ls"
    read -r space tab <<<"$where"
    shell=${SHELL:-/bin/sh}
    prepare_launch
    line="$launch; exec $(printf %q "$shell")"
    if [ -n "$lane" ]; then
      line="export LANE_MODE=$(printf %q "$lane"); export LANE_COORDINATOR=$(printf %q "$HC_TERMINAL_ID"); $line"
    fi
    cwd=$tabdir
    [ -n "$cwd" ] || cwd=$PWD
    hc_argv=(--bg --json --name "$name" --cwd "$cwd" --parent "$HC_TERMINAL_ID" --outlive-parent)
    hc_argv+=(--label "herdr.space=$space")
    if [ -z "$tabdir" ]; then hc_argv+=(--label "herdr.tab=$tab"); fi
    if [ -n "$lane" ]; then
      hc_argv+=(--label "lane_of=$HC_TERMINAL_ID" --label "lane_mode=$lane" --label "lane_state=working" --label "lane_report=start-$goal_id"
        --label "goal_id=$goal_id" --label "goal_mode=$goal_mode" --label goal_startup=pending)
    fi
    hc_argv+=(--)
    hc_argv+=("$shell" -ic "$line")
    out=$(hc run "${hc_argv[@]}") || die "hc run failed: $out"
    term=$(jq -r '.address // empty' <<<"$out")
    [ -n "$term" ] || die "hc run returned no terminal: $out"
    if [ -n "$lane" ]; then
      goal_surface=hc goal_target=$term
    fi

    inspect="hc read $term --lines 40"
    status=
    for _ in $(seq 120); do
      if codex_ready "terminal $term" "$inspect"; then
        status=$(hc get "$term" --json | jq -r --arg native "$codex_start" \
          'select(.status.app and ($native == "" or (.status.app | ascii_downcase) == "codex")) | "\(.status.app) \(.status.state)"') || true
        if [ -n "$status" ] && codex_ready "terminal $term" "$inspect"; then break; fi
      fi
      sleep 0.5
    done
    codex_ready "terminal $term" "$inspect" ||
      die "no Codex native goal startup confirmation in terminal $term after 60s, left open; inspect with: $inspect"
    [ -n "$status" ] || die "no agent detected in terminal $term after 60s, left open; inspect with: $inspect"
    if [ -n "$goal_target" ]; then
      report_goal_startup ready || die "could not record goal startup on terminal $term, left open"
      goal_target=
    fi
    echo "$term $name $status"
    exit 0
  fi
  target=$4 dir=$5
  shell=${SHELL:-/bin/sh}
  prepare_launch
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
prepare_launch

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
  goal_target=$pane
  report_goal_startup pending || die "recording goal metadata on pane $pane failed, pane left open"
  # Registered before the agent starts, so a lane that reports at once is never overwritten by a late report.
  herdr pane report-metadata "$pane" --source herdr-spawn --token "lane_of=$HERDR_PANE_ID" --token "lane_mode=$lane" \
    --token lane_state=working --token "lane_report=start-$goal_id" >/dev/null ||
    die "recording the lane tokens on pane $pane failed, pane left open"
  launch="export LANE_MODE=$(printf %q "$lane"); export LANE_COORDINATOR=$(printf %q "$HERDR_PANE_ID"); $launch"
fi
herdr pane run "$pane" "$launch" >/dev/null || die "launch failed; pane $pane left open"

inspect="herdr pane read $pane --source recent --lines 40"
info=
for _ in $(seq 120); do
  if codex_ready "pane $pane" "$inspect" && info=$(herdr agent get "$pane" 2>/dev/null); then
    if [ -z "$codex_start" ] || {
      jq -e '.result.agent.agent == "codex"' <<<"$info" >/dev/null && codex_ready "pane $pane" "$inspect"
    }; then break; fi
  fi
  info=
  sleep 0.5
done
codex_ready "pane $pane" "$inspect" ||
  die "no Codex native goal startup confirmation in pane $pane after 60s, pane left open; inspect with: $inspect"
[ -n "$info" ] || die "no agent detected in pane $pane after 60s, pane left open; inspect with: $inspect"

herdr agent rename "$pane" "$name" >/dev/null ||
  die "agent running in $pane but rename to $name failed (name taken?)"
if [ -n "$goal_target" ]; then
  report_goal_startup ready || die "could not record goal startup on pane $pane, left open"
  goal_target=
fi

if [ -n "$lane" ]; then
  watchlog=$statedir/watch-${HERDR_PANE_ID//[!A-Za-z0-9_-]/_}.log
  watch=$scriptdir/lanes-watch.sh
  # Detached so the watcher outlives this script and the caller's tool call; it exits at once if one already runs.
  detach='nohup'
  if command -v setsid >/dev/null; then detach=setsid; fi
  "$detach" "$watch" "$HERDR_PANE_ID" >>"$watchlog" 2>&1 </dev/null &
fi
jq -r --arg name "$name" '.result.agent | "\(.pane_id) \($name) \(.agent) \(.agent_status)"' <<<"$info"
