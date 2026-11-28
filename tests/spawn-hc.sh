#!/usr/bin/env bash
set -euo pipefail

repo=$(dirname -- "$0")/..
tmp=$(mktemp -d)
trap 'rm -r -- "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/timeout" "$tmp/work tree" "$tmp/home"
printf '%s\n' 'Test brief' >"$tmp/prompt"
TEST_REAL_CAT=$(command -v cat)
export TEST_REAL_CAT

# The launch lines run for real, in an interactive shell whose agent CLIs are all fakes.
cat >"$tmp/bin/test-launch" <<'SH'
#!/usr/bin/env bash
set -eu
if [[ ${TEST_ASYNC:-0} == 1 ]]; then
  "$@" </dev/null >"$TEST_PANE" 2>&1 &
else
  "$@" </dev/null >"$TEST_PANE" 2>&1
fi
SH
cat >"$tmp/bin/test-shell" <<'SH'
#!/usr/bin/env bash
set -eu
# With no arguments it is the plain shell left behind once the agent exits.
[[ $# -gt 0 ]] || exit 0
[[ $# -eq 2 && $1 == -ic ]]
if [[ ${TEST_CHILD_ZSH:-0} == 1 ]]; then
  ZDOTDIR=${TEST_RC%/*} exec zsh -d -ic "$2"
fi
exec bash --noprofile --rcfile "$TEST_RC" -ic "$2"
SH
cat >"$tmp/rc" <<'SH'
PATH="${TEST_RC%/*}/bin:$PATH"
case ${TEST_CLAUDE_WRAPPER:-} in
  function) claude() { TEST_VIA=wrapper command claude "$@"; } ;;
  alias) alias claude='TEST_VIA=alias claude' ;;
esac
opencode() { TEST_VIA=wrapper command opencode --auto "$@"; }
alias omp='TEST_VIA=alias omp'
# As where an interactive shell aliases find to a tool that takes other options.
alias find=false
if [[ ${TEST_CODEX_WRAPPER:-0} == 1 ]]; then
  codex() { TEST_VIA=wrapper command codex "$@"; }
fi
SH
ln -s rc "$tmp/.zshrc"
cat >"$tmp/bin/test-agent" <<'SH'
#!/usr/bin/env bash
set -eu
app=$1
shift
jq -cn --arg app "$app" --arg via "${TEST_VIA:-}" --arg session_name "${HERDR_SPAWN_SESSION_NAME:-}" \
  --arg config "${OPENCODE_CONFIG:-}" '{$app, argv: $ARGS.positional, $via, $session_name, $config}' \
  --args -- "$@" >>"$TEST_CALLS"
# A naming step must run before the startup mark, or its process could pass for the child.
case "$app:${1:-}:${2:-}" in
  claude:-p:*|opencode:api:*|node:--name-only:*)
    for result in "$XDG_STATE_HOME"/herdr-spawn/.startup.*/result; do
      if [[ -e $result ]]; then printf '%s\n' 'marked before the naming step ended' >&2; exit 1; fi
    done
    ;;
esac
case "$app:${1:-}" in
  claude:-p)
    sleep "${TEST_STEP_DELAY:-0}"
    color=${!#}
    # The session ID is the argument before the command. Claude Code saves the session under it.
    if [[ ${TEST_CLAUDE_EXIT:-0} == 0 && ${TEST_CLAUDE_NO_TRANSCRIPT:-0} != 1 ]]; then
      projects=${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects
      mkdir -p "$projects/child"
      : >"$projects/child/${@:$#-1:1}.jsonl"
    fi
    printf '%s\n' "${TEST_CLAUDE_RESPONSE:-Session color set to: ${color#/color }}"
    exit "${TEST_CLAUDE_EXIT:-0}"
    ;;
  opencode:api)
    sleep "${TEST_STEP_DELAY:-0}"
    if [[ -n ${TEST_OC_RESPONSE:-} ]]; then printf '%s\n' "$TEST_OC_RESPONSE"
    else jq -c '{data: {id: "ses_abc123", title, location}}' <<<"${!#}"; fi
    exit "${TEST_OC_EXIT:-0}"
    ;;
  opencode:--auto)
    if [[ ${2:-} == api ]]; then printf '%s\n' 'Unrecognized flag: --auto' >&2; exit 1; fi
    ;;
  node:*) exit 0 ;;
esac
exit "${TEST_TUI_EXIT:-0}"
SH
for agent in claude codex opencode omp; do
  printf '#!/usr/bin/env bash\nexec test-agent %s "$@"\n' "$agent" >"$tmp/bin/$agent"
done
# The Codex helper only; codex-lane.test.mjs covers the real one.
cat >"$tmp/bin/node" <<'SH'
#!/usr/bin/env bash
set -eu
[[ $1 == */codex-lane.mjs ]]
shift
test-agent node "$@"
sleep "${TEST_STEP_DELAY:-0}"
if [[ $1 == --name-only ]]; then
  if [[ ${TEST_NODE_EXIT:-0} != 0 ]]; then
    printf '%s\n' 'codex-lane: test failure' >&2
    exit "$TEST_NODE_EXIT"
  fi
  printf '%s\n' test-thread
else
  printf '%s\n' 'ready test-thread' >"$1/result.tmp"
  mv "$1/result.tmp" "$1/result"
fi
SH
cat >"$tmp/bin/uuidgen" <<'SH'
#!/usr/bin/env bash
[[ ${TEST_NO_UUIDGEN:-0} != 1 ]] || exit 127
printf '%s\n' ABCDEF12-3456-4ABC-8ABC-123456789ABC
SH
cat >"$tmp/bin/cat" <<'SH'
#!/usr/bin/env bash
if [[ ${1:-} == /proc/sys/kernel/random/uuid ]]; then
  [[ ${TEST_NO_PROC_UUID:-0} != 1 ]] || exit 1
  printf '%s\n' fedcba98-7654-4321-8fed-cba987654321
  exit 0
fi
exec "$TEST_REAL_CAT" "$@"
SH
# Records its arguments; a hung claude is one it reports as cut off.
cat >"$tmp/timeout/timeout" <<'SH'
#!/usr/bin/env bash
set -eu
jq -cn '$ARGS.positional' --args -- "$@" >>"$TEST_TIMEOUTS"
[[ $1 != -k ]] || shift 2
[[ ${TEST_CLAUDE_HANG:-0} != 1 || $2 != claude ]] || exit 124
shift
exec "$@"
SH
# Records whether a status query came after the child marked its startup directory.
cat >"$tmp/bin/test-status" <<'SH'
#!/usr/bin/env bash
mark=unmarked
for result in "$XDG_STATE_HOME"/herdr-spawn/.startup.*/result; do
  [[ -s $result && -n $(find "${result%/*}" -prune -perm 0700) ]] && mark=marked
done
printf '%s\n' "$mark" >>"$TEST_STATUS"
# The first query can still see another app than the child's own.
if [[ -n ${TEST_APP_LATE:-} && $(wc -l <"$TEST_STATUS") -gt 1 ]]; then
  printf '%s\n' "$TEST_APP_LATE"
else
  printf '%s\n' "${TEST_APP:-test-agent}"
fi
SH
cat >"$tmp/bin/herdr" <<'SH'
#!/usr/bin/env bash
set -eu
case "$1:$2" in
  agent:get)
    [[ $3 == p-child ]] || exit 1
    jq -nc --arg app "$(test-status)" \
      '{result: {agent: {pane_id: "p-child", agent: $app, agent_status: "idle", agent_session: {value: "s-child"}}}}'
    ;;
  pane:split) printf '%s\n' '{"result":{"pane":{"pane_id":"p-child"}}}' ;;
  tab:create) printf '%s\n' '{"result":{"root_pane":{"pane_id":"p-child"}}}' ;;
  pane:run) test-launch "$SHELL" -ic "$4" ;;
  agent:rename|pane:report-metadata) ;;
  # The lanes watcher stops at once.
  pane:get) printf '%s\n' pane_not_found >&2; exit 1 ;;
  *) exit 99 ;;
