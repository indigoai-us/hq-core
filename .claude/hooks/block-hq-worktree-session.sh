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

INPUT=""
INPUT_LOADED=0
load_input() {
  [ "$INPUT_LOADED" -eq 1 ] && return 0
  INPUT_LOADED=1
  IFS= read -r -d '' INPUT </dev/stdin || true
}

# Direct invocations have no master-hook field exports. Read their payload
# once in the parent shell so later field lookups can safely use command
# substitutions without losing the cached input.
if [ -z "${HQ_HOOK_AGENT_ID+set}" ] || [ -z "${HQ_HOOK_SESSION_ID+set}" ] || [ -z "${HQ_HOOK_CWD+set}" ]; then
  load_input
fi

if [ "${HQ_ALLOW_HQ_WORKTREE:-}" = "1" ]; then exit 0; fi

payload_field() {
  # master-hook.sh exports the fields it already parsed; use them and skip jq.
  case "$1" in
    hook_event_name) if [ -n "${HQ_HOOK_EVENT+set}" ]; then printf '%s' "$HQ_HOOK_EVENT"; return 0; fi ;;
    agent_id) if [ -n "${HQ_HOOK_AGENT_ID+set}" ]; then printf '%s' "$HQ_HOOK_AGENT_ID"; return 0; fi ;;
    tool_name) if [ -n "${HQ_HOOK_TOOL_NAME+set}" ]; then printf '%s' "$HQ_HOOK_TOOL_NAME"; return 0; fi ;;
    cwd) if [ -n "${HQ_HOOK_CWD+set}" ]; then printf '%s' "$HQ_HOOK_CWD"; return 0; fi ;;
    session_id) if [ -n "${HQ_HOOK_SESSION_ID+set}" ]; then printf '%s' "$HQ_HOOK_SESSION_ID"; return 0; fi ;;
  esac
  load_input
  [ -n "$INPUT" ] || return 0
  printf '%s' "$INPUT" | jq -r ".$1 // empty" 2>/dev/null || true
}

# Event: explicit argv wins (settings.json passes it), then the payload field.
EVENT="${1:-}"
[ -z "$EVENT" ] && EVENT="$(payload_field hook_event_name)"
[ -z "$EVENT" ] && EVENT="UserPromptSubmit"

