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
#   The safe form for a repo git mutation is an explicit per-command
#   anchor: `git -C /abs/path <cmd>` (git) or `-R owner/repo` (gh) in the
#   SAME Bash call. Hard policies are model-facing prose; this hook is
#   the mechanical backstop that does not depend on the model remembering
#   to run a pre-flight `pwd`.
#
# Escape hatch (deliberate, distinct, audited — NOT the generic core
# bypass): HQ_ALLOW_HQ_ROOT_GIT=1 in the hook env, or prefixed inline on a
# single sanctioned call (e.g. intentionally repairing HQ git internals).
#
# REGRESSION NOTE — harness cd-strip (2026-06-08, re-verified 2026-06-09):
#   The Claude Code harness silently STRIPS a leading `cd /abs/path && `
#   (including inside `( ... )`) from a Bash command when /abs/path equals
#   the session's current cwd — this hook then receives the command WITHOUT
#   its cd anchor. Verified by sending `( cd <cwd> && git add --dry-run … )`
#   from <cwd>: the hook's own block message echoed the command minus the
#   cd prefix. Separately, the extraction regex below historically rejected
#   the parenthesized `( cd /abs && git … )` form even when it survived
#   (no `(` in the prefix class — fixed 2026-06-09). Consequences encoded
#   in this version:
#     (a) the cd-anchor form is no longer offered as a FIX — use `git -C`;
#     (b) when NO anchor is found, fall back to the harness-reported input
#         cwd: if it resolves to a git toplevel OTHER than HQ root, the
#         mutation cannot land on HQ root and is allowed (the stripped-
#         anchor case is by construction intended-anchor == actual cwd);
#     (c) `gh repo create` (which accepts neither `git -C` nor `-R`) is
#         self-anchoring: its target is named in its args and without
#         --source it never touches a local repo; --source must be an
#         absolute non-HQ path. Previously it was unanchorable — 5
#         consecutive blocks during the hq-aws-resources build 2026-06-08.
#   Strip behavior reported upstream via /hq-bug.
#
# Exit codes: 0 = allow, 2 = block.

set -uo pipefail

INPUT=$(cat)
CMD=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null) || true
TOOL_CWD=$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null) || true
[[ -z "$CMD" ]] && exit 0

if [[ "${HQ_ALLOW_HQ_ROOT_GIT:-}" == "1" ]]; then exit 0; fi
if echo "$CMD" | grep -Eq '(^|[[:space:]])HQ_ALLOW_HQ_ROOT_GIT=1\b'; then exit 0; fi