esac
SH
cat >"$tmp/bin/hc" <<'SH'
#!/usr/bin/env bash
set -eu
case "$1:$2" in
  get:t-parent)
    jq -nc --arg space "$TEST_SPACE" --arg tab "$TEST_TAB" \
      '{labels: {"herdr.space": $space, "herdr.tab": $tab}}'
    ;;
  get:t-child) printf '{"status":{"app":"%s","state":"%s"}}\n' "$(test-status)" "${TEST_CHILD_STATE:-idle}" ;;
  get:done-name) printf '%s\n' '{"state":"finished"}' ;;
  get:live-name) printf '%s\n' '{"state":"live"}' ;;
  get:*) exit 3 ;;
  label:t-child)
    case "${3:-}" in goal_startup=ready|goal_startup=blocked) ;; *) exit 1 ;; esac
    printf '%s\n' "$3" >"$TEST_LABEL"
    ;;
  run:*)
    printf '%s\n' "$@" >"$TEST_ARGS"
    while [[ $1 != -- ]]; do shift; done
    shift
    test-launch "$@"
    printf '%s\n' '{"address":"t-child"}'
    ;;
  *) exit 99 ;;
esac
SH
cat >"$tmp/bin/herdr-app" <<'SH'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$@" >>"$TEST_UI"
printf '%s\n' '--' >>"$TEST_UI"
case ${1:-} in
  ls)
    tab=$(sed -n 's/^herdr\.tab=//p' "$TEST_ARGS")
    if [ "$TEST_UI_SHOWS_TAB" = 1 ]; then
      jq -nc --arg tab "$tab" '{spaces: [{id: "sp-parent", tabs: [{id: $tab}]}]}'
    else
      jq -nc '{spaces: [{id: "sp-parent", tabs: []}]}'
    fi
    exit 0
    ;;
  do)
    if [ "${2:-}" = pane.split ]; then
      argv=()
      while IFS= read -r arg; do argv+=("$arg"); done < <(jq -r '.[]' <<<"$8")
      test-launch "${argv[@]}"
      printf '%s\n' '{"terminal":"t-child"}'
      exit 0
    fi
    if [ "${2:-}" = tab.rename ]; then
      if [ "$TEST_RENAME_FAIL" = 1 ]; then
        printf '%s\n' '{"error":"test"}'
        exit 1
      fi
      printf '%s\n' '{"ok":true}'
      exit 0
    fi
    ;;
esac
printf '%s\n' 'Unexpected call to the UI' >&2
exit 99
SH
chmod +x "$tmp/bin/"* "$tmp/timeout/timeout"

export TEST_TIMEOUTS="$tmp/timeouts"
export PATH="$tmp/bin:$tmp/timeout:$PATH" HERDR_ENV=0 HC_TERMINAL_ID=t-parent SHELL="$tmp/bin/test-shell" HOME="$tmp/home"
export TEST_RC="$tmp/rc" TEST_CALLS="$tmp/calls" TEST_PANE="$tmp/pane" TEST_STATUS="$tmp/status"
unset CLAUDE_CODE_SESSION_ID OPENCODE_CONFIG OPENCODE_CONFIG_CONTENT HERDR_SPAWN_SESSION_NAME \
  HERDR_PANE_ID HERDR_WORKSPACE_ID
export TEST_SPACE=sp-parent TEST_TAB=tb-parent TEST_ARGS="$tmp/args"
export TEST_LABEL="$tmp/label" TEST_UI="$tmp/ui" TEST_UI_SHOWS_TAB=1 TEST_RENAME_FAIL=0
export HERDR_SPAWN_CONFIG="$tmp/no-config" XDG_STATE_HOME="$tmp/state"
export CLAUDE_CONFIG_DIR="$tmp/claude"
: >"$TEST_UI"

spawn() {
  bash "$repo/skills/herdr-spawn/scripts/spawn.sh" "$@" \
    --lane unit --goal 'Check placement' claude test-lane "$tmp/prompt"
}

assert_spawn() {
  local out
  : >"$TEST_LABEL"
  out=$(spawn "$@")
  [[ $out == 't-child test-lane test-agent idle' ]]
  grep -Fxq 'herdr.space=sp-parent' "$TEST_ARGS"
  grep -Fxq 't-parent' "$TEST_ARGS"
  grep -Fxq 'lane_of=t-parent' "$TEST_ARGS"
  grep -Fxq 'lane_mode=unit' "$TEST_ARGS"
  grep -Fxq 'lane_state=working' "$TEST_ARGS"
  grep -Fxq 'goal_startup=pending' "$TEST_ARGS"
  grep -Fxq 'goal_mode=native' "$TEST_ARGS"
  grep -Fxq 'goal_startup=ready' "$TEST_LABEL"
}

out=$(bash "$repo/skills/herdr-spawn/scripts/spawn.sh" claude ordinary "$tmp/prompt")
[[ $out == 't-child ordinary test-agent idle' ]]
grep -Fxq 'herdr.space=sp-parent' "$TEST_ARGS"
grep -Fxq 'herdr.tab=tb-parent' "$TEST_ARGS"
if grep -Fq -- --model "$TEST_ARGS"; then exit 1; fi
printf '%s\n' 'PASS: ordinary same-tab launches get both labels without the UI or a model override'

out=$(TEST_APP=codex bash "$repo/skills/herdr-spawn/scripts/spawn.sh" --task mechanical codex codex-small "$tmp/prompt")
[[ $out == 't-child codex-small codex idle' ]]
jq -es '.[-1].argv == ["resume", "--model", "gpt-6-luna", "--", "test-thread", "Test brief"]' "$TEST_CALLS" >/dev/null
printf '%s\n' 'PASS: ordinary Codex receives the model before the prompt'

