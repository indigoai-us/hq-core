#!/bin/bash
# block-hq-worktree-session.sh — SessionStart / UserPromptSubmit / PreToolUse hook.
#
# THE CONCEPT THIS GUARDS:
#   HQ is an orchestration layer, not a branchable codebase. It must always run
#   from its single canonical checkout on `main` (hard policy
#   hq-no-worktree-for-repo-work). When a Claude session is started from a
#   LINKED GIT WORKTREE OF THE HQ REPO — Claude Code's built-in worktree /
#   agent-isolation mode, or a hand-made `git worktree add` of HQ — everything
#   HQ owns silently forks: workspace/sessions, workspace/threads, journals,
#   locks, the active-run registry, company settings and the vault-backed
#   state that hq-sync reconciles. Work done there looks normal and is then
#   lost or, worse, merged back as a branch that deletes unrelated HQ files.
#   Real symptom (policy hq-no-worktree-for-repo-work): `git status` showing
#   mass deletes of unrelated HQ files, and confusion over which directory is
#   canonical.
#
#   This hook is the mechanical backstop for that hard policy. It does not
#   depend on the model remembering the rule.
#
# WHAT IS BLOCKED (narrow, on purpose):
#   (a) the session's project dir (CLAUDE_PROJECT_DIR / HQ root) is itself a
#       linked worktree, or
#   (b) the session cwd is a linked worktree whose MAIN worktree is the HQ
#       root — i.e. a worktree cut from the HQ repository.
#
# WHAT IS NOT BLOCKED:
#   Task subagents launched with worktree isolation. Claude marks every hook
#   call made inside a subagent with a non-empty agent_id, which distinguishes
#   an intentional delegated child from an ordinary worktree session.
#
#   Worktrees of source repos under repos/ (the normal HQ editing flow lives
#   in workspace/worktrees/<repo>/<name>/ — see block-core-writes-bash.sh,
#   which REQUIRES them). Their main worktree is the repo checkout, never HQ
#   root, so they never match.
#
# Behaviour by event:
#   SessionStart      — emit a banner, exit 0 (SessionStart cannot block a
#                       session; the hard stop comes from the two events below).
#   UserPromptSubmit  — exit 2: the prompt is erased and the reason is shown to
#                       the user. Nothing runs.
#   PreToolUse        — exit 2: every tool call is refused, so a resumed or
#                       SDK-driven session in a worktree cannot do work either.
#
# Escape hatch (deliberate, audited, distinct from the generic core bypass):
#   HQ_ALLOW_HQ_WORKTREE=1 in the hook env.
#
# Exit codes: 0 = allow, 2 = block.

set -uo pipefail

INPUT="$(cat 2>/dev/null || true)"

if [ "${HQ_ALLOW_HQ_WORKTREE:-}" = "1" ]; then exit 0; fi

payload_field() {
  # master-hook.sh exports the fields it already parsed; use them and skip jq.
  case "$1" in
    hook_event_name) if [ -n "${HQ_HOOK_EVENT+set}" ]; then printf '%s' "$HQ_HOOK_EVENT"; return 0; fi ;;
    agent_id) if [ -n "${HQ_HOOK_AGENT_ID+set}" ]; then printf '%s' "$HQ_HOOK_AGENT_ID"; return 0; fi ;;
    cwd) if [ -n "${HQ_HOOK_CWD+set}" ]; then printf '%s' "$HQ_HOOK_CWD"; return 0; fi ;;
    session_id) if [ -n "${HQ_HOOK_SESSION_ID+set}" ]; then printf '%s' "$HQ_HOOK_SESSION_ID"; return 0; fi ;;
  esac
  [ -n "$INPUT" ] || return 0
  printf '%s' "$INPUT" | jq -r ".$1 // empty" 2>/dev/null || true
}

# Event: explicit argv wins (settings.json passes it), then the payload field.
EVENT="${1:-}"
[ -z "$EVENT" ] && EVENT="$(payload_field hook_event_name)"
[ -z "$EVENT" ] && EVENT="UserPromptSubmit"

