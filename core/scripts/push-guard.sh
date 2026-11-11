#!/usr/bin/env bash
# hq-core: public
#
# push-guard.sh — pre-push backstop: refuse a push whose new commits add an
# HQ-root marker path (personal/.codex/, companies/<co>/, credentials/, drift
# or rescue files, ...) or more than HQ_PUSH_GUARD_MAX_ADDED files (default
# 2000). Runs from the HQ git-hooks dispatcher on every `git push` once
# `commit-secret-scan.sh enable` has wired the hooks, in every repo on this
# computer.
#
#   push-guard.sh gate <remote> <url>     the pre-push hook body; reads the
#                                         "<local-ref> <local-sha> <remote-ref>
#                                         <remote-sha>" lines git gives a
#                                         pre-push hook on stdin
#   push-guard.sh check <base> <tip>      the same check for one range, from
#                                         inside the repo (base "" = root)
#
# Exit 0 ok, 1 blocked, 2 usage. A blocked push prints the marker paths (names
# only) and how to proceed. Override for one push, with the owner's OK:
#   HQ_PUSH_GUARD_ALLOW=1 git push ...
# `git push --no-verify` also skips this hook; the PreToolUse rule
# block-no-verify-bulk-add stops agents from typing that.
#
# Bash 3.2-safe, no python/node: it runs inside git hooks.

set -u

HQ_ROOT="${HQ_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)}"
MAX_ADDED="${HQ_PUSH_GUARD_MAX_ADDED:-2000}"
ZERO="0000000000000000000000000000000000000000"
# shellcheck source=lib/hq-root-markers.sh
. "$HQ_ROOT/core/scripts/lib/hq-root-markers.sh"

check_range() { # base tip label
  local base="$1" tip="$2" label="$3" list n hits
  list="$(mktemp "${TMPDIR:-/tmp}/hq-push-guard.XXXXXX")" || { echo "push-guard: mktemp failed" >&2; return 2; }
  if [ -n "$base" ]; then
    # --no-renames: a file moved into a marker path is an addition there.
    git -c core.quotePath=false diff --name-only --no-renames --diff-filter=A "$base" "$tip" >"$list" 2>/dev/null </dev/null
  else
    git -c core.quotePath=false ls-tree -r --name-only "$tip" >"$list" 2>/dev/null </dev/null
  fi
  n="$(grep -c . "$list" || true)"
  if [ "$n" -gt "$MAX_ADDED" ]; then
    local how="adds $n files"
    [ -n "$base" ] || how="carries $n files with no history in common with the remote"
    cat >&2 <<EOF

HQ push guard: PUSH BLOCKED — $label $how (ceiling $MAX_ADDED).
A branch never legitimately adds that many files at once; this is what a
folder copied into the worktree looks like. Check \`git diff --stat ${base:-<root>}..$tip\`.
If it is intended (a vendored tree, a generated corpus), push once with the
owner's OK:  HQ_PUSH_GUARD_ALLOW=1 git push ...
EOF
    rm -f "$list"; return 1
  fi
  hits="$(hqm_scan . "$base" "$list")" || {
    cat >&2 <<EOF

HQ push guard: PUSH BLOCKED — $label adds HQ-root marker paths:
$(printf '%s\n' "$hits" | sed 's/^/  /')
These names come from an HQ root (personal overlay, company folders,
credentials, drift or rescue files), not from this repository's work. A
"foreign:" line means a new second-level folder (for example personal/.codex/)
that this repository has never tracked. Remove the paths from the commits
before pushing. If the folder is intended new work, push once with the
owner's OK:  HQ_PUSH_GUARD_ALLOW=1 git push ...
(exceptions can be recorded in personal/settings/worktree-preserve-denylist.txt)
EOF
    rm -f "$list"; return 1
  }
  rm -f "$list"
  return 0
}

gate() { # remote url   (stdin: ref lines)
  local remote="${1:-origin}" lref lsha rref rsha base first rc=0
  [ "${HQ_PUSH_GUARD_ALLOW:-}" = "1" ] && return 0
  git rev-parse --show-toplevel >/dev/null 2>&1 </dev/null || { echo "HQ push guard: not inside a git work tree; skipping" >&2; return 0; }
  hqm_load "$HQ_ROOT" || { echo "HQ push guard: no denylist under $HQ_ROOT; skipping" >&2; return 0; }
  while read -r lref lsha rref rsha; do
    [ -n "${lsha:-}" ] || continue
    [ "$lsha" = "$ZERO" ] && continue # delete
    if [ -n "${rsha:-}" ] && [ "$rsha" != "$ZERO" ] && git cat-file -e "$rsha^{commit}" 2>/dev/null </dev/null; then
      base="$rsha"
    else
      # New remote branch: everything not already on that remote is new. With
      # no remote-tracking refs at all (fresh `git remote add`, a URL push)
      # the whole history is new and the whole tree counts.
      first="$(git rev-list --topo-order --reverse "$lsha" --not --remotes="$remote" 2>/dev/null </dev/null | head -1)"
      if [ -z "$first" ]; then continue; fi # nothing new
      base="$(git rev-parse -q --verify "$first^" 2>/dev/null </dev/null || echo "")"
    fi
    check_range "$base" "$lsha" "$lref -> $remote ${rref:-$lref}" || rc=1
  done
  return "$rc"
}

case "${1:-}" in
  gate)  shift; gate "$@"; exit $? ;;
  check) [ $# -ge 3 ] || { echo "usage: push-guard.sh check <base> <tip>" >&2; exit 2; }
         git rev-parse --show-toplevel >/dev/null 2>&1 || { echo "push-guard: not inside a git work tree" >&2; exit 2; }
         hqm_load "$HQ_ROOT" || exit 2
         check_range "$2" "$3" "$2..$3"; exit $? ;;
  -h|--help) sed -n '2,23p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) echo "usage: push-guard.sh gate <remote> <url> | check <base> <tip>" >&2; exit 2 ;;
esac