TEST_TAB='' assert_spawn --tab "$tmp/work tree"
tab=$(sed -n 's/^herdr\.tab=//p' "$TEST_ARGS")
[[ -n $tab && $tab != tb-parent ]]
grep -Fxq "$tmp/work tree" "$TEST_ARGS"
grep -Fq -- '--model sonnet' "$TEST_ARGS"
printf '%s\n' 'PASS: new-tab lane needs only the parent space, gets its own tab, and uses the requested cwd'

out=$(bash "$repo/skills/herdr-spawn/scripts/spawn.sh" --task complex opencode routed "$tmp/prompt")
[[ $out == 't-child routed test-agent idle' ]]
grep -Fxq 'herdr.tab=tb-parent' "$TEST_ARGS"
jq -es '.[-1].argv == ["--auto", "--standalone", "--session", "ses_abc123", "--prompt", "Test brief"]' \
  "$TEST_CALLS" >/dev/null
routed_config=$(find "$XDG_STATE_HOME/herdr-spawn" -path '*/oc.*/opencode.json')
jq -e '. == {model: "openai/gpt-6.2-sol"}' "$routed_config" >/dev/null
printf '%s\n' 'PASS: an ordinary routed OpenCode launch uses a private server and no lane plugin'

assert_rejected() {
  local label=$1 out
  shift
  : >"$TEST_ARGS"
  if out=$(spawn "$@" 2>&1); then
    printf '%s\n' 'Expected spawn to fail' >&2
    exit 1
  fi
  [[ $out == *"$label"* && ! -s $TEST_ARGS ]]
}

assert_rejected '--lane needs --tab'
TEST_SPACE='' assert_rejected herdr.space --tab "$tmp/work tree"
printf '%s\n' 'PASS: missing placement fails before starting any terminal'

out=$(bash "$repo/skills/herdr-spawn/scripts/spawn.sh" claude done-name "$tmp/prompt")
[[ $out == 't-child done-name test-agent idle' ]]
printf '%s\n' 'PASS: a name only a finished terminal holds is reused'

: >"$TEST_ARGS"
if out=$(bash "$repo/skills/herdr-spawn/scripts/spawn.sh" claude live-name "$tmp/prompt" 2>&1); then exit 1; fi
[[ $out == *"agent name 'live-name' is already taken"* && ! -s $TEST_ARGS ]]
printf '%s\n' 'PASS: a name a live terminal holds is refused before starting any terminal'

mkdir -p "$tmp/agent/skills"
ln -s "$(cd -P -- "$repo/skills/herdr-spawn" && pwd)" "$tmp/agent/skills/herdr-spawn"
out=$(bash "$tmp/agent/skills/herdr-spawn/scripts/spawn.sh" \
  --tab "$tmp/work tree" --lane unit --goal 'Check adapters' --model default opencode oc-lane "$tmp/prompt")
[[ $out == 't-child oc-lane test-agent idle' ]]
goal_id=$(sed -n 's/^goal_id=//p' "$TEST_ARGS")
plugin=$(jq -er 'select(has("model") | not) | .plugins[0]' "$XDG_STATE_HOME/herdr-spawn/goals/$goal_id/opencode.json")
[[ $plugin == "file://$(cd -P -- "$repo" && pwd)/adapters/opencode/herdr-lanes" ]]
if grep -Fq -- OPENCODE_CONFIG_CONTENT "$TEST_ARGS"; then exit 1; fi
printf '%s\n' 'PASS: a symlinked skill directory still finds the repo adapters'

export TEST_UI_SHOWS_TAB=1 TEST_RENAME_FAIL=0
: >"$TEST_UI"
out=$(bash "$repo/skills/herdr-spawn/scripts/spawn.sh" claude ui-none "$tmp/prompt")
[[ $out == 't-child ui-none test-agent idle' ]]
[[ ! -s $TEST_UI ]]
printf '%s\n' 'PASS: an ordinary app launch never calls the UI to name the tab'

: >"$TEST_UI"
out=$(bash "$repo/skills/herdr-spawn/scripts/spawn.sh" --tab "$tmp/work tree" claude ui-tab "$tmp/prompt")
[[ $out == 't-child ui-tab test-agent idle' ]]
tab=$(sed -n 's/^herdr\.tab=//p' "$TEST_ARGS")
[[ -n $tab ]]
awk 'seen { print } $0 == "--" { seen = 1 }' "$TEST_UI" >"$tmp/rename-calls"
printf '%s\n' 'do' tab.rename --id "$tab" --name ui-tab -- >"$tmp/expected-rename"
diff -u "$tmp/expected-rename" "$tmp/rename-calls"
printf '%s\n' 'PASS: a new app tab is renamed after the child with herdr-app'

export TEST_UI_SHOWS_TAB=0 TEST_RENAME_FAIL=0
: >"$TEST_UI"
out=$(bash "$repo/skills/herdr-spawn/scripts/spawn.sh" --tab "$tmp/work tree" claude ui-tab "$tmp/prompt")
[[ $out == 't-child ui-tab test-agent idle' ]]
grep -Fxq 'ls' "$TEST_UI"
if grep -Fq 'tab.rename' "$TEST_UI"; then exit 1; fi
printf '%s\n' 'PASS: a tab the UI does not list keeps its number'

export TEST_UI_SHOWS_TAB=1 TEST_RENAME_FAIL=1
: >"$TEST_UI"
err="$tmp/err"
out=$(bash "$repo/skills/herdr-spawn/scripts/spawn.sh" --tab "$tmp/work tree" claude ui-tab "$tmp/prompt" 2>"$err")
[[ $out == 't-child ui-tab test-agent idle' ]]
grep -Fq 'could not name tab' "$err"
printf '%s\n' 'PASS: a failed tab rename warns but leaves the spawn successful'

export TEST_UI_SHOWS_TAB=1 TEST_RENAME_FAIL=0
cache_dir="$tmp/claude/plugins/cache/hs/herdr-spawn/1.0.0"
mkdir -p "$cache_dir"
cp -R "$repo/.claude-plugin" "$repo/skills" "$repo/adapters" "$cache_dir/"
cache=$(cd -P -- "$tmp/claude/plugins/cache/hs/herdr-spawn" && pwd)
jq -n --arg path "$cache/9.9.9" \
  '{version: 2, plugins: {"herdr-spawn@hs": [{scope: "user", installPath: $path, version: "9.9.9"}]}}' \
  >"$tmp/claude/plugins/installed_plugins.json"
err="$tmp/err"
out=$(bash "$cache_dir/skills/herdr-spawn/scripts/spawn.sh" claude stale-old "$tmp/prompt" 2>"$err")
[[ $out == 't-child stale-old test-agent idle' ]]
grep -Fq 'warning: running herdr-spawn' "$err"
grep -Fq 'but 9.9.9 is installed' "$err"
grep -Fq 'start a new session' "$err"
printf '%s\n' 'PASS: an older copy warns when a newer plugin is installed'

jq -n --arg path "$cache/1.0.0" \
  '{version: 2, plugins: {"herdr-spawn@hs": [{scope: "user", installPath: $path, version: "9.9.9"}]}}' \
  >"$tmp/claude/plugins/installed_plugins.json"
