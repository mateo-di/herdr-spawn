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
  run:*)
    printf '%s\n' "$@" >"$TEST_ARGS"
    printf '%s\n' '{"address":"t-child"}'
    ;;
  *) exit 99 ;;
esac
SH
cat >"$tmp/bin/herdr-app" <<'SH'
#!/usr/bin/env bash
printf '%s\n' 'Unexpected call to the UI' >&2
exit 99
SH
chmod +x "$tmp/bin/hc" "$tmp/bin/herdr-app"

export PATH="$tmp/bin:$PATH" HERDR_ENV=0 HC_TERMINAL_ID=t-parent
export TEST_SPACE=sp-parent TEST_TAB=tb-parent TEST_ARGS="$tmp/args"
export HERDR_SPAWN_CONFIG="$tmp/no-config" XDG_STATE_HOME="$tmp/state"

spawn() {
  bash "$repo/skills/herdr-spawn/scripts/spawn.sh" "$@" \
    --lane unit --goal 'Check placement' claude test-lane "$tmp/prompt"
}

assert_spawn() {
  local out
  out=$(spawn "$@")
  [[ $out == 't-child test-lane test-agent idle' ]]
  grep -Fxq 'herdr.space=sp-parent' "$TEST_ARGS"
  grep -Fxq 't-parent' "$TEST_ARGS"
  grep -Fxq 'lane_of=t-parent' "$TEST_ARGS"
  grep -Fxq 'lane_mode=unit' "$TEST_ARGS"
  grep -Fxq 'lane_state=working' "$TEST_ARGS"
}

assert_spawn
grep -Fxq 'herdr.tab=tb-parent' "$TEST_ARGS"
printf '%s\n' 'PASS: same-tab lane gets both labels without the UI'

TEST_TAB='' assert_spawn --tab "$tmp/work tree"
tab=$(sed -n 's/^herdr\.tab=//p' "$TEST_ARGS")
[[ -n $tab && $tab != tb-parent ]]
grep -Fxq "$tmp/work tree" "$TEST_ARGS"
printf '%s\n' 'PASS: new-tab lane needs only the parent space, gets its own tab, and uses the requested cwd'

TEST_TAB=$tab assert_spawn
grep -Fxq "herdr.tab=$tab" "$TEST_ARGS"
printf '%s\n' 'PASS: the new tab label can route a later same-tab child'

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

TEST_SPACE='' assert_rejected herdr.space
TEST_SPACE='' assert_rejected herdr.space --tab "$tmp/work tree"
TEST_TAB='' assert_rejected herdr.tab
printf '%s\n' 'PASS: missing placement fails before starting any terminal'
