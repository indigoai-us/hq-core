#!/bin/bash
# hq-core: public
# hq-autocommit.sh — quiet local HQ autosave for non-repo edits.
#
# Runs after Edit/Write/MultiEdit-shaped changes. It commits only the file path
# touched by the just-finished tool call, skips repos/ and nested git repos, and
# says nothing while it is working. Specific repo work keeps normal commit
# discipline.
#
# Quiet is not the same as silent. Every path that is a deliberate no-op (wrong
# tool, path outside the HQ root, excluded prefix, nothing staged) still exits 0
# without a word. A path where git itself FAILED is recorded in
# workspace/logs/hq-autocommit.log and warned about once per session — an
# orphaned .git/index.lock used to stop autosave for hours while producing zero
# output anywhere, which read to the user as a healthy quiet system.
#
# Exit status stays 0 on git failure so a broken autosave never blocks the
# editor. Set HQ_AUTOCOMMIT_STRICT=1 to make failures exit non-zero instead
# (for diagnostics and tests, where "did it work" must be machine-readable).

set -uo pipefail

INPUT="$(cat 2>/dev/null || echo '{}')"

if [[ "${HQ_AUTOCOMMIT:-1}" == "0" ]]; then
  exit 0
fi

TOOL_NAME="$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null || true)"
case "$TOOL_NAME" in
  Edit|Write|MultiEdit) ;;
  *) exit 0 ;;
esac

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HQ_ROOT="${CLAUDE_PROJECT_DIR:-$(cd "$SCRIPT_DIR/../.." && pwd)}"

if [[ ! -d "$HQ_ROOT/.git" || ! -f "$HQ_ROOT/core/core.yaml" ]]; then
  exit 0
fi

FILE_PATH="$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null || true)"
if [[ -z "$FILE_PATH" ]]; then
  exit 0
fi