err="$tmp/err"
out=$(bash "$cache_dir/skills/herdr-spawn/scripts/spawn.sh" claude stale-current "$tmp/prompt" 2>"$err")
[[ $out == 't-child stale-current test-agent idle' ]]
if grep -Fq 'warning: running herdr-spawn' "$err"; then exit 1; fi
printf '%s\n' 'PASS: a copy matching the installed plugin root does not warn'

jq -n --arg path "$cache/9.9.9" \
  '{version: 2, plugins: {"herdr-spawn@hs": [{scope: "user", installPath: $path, version: "9.9.9"}]}}' \
  >"$tmp/claude/plugins/installed_plugins.json"
err="$tmp/err"
out=$(bash "$repo/skills/herdr-spawn/scripts/spawn.sh" claude stale-repo "$tmp/prompt" 2>"$err")
[[ $out == 't-child stale-repo test-agent idle' ]]
if grep -Fq 'warning: running herdr-spawn' "$err"; then exit 1; fi
printf '%s\n' 'PASS: an unrelated plugin root does not warn about another install'

export TEST_CHILD_STATE=blocked
: >"$TEST_LABEL"
err="$tmp/err"
set +e
out=$(spawn --tab "$tmp/work tree" 2>"$err")
rc=$?
set -e
[[ $rc -eq 3 ]]
[[ $out == 't-child test-lane test-agent blocked' ]]
grep -Fxq 'goal_startup=blocked' "$TEST_LABEL"
grep -Fq 'do not respawn the lane' "$err"
grep -Fq 'hc read t-child --lines 40' "$err"
unset TEST_CHILD_STATE
printf '%s\n' 'PASS: a blocked lane records goal_startup=blocked and exits 3'

# Session names and colors: assert what each fake CLI was called with once the launch line ran.
export TEST_UI_SHOWS_TAB=0
root=$(cd -P -- "$repo" && pwd)
script=$root/skills/herdr-spawn/scripts/spawn.sh
prompt="$tmp/work tree/brief 'literal \$x.md"
brief=$'First line\nSecond line: $(false) {name}'
goal=$'Check "$HOME" and {name}\nsecond line'
printf '%s\n' "$brief" >"$prompt"
err="$tmp/err"

run_spawn() {
  : >"$TEST_CALLS"
  : >"$TEST_TIMEOUTS"
  : >"$TEST_STATUS"
  bash "$script" "$@" >/dev/null 2>"$err"
}
calls() { # <jq args...> <filter over the array of calls>
  if ! jq -es --arg brief "$brief" --arg goal "$goal" "$@" "$TEST_CALLS" >/dev/null; then
    printf '%s\n' 'Unexpected calls:' >&2
    cat "$TEST_CALLS" "$TEST_PANE" "$err" >&2
    return 1
  fi
}
goal_dir() { printf '%s' "$XDG_STATE_HOME/herdr-spawn/goals/$(sed -n 's/^goal_id=//p' "$TEST_ARGS")"; }
lane=(--tab "$tmp/work tree" --lane unit --goal "$goal")

# RANDOM stays 0, so the first color left after the exclusion is picked.
printf '%s\n' 'unset RANDOM; RANDOM=0' >"$tmp/seed"
export BASH_ENV="$tmp/seed"
uuid=abcdef12-3456-4abc-8abc-123456789abc

check_claude_color() { # <name> <color>
  calls --arg name "$1" --arg color "$2" --arg id "$uuid" '
    map([.app, .via]) == [["claude", ""], ["claude", ""]]
    and .[0].argv == ["-p", "--safe-mode", "--setting-sources", "user", "-n", $name, "--session-id", $id, "/color " + $color]
    and .[1].argv[:2] == ["--resume", $id]'
}
check_claude() {
  run_spawn claude cc-plain "$prompt"
  check_claude_color cc-plain red
  calls '.[1].argv[2:] == ["-n", "cc-plain", $brief]'
  run_spawn --tab "$tmp/work tree" --lane driver --goal "$goal" claude cc-lane "$prompt"
  check_claude_color cc-lane red
  calls --arg file "$(goal_dir)/brief.md" '.[1].argv[2:] == ["--model", "opus", "-n", "cc-lane",
    "--append-system-prompt-file", $file, "/goal \($goal) (brief: \($file))"]'
}
check_claude_fallback() {
  local failure
  for failure in TEST_CLAUDE_RESPONSE=nope TEST_CLAUDE_EXIT=1; do
    export "${failure?}"
    run_spawn claude cc-fallback "$prompt"
    unset "${failure%%=*}"
    calls 'length == 2 and .[1].argv == ["-n", "cc-fallback", $brief]'
    grep -Fxq 'spawn.sh: could not set the Claude session color; starting without it' "$TEST_PANE"
  done
}
check_claude_bounded() {
  check_claude
  # The last run opened a tab, whose naming calls `timeout` too.
  jq -es --slurpfile calls "$TEST_CALLS" \
    'map(select(index("claude"))) == [["-k", "5", "20", "claude"] + $calls[0].argv]' "$TEST_TIMEOUTS" >/dev/null
  TEST_CLAUDE_HANG=1 run_spawn claude cc-hung "$prompt"
  calls 'map(.argv) == [["-n", "cc-hung", $brief]]'
  jq -es 'length == 1 and .[0][:5] == ["-k", "5", "20", "claude", "-p"]' "$TEST_TIMEOUTS" >/dev/null
  grep -Fxq 'spawn.sh: could not set the Claude session color; starting without it' "$TEST_PANE"
}
# A function or alias cannot be time-limited, so it gets no color call.
check_claude_wrapped() {
  local wrapper
  for wrapper in function:wrapper alias:alias; do
    TEST_CLAUDE_WRAPPER=${wrapper%:*} run_spawn claude cc-wrapped "$prompt"
    calls --arg via "${wrapper#*:}" 'map([.via, .argv]) == [[$via, ["-n", "cc-wrapped", $brief]]]'
    jq -es 'all(.[]; index("claude") == null)' "$TEST_TIMEOUTS" >/dev/null
    grep -Fxq 'spawn.sh: could not set the Claude session color; starting without it' "$TEST_PANE"
  done
}
# Without a saved transcript there is nothing to resume. It is looked up where the child shell keeps it, through a
# linked projects directory too.
check_claude_transcript() {
  rm -rf -- "$CLAUDE_CONFIG_DIR/projects/child"
  TEST_CLAUDE_NO_TRANSCRIPT=1 run_spawn claude cc-unsaved "$prompt"
  calls 'length == 2 and .[0].argv[0] == "-p" and .[1].argv == ["-n", "cc-unsaved", $brief]'
  grep -Fxq 'spawn.sh: could not set the Claude session color; starting without it' "$TEST_PANE"
  rm -rf -- "$tmp/linked-config" "$tmp/linked-projects"
  mkdir "$tmp/linked-config" "$tmp/linked-projects"
  ln -s "$tmp/linked-projects" "$tmp/linked-config/projects"
  CLAUDE_CONFIG_DIR="$tmp/linked-config" check_claude
  (unset CLAUDE_CONFIG_DIR; check_claude)
  [[ -f $HOME/.claude/projects/child/$uuid.jsonl ]]
  rm -r -- "$HOME/.claude"
}
check_claude_bounded
check_claude_wrapped
check_claude_fallback
check_claude_transcript
TEST_TUI_EXIT=1 run_spawn claude cc-exit "$prompt"
check_claude_color cc-exit red
printf '%s\n' 'PASS: a plain claude colors a new session under a time limit; a wrapper or failure starts one plain TUI'

