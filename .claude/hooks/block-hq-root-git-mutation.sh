#!/bin/bash
# block-hq-root-git-mutation.sh — PreToolUse hook for Bash.
#
# THE CONCEPT THIS GUARDS (one of the most important in HQ):
#   HQ root is itself a git repo, and every working repo is nested under it
#   (repos/*, companies/*/knowledge/.git, ...). A git/gh MUTATION whose
#   target directory is ambient (depends on invisible shell cwd) will
#   silently operate on whichever .git it resolves to. From HQ root that is
#   HQ — which by hard policy (hq-root-never-push-remote, hq-git-discipline)
#   is NEVER committed or pushed. Shell cwd is unreliable across context
#   compaction, long-running tools, and parallel-call leakage
#   (hq-verify-cwd-pwd-after-long-running-tools, parallel-bash-cwd-prefix),
#   so "I cd'd earlier" is not a safe assumption for a mutation.
#
#   The ONLY safe form for a repo git mutation is an explicit per-command
#   anchor:  `git -C /abs/path <cmd>`  or  `cd /abs/path && git <cmd>` in
#   the SAME Bash call. Hard policies are model-facing prose; this hook is
#   the mechanical backstop that does not depend on the model remembering
#   to run a pre-flight `pwd`.
#
# Escape hatch (deliberate, distinct, audited — NOT the generic core
# bypass): HQ_ALLOW_HQ_ROOT_GIT=1 in the hook env, or prefixed inline on a
# single sanctioned call (e.g. intentionally repairing HQ git internals).
#
# Exit codes: 0 = allow, 2 = block.

set -uo pipefail

INPUT=$(cat)
CMD=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null) || true
[[ -z "$CMD" ]] && exit 0

if [[ "${HQ_ALLOW_HQ_ROOT_GIT:-}" == "1" ]]; then exit 0; fi
if echo "$CMD" | grep -Eq '(^|[[:space:]])HQ_ALLOW_HQ_ROOT_GIT=1\b'; then exit 0; fi

echo "$CMD" | grep -Eq '(^|[[:space:];&|(])(git|gh)([[:space:]]|$)' || exit 0

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
norm() {
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import os,sys; sys.stdout.write(os.path.realpath(os.path.expanduser(sys.argv[1])))' "$1" 2>/dev/null || echo "$1"
  else
    echo "$1"
  fi
}
HQ_ROOT="$(norm "$PROJECT_DIR")"

GIT_RE_MUTATION='^(push|pull|fetch|clone|commit|merge|rebase|cherry-pick|revert|am|apply|format-patch|reset|restore|rm|mv|add|stage|checkout|switch|clean|gc|prune|repack|reflog|update-ref|update-index|filter-repo|filter-branch|fast-import|replace|fsck)$'
GIT_RE_READONLY='^(status|log|diff|show|shortlog|whatchanged|rev-parse|rev-list|describe|blame|annotate|cat-file|ls-files|ls-remote|ls-tree|for-each-ref|symbolic-ref|name-rev|var|version|help|count-objects|verify-pack|grep|bisect|branch|tag|stash|remote|notes|config|worktree|submodule)$'

git_subcommand() {
  local arr; read -r -a arr <<<"$1"
  local i seen_git=0
  for ((i=0; i<${#arr[@]}; i++)); do
    local t="${arr[i]}"
    if [[ $seen_git -eq 0 ]]; then
      [[ "$t" == "git" ]] && seen_git=1
      continue
    fi
    case "$t" in
      -C|-c|--git-dir|--work-tree|--namespace|--exec-path|--super-prefix) ((i++)); continue ;;
      --git-dir=*|--work-tree=*|--namespace=*|--exec-path=*|-c=*) continue ;;
      -p|--paginate|--no-pager|--no-replace-objects|--bare|--literal-pathspecs|--glob-pathspecs|--noglob-pathspecs|--icase-pathspecs) continue ;;
      -*) continue ;;
      *) echo "$t"; return 0 ;;
    esac
  done
  return 1
}

is_dual_mutation() {
  local sub="$1" cmd="$2"
  case "$sub" in
    branch) echo "$cmd" | grep -Eq 'git[^|;&]*\bbranch\b[^|;&]*( -[dDmMcC]\b| --delete| --move| --copy| --force)' && return 0 ;;
    tag)    echo "$cmd" | grep -Eq 'git[^|;&]*\btag\b[^|;&]*( -[dfasum]\b| --delete| --force| --sign| --annotate)' && return 0 ;;
    stash)  echo "$cmd" | grep -Eq 'git[^|;&]*\bstash\b[^|;&]*(push|pop|drop|apply|clear|save|create|store|branch)' && return 0
            echo "$cmd" | grep -Eq 'git[^|;&]*\bstash[[:space:]]*("|'"'"'| *$|\||&&|;)' && return 0 ;;
    remote) echo "$cmd" | grep -Eq 'git[^|;&]*\bremote\b[^|;&]*(add|remove|rm|rename|set-url|set-head|set-branches|prune)' && return 0 ;;
    notes)  echo "$cmd" | grep -Eq 'git[^|;&]*\bnotes\b[^|;&]*(add|append|copy|edit|remove|prune)' && return 0 ;;
    config) echo "$cmd" | grep -Eq 'git[^|;&]*\bconfig\b' && ! echo "$cmd" | grep -Eq 'git[^|;&]*\bconfig\b[^|;&]*(--get|--list|-l\b|--get-all|--get-regexp)' && return 0 ;;
    worktree)  echo "$cmd" | grep -Eq 'git[^|;&]*\bworktree\b[^|;&]*(add|remove|move|prune|repair|lock|unlock)' && return 0 ;;
    submodule) echo "$cmd" | grep -Eq 'git[^|;&]*\bsubmodule\b[^|;&]*(add|update|deinit|set-url|set-branch|sync)' && return 0 ;;
  esac
  return 1
}

