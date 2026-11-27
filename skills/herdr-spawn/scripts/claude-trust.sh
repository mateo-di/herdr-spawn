#!/usr/bin/env bash
# Usage: claude-trust.sh <dir>
# spawn.sh runs this before it starts a Claude Code child. Claude Code stops on "Do you trust the files in
# this folder?" for a folder it has not seen, so a spawned child would sit idle before taking its prompt.
# The spawn starts the child in a folder the user chose, so it marks that folder's repository trusted first.
# Trust lives in .claude.json as projects["<repo root>"].hasTrustDialogAccepted. Other Claude sessions rewrite
# that file while they run, so this changes only that one key, locks out other spawns, starts over when the file
# changed while it was read, and replaces it atomically; a session's write in the moment before the rename can
# still be lost. Any failure is a warning: a missing key must never fail the spawn.
set -uo pipefail
# Another user who can open the lock file could hold the lock and keep every spawn from trusting.
umask 077

warn() { echo "spawn.sh: $*" >&2; }
# Command substitution drops trailing newlines, so a path with a newline in it could name another directory.
physical() {
  local p
  p=$(CDPATH='' cd -P -- "$1" 2>/dev/null && pwd && echo .) || return 1
  p=${p%$'\n.'}
  case $p in *$'\n'*) return 1 ;; esac
  printf '%s\n' "$p"
}
command -v jq >/dev/null || { warn "jq is missing; leaving folder trust to the user"; exit 0; }
# An inherited GIT_DIR, GIT_WORK_TREE, GIT_COMMON_DIR or GIT_INDEX_FILE can point git at another repository.
git_clean() { env -u GIT_DIR -u GIT_WORK_TREE -u GIT_COMMON_DIR -u GIT_INDEX_FILE git "$@"; }

if [ $# -ne 1 ]; then
  warn "claude-trust.sh needs one directory; leaving folder trust to the user"
  exit 0
fi

dir=$(physical "$1") || { warn "cannot resolve $1; leaving folder trust to the user"; exit 0; }

# Claude Code keys a linked worktree's trust on its main checkout, so the key is the first worktree git lists.
# A worktree git does not list, such as a .git file pointing at another repository, is not trusted here.
key=
if top=$(git_clean -C "$dir" rev-parse --show-toplevel 2>/dev/null) && [ -n "$top" ]; then
  topphys=$(physical "$top") || topphys=
  if [ -z "$topphys" ]; then
    warn "cannot resolve the working tree root $top; leaving folder trust to the user"
    exit 0
  fi
  first='' firstphys='' entry=0 seen=0 firstbare=0
  # -z, because git prints paths raw and a newline in one would forge another entry.
  while IFS= read -r -d '' line; do
    case $line in
      'worktree '*)
        entry=$((entry + 1))
        path=${line#worktree }
        phys=$(physical "$path") || phys=
        if [ "$entry" -eq 1 ]; then first=$path; firstphys=$phys; fi
        if [ -n "$phys" ] && [ "$phys" = "$topphys" ]; then seen=1; fi
        ;;
      bare)
        if [ "$entry" -eq 1 ]; then firstbare=1; fi
        ;;
    esac
  done < <(git_clean -C "$dir" worktree list --porcelain -z 2>/dev/null)
  if [ -z "$first" ]; then
    warn "cannot list the git worktrees for $dir (needs git 2.36 or newer); leaving folder trust to the user"
    exit 0
  fi
  if [ "$seen" != 1 ]; then
    warn "$dir is not a worktree of the repository git reports; leaving folder trust to the user"
    exit 0
  fi
  if [ "$firstbare" = 1 ]; then
    key=$topphys
  else
    key=$firstphys
  fi
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
# A FIFO or device would hang the reads below.
if [ ! -f "$target" ]; then
  warn "$config is not a regular file; leaving folder trust to the user"
  exit 0
fi
targetdir=$(physical "$(dirname -- "$target")") ||
  { warn "cannot resolve the directory of $target; leaving folder trust to the user"; exit 0; }