TEST_NO_UUIDGEN=1 run_spawn claude cc-proc "$prompt"
calls '.[1].argv[:2] == ["--resume", "fedcba98-7654-4321-8fed-cba987654321"]'
TEST_NO_UUIDGEN=1 TEST_NO_PROC_UUID=1 run_spawn claude cc-no-uuid "$prompt"
calls 'map(.argv) == [["-n", "cc-no-uuid", $brief]]'
grep -Fq 'no UUID from uuidgen or /proc' "$err"
XDG_STATE_HOME="$tmp/prompt" run_spawn claude cc-no-state "$prompt"
calls 'map(.argv) == [["-n", "cc-no-state", $brief]]'
grep -Fq 'could not create a startup directory' "$err"
(cd "$tmp" && XDG_STATE_HOME=relative/missing run_spawn claude cc-relative "$prompt")
check_claude_color cc-relative red
grep -Fq "ready > $(cd -P -- "$tmp" && pwd)/relative/missing/herdr-spawn/.startup." "$TEST_ARGS" ||
  grep -Fq "ready > $tmp/relative/missing/herdr-spawn/.startup." "$TEST_ARGS"
printf '%s\n' 'PASS: Claude takes a UUID from /proc without uuidgen, and starts plain without a UUID or state directory'

coordinator=01234567-89ab-4cde-8fab-0123456789ab
mkdir -p "$CLAUDE_CONFIG_DIR/projects/coordinator" "$CLAUDE_CONFIG_DIR/projects/duplicate"
transcript=$CLAUDE_CONFIG_DIR/projects/coordinator/$coordinator.jsonl
cat >"$transcript" <<JSONL
{"type":"agent-color","agentColor":"cyan","sessionId":"$coordinator"}
{"type":"agent-color","agentColor":"red","sessionId":"$coordinator"}
{"type":"agent-color","agentColor":"blue","sessionId":"$uuid"}
{"type":"user","agentColor":"orange","sessionId":"$coordinator","message":"synthetic private text \"agent-color\""}
{"type":"agent-color"
JSONL
CLAUDE_CODE_SESSION_ID=$(printf '%s' "$coordinator" | tr 'a-f' 'A-F') run_spawn claude cc-excluded "$prompt"
check_claude_color cc-excluded blue
if grep -Fq 'synthetic private text' "$TEST_PANE" "$err" "$TEST_ARGS"; then exit 1; fi
CLAUDE_CODE_SESSION_ID=not-a-session run_spawn claude cc-bad-id "$prompt"
check_claude_color cc-bad-id red
CLAUDE_CODE_SESSION_ID=99999999-8888-4777-8666-555555555555 run_spawn claude cc-no-file "$prompt"
check_claude_color cc-no-file red
cp "$transcript" "$CLAUDE_CONFIG_DIR/projects/duplicate/"
CLAUDE_CODE_SESSION_ID=$coordinator run_spawn claude cc-ambiguous "$prompt"
check_claude_color cc-ambiguous red
rm "$CLAUDE_CONFIG_DIR/projects/duplicate/$coordinator.jsonl"
printf '%s\n' "{\"type\":\"agent-color\",\"agentColor\":\"default\",\"sessionId\":\"$coordinator\"}" >>"$transcript"
CLAUDE_CODE_SESSION_ID=$coordinator run_spawn claude cc-default "$prompt"
check_claude_color cc-default red
printf '%s\n' "{\"type\":\"user\",\"sessionId\":\"$coordinator\"}" >"$transcript"
CLAUDE_CODE_SESSION_ID=$coordinator run_spawn claude cc-no-row "$prompt"
check_claude_color cc-no-row red
printf '%s\n' "PASS: Claude excludes the coordinator's last color and still colors the child when it is unknown"

printf '%s\n' \
  'claude-opus claude -n {name} --model opus {prompt}' \
  'lane:claude-opus claude -n {name} --model opus {prompt}' \
  'claude-back claude --resume abc -n {name} {prompt}' \
  'claude-equals claude --session-id=abc -n {name} {prompt}' \
  'claude-note claude -n {name} {prompt} # pinned' \
  'claude-semi claude -n {name} {prompt};' \
  'claude-first claude {prompt}' \
  'claude-env claude --environment abc -n {name} {prompt}' \
  'claude-desktop claude --desktop -n {name} {prompt}' \
  'claude-agents claude agents {prompt}' \
  'claude-mcp claude  mcp list' \
  'codex codex --custom {prompt}' \
  'opencode opencode --prompt {prompt}' >"$tmp/agents.conf"
export HERDR_SPAWN_CONFIG="$tmp/agents.conf"
run_spawn claude-opus cc-custom "$prompt"
check_claude_color cc-custom red
calls '.[1].argv[2:] == ["-n", "cc-custom", "--model", "opus", $brief]'
run_spawn "${lane[@]}" claude-opus cc-custom-lane "$prompt"
check_claude_color cc-custom-lane red
calls --arg file "$(goal_dir)/brief.md" '.[1].argv[2:5] == ["-n", "cc-custom-lane", "--model"] and (.[1].argv | length) == 7'
run_spawn claude-back cc-back "$prompt"
calls 'map(.argv) == [["--resume", "abc", "-n", "cc-back", $brief]]'
run_spawn claude-equals cc-equals "$prompt"
calls 'map(.argv) == [["--session-id=abc", "-n", "cc-equals", $brief]]'
run_spawn claude-note cc-note "$prompt"
check_claude_color cc-note red
calls '.[1].argv[2:] == ["-n", "cc-note", $brief]'
# Only the TUI types the template with nothing after it, where a trailing separator is valid.
HERDR_ENV=1 HERDR_PANE_ID=p-parent run_spawn claude-semi cc-semi "$prompt" p-target right
check_claude_color cc-semi red
calls '.[1].argv[2:] == ["-n", "cc-semi", $brief]'
run_spawn claude-first cc-first "$prompt"
check_claude_color cc-first red
calls '.[1].argv[2:] == [$brief]'
run_spawn claude-env cc-env "$prompt"
calls 'map(.argv) == [["--environment", "abc", "-n", "cc-env", $brief]]'
run_spawn claude-desktop cc-desktop "$prompt"
calls 'map(.argv) == [["--desktop", "-n", "cc-desktop", $brief]]'
run_spawn claude-agents cc-agents "$prompt"
calls 'map(.argv) == [["agents", $brief]]'
run_spawn claude-mcp cc-mcp "$prompt"
calls 'map(.argv) == [["mcp", "list"]]'
run_spawn codex cx-custom "$prompt"
calls 'map([.app, .argv]) == [["codex", ["--custom", $brief]]]'
run_spawn opencode oc-custom "$prompt"
calls 'map(.argv) == [["--auto", "--prompt", $brief]]'
export HERDR_SPAWN_CONFIG="$tmp/no-config"
unset BASH_ENV
printf '%s\n' 'PASS: a custom claude template gets a color unless it runs a subcommand or picks its session; others are unchanged'

export TEST_APP=codex
helper=$root/skills/herdr-spawn/scripts/codex-lane.mjs
check_codex() {
  run_spawn codex cx-plain "$prompt"
  calls 'map([.app, .argv]) == [["node", ["--name-only", "cx-plain"]], ["codex", ["resume", "--", "test-thread", $brief]]]'
  run_spawn --task mechanical codex cx-routed "$prompt"
  calls 'map(.argv) == [["--name-only", "cx-routed", "gpt-6-luna"],
    ["resume", "--model", "gpt-6-luna", "--", "test-thread", $brief]]'
  grep -Fq -- "$(printf %q "$helper") --name-only" "$TEST_ARGS"
  run_spawn "${lane[@]}" codex cx-lane "$prompt"
  calls --arg file "$(goal_dir)/brief.md" 'length == 1 and .[0].argv[1:] == [$file, $goal, "cx-lane", "gpt-6.1-terra"]
    and (.[0].argv[0] | test("/\\.startup\\.[A-Za-z0-9]+$"))'
  grep -Fxq 'goal_startup=ready' "$TEST_LABEL"
}
check_codex_fallback() {
  local code
  for code in 1 127; do
    TEST_NODE_EXIT=$code run_spawn --task mechanical codex cx-fallback "$prompt"
    calls 'length == 2 and .[1].app == "codex" and .[1].argv == ["--model", "gpt-6-luna", $brief]'
    grep -Fxq 'spawn.sh: could not name the Codex session; starting without a name' "$TEST_PANE"
    grep -Fq 'codex-lane: test failure' "$TEST_PANE"
  done
  TEST_CODEX_WRAPPER=1 run_spawn codex cx-wrapper "$prompt"
  calls 'map([.app, .via, .argv]) == [["codex", "wrapper", [$brief]]]'
  grep -Fxq 'spawn.sh: could not name the Codex session; starting without a name' "$TEST_PANE"
}
run_path() { # <app|tui> <agent> <name>
  case $1 in
    app) run_spawn "$2" "$3" "$prompt" ;;
    tui) HERDR_ENV=1 HERDR_PANE_ID=p-parent run_spawn "$2" "$3" "$prompt" p-target right ;;
  esac
}
# Only a plain `codex` has to be detected as codex, named or not; a wrapper may be detected as anything.
check_codex_app() {
  local path late code
  for path in app:Codex tui:codex; do
    late=${path#*:} path=${path%:*}
    for code in 0 1; do
      TEST_NODE_EXIT=$code TEST_APP=test-agent TEST_APP_LATE=$late run_path "$path" codex cx-late
      [[ $(wc -l <"$TEST_STATUS") -eq 2 ]]
    done
    TEST_CODEX_WRAPPER=1 TEST_APP=wrapped run_path "$path" codex cx-wrapped
    [[ $(wc -l <"$TEST_STATUS") -eq 1 ]]
    calls 'map(.via) == ["wrapper"]'
  done
}
check_codex
check_codex_fallback
run_spawn "${lane[@]}" --model default codex cx-default "$prompt"
calls '.[0].argv | length == 4'
TEST_APP=test-agent TEST_APP_LATE=Codex run_spawn "${lane[@]}" codex cx-lane-late "$prompt"
[[ $(wc -l <"$TEST_STATUS") -eq 2 ]]
check_codex_app
unset TEST_APP
printf '%s\n' 'PASS: Codex resumes the thread the helper named, keeps its launch otherwise, and waits for codex when it is plain'

check_opencode() {
  local dir jq_defs
  dir=$(pwd -P)
  # The API call's --data is its last argument.
  jq_defs='def parsed: map(if .argv[0] == "api" then .argv[-1] |= fromjson else . end);
    def created($title): {$title, location: {directory: $dir}};'
  run_spawn opencode oc-plain "$prompt"
  calls --arg dir "$dir" "$jq_defs"'parsed | map([.via, .argv, .config]) == [
    ["", ["api", "session.create", "--data", created("oc-plain")], ""],
    ["wrapper", ["--auto", "--session", "ses_abc123", "--prompt", $brief], ""]]'
  run_spawn --task complex opencode oc-routed "$prompt"
  calls --arg dir "$dir" "$jq_defs"'parsed
    | map(.argv) == [["api", "--standalone", "session.create", "--data", created("oc-routed")],
      ["--auto", "--standalone", "--session", "ses_abc123", "--prompt", $brief]]
    and (.[0].config | endswith("/opencode.json")) and .[0].config == .[1].config'
  run_spawn "${lane[@]}" opencode oc-lane "$prompt"
  calls --arg dir "$dir" --arg config "$(goal_dir)/opencode.json" --rawfile composed "$(goal_dir)/brief.md" "$jq_defs"'
    parsed | map(.argv) == [["api", "--standalone", "session.create", "--data", created("oc-lane")],
      ["--auto", "--standalone", "--session", "ses_abc123", "--prompt", ($composed | sub("\n+$"; ""))]]
    and all(.[]; .config == $config)'
}
oc_response() { # <id> <title> <directory>
  jq -cn --arg id "$1" --arg title "$2" --arg directory "$3" '{data: {$id, $title, location: {$directory}}}'
}
check_opencode_fallback() {
  local failure dir
  dir=$(pwd -P)
  # A bad ID, another title, another directory and no location, then a failed call.
  for failure in "TEST_OC_RESPONSE=$(oc_response ses_bad-id oc-fallback "$dir")" \
    "TEST_OC_RESPONSE=$(oc_response ses_abc123 other "$dir")" \
    "TEST_OC_RESPONSE=$(oc_response ses_abc123 oc-fallback "$HOME")" \
    'TEST_OC_RESPONSE={"data":{"id":"ses_abc123","title":"oc-fallback"}}' TEST_OC_EXIT=1; do
    export "${failure?}"
    run_spawn opencode oc-fallback "$prompt"
    unset "${failure%%=*}"
    calls 'length == 2 and .[1].argv == ["--auto", "--prompt", $brief]'
    grep -Fxq 'spawn.sh: could not create a named OpenCode session; starting with the default title' "$TEST_PANE"
  done
}
check_opencode
jq -es 'map(select(index("opencode"))) | length == 1
  and .[0][:6] == ["-k", "5", "20", "opencode", "api", "--standalone"]' "$TEST_TIMEOUTS" >/dev/null