if [[ "$FILE_PATH" != /* ]]; then
  FILE_PATH="$HQ_ROOT/$FILE_PATH"
fi

DIR_PATH="$FILE_PATH"
if [[ ! -d "$DIR_PATH" ]]; then
  DIR_PATH="$(dirname "$FILE_PATH")"
fi

PATH_TOP="$(git -C "$DIR_PATH" rev-parse --show-toplevel 2>/dev/null || true)"
HQ_TOP="$(git -C "$HQ_ROOT" rev-parse --show-toplevel 2>/dev/null || true)"
if [[ -z "$PATH_TOP" || -z "$HQ_TOP" || "$PATH_TOP" != "$HQ_TOP" ]]; then
  exit 0
fi

if [[ -d "$FILE_PATH" ]]; then
  REL_PATH="$(git -C "$FILE_PATH" rev-parse --show-prefix 2>/dev/null || true)"
  REL_PATH="${REL_PATH%/}"
else
  PREFIX="$(git -C "$DIR_PATH" rev-parse --show-prefix 2>/dev/null || true)"
  REL_PATH="${PREFIX}$(basename "$FILE_PATH")"
fi

if [[ -z "$REL_PATH" ]]; then
  exit 0
fi

# Refuse any path carrying a control character. The case that matters in the
# wild is the macOS Finder custom-icon file — the literal name `Icon` followed
# by a carriage return — which Finder writes into every directory it renders an
# icon for, and which a folder-level cloud-sync agent then spreads tree-wide.
#
# Two reasons this has to be a hook-level guard rather than a .gitignore entry:
#
#   1. gitignore does not apply to files git already tracks. Once one of these
#      is committed, Finder rewriting it makes it a tracked modification that
#      this hook would autosave forever.
#   2. The staging path below is `git add -- "$REL_PATH"`, and when the tool
#      call touched a DIRECTORY, REL_PATH is that directory — so a single add
#      sweeps in every control-char file beneath it regardless of the file the
#      tool actually wrote.
#
# These names also break HQ cloud sync outright: an S3 key cannot contain a
# control character, so each one is a permanent per-file upload failure. Never
# stage them; a shell glob cannot express the name, so match the bytes.
if [[ "$REL_PATH" == *$'\r'* || "$REL_PATH" == *$'\n'* || "$REL_PATH" =~ [[:cntrl:]] ]]; then
  exit 0
fi

case "$REL_PATH" in
  .git/*|repos/*|node_modules/*|.next/*|.vercel/*|*.tmp|*.log)
    exit 0
    ;;
  workspace/worktrees/*|.claude/worktrees/*)
    # Live project worktrees are their own linked git repos with a moving HEAD.
    # Never sweep one into the HQ root as an embedded gitlink — that leaves the
    # tree permanently dirty and blocks /handoff + session archiving.
    # (feedback_2ada615f)
    exit 0
    ;;
  companies/*/knowledge|companies/*/knowledge/*)
    # Company knowledge is a real canonical directory and may contain an
    # embedded repo. Let that repo's discipline decide when to commit.
    exit 0
    ;;
esac

LOG_DIR="$HQ_ROOT/workspace/logs"
LOG_FILE="$LOG_DIR/hq-autocommit.log"
LOG_MAX_BYTES="${HQ_AUTOCOMMIT_LOG_MAX_BYTES:-1048576}"
WARN_DIR="$HQ_ROOT/workspace/.autocommit-warnings"
LOCK_DIR="${TMPDIR:-/tmp}/hq-autocommit.lock"
STALE_LOCK_MINUTES="${HQ_AUTOCOMMIT_STALE_LOCK_MINUTES:-5}"

SESSION_KEY="$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null || true)"
[[ -z "$SESSION_KEY" ]] && SESSION_KEY="pid-${PPID:-$$}"
SESSION_KEY="$(printf '%s' "$SESSION_KEY" | tr -c 'A-Za-z0-9._-' '_')"

log_line() {
  mkdir -p "$LOG_DIR" 2>/dev/null || return 0
  local size
  size="$(wc -c <"$LOG_FILE" 2>/dev/null || echo 0)"
  size="${size//[^0-9]/}"
  if [[ -n "$size" && "$size" -gt "$LOG_MAX_BYTES" ]]; then
    mv -f "$LOG_FILE" "$LOG_FILE.1" 2>/dev/null || true
  fi
  printf '%s\n' "$1" >>"$LOG_FILE" 2>/dev/null || true
}

# One warning per session per distinct cause. A wedged repo fails on every
# single edit; repeating the same line hundreds of times would train the user
# to ignore it, which is the failure mode this hook is meant to end.
warn_once() {
  local key="$1" msg="$2" cache
  if mkdir -p "$WARN_DIR" 2>/dev/null; then
    cache="$WARN_DIR/$SESSION_KEY.keys"
    if grep -Fqx "$key" "$cache" 2>/dev/null; then
      return 0
    fi
    printf '%s\n' "$key" >>"$cache" 2>/dev/null || true
  fi
  printf '%s\n' "$msg"
  printf '%s\n' "$msg" >&2
}

report_failure() {
  local stage="$1" rc="$2" output="$3"
  log_line "[$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo unknown)] FAIL stage=${stage} exit=${rc} path=${REL_PATH} session=${SESSION_KEY}"
  if [[ -n "$output" ]]; then
    log_line "$(printf '%s' "$output" | sed 's/^/    git: /')"
  fi
  warn_once "autocommit|${stage}|${rc}" \
    "WARNING: HQ autosave failed — git ${stage} exited ${rc} for '${REL_PATH}'. Local HQ edits are NOT being committed until this is resolved. Details: workspace/logs/hq-autocommit.log"
  if [[ "${HQ_AUTOCOMMIT_STRICT:-0}" == "1" ]]; then
    exit 1
  fi
  exit 0
}

is_stale_path() {
  [[ -n "$(find "$1" -maxdepth 0 -mmin "+${STALE_LOCK_MINUTES}" 2>/dev/null)" ]]
}

# Return 0 when a process definitely holds the lock, or when this machine has
# no trustworthy ownership probe. Unknown must fail closed: deleting a live
# Git index lock can corrupt an in-flight write.
lock_has_holder() {
  local lock_path="$1" probe="${HQ_AUTOCOMMIT_LOCK_PROBE:-}"
  if [[ -n "$probe" ]]; then
    "$probe" "$lock_path" >/dev/null 2>&1
    return $?
  fi
  if command -v lsof >/dev/null 2>&1; then
    lsof "$lock_path" >/dev/null 2>&1
    return $?
  fi
  if command -v fuser >/dev/null 2>&1; then
    fuser "$lock_path" >/dev/null 2>&1
    return $?
  fi
  return 0
}

process_birth_token() {
  local pid="$1"
  LC_ALL=C ps -p "$pid" -o lstart= 2>/dev/null | tr -d '[:space:]'
}

recover_stale_index_lock() {
  local index_lock
  index_lock="$(git -C "$HQ_ROOT" rev-parse --git-path index.lock 2>/dev/null || true)"
  [[ -n "$index_lock" ]] || return 0
  [[ "$index_lock" == /* ]] || index_lock="$HQ_ROOT/$index_lock"
  [[ -f "$index_lock" ]] || return 0
  is_stale_path "$index_lock" || return 0
  lock_has_holder "$index_lock" && return 0

  # Exact-file removal only, after age + live-holder checks. index.lock is a
  # transaction sentinel, not repository data; an unowned stale copy can only
  # block future Git writes.
  if rm -f -- "$index_lock" 2>/dev/null; then
    log_line "[$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo unknown)] RECOVER stage=index-lock path=${REL_PATH} session=${SESSION_KEY}"
  fi
}

STATUS_OUT="$(git -C "$HQ_ROOT" status --porcelain -- "$REL_PATH" 2>&1)"
STATUS_RC=$?
if [[ $STATUS_RC -ne 0 ]]; then
  report_failure "status" "$STATUS_RC" "$STATUS_OUT"
fi
if [[ -z "$STATUS_OUT" ]]; then
  exit 0
fi

PRESTAGED="$(git -C "$HQ_ROOT" diff --cached --name-only 2>&1)"
PRESTAGED_RC=$?
if [[ $PRESTAGED_RC -ne 0 ]]; then
  report_failure "diff-cached" "$PRESTAGED_RC" "$PRESTAGED"
fi
if [[ -n "$PRESTAGED" ]]; then
  # Someone else is mid-commit with a staged index. Not our index to touch.
  exit 0
fi

LOCK_ACQUIRED=0
if mkdir "$LOCK_DIR" 2>/dev/null; then
  LOCK_ACQUIRED=1
else
  # Contention with a concurrent autosave is normal and silent. A lock that
  # outlives the staleness window is an orphan from a killed run. New locks
  # carry their owner pid; old ownerless locks are safe to recover after age.
  OWNER_PID="$(sed -n 's/^pid=//p' "$LOCK_DIR/owner" 2>/dev/null | head -1)"
  OWNER_BIRTH="$(sed -n 's/^birth=//p' "$LOCK_DIR/owner" 2>/dev/null | head -1)"
  OWNER_LIVE=0
  if [[ "$OWNER_PID" =~ ^[0-9]+$ ]] && kill -0 "$OWNER_PID" 2>/dev/null; then
    CURRENT_BIRTH="$(process_birth_token "$OWNER_PID")"
    # Owner files from older HQ releases have no birth token. Fail closed for
    # those live PIDs, while new locks distinguish the original process from a
    # later process that reused the same numeric PID.
    if [[ -z "$OWNER_BIRTH" || -z "$CURRENT_BIRTH" || "$OWNER_BIRTH" == "$CURRENT_BIRTH" ]]; then
      OWNER_LIVE=1
    fi
  fi
  if is_stale_path "$LOCK_DIR" && [[ "$OWNER_LIVE" -eq 0 ]]; then
    rm -f -- "$LOCK_DIR/owner" 2>/dev/null || true
    if rmdir "$LOCK_DIR" 2>/dev/null && mkdir "$LOCK_DIR" 2>/dev/null; then
      LOCK_ACQUIRED=1
      log_line "[$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo unknown)] RECOVER stage=lock path=${REL_PATH} session=${SESSION_KEY}"
    fi
  fi
fi
if [[ "$LOCK_ACQUIRED" -ne 1 ]]; then
  exit 0
fi
SELF_BIRTH="$(process_birth_token "$$")"
printf 'pid=%s\nbirth=%s\n' "$$" "$SELF_BIRTH" >"$LOCK_DIR/owner" 2>/dev/null || true
trap 'rm -f -- "$LOCK_DIR/owner" 2>/dev/null || true; rmdir "$LOCK_DIR" 2>/dev/null || true' EXIT

recover_stale_index_lock

ADD_OUT="$(git -C "$HQ_ROOT" add -- "$REL_PATH" 2>&1)"
ADD_RC=$?
if [[ $ADD_RC -ne 0 ]]; then
  report_failure "add" "$ADD_RC" "$ADD_OUT"
fi

# Unstage any control-character path the add pulled in. The guard above rejects
# a control-char REL_PATH, but when REL_PATH is a DIRECTORY the add sweeps in
# everything beneath it — which is how a macOS `Icon\r` file becomes tracked in
# the first place, after which Finder rewriting it makes it a tracked
# modification autosaved forever. NUL-delimited because these names contain the
# very bytes that would otherwise split the list.
STAGED_CONTROL_CHAR=0
while IFS= read -r -d '' staged_path; do
  [[ -n "$staged_path" ]] || continue
  if [[ "$staged_path" =~ [[:cntrl:]] ]]; then
    git -C "$HQ_ROOT" reset -q -- "$staged_path" 2>/dev/null || true
    STAGED_CONTROL_CHAR=$((STAGED_CONTROL_CHAR+1))
  fi
done < <(git -C "$HQ_ROOT" diff --cached --name-only -z 2>/dev/null)
if [[ $STAGED_CONTROL_CHAR -gt 0 ]]; then
  log_line "[$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo unknown)] SKIP stage=control-char count=${STAGED_CONTROL_CHAR} path=${REL_PATH} session=${SESSION_KEY}"
fi

# Refuse to autosave an embedded git repo (gitlink, mode 160000). A directory
# add that reaches a nested worktree/repo would otherwise stage it into the HQ
# root, leaving the tree permanently dirty and blocking /handoff + archiving.
# Unstage and bail rather than commit a moving gitlink. (feedback_2ada615f)
if git -C "$HQ_ROOT" ls-files --stage -- "$REL_PATH" 2>/dev/null \
     | awk '$1 == "160000" { hit = 1 } END { exit hit ? 0 : 1 }'; then
  git -C "$HQ_ROOT" reset -q -- "$REL_PATH" 2>/dev/null || true
  exit 0
fi

git -C "$HQ_ROOT" diff --cached --quiet -- "$REL_PATH" 2>/dev/null
DIFF_RC=$?
case "$DIFF_RC" in
  0) exit 0 ;;                                    # staged, but identical to HEAD
  1) ;;                                           # real staged change — commit it
  *) report_failure "diff-staged" "$DIFF_RC" "" ;;
esac

msg_path="$REL_PATH"
if [[ ${#msg_path} -gt 72 ]]; then
  msg_path="${msg_path:0:69}..."
fi

COMMIT_OUT="$(git -C "$HQ_ROOT" commit --no-verify -m "autosave(hq): ${msg_path}" 2>&1)"
COMMIT_RC=$?
if [[ $COMMIT_RC -ne 0 ]]; then
  report_failure "commit" "$COMMIT_RC" "$COMMIT_OUT"
fi

exit 0