# A Task subagent with `isolation: "worktree"` intentionally runs in a linked
# worktree. Claude includes agent_id on hook events fired inside a subagent;
# main-thread sessions (including manually started --worktree / --agent
# sessions) do not have it. Exempt only this provider-owned discriminator —
# agent_type alone is also present for manual --agent sessions.
[ -n "$(payload_field agent_id)" ] && exit 0

# Fast path: a cached allow verdict for this session, root and cwd (written
# below) answers before git or hook-lib.sh are touched.
guard_now() {
  if [ -n "${EPOCHSECONDS:-}" ]; then printf '%s' "$EPOCHSECONDS"; else date +%s 2>/dev/null || printf '0'; fi
}
GUARD_SESSION="$(payload_field session_id)"
GUARD_CACHE=""
GUARD_TTL="${HQ_WORKTREE_GUARD_TTL:-600}"
EARLY_ROOT="${CLAUDE_PROJECT_DIR:-${HQ_ROOT:-}}"
EARLY_CWD="$(payload_field cwd)"
if [ -n "$GUARD_SESSION" ] && [ -n "$EARLY_ROOT" ] && [ "$GUARD_TTL" != "0" ]; then
  case "$GUARD_SESSION" in
    *[!A-Za-z0-9._-]*) ;;
    *) GUARD_CACHE="$EARLY_ROOT/workspace/orchestrator/hook-state/worktree-guard/$GUARD_SESSION" ;;
  esac
fi
if [ -n "$GUARD_CACHE" ] && [ -f "$GUARD_CACHE" ]; then
  cached_root=""; cached_cwd=""; cached_ts=0
  while IFS='=' read -r k v; do
    case "$k" in root) cached_root="$v" ;; cwd) cached_cwd="$v" ;; ts) cached_ts="$v" ;; esac
  done < "$GUARD_CACHE"
  if [ "$cached_root" = "$EARLY_ROOT" ] && [ -n "$EARLY_CWD" ] && [ "$cached_cwd" = "$EARLY_CWD" ] \
     && [ $(( $(guard_now) - cached_ts )) -lt "$GUARD_TTL" ]; then
    exit 0
  fi
fi

command -v git >/dev/null 2>&1 || exit 0

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)"
HQ_ROOT="${CLAUDE_PROJECT_DIR:-${HQ_ROOT:-}}"
[ -z "$HQ_ROOT" ] && HQ_ROOT="$(cd "$HOOK_DIR/../.." 2>/dev/null && pwd)"
[ -n "$HQ_ROOT" ] || exit 0

# hq_normpath: lexical fallback for paths realpath cannot resolve.
if [ -f "$HQ_ROOT/core/scripts/hook-lib.sh" ]; then
  # shellcheck disable=SC1091
  . "$HQ_ROOT/core/scripts/hook-lib.sh" 2>/dev/null || true
fi

norm() {
  local p="${1:-}" resolved
  [ -n "$p" ] || return 0
  case "$p" in "~") p="$HOME" ;; "~/"*) p="$HOME${p#\~}" ;; esac
  resolved="$(realpath "$p" 2>/dev/null \
    || hq_normpath "$p" 2>/dev/null \
    || printf '%s\n' "$p")"
  if declare -F hq_canonical_path >/dev/null 2>&1; then
    hq_canonical_path "$resolved"
  else
    printf '%s\n' "$resolved"
  fi
}

SESSION_CWD="$(payload_field cwd)"
[ -z "$SESSION_CWD" ] && SESSION_CWD="$(pwd 2>/dev/null || true)"