GIT_IS_MUTATION=0
if echo "$CMD" | grep -Eq '(^|[[:space:];&|(])git([[:space:]]|$)'; then
  SUB="$(git_subcommand "$CMD" || true)"
  if [[ -n "$SUB" ]]; then
    if echo "$SUB" | grep -Eq "$GIT_RE_MUTATION"; then
      GIT_IS_MUTATION=1
    elif echo "$SUB" | grep -Eq "$GIT_RE_READONLY"; then
      is_dual_mutation "$SUB" "$CMD" && GIT_IS_MUTATION=1
    else
      GIT_IS_MUTATION=1
    fi
  fi
fi

GH_IS_MUTATION=0
if echo "$CMD" | grep -Eq '(^|[[:space:];&|(])gh[[:space:]]+(pr|repo|release|issue|api)'; then
  if echo "$CMD" | grep -Eq 'gh[[:space:]]+(pr[[:space:]]+(create|merge|close|reopen|edit|comment|ready|review)|repo[[:space:]]+(create|delete|rename|archive|edit|sync|fork)|release[[:space:]]+(create|delete|edit|upload)|issue[[:space:]]+(create|close|edit|comment|delete)|api[^|;&]*-X[[:space:]]*(POST|PUT|PATCH|DELETE))'; then
    GH_IS_MUTATION=1
  fi
fi

[[ $GIT_IS_MUTATION -eq 0 && $GH_IS_MUTATION -eq 0 ]] && exit 0

ANCHOR_PATH=""
ANCHOR_KIND=""

if [[ $GIT_IS_MUTATION -eq 1 ]]; then
  GC=$(echo "$CMD" | grep -oE 'git[[:space:]]+([^|;&]*[[:space:]])?-C[[:space:]]+("[^"]+"|'"'"'[^'"'"']+'"'"'|[^ ;&|]+)' | head -1 \
       | sed -E 's/.*-C[[:space:]]+//; s/^"//; s/"$//; s/^'"'"'//; s/'"'"'$//')
  if [[ -n "$GC" ]]; then ANCHOR_PATH="$GC"; ANCHOR_KIND="git -C"; fi
fi

if [[ -z "$ANCHOR_PATH" && $GH_IS_MUTATION -eq 1 ]]; then
  if echo "$CMD" | grep -Eq 'gh[^|;&]*[[:space:]](-R|--repo)[[:space:]]+[^ ;&|]+'; then
    exit 0
  fi
fi

if [[ -z "$ANCHOR_PATH" ]]; then
  PREFIX_GIT="${CMD%%git*}"
  PREFIX_GH="${CMD%%gh *}"
  PREFIX="$PREFIX_GIT"
  [[ ${#PREFIX_GH} -lt ${#PREFIX} ]] && PREFIX="$PREFIX_GH"
  CDP=$(echo "$PREFIX" | grep -oE '(^|[;&|])[[:space:]]*cd[[:space:]]+("[^"]+"|'"'"'[^'"'"']+'"'"'|[^ ;&|]+)' | tail -1 \
        | sed -E 's/.*cd[[:space:]]+//; s/^"//; s/"$//; s/^'"'"'//; s/'"'"'$//')
  if [[ -n "$CDP" ]]; then ANCHOR_PATH="$CDP"; ANCHOR_KIND="cd &&"; fi
fi

block() {
  cat >&2 <<MSG
BLOCKED: $1

  Command: $CMD

WHY: A git/gh mutation must carry its OWN explicit repo anchor in the same
Bash call. Shell cwd is not a reliable anchor — it silently drifts across
context compaction, long-running tools, and parallel-call leakage, so a
bare mutation can land on the HQ root repo (never committed/pushed:
hq-root-never-push-remote, hq-git-discipline) or the wrong repo.

FIX — re-issue with an explicit anchor:
  git -C /abs/path/to/repo <subcommand> ...
  ( cd /abs/path/to/repo && git <subcommand> ... )     # in ONE call
  gh pr create -R owner/repo ...                         # for gh

Mechanical backstop for a real incident (a bare \`git push\` after earlier
\`cd\`s — the DISABLED HQ push URL caught it only by luck). If you are
intentionally operating on HQ git internals, prefix the single command
with HQ_ALLOW_HQ_ROOT_GIT=1.

If this block is wrong or surprising, report it with /hq-bug.
MSG
  exit 2
}

if [[ -z "$ANCHOR_PATH" ]]; then
  block "Unanchored git/gh mutation (no \`git -C\`, no \`cd <abs> &&\`, no \`gh -R\`)."
fi

case "$ANCHOR_PATH" in
  /*|\~*) RESOLVED="$ANCHOR_PATH" ;;
  *)      RESOLVED="$HQ_ROOT/$ANCHOR_PATH" ;;
esac
RESOLVED="$(norm "$RESOLVED")"

TOPLEVEL="$(git -C "$RESOLVED" rev-parse --show-toplevel 2>/dev/null || true)"
if [[ -n "$TOPLEVEL" ]]; then
  TOPLEVEL="$(norm "$TOPLEVEL")"
  if [[ "$TOPLEVEL" == "$HQ_ROOT" ]]; then
    block "Anchor ($ANCHOR_KIND -> $ANCHOR_PATH) resolves to the HQ root git repo."
  fi
fi

exit 0