check_opencode_fallback
TEST_OC_EXIT=1 run_spawn --task complex opencode oc-routed "$prompt"
calls '.[1].argv == ["--auto", "--standalone", "--prompt", $brief] and (.[1].config | endswith("/opencode.json"))'
# A directory to quote, reached through a link: the session gets the physical path.
mkdir "$tmp/oc \"dir\" 'with' \$HOME; (x)"
ln -s "$tmp/oc \"dir\" 'with' \$HOME; (x)" "$tmp/oc-link"
(cd "$tmp/oc-link"; check_opencode; check_opencode_fallback)
printf '%s\n' 'PASS: OpenCode titles a session in the child directory and opens it, or warns and keeps its launch'

# A host without `timeout`: nothing but these tools, and perl once it is linked.
mkdir "$tmp/tools"
for tool in bash jq dirname awk mktemp mkdir mv rm rmdir seq sleep tr find wc; do
  ln -s "$(command -v "$tool")" "$tmp/tools/$tool"
done
! command -v zsh >/dev/null || ln -s "$(command -v zsh)" "$tmp/tools/zsh"
PATH="$tmp/bin:$tmp/tools" run_spawn opencode oc-no-limit "$prompt"
calls 'map(.argv) == [["--auto", "--prompt", $brief]]'
grep -Fxq 'spawn.sh: could not create a named OpenCode session; starting with the default title' "$TEST_PANE"
PATH="$tmp/bin:$tmp/tools" run_spawn claude cc-no-limit "$prompt"
calls 'map(.argv) == [["-n", "cc-no-limit", $brief]]'
grep -Fxq 'spawn.sh: could not set the Claude session color; starting without it' "$TEST_PANE"
ln -s "$(command -v perl)" "$tmp/tools/perl"
check_perl_limit() {
  PATH="$tmp/bin:$tmp/tools" run_spawn opencode oc-perl "$prompt"
  calls 'length == 2 and .[0].argv[:2] == ["api", "session.create"] and .[1].argv[1:3] == ["--session", "ses_abc123"]'
  grep -Fq "perl -e 'alarm shift; exec @ARGV' 20 opencode api session.create" "$TEST_ARGS"
  PATH="$tmp/bin:$tmp/tools" run_spawn claude cc-perl "$prompt"
  calls 'length == 2 and .[0].argv[0] == "-p" and .[1].argv[0] == "--resume"'
  grep -Fq "perl -e 'alarm shift; exec @ARGV' 20 claude -p" "$TEST_ARGS"
}
check_perl_limit
printf '%s\n' 'PASS: without timeout the naming steps run under a perl limit, and without either the launch is plain'