linked_worktree_main() {
  local dir="${1:-}" gd cdir main
  [ -n "$dir" ] && [ -d "$dir" ] || return 1

  gd="$(git -C "$dir" rev-parse --absolute-git-dir 2>/dev/null)" || gd=""
  if [ -z "$gd" ]; then
    # git < 2.13 has no --absolute-git-dir; resolve the relative form ourselves.
    gd="$(git -C "$dir" rev-parse --git-dir 2>/dev/null)" || return 1
    case "$gd" in /*) ;; *) gd="$dir/$gd" ;; esac
  fi
  cdir="$(git -C "$dir" rev-parse --git-common-dir 2>/dev/null)" || return 1
  case "$cdir" in /*) ;; *) cdir="$dir/$cdir" ;; esac

  gd="$(norm "$gd")"
  cdir="$(norm "$cdir")"
  [ -n "$gd" ] && [ -n "$cdir" ] || return 1
  [ "$gd" != "$cdir" ] || return 1

  # `git worktree list` always reports the main worktree first.
  main="$(git -C "$dir" worktree list --porcelain 2>/dev/null \
    | awk '/^worktree /{print substr($0, 10); exit}')"
  if [ -z "$main" ]; then
    case "$cdir" in
      */.git) main="${cdir%/.git}" ;;
      *) return 1 ;;
    esac
  fi
  norm "$main"
}

REASON=""
CANONICAL=""
WORKTREE_PATH=""

MAIN_FOR_ROOT="$(linked_worktree_main "$HQ_ROOT" || true)"
if [ -n "$MAIN_FOR_ROOT" ]; then
  REASON="project-dir"
  CANONICAL="$MAIN_FOR_ROOT"
  WORKTREE_PATH="$(norm "$HQ_ROOT")"
else
  HQ_TOP="$(git -C "$HQ_ROOT" rev-parse --show-toplevel 2>/dev/null || true)"
  HQ_TOP="$(norm "$HQ_TOP")"
  MAIN_FOR_CWD="$(linked_worktree_main "$SESSION_CWD" || true)"
  if [ -n "$MAIN_FOR_CWD" ] && [ -n "$HQ_TOP" ] && [ "$MAIN_FOR_CWD" = "$HQ_TOP" ]; then
    REASON="cwd"
    CANONICAL="$MAIN_FOR_CWD"
    WORKTREE_PATH="$(norm "$SESSION_CWD")"
  fi
fi

if [ -z "$REASON" ]; then
  if [ -n "$GUARD_CACHE" ]; then
    mkdir -p "${GUARD_CACHE%/*}" 2>/dev/null \
      && printf 'root=%s\ncwd=%s\nts=%s\n' "$HQ_ROOT" "$SESSION_CWD" "$(guard_now)" > "$GUARD_CACHE.tmp.$$" 2>/dev/null \
      && mv -f "$GUARD_CACHE.tmp.$$" "$GUARD_CACHE" 2>/dev/null || true
  fi
  exit 0
fi

if [ "$REASON" = "project-dir" ]; then
  WHERE="This Claude session's project directory is a linked git worktree of the HQ repository."
else
  WHERE="This Claude session's working directory is a linked git worktree cut from the HQ repository."
fi

message() {
  cat <<MSG
$WHERE

  Worktree:      $WORKTREE_PATH
  Canonical HQ:  $CANONICAL

WHY THIS IS BLOCKED: HQ is an orchestration layer, not a branchable codebase,
and it must always run from its single canonical checkout on main (hard policy
hq-no-worktree-for-repo-work). Running HQ from a worktree forks every piece of
state HQ owns — sessions, threads, journals, locks, the active-run registry,
company settings, and the vault-backed state hq-sync reconciles. Work done in
the fork looks normal, then either disappears or comes back as an HQ branch
whose merge deletes unrelated HQ files.

WHAT TO DO: exit this session and start Claude from the canonical checkout:

  cd $CANONICAL

Source-repo worktrees are unaffected: editing a checkout under repos/ from a
worktree in workspace/worktrees/<repo>/<name>/ is the normal, required flow.
That is a worktree of the repo, not of HQ, and this guard never fires on it.

If HQ itself is genuinely meant to run from this directory, set
HQ_ALLOW_HQ_WORKTREE=1 in the environment for that session.

If this block is wrong or surprising, report it with /hq-bug.
MSG
}

case "$EVENT" in
  SessionStart)
    # SessionStart cannot stop a session; warn loudly and let the
    # UserPromptSubmit / PreToolUse blocks do the enforcing.
    printf '<hq-worktree-block>\n'
    message
    printf '</hq-worktree-block>\n'
    exit 0
    ;;
  *)
    printf 'BLOCKED: HQ is running from a git worktree.\n\n' >&2
    message >&2
    exit 2
    ;;
esac
