#!/usr/bin/env bash
set -euo pipefail

repo=$(dirname -- "$0")/..
tmp=$(mktemp -d)
trap 'rm -r -- "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/work tree"
printf '%s\n' 'Test brief' >"$tmp/prompt"

cat >"$tmp/bin/hc" <<'SH'
#!/usr/bin/env bash
set -eu
case "$1:$2" in
  get:t-parent)
    jq -nc --arg space "$TEST_SPACE" --arg tab "$TEST_TAB" \
      '{labels: {"herdr.space": $space, "herdr.tab": $tab}}'
    ;;
  get:t-child) printf '%s\n' '{"status":{"app":"test-agent","state":"idle"}}' ;;
  get:*) exit 3 ;;
  label:t-child)
    [[ $# -eq 3 && $3 == goal_startup=ready ]]
    printf '%s\n' "$3" >"$TEST_LABEL"
    ;;
  run:*)
    printf '%s\n' "$@" >"$TEST_ARGS"
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
chmod +x "$tmp/bin/hc" "$tmp/bin/herdr-app"

export PATH="$tmp/bin:$PATH" HERDR_ENV=0 HC_TERMINAL_ID=t-parent
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

out=$(bash "$repo/skills/herdr-spawn/scripts/spawn.sh" --task mechanical codex codex-small "$tmp/prompt")
[[ $out == 't-child codex-small test-agent idle' ]]
grep -Fq -- 'codex --model gpt-6-luna' "$TEST_ARGS"
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
grep -Fq -- 'opencode --standalone --prompt' "$TEST_ARGS"
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