adapters=$root/adapters/omp
[[ -f $adapters/herdr-spawn.ts && -f $adapters/herdr-spawn.yml ]]
check_omp() {
  run_spawn omp omp-plain "$prompt"
  calls --arg dir "$adapters" 'map([.via, .session_name, .argv]) == [["alias", "omp-plain",
    ["--no-title", "-e", $dir + "/herdr-spawn.ts", "--config", $dir + "/herdr-spawn.yml", $brief]]]'
  [[ ! -s $err ]]
  run_spawn --task simple omp omp-routed "$prompt"
  calls '.[0].argv[-3:] == ["--model", "openai-codex/gpt-6.1-terra", $brief]'
  run_spawn "${lane[@]}" omp omp-lane "$prompt"
  calls --arg dir "$adapters" --arg file "$(goal_dir)/brief.md" 'map([.session_name, .argv]) == [["omp-lane",
    ["--model", "openai-codex/gpt-6.1-terra", "--no-title", "-e", $dir + "/herdr-spawn.ts", "--goal", $goal,
     "--append-system-prompt", $file, "-e", $dir + "/herdr-lanes.ts"]]]'
  run_spawn "${lane[@]}" --model default omp omp-default "$prompt"
  calls '.[0].argv[0] == "--no-title"'
}
check_omp
printf '%s\n' 'PASS: oh-my-pi receives the name and the naming extension, with model routing and lane goals unchanged'

# The child marks startup after a slow naming step; no path may query its status before that.
export TEST_ASYNC=1 TEST_STEP_DELAY=1
for agent in claude codex opencode; do
  app=test-agent
  [[ $agent != codex ]] || app=codex
  for path in app app-split tui; do
    case $path in
      app) TEST_APP=$app run_spawn "$agent" marked "$prompt" ;;
      app-split) TEST_APP=$app run_spawn "$agent" marked "$prompt" p-target right ;;
      tui) HERDR_ENV=1 HERDR_PANE_ID=p-parent TEST_APP=$app run_spawn "$agent" marked "$prompt" p-target right ;;
    esac
    [[ -s $TEST_STATUS ]]
    if grep -Fxq unmarked "$TEST_STATUS"; then
      printf '%s\n' "$agent over $path reported the child before its startup mark" >&2
      exit 1
    fi
    # Let the background child finish its TUI call before the next run reuses the log.
    for _ in $(seq 50); do
      [[ $(wc -l <"$TEST_CALLS") -ge 2 ]] && break
      sleep 0.1
    done
    [[ $(wc -l <"$TEST_CALLS") -eq 2 ]]
  done
done
unset TEST_ASYNC TEST_STEP_DELAY
left=("$XDG_STATE_HOME"/herdr-spawn/.startup.*)
[[ ! -e ${left[0]} ]]
printf '%s\n' 'PASS: both app paths and the TUI wait for the startup mark, then remove the private directory'

if command -v zsh >/dev/null; then
  export TEST_CHILD_ZSH=1 BASH_ENV="$tmp/seed"
  check_claude_bounded
  check_claude_wrapped
  check_claude_fallback
  check_claude_transcript
  TEST_APP=codex check_codex
  TEST_APP=codex check_codex_fallback
  check_codex_app
  check_opencode
  check_opencode_fallback
  (cd "$tmp/oc-link"; check_opencode)
  check_perl_limit
  check_omp
  unset TEST_CHILD_ZSH BASH_ENV
  printf '%s\n' 'PASS: the same launch lines work in an interactive zsh'
else
  printf '%s\n' 'SKIP: zsh is not installed'
fi

# A coordinator's name and color. RANDOM stays 0: red is requested unless the transcript says otherwise, and a
# child that avoids red gets blue.
export BASH_ENV="$tmp/seed" XDG_STATE_HOME="$tmp/identity-state" GIT_CEILING_DIRECTORIES="$tmp"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR
me=11111111-2222-4333-8444-abcdefabcdef
identity=$XDG_STATE_HOME/herdr-spawn/identity
request=$identity/$me.json
git init -q "$tmp/main-repo.x"
git -C "$tmp/main-repo.x" -c user.name=test -c user.email=test@example.invalid commit -q --allow-empty -m init
git -C "$tmp/main-repo.x" worktree add -q "$tmp/linked"
cd "$tmp/main-repo.x"

