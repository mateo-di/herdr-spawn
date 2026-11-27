#!/usr/bin/env bash
# Usage: claude-trust.sh <dir>
# spawn.sh runs this before it starts a Claude Code child. Claude Code stops on "Do you trust the files in
# this folder?" for a folder it has not seen, so a spawned child would sit idle before taking its prompt.
# The spawn starts the child in a folder the user chose, so it marks that folder's repository trusted first.
# Trust lives in .claude.json as projects["<repo root>"].hasTrustDialogAccepted. Other Claude sessions rewrite
# that file while they run, so this changes only that one key, keeps every other field, and replaces the file
# atomically. Any failure is a warning: a missing key must never fail the spawn.
set -uo pipefail

warn() { echo "spawn.sh: $*" >&2; }

if [ $# -ne 1 ]; then
  warn "claude-trust.sh needs one directory; leaving folder trust to the user"
  exit 0
fi

dir=$(CDPATH='' cd -P -- "$1" 2>/dev/null && pwd) ||
  { warn "cannot resolve $1; leaving folder trust to the user"; exit 0; }

# A linked worktree keeps its trust on the main checkout's root, the parent of the common git dir. Other
# layouts (a submodule, a separate git dir) fall back to the working tree root.
key=
if common=$(git -C "$dir" rev-parse --path-format=absolute --git-common-dir 2>/dev/null); then
  case $common in
    */.git) key=${common%/.git} ;;
    *) key=$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null) || key= ;;
  esac
else
  key=$dir
fi
if [ -z "$key" ]; then
  warn "cannot find the repository root for $dir; leaving folder trust to the user"
  exit 0
fi

base=${CLAUDE_CONFIG_DIR:-${HOME:-}}
if [ -z "$base" ]; then
  warn "neither CLAUDE_CONFIG_DIR nor HOME is set; leaving folder trust to the user"
  exit 0
fi
config=$base/.claude.json
if [ ! -e "$config" ]; then
  warn "no Claude Code config at $config; leaving folder trust to the user"
  exit 0
fi

# A symlinked config is often how people share one .claude.json: edit its target and keep the link.
target=$config
links=0
while [ -L "$target" ]; do
  links=$((links + 1))
  if [ "$links" -gt 40 ]; then
    warn "too many symlinks at $config; leaving folder trust to the user"
    exit 0
  fi
  link=$(readlink -- "$target" 2>/dev/null) || link=
  if [ -z "$link" ]; then
    warn "cannot resolve the symlink at $target; leaving folder trust to the user"
    exit 0
  fi
  case $link in
    /*) target=$link ;;
    *) target=$(dirname -- "$target")/$link ;;
  esac
done
if [ ! -e "$target" ]; then
  warn "the symlink at $config points nowhere; leaving folder trust to the user"
  exit 0
fi
targetdir=$(CDPATH='' cd -P -- "$(dirname -- "$target")" 2>/dev/null && pwd) ||
  { warn "cannot resolve the directory of $target; leaving folder trust to the user"; exit 0; }
target=$targetdir/${target##*/}

jq -e --arg key "$key" '.projects[$key].hasTrustDialogAccepted == true' "$target" >/dev/null 2>&1
case $? in
  0) exit 0 ;;
  1) : ;;
  *) warn "cannot read $target as JSON; leaving folder trust to the user"; exit 0 ;;
esac

# The replacement keeps the target's mode; mktemp already makes it private.
mode=$(stat -c '%a' -- "$target" 2>/dev/null) || mode=
[ -n "$mode" ] || mode=$(stat -f '%Lp' -- "$target" 2>/dev/null) || mode=

tmp=$(mktemp "$targetdir/.claude.json.XXXXXXXX" 2>/dev/null) ||
  { warn "cannot create a temporary file next to $target; leaving folder trust to the user"; exit 0; }
if ! jq --arg key "$key" '
  .projects = (
    (.projects | if type == "object" then . else {} end)
    | .[$key] = ((.[$key] | if type == "object" then . else {} end) | .hasTrustDialogAccepted = true)
  )' "$target" >"$tmp" 2>/dev/null; then
  rm -f -- "$tmp"
  warn "cannot update $target; leaving folder trust to the user"
  exit 0
fi
if [ -n "$mode" ]; then chmod "$mode" -- "$tmp" 2>/dev/null || :; fi
mv -f -- "$tmp" "$target" 2>/dev/null ||
  { rm -f -- "$tmp"; warn "cannot replace $target; leaving folder trust to the user"; exit 0; }

if jq -e --arg key "$key" '.projects[$key].hasTrustDialogAccepted == true' "$target" >/dev/null 2>&1; then
  echo "spawn.sh: trusted $key for Claude Code in $config" >&2
else
  warn "wrote $target but $key is still not trusted"
fi
exit 0