target=$targetdir/${target##*/}

# jq accepts empty input and concatenated objects, so both filters read the file as a list and want one object.
# shellcheck disable=SC2016 # $key is a jq variable.
trusted='length == 1 and (.[0] | type == "object") and (((.[0].projects[$key].hasTrustDialogAccepted)? // null) == true)'
# Setting the one key must not replace anything, so projects and this repository's entry are objects or absent.
# shellcheck disable=SC2016 # $key is a jq variable.
usable='length == 1 and (.[0] | type == "object" and (.projects | type == "object" or type == "null")
  and ((.projects // {})[$key] | type == "object" or type == "null"))'

# The common case: another spawn or session already trusted this repository, so the file stays untouched.
if jq -s -e --arg key "$key" "$trusted" "$target" >/dev/null 2>&1; then
  exit 0
fi

# An flock(2) lock on fd 9 lets go when the run ends, however it ends. macOS has no flock(1), so perl takes the
# same lock there, and this shell keeps holding it through fd 9 after perl exits. With neither, spawns are not
# serialized, and the checksum below still catches most overlaps.
if command -v flock >/dev/null || command -v perl >/dev/null; then
  statebase=${XDG_STATE_HOME:-${HOME:+$HOME/.local/state}}
  if [ -z "$statebase" ]; then
    warn "neither XDG_STATE_HOME nor HOME is set; leaving folder trust to the user"
    exit 0
  fi
  lock=$statebase/herdr-spawn/claude-trust.lock
  { mkdir -p "${lock%/*}" && exec 9>>"$lock"; } 2>/dev/null ||
    { warn "cannot open $lock; leaving folder trust to the user"; exit 0; }
  if command -v flock >/dev/null; then
    flock -w 5 9
  else
    # A relative PERL5LIB or a PERL5OPT would load code from wherever the spawn runs.
    # shellcheck disable=SC2016 # Perl code, not shell.
    env -u PERL5LIB -u PERLLIB -u PERL5OPT perl -MFcntl=:flock -e 'open(my $fh, ">&=", 9) or exit 1; local $SIG{ALRM} = sub { exit 1 }; alarm 5; flock($fh, LOCK_EX) or exit 1'
  fi || { warn "another claude-trust run holds $lock; leaving folder trust to the user"; exit 0; }
fi
# A temp file left behind would be a full copy of the config.
tmp=
trap '[ -z "$tmp" ] || rm -f -- "$tmp"' EXIT

attempt=0
written=0
while [ "$attempt" -lt 5 ]; do
  attempt=$((attempt + 1))
  before=$(cksum <"$target" 2>/dev/null) || before=
  if [ -z "$before" ]; then
    warn "cannot read $target; leaving folder trust to the user"
    exit 0
  fi
  # Trusted while this run waited for the lock.
  if jq -s -e --arg key "$key" "$trusted" "$target" >/dev/null 2>&1; then
    exit 0
  fi
  if ! jq -s -e --arg key "$key" "$usable" "$target" >/dev/null 2>&1; then
    warn "$target is not one JSON object, or its projects entry for $key is not an object; leaving folder trust to the user"
    exit 0
  fi
  mode=$(stat -c '%a' -- "$target" 2>/dev/null) || mode=
  [ -n "$mode" ] || mode=$(stat -f '%Lp' -- "$target" 2>/dev/null) || mode=
  tmp=$(mktemp "$targetdir/.claude.json.XXXXXXXX" 2>/dev/null) ||
    { tmp=; warn "cannot create a temporary file next to $target; leaving folder trust to the user"; exit 0; }
  if ! jq --arg key "$key" '.projects[$key].hasTrustDialogAccepted = true' "$target" >"$tmp" 2>/dev/null; then
    warn "cannot update $target; leaving folder trust to the user"
    exit 0
  fi
  if [ ! -s "$tmp" ] || ! jq -s -e --arg key "$key" "$trusted" "$tmp" >/dev/null 2>&1; then
    warn "refusing to write a broken $target; leaving folder trust to the user"
    exit 0
  fi
  after=$(cksum <"$target" 2>/dev/null) || after=
  if [ "$after" != "$before" ]; then
    rm -f -- "$tmp"
    tmp=
    continue
  fi
  if [ -n "$mode" ]; then chmod "$mode" -- "$tmp" 2>/dev/null || :; fi
  if mv -f -- "$tmp" "$target" 2>/dev/null; then
    tmp=
    written=1
    break
  fi
  warn "cannot replace $target; leaving folder trust to the user"
  exit 0
done
if [ "$written" != 1 ]; then
  warn "$target kept changing while it was updated; leaving folder trust to the user"
  exit 0
fi

if jq -s -e --arg key "$key" "$trusted" "$target" >/dev/null 2>&1; then
  echo "spawn.sh: trusted $key for Claude Code in $config" >&2
else
  warn "wrote $target but $key is still not trusted"
fi
exit 0