check_request() { # <name> <color>
  jq -es --arg id "$me" --arg name "$1" --arg color "$2" \
    '. == [{sessionId: $id, name: $name, color: $color, done: false}]' "$request" >/dev/null
}
check_notice() { # <name> <color>
  [[ $(grep -c 'coordinator name' "$err") -eq 1 ]]
  grep -Fq "coordinator name $1 and color $2 requested for this session, not applied yet" "$err"
  grep -Fq "Tell the user now, once: if this session's name and color have not changed when this turn ends" "$err"
  grep -Fq "they can type /rename $1 and /color $2, whichever it lacks" "$err"
}
check_silent() { if grep -Fq 'coordinator name' "$err"; then return 1; fi; }

run_spawn "${lane[@]}" claude id-no-caller "$prompt"
check_claude_color id-no-caller red
check_silent
CLAUDE_CODE_SESSION_ID=not-a-session run_spawn "${lane[@]}" claude id-bad-caller "$prompt"
check_silent
CLAUDE_CODE_SESSION_ID=$me run_spawn claude id-ordinary "$prompt"
check_claude_color id-ordinary red
check_silent
CLAUDE_CODE_SESSION_ID=$me run_spawn --tab "$tmp/work tree" claude id-ordinary-tab "$prompt"
check_silent
[[ ! -e $identity ]]
printf '%s\n' 'PASS: ordinary spawns and callers without a Claude session ID request no coordinator identity'

export CLAUDE_CODE_SESSION_ID
CLAUDE_CODE_SESSION_ID=$(printf '%s' "$me" | tr 'a-f' 'A-F')
(cd "$tmp/linked" && run_spawn "${lane[@]}" claude id-first "$prompt")
check_request coord-main-repo.x red
[[ -n $(find "$request" -prune -perm 0600) ]]
[[ $(find "$identity" -type f) == "$request" ]]
check_notice coord-main-repo.x red
check_claude_color id-first blue
printf '%s\n' "PASS: a first lane requests the main repository's name and a color its child avoids"

cp "$request" "$tmp/first-request"
run_spawn "${lane[@]}" claude id-second "$prompt"
cmp "$request" "$tmp/first-request"
check_notice coord-main-repo.x red
check_claude_color id-second blue
run_spawn claude id-later "$prompt"
check_claude_color id-later blue
check_silent
jq -c '.done = true' "$tmp/first-request" >"$request"
cp "$request" "$tmp/done-request"
run_spawn "${lane[@]}" claude id-done "$prompt"
cmp "$request" "$tmp/done-request"
check_silent
check_claude_color id-done blue
printf '%s\n' 'PASS: the request is written once and repeated on each lane until it is done'

transcript=$CLAUDE_CONFIG_DIR/projects/coordinator/$me.jsonl
printf '%s\n' "{\"type\":\"agent-color\",\"agentColor\":\"red\",\"sessionId\":\"$me\"}" >"$transcript"
jq -c '.color = "blue"' "$tmp/first-request" >"$request"
run_spawn "${lane[@]}" claude id-transcript-first "$prompt"
check_claude_color id-transcript-first blue
rm "$request"
printf '%s\n' "{\"type\":\"agent-color\",\"agentColor\":\"pink\",\"sessionId\":\"$me\"}" >"$transcript"
run_spawn "${lane[@]}" claude id-transcript "$prompt"
check_request coord-main-repo.x pink
check_claude_color id-transcript red
rm "$request"
printf '%s\n' "{\"type\":\"agent-color\",\"agentColor\":\"default\",\"sessionId\":\"$me\"}" >"$transcript"
run_spawn "${lane[@]}" claude id-transcript-default "$prompt"
jq -e '.color == "red"' "$request" >/dev/null
rm "$transcript" "$request"
printf '%s\n' "PASS: the transcript color is requested and avoided; a value /color does not take is replaced"

mkdir -p "$tmp/.-plain dir_1.é" "$tmp/---"
(cd "$tmp/.-plain dir_1.é" && run_spawn "${lane[@]}" claude id-plain "$prompt")
check_request coord-plaindir_1. red
rm "$request"
(cd "$tmp/---" && run_spawn "${lane[@]}" claude id-unnamed "$prompt")
check_request coord-session red
rm "$request"
mkdir "$tmp/no-git"
printf '%s\n' '#!/usr/bin/env bash' 'exit 127' >"$tmp/no-git/git"
chmod +x "$tmp/no-git/git"
(cd "$tmp/linked" && PATH="$tmp/no-git:$PATH" run_spawn "${lane[@]}" claude id-no-git "$prompt")
check_request coord-linked red
rm "$request"
printf '%s\n' 'PASS: outside git, or without it, the working directory names the coordinator'

check_unusable() {
  grep -Fq "no usable coordinator name and color request at $request. Tell the user now, once:" "$err"
  grep -Fq "they can type /rename and /color to set this session's name and color" "$err"
}
for content in 'not json' '' '[]' '{"done":false}' \
  "{\"sessionId\":\"$coordinator\",\"name\":\"coord-other\",\"color\":\"red\",\"done\":false}" \
  "{\"sessionId\":\"$me\",\"name\":\"coord-a b\",\"color\":\"red\",\"done\":false}" \
  "{\"sessionId\":\"$me\",\"name\":\"coord-a\",\"color\":\"red blue\",\"done\":false}"; do
  printf '%s\n' "$content" >"$request"
  cp "$request" "$tmp/foreign-request"
  run_spawn "${lane[@]}" claude id-foreign "$prompt"
  cmp "$request" "$tmp/foreign-request"
  [[ $(wc -l <"$err") -eq 1 ]]
  check_unusable
  calls 'length == 2 and .[1].argv[0] == "--resume"'
done
rm -r "$identity"
: >"$identity"
run_spawn "${lane[@]}" claude id-unwritable "$prompt"
check_claude_color id-unwritable red
grep -Fxq 'goal_startup=ready' "$TEST_LABEL"
[[ $(wc -l <"$err") -eq 1 ]]
check_unusable
[[ -f $identity && ! -s $identity ]]
rm "$identity"
printf '%s\n' 'PASS: an unusable or unwritable request warns in one line and the lane still starts'

HERDR_ENV=1 HERDR_PANE_ID=p-parent run_spawn "${lane[@]}" claude id-tui "$prompt"
check_request coord-main-repo.x red
check_notice coord-main-repo.x red
check_claude_color id-tui blue
# Let the detached watcher end before the directory goes.
for _ in $(seq 50); do
  ! grep -Fq 'is gone' "$XDG_STATE_HOME/herdr-spawn/watch-p-parent.log" 2>/dev/null || break
  sleep 0.1
done
grep -Fq 'is gone' "$XDG_STATE_HOME/herdr-spawn/watch-p-parent.log"
for _ in $(seq 50); do
  [[ -e $XDG_STATE_HOME/herdr-spawn/watch-p-parent.lock ]] || break
  sleep 0.1
done
[[ ! -e $XDG_STATE_HOME/herdr-spawn/watch-p-parent.lock ]]
printf '%s\n' 'PASS: a lane in a Herdr pane requests the coordinator identity too'