# Session-spawn tools (feedback_ddf0470d). A desktop spawn_task chip, or a
# start_session call asking for its own worktree, launched from the HQ root
# creates a new session in a linked worktree of HQ. This guard then blocks that
# session on its first prompt, after the user has already accepted the chip.
# Refuse the spawn up front instead, with what to do. A spawn aimed at a source
# repo under repos/, outside HQ, at another host (cloud/ssh/preset), or
# explicitly in this checkout (use_worktree: false) is allowed. Offers without
# a brief and starts of an already-checked proposal create nothing new here.
spawn_target_is_hq_worktree() {
  local tool="$1" root="${CLAUDE_PROJECT_DIR:-${HQ_ROOT:-}}" fields use_wt cwd target host preset context prompt proposal
  # Only a session rooted at HQ itself forks HQ; a source-repo session's own
  # worktrees are the normal flow.
  case "$root" in */repos/*) return 1 ;; esac
  load_input
  [ -n "$INPUT" ] || return 1
  # Unit-separator framing: tab is IFS whitespace and would collapse empty
  # fields, shifting every later column.
  fields="$(printf '%s' "$INPUT" | jq -r '.tool_input // {} | [
      (if has("use_worktree") then (.use_worktree | tostring) else "" end),
      (.cwd // ""), (.target // ""), (.host // ""), (.preset // ""), (.context // ""),
      ((.prompt // "") | .[0:1]), (.proposal_id // "") ]
      | map(tostring | gsub("[\u001f\n]"; " ")) | join("\u001f")' 2>/dev/null)" || return 1
  IFS=$'\x1f' read -r use_wt cwd target host preset context prompt proposal <<<"$fields"
  [ "$use_wt" = "false" ] && return 1
  case "$target" in cloud|ssh) return 1 ;; esac
  [ -n "$host" ] || [ -n "$preset" ] && return 1
  if [ -n "$cwd" ] && [ -n "$root" ]; then
    case "$cwd" in "~"*) cwd="$HOME${cwd#\~}" ;; esac
    case "$cwd" in
      "$root"/repos/*) return 1 ;;
      "$root"|"$root"/*) ;;
      *) return 1 ;;
    esac
  fi
  case "$tool" in
    *spawn_task)
      # spawn_task always starts its session in a new worktree of the project.
      return 0 ;;
  esac
  # start_session: a fork shares a plain checkout; an omitted use_worktree
  # keeps a plain checkout's folder. Only an explicit worktree request forks HQ.
  [ "$context" = "fork" ] && return 1
  [ -n "$proposal" ] && [ -z "$prompt" ] && return 1
  [ "$use_wt" = "true" ]
}

if [ "$EVENT" = "PreToolUse" ]; then
  SPAWN_TOOL="$(payload_field tool_name)"
  case "$SPAWN_TOOL" in
    spawn_task|*__spawn_task|start_session|*__start_session)
      if spawn_target_is_hq_worktree "$SPAWN_TOOL"; then
        cat >&2 <<'MSG'
BLOCKED: this would start an HQ session in a linked git worktree.

A new session started from the HQ root in its own worktree is a worktree of
HQ itself, and HQ's worktree guard blocks such a session on its first prompt
(hard policy hq-no-worktree-for-repo-work). The user would accept the chip and
then get a session that cannot run.

Instead:
  - start the session in this checkout: start_session with use_worktree: false
  - for code work in a source repo, set cwd to the repo under repos/ (its own
    worktree there is fine)
  - or do the work here, or in a background Task subagent

Do not offer a spawn_task chip from the HQ root: it always uses a worktree.
MSG
        exit 2
      fi
      ;;
  esac
fi

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

HOOK_SOURCE="${BASH_SOURCE[0]:-$0}"
HOOK_DIR="${HOOK_SOURCE%/*}"
[ "$HOOK_DIR" != "$HOOK_SOURCE" ] || HOOK_DIR="."
HOOK_DIR="$(cd "$HOOK_DIR" 2>/dev/null && pwd -P)"
HQ_ROOT="${CLAUDE_PROJECT_DIR:-${HQ_ROOT:-}}"
[ -z "$HQ_ROOT" ] && HQ_ROOT="$(cd "$HOOK_DIR/../.." 2>/dev/null && pwd)"
[ -n "$HQ_ROOT" ] || exit 0

# Existing hook paths are directories. Resolve them with Bash's cd builtin;
# sourcing hook-lib.sh and asking Git to enumerate worktrees made a cold
# SessionStart pay for several child processes before it could warn.
norm() {
  local p="${1:-}" resolved="" old_pwd="${PWD:-}"
  [ -n "$p" ] || return 0
  case "$p" in "~") p="$HOME" ;; "~/"*) p="$HOME${p#\~}" ;; esac
  if [ -d "$p" ] && CDPATH= cd -P -- "$p" >/dev/null 2>&1; then
    resolved="$PWD"
    [ -n "$old_pwd" ] && CDPATH= cd -- "$old_pwd" >/dev/null 2>&1 || true
  fi
  printf '%s\n' "${resolved:-$p}"
}

parent_dir() {
  local path="$1" parent
  case "$path" in
    /) return 1 ;;
    */*) parent="${path%/*}"; [ -n "$parent" ] || parent="/" ;;
    *) return 1 ;;
  esac
  [ "$parent" != "$path" ] || return 1
  printf '%s\n' "$parent"
}

repo_root_for() {
  local dir="${1:-}" next
  [ -d "$dir" ] || return 1
  dir="$(norm "$dir")"
  while [ -n "$dir" ]; do
    if [ -d "$dir/.git" ] || [ -f "$dir/.git" ]; then
      printf '%s\n' "$dir"
      return 0
    fi
    next="$(parent_dir "$dir")" || return 1
    dir="$next"
  done
  return 1
}

SESSION_CWD="$(payload_field cwd)"
[ -z "$SESSION_CWD" ] && SESSION_CWD="${PWD:-}"

repo_common_git_dir_for() {
  local dir="${1:-}" root marker entry gd common_file common
  [ -n "$dir" ] && [ -d "$dir" ] || return 1
  root="$(repo_root_for "$dir")" || return 1
  marker="$root/.git"
  if [ -d "$marker" ]; then
    common="$marker"
  elif [ -f "$marker" ]; then
    IFS= read -r entry < "$marker" || return 1
    entry="${entry%$'\r'}"
    case "$entry" in "gitdir: "*) gd="${entry#gitdir: }" ;; *) return 1 ;; esac
    case "$gd" in /*|[A-Za-z]:/*) ;; *) gd="$root/$gd" ;; esac
    gd="$(norm "$gd")"
    [ -n "$gd" ] || return 1
    common_file="$gd/commondir"
    if [ -f "$common_file" ]; then
      IFS= read -r common < "$common_file" || return 1
      common="${common%$'\r'}"
      case "$common" in /*|[A-Za-z]:/*) ;; *) common="$gd/$common" ;; esac
    else
      common="$gd"
    fi
  else
    return 1
  fi
  common="$(norm "$common")"
  [ -n "$common" ] || return 1
  printf '%s\n' "$common"
}

linked_worktree_common_git_dir_for() {
  local dir="${1:-}" root marker entry gd common_file common
  [ -n "$dir" ] && [ -d "$dir" ] || return 1
  root="$(repo_root_for "$dir")" || return 1
  marker="$root/.git"
  [ -f "$marker" ] || return 1
  IFS= read -r entry < "$marker" || return 1
  entry="${entry%$'\r'}"
  case "$entry" in "gitdir: "*) gd="${entry#gitdir: }" ;; *) return 1 ;; esac
  case "$gd" in /*|[A-Za-z]:/*) ;; *) gd="$root/$gd" ;; esac
  gd="$(norm "$gd")"
  [ -n "$gd" ] || return 1
  common_file="$gd/commondir"
  [ -f "$common_file" ] || return 1
  IFS= read -r common < "$common_file" || return 1
  common="${common%$'\r'}"
  case "$common" in /*|[A-Za-z]:/*) ;; *) common="$gd/$common" ;; esac
  common="$(norm "$common")"
  [ -n "$common" ] && [ "$gd" != "$common" ] || return 1
  printf '%s\n' "$common"
}

linked_worktree_main() {
  local dir="${1:-}" common main
  common="$(linked_worktree_common_git_dir_for "$dir")" || return 1
  # The common directory is usually <main checkout>/.git. Separate-git-dir
  # repositories use an arbitrary metadata path, which identifies the linked
  # worktree but does not encode the main checkout's path.
  case "$common" in
    */.git) main="${common%/.git}" ;;
    *) return 1 ;;
  esac
  norm "$main"
}

