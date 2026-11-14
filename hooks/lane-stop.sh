#!/usr/bin/env bash
# Stop hook for Claude Code and Codex, which read the same block decision: holds a lane or coordinator to its
# role with the reason lane-stop-check.sh prints, and stays silent (lets the stop through) otherwise.
reason=$("$(dirname -- "$0")/../skills/herdr-spawn/scripts/lane-stop-check.sh")
[ -z "$reason" ] || jq -cn --arg r "$reason" '{decision: "block", reason: $r}'
