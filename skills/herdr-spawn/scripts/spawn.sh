#!/usr/bin/env bash
# Usage: spawn.sh [--tab <dir> [--lane <unit|driver>] | --subtask-of <root>] [--goal <objective>]
#                 [--task <class>] [--model <id|default>] <agent> <name> <prompt-file> [<pane-id> <right|down>]
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
# --subtask-of <root> creates a unit lane in the root's tab and workdir, still reporting to the caller.
# --goal "<objective with its done criterion>" is required for lanes and refused otherwise: a lane always has a
# goal from its coordinator. The lane's prompt becomes a composed file in the state dir (lane protocol, goal, then
# the caller's brief), and the lane launches from a `lane:<agent>` template that holds the harness to the goal.
# In the Herdr app (HC_TERMINAL_ID set, no HERDR_ENV) it starts the child as an hc terminal of the caller (lane state
# in hc labels, no watcher), or with <pane-id> <right|down> and no --lane splits that pane through herdr-app, and
# prints "<terminal> <name> <app> <state>"; see the block below the jq check. With --tab it then names the new tab
# after the child through herdr-app, when herdr-app on this host lists that tab.
# Under Claude Code it warns on stderr when installed_plugins.json records another copy of this plugin as installed.
# Launch templates come from built-in defaults, overridden or extended by the config file
# ${HERDR_SPAWN_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/herdr-spawn/agents.conf}: one "<agent> <template>" per
# line; blank lines and full-line # comments are ignored. With --lane the key is `lane:<agent>`. Placeholders,
# each shell-quoted: {name}, {prompt} (reads the prompt file), {promptfile}, {goal}, {slashgoal} (a /goal line
# pointing at the prompt file), {adapters} (the repo's adapters dir), {occonfig} (an OpenCode config file that
# can load the lane plugin and set a model), {model}, {modelarg} (optional --model pair).
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
  printf '%s\n' 'claude builtin claude {modelarg} -n {name} {prompt}' 'codex builtin codex {modelarg} {prompt}' \
    'opencode builtin opencode --prompt {prompt}' 'omp builtin omp {modelarg} {prompt}' \
    'lane:claude builtin claude {modelarg} -n {name} --append-system-prompt-file {promptfile} {slashgoal}' \
    'lane:codex builtin {builtin-codex-lane}' \
    'lane:opencode builtin export OPENCODE_CONFIG={occonfig}; opencode --standalone --prompt {prompt}' \
    'lane:omp builtin omp {modelarg} --goal {goal} --append-system-prompt {promptfile} -e {adapters}/omp/herdr-lanes.ts'
}

lookup() { templates | awk -v a="$1" '!d && $1 == a { sub(/^[^ ]+ /, ""); print; d = 1 }'; }

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

usage="usage: spawn.sh [--tab <dir> [--lane <unit|driver>] | --subtask-of <root>] [--goal <objective>] [--task <class>] [--model <id|default>] <agent> <name> <prompt-file> [<pane-id> <right|down>]"
tabpath="" tabdir="" lane="" goal="" root_ref="" task_class="" model_option=""
model_pattern='^[A-Za-z0-9][A-Za-z0-9._+@:-]*(/[A-Za-z0-9][A-Za-z0-9._+@:-]*)*$'
valid_model() { local LC_ALL=C; [[ $1 =~ $model_pattern ]]; }
absolute_dir() { CDPATH='' cd "$@" && printf '%s.' "$PWD"; }
while [ $# -gt 0 ]; do
  case $1 in
    --tab)
      [ $# -ge 5 ] || die "$usage"
      [ -d "$2" ] || die "--tab directory not found: $2"
      tabpath=$2
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
    --subtask-of)
      [ $# -ge 5 ] || die "$usage"
      [[ -n $2 && $2 != -* ]] || die "--subtask-of needs a root lane name or ID"
      root_ref=$2
      shift 2 ;;
    --task)
      [ $# -ge 5 ] || die "$usage"
      case $2 in mechanical|simple|complex|exceptional|fact-check) task_class=$2 ;;
        *) die "--task must be mechanical, simple, complex, exceptional, or fact-check" ;;
      esac
      shift 2 ;;
    --model)
      [ $# -ge 5 ] || die "$usage"
      valid_model "$2" || die "--model needs a safe model ID or default"
      model_option=$2
      shift 2 ;;
    *) break ;;
  esac