REASON=""
CANONICAL=""
WORKTREE_PATH=""

MAIN_FOR_ROOT_COMMON="$(linked_worktree_common_git_dir_for "$HQ_ROOT" || true)"
MAIN_FOR_ROOT="$(linked_worktree_main "$HQ_ROOT" || true)"
if [ -n "$MAIN_FOR_ROOT_COMMON" ]; then
  REASON="project-dir"
  CANONICAL="$MAIN_FOR_ROOT"
  COMMON_GIT_DIR="$MAIN_FOR_ROOT_COMMON"
  WORKTREE_PATH="$(norm "$HQ_ROOT")"
else
  HQ_TOP="$(repo_root_for "$HQ_ROOT" 2>/dev/null || true)"
  HQ_TOP="$(norm "$HQ_TOP")"
  HQ_COMMON_GIT_DIR="$(repo_common_git_dir_for "$HQ_TOP" || true)"
  CWD_LINKED_COMMON="$(linked_worktree_common_git_dir_for "$SESSION_CWD" || true)"
  if [ -n "$CWD_LINKED_COMMON" ] && [ -n "$HQ_COMMON_GIT_DIR" ] \
     && [ "$CWD_LINKED_COMMON" = "$HQ_COMMON_GIT_DIR" ]; then
    REASON="cwd"
    CANONICAL="$HQ_TOP"
    COMMON_GIT_DIR="$CWD_LINKED_COMMON"
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

# A session whose project root is canonical HQ may deliberately `cd` into an
# HQ-linked worktree for shell work. Keep sessions launched from an HQ
# worktree blocked; only the cwd-only case is eligible for this default-off
# hq-flags gate.
if [ "$REASON" = "cwd" ] && command -v node >/dev/null 2>&1; then
  if [ -z "${HQ_CLI_BIN:-}" ]; then
    HQ_CLI_BIN="$(command -v hq 2>/dev/null || true)"
    export HQ_CLI_BIN
  fi
  SAFE_CWD_FLAG="$(node "$HOOK_DIR/block-hq-worktree-safe-cd-flag.cjs")" || SAFE_CWD_FLAG=false
  [ "$SAFE_CWD_FLAG" = "true" ] && exit 0
fi

if [ "$REASON" = "project-dir" ]; then
  WHERE="This Claude session's project directory is a linked git worktree of the HQ repository."
else
  WHERE="This Claude session's working directory is a linked git worktree cut from the HQ repository."
fi

message() {
  local canonical_display next_step
  if [ -n "$CANONICAL" ]; then
    canonical_display="Canonical HQ:  $CANONICAL"
    next_step="cd $CANONICAL"
  else
    canonical_display="Canonical HQ:  path unavailable (separate Git directory: $COMMON_GIT_DIR)"
    next_step="start Claude from HQ's main checkout; its path is not recorded in this separate Git directory"
  fi
  cat <<MSG
$WHERE

  Worktree:      $WORKTREE_PATH
  $canonical_display

WHY THIS IS BLOCKED: HQ is an orchestration layer, not a branchable codebase,
and it must always run from its single canonical checkout on main (hard policy
hq-no-worktree-for-repo-work). Running HQ from a worktree forks every piece of
state HQ owns — sessions, threads, journals, locks, the active-run registry,
company settings, and the vault-backed state hq-sync reconciles. Work done in
the fork looks normal, then either disappears or comes back as an HQ branch
whose merge deletes unrelated HQ files.

WHAT TO DO: exit this session and start Claude from the canonical checkout:

  $next_step

When starting an HQ session, leave Claude Code's Worktree toggle unchecked. It
starts HQ in a linked worktree, which this guard blocks. Use the toggle for a
source-repository session; those worktrees are unaffected.

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