echo "$CMD" | grep -Eq '(^|[[:space:];&|(])(git|gh)([[:space:]]|$)' || exit 0

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/core/scripts/hook-lib.sh"
# expanduser + realpath (symlink-resolving when the path exists), python-free:
# `realpath` ships with GNU coreutils (Linux, Git Bash) and modern macOS; fall
# back to the lexical hq_normpath when it is missing or the path is dangling.
norm() {
  local p="$1"
  case "$p" in "~") p="$HOME" ;; "~/"*) p="$HOME${p#\~}" ;; esac
  realpath "$p" 2>/dev/null || hq_normpath "$p" 2>/dev/null || echo "$p"
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
  CDP=$(echo "$PREFIX" | grep -oE '(^|[;&|(])[[:space:]]*cd[[:space:]]+("[^"]+"|'"'"'[^'"'"']+'"'"'|[^ ;&|)]+)' | tail -1 \
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
  git -C /abs/path/to/repo <subcommand> ...    # canonical for git
  gh pr create -R owner/repo ...               # canonical for gh
  gh repo create owner/name ...                # self-anchoring (--source, if
                                               # used, must be absolute, non-HQ)

Do NOT use \`( cd /abs/path && git ... )\` as the anchor: the Claude Code
harness silently strips a leading \`cd <path> && \` when <path> equals the
session cwd, so this hook never sees it (verified 2026-06-08, re-verified
2026-06-09). If your cwd is already inside the target non-HQ repo, bare
mutations are permitted via the cwd fallback — so seeing this block means
the effective cwd IS the HQ root repo (or not a repo at all), and the
mutation would land on HQ.

Mechanical backstop for a real incident (a bare \`git push\` after earlier
\`cd\`s — the DISABLED HQ push URL caught it only by luck). If you are
intentionally operating on HQ git internals, prefix the single command
with HQ_ALLOW_HQ_ROOT_GIT=1.

If this block is wrong or surprising, report it with /hq-bug.
MSG
  exit 2
}

# `git init` is the one mutation for which upward git discovery can identify
# the wrong repository: before the new repository has a .git, a direct child
# of repos/private or repos/public resolves upward to HQ_ROOT. Parse the init
# invocation itself so the exception is based on Git's actual target directory,
# not merely on the process cwd. This intentionally accepts only a standalone
# `git init` command; compound commands continue through the normal guard.
git_init_target() {
  local cmd="$1" token value
  local -a arr
  local i=0 base="${TOOL_CWD:-$HQ_ROOT}" dir="" end_options=0

  [[ "$cmd" != *$'\n'* && "$cmd" != *$'\r'* ]] || return 1
  echo "$cmd" | grep -Eq '[;&|`$()<>]' && return 1
  read -r -a arr <<<"$cmd"
  [[ ${#arr[@]} -gt 0 && "${arr[0]}" == "git" ]] || return 1

  # Remove simple surrounding quotes without evaluating any command text.
  unquote_init_token() {
    local v="$1"
    if [[ "$v" == \"*\" && "$v" == *\" ]]; then
      v="${v#\"}"; v="${v%\"}"
    elif [[ "$v" == \'*\' && "$v" == *\' ]]; then
      v="${v#\'}"; v="${v%\'}"
    fi
    printf '%s\n' "$v"
  }

  # Apply global -C options in order, matching Git's relative -C semantics.
  i=1
  while (( i < ${#arr[@]} )); do
    token="${arr[i]}"
    case "$token" in
      -C)
        ((i++)); (( i < ${#arr[@]} )) || return 1
        value="$(unquote_init_token "${arr[i]}")"
        case "$value" in
          /*|\~*) base="$(norm "$value")" ;;
          *)      base="$(norm "$base/$value")" ;;
        esac
        ;;
      -c|--namespace|--exec-path|--super-prefix)
        ((i++)); (( i < ${#arr[@]} )) || return 1
        ;;
      -c=*|--namespace=*|--exec-path=*|-p|--paginate|--no-pager|--no-replace-objects|--literal-pathspecs|--glob-pathspecs|--noglob-pathspecs|--icase-pathspecs|--bare)
        ;;
      init)
        ((i++))
        break
        ;;
      *) return 1 ;;
    esac
    ((i++))
  done
  [[ "${arr[i-1]:-}" == "init" ]] || return 1

  # git-init options that consume a following value must not be mistaken for
  # the optional directory. --separate-git-dir is deliberately excluded: it
  # initializes repository metadata at a second path and is not this carve-out.
  while (( i < ${#arr[@]} )); do
    token="${arr[i]}"
    if [[ $end_options -eq 1 ]]; then
      [[ -z "$dir" ]] || return 1
      dir="$(unquote_init_token "$token")"
    else
      case "$token" in
        --) end_options=1 ;;
        -q|--quiet|--bare|--shared) ;;
        --shared=*|--template=*|--object-format=*|--ref-format=*|--initial-branch=*|-b?*) ;;
        -b|--initial-branch|--template|--object-format|--ref-format)
          ((i++)); (( i < ${#arr[@]} )) || return 1
          ;;
        --separate-git-dir|--separate-git-dir=*) return 1 ;;
        -*) return 1 ;;
        *)
          [[ -z "$dir" ]] || return 1
          dir="$(unquote_init_token "$token")"
          ;;
      esac
    fi
    ((i++))
  done

  if [[ -n "$dir" ]]; then
    case "$dir" in
      /*|\~*) printf '%s\n' "$(norm "$dir")" ;;
      *)      printf '%s\n' "$(norm "$base/$dir")" ;;
    esac
  else
    printf '%s\n' "$(norm "$base")"
  fi
}

is_new_direct_child_repo_target() {
  local target="$1" parent existing_git_dir hq_git_dir
  parent="$(norm "$target/..")"
  [[ "$parent" == "$(norm "$HQ_ROOT/repos/private")" ||
     "$parent" == "$(norm "$HQ_ROOT/repos/public")" ]] || return 1
  [[ ! -e "$target" || -d "$target" ]] || return 1
  [[ ! -e "$target/.git" && ! -L "$target/.git" ]] || return 1

  # A bare repository has no .git child. Reject it (and any other nested repo)
  # by comparing its resolved git dir with the HQ git dir inherited by a plain
  # uninitialized child directory.
  if [[ -d "$target" ]]; then
    existing_git_dir="$(git -C "$target" rev-parse --absolute-git-dir 2>/dev/null || true)"
    hq_git_dir="$(git -C "$HQ_ROOT" rev-parse --absolute-git-dir 2>/dev/null || true)"
    if [[ -n "$existing_git_dir" &&
          "$(norm "$existing_git_dir")" != "$(norm "$hq_git_dir")" ]]; then
      return 1
    fi
  fi
  return 0
}

if [[ $GIT_IS_MUTATION -eq 1 && $GH_IS_MUTATION -eq 0 && "$SUB" == "init" ]]; then
  INIT_TARGET="$(git_init_target "$CMD" || true)"
  if [[ -n "$INIT_TARGET" ]] && is_new_direct_child_repo_target "$INIT_TARGET"; then
    exit 0
  fi
fi

# `gh repo create` names its target in its own args (owner/name, or name under
# the authenticated account) and accepts neither `git -C` nor `-R` — requiring
# an external anchor made it impossible to invoke. Without --source it never
# touches a local repo, so the HQ-root guard has nothing to protect. The one
# cwd-dependent part is --source: require it absolute and outside the HQ root
# repo. Only applies when the command carries no other git/gh mutation.
if [[ $GIT_IS_MUTATION -eq 0 && $GH_IS_MUTATION -eq 1 && -z "$ANCHOR_PATH" ]] \
   && echo "$CMD" | grep -Eq 'gh[[:space:]]+repo[[:space:]]+create' \
   && ! echo "$CMD" | grep -Eq '(^|[[:space:];&|(])gh[[:space:]]+(pr|release|issue|api)([[:space:]]|$)' \
   && ! echo "$CMD" | grep -Eq 'gh[[:space:]]+repo[[:space:]]+(delete|rename|archive|edit|sync|fork)'; then
  SRC=$(echo "$CMD" | grep -oE -- '--source(=|[[:space:]]+)("[^"]+"|'"'"'[^'"'"']+'"'"'|[^ ;&|)]+)' | head -1 \
        | sed -E 's/^--source(=|[[:space:]]+)//; s/^"//; s/"$//; s/^'"'"'//; s/'"'"'$//')
  if [[ -z "$SRC" ]]; then
    exit 0
  fi
  case "$SRC" in
    /*)
      SRC_TOP="$(git -C "$(norm "$SRC")" rev-parse --show-toplevel 2>/dev/null || true)"
      if [[ -n "$SRC_TOP" && "$(norm "$SRC_TOP")" == "$HQ_ROOT" ]]; then
        block "gh repo create --source ($SRC) resolves to the HQ root git repo (never pushed to a remote)."
      fi
      exit 0
      ;;
    *)
      block "gh repo create --source must be an ABSOLUTE path ('$SRC' is relative — ambient-cwd dependent)."
      ;;
  esac
fi

if [[ -z "$ANCHOR_PATH" ]]; then
  # Harness-strip fallback (see REGRESSION NOTE in header): a correctly
  # cd-anchored command can reach this hook bare because the harness strips
  # `cd <path> && ` when <path> equals the session cwd — and in exactly that
  # case the intended anchor IS the input cwd. If the harness-reported cwd
  # resolves to a git toplevel other than HQ root, the mutation mechanically
  # cannot land on the HQ root repo — allow it. Bare mutations whose
  # effective cwd is HQ root (or not a repo) remain blocked: that is the
  # incident class this hook exists for.
  if [[ -n "$TOOL_CWD" ]]; then
    CWD_TOP="$(git -C "$TOOL_CWD" rev-parse --show-toplevel 2>/dev/null || true)"
    if [[ -n "$CWD_TOP" && "$(norm "$CWD_TOP")" != "$HQ_ROOT" ]]; then
      exit 0
    fi
  fi
  block "Unanchored git/gh mutation with effective cwd at the HQ root (no \`git -C\`, no \`gh -R\`)."
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
