#!/usr/bin/env bash
# Usage: lanes-of.sh <app|tui> <coordinator>
# Prints one JSON object per lane whose lane_of names <coordinator>: {name, shown, l}, where l holds the lane's hc
# labels (Herdr app: the terminals whose parent is <coordinator>) or its pane tokens (herdr TUI), and shown is the
# name to put in front of a model. lane-stop-check.sh and hooks/coordinator-ask.sh both read lanes through this,
# so a fix to how lanes are found lands once. Prints nothing when a CLI is missing or fails.
# The app reads run without HC_TERMINAL_ID: a read by the parent marks a child's news seen and swallows its
# notice. Each child is parsed on its own, so one that ended or answered garbage hides no other lane.
# Any pane picks its own name, so one with anything beyond letters, digits and _ : . - is shown as "a lane".
set -uo pipefail
c=${2:-}
# shellcheck disable=SC2016 # $c is a jq variable.
lane='{name, shown: (.name | if type == "string" and test("\\A[A-Za-z0-9][A-Za-z0-9_:.-]{0,63}\\z") then . else "a lane" end), l: $l}
  | select(.l | type == "object" and .lane_of == $c)'
case ${1:-} in
  app)
    unset HC_TERMINAL_ID
    hc ls --json 2>/dev/null | jq -r --arg c "$c" '.terminals[] | select(.parent == $c) | .address' 2>/dev/null |
      while read -r t; do
        hc get "$t" --json 2>/dev/null | jq -c --arg c "$c" 'select(type == "object") | .labels as $l | '"$lane" 2>/dev/null || :
      done
    ;;
  tui)
    herdr agent list 2>/dev/null | jq -c --arg c "$c" '.result.agents[] | select(type == "object") | .tokens as $l | '"$lane" 2>/dev/null
    ;;
esac
exit 0