done
if [ -n "$root_ref" ]; then
  [ -z "$tabpath$lane" ] && [ $# -eq 3 ] || die "--subtask-of does not combine with --tab, --lane, or an explicit split"
  lane=unit
elif [ -n "$lane" ]; then
  [ -n "$tabpath" ] || die "--lane needs --tab <dir>"
  tabdir=$(absolute_dir -P -- "$tabpath") || die "could not resolve --tab directory: $tabpath"
  tabdir=${tabdir%.}
elif [ -n "$tabpath" ]; then
  tabdir=$(absolute_dir -- "$tabpath") || die "could not resolve --tab directory: $tabpath"
  tabdir=${tabdir%.}
fi
[ -z "$goal" ] || [ -n "$lane" ] || die "--goal needs --lane or --subtask-of"
[ -z "$lane" ] || [ -n "$goal" ] || die "a lane needs --goal \"<objective with its done criterion>\""
[ $# -eq 3 ] || { [ $# -eq 5 ] && [ -z "$tabdir" ]; } || die "$usage"
agent=$1 name=$2 promptfile=$3
case $agent in lane:*|model:*) die "agent must not start with lane: or model:" ;; esac
[[ $name =~ ^[a-z][a-z0-9_-]{0,31}$ ]] || die "name must match ^[a-z][a-z0-9_-]{0,31}\$"
[ -r "$promptfile" ] || die "prompt file not readable: $promptfile"
command -v jq >/dev/null || die "jq is required"
# The child's shell may start in another directory (--tab), so it needs an absolute path.
promptfile=$(CDPATH='' cd -- "$(dirname -- "$promptfile")" && pwd)/${promptfile##*/}

statedir=${XDG_STATE_HOME:-$HOME/.local/state}/herdr-spawn
[[ $statedir = /* ]] || statedir=$PWD/$statedir
# -P: the skill directory is often a symlink to the repo (the README's install), and the walk up to adapters must
# leave from the repo, not from the link's parent.
scriptdir=$(CDPATH='' cd -P -- "$(dirname -- "$0")" && pwd)
adapters=$(CDPATH='' cd -- "$scriptdir/../../.." && pwd)/adapters
# A Claude Code session keeps the plugin copy it loaded after an update installs another beside it, so its skill
# text can describe flags and steps this copy lacks. This plugin's records are those whose installPath shares
# this copy's parent (cache/<marketplace>/<plugin>/<version>); a copy outside the cache, such as a clone, has none.
plugin_root=${adapters%/adapters}
installed=${CLAUDE_CONFIG_DIR:-$HOME/.claude}/plugins/installed_plugins.json
if [ -r "$installed" ]; then
  recorded=$(jq -r --arg root "$plugin_root" '
    [.plugins[]?[]? | select(.installPath | type == "string")] as $all
    | ($root | sub("/[^/]*$"; "")) as $parent
    | if any($all[]; .installPath == $root) then empty
      else first($all[] | select((.installPath | sub("/[^/]*$"; "")) == $parent) | "\(.version) \(.installPath)")
      end' "$installed" 2>/dev/null) || recorded=
  if [ -n "$recorded" ]; then
    own=$(jq -r '.version // "unknown"' "$plugin_root/.claude-plugin/plugin.json" 2>/dev/null) || own=unknown
    echo "spawn.sh: warning: running herdr-spawn $own ($plugin_root), but ${recorded%% *} is installed (${recorded#* });" \
      "this session loaded a skill copy other than the installed one, so ask the user to start a new session to use ${recorded%% *}" >&2
  fi
fi
if [ -n "$lane" ]; then
  callerprompt=$promptfile
  key=lane:$agent
else
  key=$agent
fi

entry=$(lookup "$key")
origin=${entry%% *}
template=${entry#* }
if [ -z "$template" ]; then
  if [ -n "$lane" ]; then
    die "unknown lane agent '$agent'; known: $(templates | awk '/^lane:/ { sub(/^lane:/, "", $1); print $1 }' | sort -u | paste -sd' ' -); add lane:$agent to $conf"
  fi
  die "unknown agent '$agent'; known: $(templates | awk '$1 !~ /^(lane|model):/ { print $1 }' | sort -u | paste -sd' ' -); add one to $conf"
fi

explicit_task=$task_class
case "$task_class:$lane" in
  :driver) task_class=complex ;;
  :unit) task_class=simple ;;
esac
model=
route_model() {
  [ "$model_option" != default ] || return 0
  [ -n "$model_option$task_class" ] || return 0
  if [ "$origin" = custom ] && [[ $template != *'{model}'* && $template != *'{modelarg}'* ]]; then
    [ -z "$model_option$explicit_task" ] ||
      die "$key template cannot route a model; add {model} or {modelarg}, or use --model default"
    echo "spawn.sh: $key custom template kept its own model; replace any fixed --model with {modelarg} in $conf to enable routing" >&2
    return 0
  fi
  if [ -n "$model_option" ]; then
    model=$model_option
    return 0
  fi
  local tier index override
  local -a defaults
  case $task_class in
    mechanical) tier=small index=0 ;;
    simple) tier=standard index=1 ;;
    complex) tier=strong index=2 ;;
    exceptional|fact-check) tier=frontier index=3 ;;
  esac
  override=$(lookup "model:$agent:$tier")
  if [ -n "$override" ]; then
    model=${override#* }
    valid_model "$model" && [ "$model" != default ] || die "invalid model ID in model:$agent:$tier in $conf"
    return 0
  fi
  case $agent in
    claude) defaults=(haiku sonnet opus fable) ;;
    codex|opencode|omp) defaults=(gpt-6-luna gpt-6.1-terra gpt-6.2-sol gpt-6.2-astra) ;;
    *)
      [ -z "$explicit_task" ] || die "no model mapping for $agent/$tier; add model:$agent:$tier to $conf or use --model default"
      echo "spawn.sh: no model mapping for $agent/$tier; add model:$agent:$tier to $conf to enable routing" >&2
      return 0 ;;
  esac
  model=${defaults[index]}
  case $agent in
    opencode) model=openai/$model ;;
    omp) model=openai-codex/$model ;;
  esac
}
route_model
if [ "$origin" = builtin ]; then
  if [ -z "$model" ]; then
    template=${template/' {modelarg}'/}
  elif [ "$key" = opencode ]; then
    # shellcheck disable=SC2016 # Inspect the child shell's environment at launch.
    template='if [ -z "${OPENCODE_CONFIG:-}" ]; then export OPENCODE_CONFIG={occonfig}; fi; opencode --standalone --prompt {prompt}'
  fi
fi

opencode_plugin="file://$adapters/opencode/herdr-lanes"
opencode_config() {
  local config plugin=''
  if [ -n "$lane" ]; then
    config=$goal_dir/opencode.json
  else
    mkdir -p "$statedir" || return 1
    if [ -n "$model" ]; then
      config=$(mktemp -d "$statedir/oc.XXXXXXXXXXXX")/opencode.json || return 1
    else
      config=$statedir/lane-$name-opencode.json
    fi
  fi
  if [ -n "$lane" ] || [ "$origin" = custom ]; then plugin=$opencode_plugin; fi
  jq -n --arg p "$plugin" --arg model "$model" '
    (if $p == "" then {} else {plugins: [$p]} end)
    + (if $model == "" then {} else {$model} end)' >"$config" || return 1
  printf %q "$config"
}

# shellcheck disable=SC2016 # jq variables, not shell variables.
oc_inline_filter='
  (env.OPENCODE_CONFIG_CONTENT // "" | if . == "" then {} else fromjson end)
  | if type != "object" then error("expected one JSON object") else . end
  | .model = $model
  | if $plugin != "" and (.plugins | type) == "array"
      and all(.plugins[]; . != $plugin and (type != "array" or .[0] != $plugin))
    then .plugins += [$plugin] else . end
'
oc_inline=''
if [ "$origin:$agent" = builtin:opencode ] && [ -n "$model" ]; then
  inline_plugin=''
  if [ -n "$lane" ]; then inline_plugin=$opencode_plugin; fi
  # Check the caller's environment before placement; merge the child's own inline config at launch.
  # The inherited JSON can hold credentials, so never paste it into a pane or print parse errors.
  jq -nce --arg model "$model" --arg plugin "$inline_plugin" "$oc_inline_filter" >/dev/null 2>&1 ||
    die "OPENCODE_CONFIG_CONTENT must contain one valid JSON object to route a model"
  printf -v oc_inline 'jq -nce --arg model %q --arg plugin %q %q 2>/dev/null' \
    "$model" "$inline_plugin" "$oc_inline_filter"
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
      "model}"*) out+=$(printf %q "$model"); rest=${rest#"model}"} ;;
      "modelarg}"*)
        if [ -n "$model" ]; then out+=$(printf -- '--model %q' "$model"); fi
        rest=${rest#"modelarg}"} ;;
      "occonfig}"*)
        out+=$(opencode_config) || return 1
        rest=${rest#"occonfig}"} ;;
      *) out+="{" ;;
    esac
  done
  printf '%s' "$out$rest"
}
codex_start='' goal_id='' goal_target='' goal_surface=herdr parent_lane='' workdir=$tabdir

resolve_parent_lane() {
  local coordinator=$1 info root required ref manifest canonical
  if [ "$goal_surface" = hc ]; then
    placement=$(unset HC_TERMINAL_ID; hc get "$root_ref" --json) || die "no root lane terminal $root_ref"
    root=$(jq -c '{id: .address, meta: .labels}' <<<"$placement")
  elif [[ $root_ref != *:* ]] && info=$(herdr agent get "$root_ref" 2>/dev/null); then
    root=$(jq -c '.result.agent | {id: .pane_id, meta: .tokens}' <<<"$info")
  else
    info=$(herdr pane get "$root_ref") || die "no root lane pane $root_ref"
    root=$(jq -c '.result.pane | {id: .pane_id, meta: .tokens}' <<<"$info")
  fi
  required=$(jq -ec --arg coordinator "$coordinator" '
    select((.id | strings | test("^[^-[:space:]][^[:space:]]*$"))
      and .meta.lane_of == $coordinator and .meta.goal_startup == "ready")
  ' <<<"$root") || die "$root_ref is not a ready lane of the caller"
  parent_lane=$(jq -r '.id' <<<"$required")
  ref=$(jq -r '.meta.goal_id // empty' <<<"$required")
  [[ $ref =~ ^g\.[[:alnum:]]{12}$ ]] || die "$root_ref has no valid goal manifest reference"
  manifest=$statedir/goals/$ref/goal.json
  [ ! -L "${manifest%/*}" ] && [ -O "${manifest%/*}" ] &&
    [ ! -L "$manifest" ] && [ -O "$manifest" ] && [ -f "$manifest" ] &&
    [ -n "$(find "${manifest%/*}" -prune -type d -perm 0700 -print)" ] &&
    [ -n "$(find "$manifest" -prune -perm 0400 -print)" ] ||
    die "$root_ref has no private goal manifest $ref"
  workdir=$(jq -ser --argjson root "$required" --arg pattern "$model_pattern" '
    select(length == 1) | .[0] | select(
      .goal_id == $root.meta.goal_id and .goal_mode == $root.meta.goal_mode
      and (.goal_mode == "managed" or .goal_mode == "native" or .goal_mode == "custom")
      and .lane_mode == $root.meta.lane_mode and (.lane_mode == "unit" or .lane_mode == "driver")
      and (.objective | strings | test("[^[:space:]]")) and (.agent | strings | length > 0)
      and has("parent_lane") and .parent_lane == null
      and (.task_class == "mechanical" or .task_class == "simple" or .task_class == "complex"
        or .task_class == "exceptional" or .task_class == "fact-check")
      and has("model") and (.model == null or (.model | strings | test($pattern)))
    ) | .workdir | strings | select(startswith("/") and (contains("\u0000") | not)) | . + "."
  ' "$manifest") || die "$root_ref is not a registered root lane with a matching goal manifest"
  workdir=${workdir%.}
  canonical=$(absolute_dir -P -- "$workdir" 2>/dev/null) ||
    die "workdir for root lane $root_ref no longer exists: $workdir"
  [ "${canonical%.}" = "$workdir" ] || die "workdir for root lane $root_ref is no longer canonical: $workdir"
}

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
      --arg agent "$agent" --arg lane_mode "$lane" --arg parent_lane "$parent_lane" \
      --arg workdir "$workdir" --arg task_class "$task_class" --arg model "$model" '
      { $goal_id, $objective, $goal_mode, $agent, $lane_mode, $workdir, $task_class,
        parent_lane: ($parent_lane | select(length > 0) // null), model: ($model | select(length > 0) // null) }
    ' >"$goal_dir/goal.json" &&
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
    if [ -n "$model" ]; then launch+=" $(printf %q "$model")"; fi
    result=$(printf %q "$codex_start/result")
    launch+=" || { if [ -d $(printf %q "$codex_start") ] && [ ! -s $result ]; then printf '%s\n' 'error Codex lane helper failed (Node.js 18+ is required in the child shell)' > $result; fi; }"
  else
    launch=$(expand "$template") || die "could not prepare the $key launch"
    if [ -n "$oc_inline" ]; then
      # shellcheck disable=SC2016 # Merge only after entering the child shell.
      launch='( set +x; if OPENCODE_CONFIG_CONTENT=$('"$oc_inline"'); then export OPENCODE_CONFIG_CONTENT; '"$launch"'; else printf "%s\n" "spawn.sh: invalid child OPENCODE_CONFIG_CONTENT; OpenCode not started" >&2; exit 1; fi )'
    fi
  fi
}

# The Herdr app (herdr-core, `hc`) sets HC_TERMINAL_ID instead of HERDR_ENV. The child launches through hc run
# as the caller's child, so the agents list nests it under the caller: a pane of the caller's tab, or with --tab
# a tab of its space. Only hc run records a parent, so a split (an explicit <pane-id> <right|down> without
# --lane) is the one spawn the list shows on its own. The launch line runs in an interactive instance of the
# user's shell (wrappers, aliases and functions apply), replaced by a plain shell once the agent exits. An hc run
# child doesn't take the person's focus; a split does.
if [ "${HERDR_ENV:-}" != 1 ] && [ -n "${HC_TERMINAL_ID:-}" ]; then
  command -v hc >/dev/null || die "hc (herdr-core) is required"
  if [ $# -eq 3 ]; then
    if hc get "$name" >/dev/null 2>&1; then die "agent name '$name' is already taken"; fi
    # The placement labels live on the caller's core, even when the window runs on another host.
    goal_surface=hc
    if [ -n "$root_ref" ]; then
      resolve_parent_lane "$HC_TERMINAL_ID"
      label_owner="root lane terminal $parent_lane"
      no_tab_hint=
    else
      placement=$(hc get "$HC_TERMINAL_ID" --json) || die "could not read coordinator terminal $HC_TERMINAL_ID"
      label_owner="coordinator terminal $HC_TERMINAL_ID"
      no_tab_hint='; use --tab or start from a tab created in Herdr App'
    fi
    space=$(jq -er '.labels["herdr.space"] | strings | select(length > 0)' <<<"$placement") ||
      die "$label_owner has no herdr.space label; open it in Herdr first"
    if [ -n "$tabdir" ]; then
      # The app creates unknown tab IDs from labels but does not label tabs it assigns itself.
      tab="tbspawn-$(date +%s)-$$-$RANDOM"
    else
      tab=$(jq -er '.labels["herdr.tab"] | strings | select(length > 0)' <<<"$placement") ||
        die "$label_owner has no herdr.tab label$no_tab_hint"
    fi
    shell=${SHELL:-/bin/sh}
    prepare_launch
    line="$launch; exec $(printf %q "$shell")"
    if [ -n "$lane" ]; then
      line="export LANE_MODE=$(printf %q "$lane"); export LANE_COORDINATOR=$(printf %q "$HC_TERMINAL_ID"); $line"
    fi
    cwd=$workdir
    [ -n "$cwd" ] || cwd=$PWD
    hc_argv=(--bg --json --name "$name" --cwd "$cwd" --parent "$HC_TERMINAL_ID" --outlive-parent)
    hc_argv+=(--label "herdr.space=$space" --label "herdr.tab=$tab")
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
      goal_target=$term
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
    # hc labels carry no tab name, so the window names a label-made tab by its number. Only a window on this
    # host can rename it; placement already works without one, so naming never fails the spawn. A hung window must
    # not hold the spawn once its child runs, so the calls are bounded where `timeout` exists (macOS lacks it).
    app=(herdr-app)
    command -v timeout >/dev/null && app=(timeout 5 herdr-app)
    if [ -n "$tabdir" ] && command -v herdr-app >/dev/null &&
      "${app[@]}" ls 2>/dev/null | jq -e --arg tab "$tab" 'any(.spaces[]?.tabs[]?; .id == $tab)' >/dev/null 2>&1; then
      "${app[@]}" 'do' tab.rename --id "$tab" --name "$name" >/dev/null 2>&1 ||
        echo "spawn.sh: could not name tab $tab after $name; it keeps its number" >&2
    fi
    echo "$term $name $status"
    exit 0
  fi
  command -v herdr-app >/dev/null || die "run an explicit pane split on the window's host with herdr-app on PATH"
  target=$4 dir=$5
  shell=${SHELL:-/bin/sh}
  prepare_launch
  line="cd $(printf %q "$PWD") && $launch; exec $(printf %q "$shell")"
  split=$(herdr-app 'do' pane.split --pane "$target" --direction "$dir" \
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
[ -z "$lane" ] || [ -n "${HERDR_PANE_ID:-}" ] || die "a lane needs HERDR_PANE_ID, the coordinator's pane"
if herdr agent get "$name" >/dev/null 2>&1; then die "agent name '$name' is already taken"; fi
if [ -n "$root_ref" ]; then resolve_parent_lane "$HERDR_PANE_ID"; fi
prepare_launch

if [ -n "$tabdir" ]; then
  tabcmd=(herdr tab create)
  [ -z "${HERDR_WORKSPACE_ID:-}" ] || tabcmd+=(--workspace "$HERDR_WORKSPACE_ID")
  pane=$("${tabcmd[@]}" --cwd "$tabdir" --label "$name" --no-focus | jq -r '.result.root_pane.pane_id')
  { [ -n "$pane" ] && [ "$pane" != null ]; } || die "tab create returned no pane id"
else
  if [ -n "$parent_lane" ]; then
    target=$parent_lane dir=right
  elif [ $# -eq 5 ]; then
    target=$4 dir=$5
  else
    picked=$(pick) || die "could not pick a pane to split; pass <pane-id> <right|down>"
    read -r target dir <<<"$picked"
  fi
  { [ -n "${target:-}" ] && [ "$target" != null ] && [ -n "${dir:-}" ] && [ "$dir" != null ]; } ||
    die "could not pick a pane to split; pass <pane-id> <right|down>"

  pane=$(herdr pane split "$target" --direction "$dir" --cwd "${workdir:-$PWD}" --no-focus | jq -r '.result.pane.pane_id')
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
