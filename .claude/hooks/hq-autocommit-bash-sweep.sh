#!/usr/bin/env bash
# hq-core: public
# Opt-in Stop-time sweep for files written by Bash commands.
# The hard cap bounds the scan and autosave fan-out to 20 changed paths per Stop.
set -uo pipefail

INPUT="$(cat 2>/dev/null || echo '{}')"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
HQ_ROOT="${CLAUDE_PROJECT_DIR:-$(cd "$SCRIPT_DIR/../.." && pwd -P)}"
HQ_ROOT="$(cd "$HQ_ROOT" 2>/dev/null && pwd -P)" || exit 0

if [[ ( ! -d "$HQ_ROOT/.git" && ! -f "$HQ_ROOT/.git" ) || ! -f "$HQ_ROOT/core/core.yaml" ]]; then
  exit 0
fi
HQ_TOP="$(git -C "$HQ_ROOT" rev-parse --show-toplevel 2>/dev/null || true)"
[[ "$HQ_TOP" == "$HQ_ROOT" ]] || exit 0

SESSION_KEY="$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null || true)"
[[ -n "$SESSION_KEY" ]] || SESSION_KEY="pid-${PPID:-$$}"
SESSION_KEY="$(printf '%s' "$SESSION_KEY" | tr -c 'A-Za-z0-9._-' '_')"
LOG_DIR="$HQ_ROOT/workspace/logs"
LOG_FILE="$LOG_DIR/hq-autocommit.log"
log_line() {
  mkdir -p "$LOG_DIR" 2>/dev/null || return 0
  printf '[%s] %s session=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo unknown)" "$1" "$SESSION_KEY" >>"$LOG_FILE" 2>/dev/null || true
}

# Missing flag context, missing rows, false values, and lookup errors all keep
# the Bash sweep off. A canary requires an explicit company-scoped true value.
FLAG_READER="$SCRIPT_DIR/hq-autocommit-bash-flag.cjs"
FLAG_ENABLED=false
if command -v node >/dev/null 2>&1 && [[ -f "$FLAG_READER" ]]; then
  HQ_CLI_BIN="$(command -v hq 2>/dev/null || true)"
  export HQ_CLI_BIN
  FLAG_ENABLED="$(node "$FLAG_READER")" || FLAG_ENABLED=false
fi
[[ "$FLAG_ENABLED" == true ]] || exit 0

MAX_CHANGED_PATHS=20
STATUS_FILE="$(mktemp "${TMPDIR:-/tmp}/hq-autocommit-bash-status.XXXXXX" 2>/dev/null)"
if [[ -z "$STATUS_FILE" ]]; then
  log_line 'FAIL stage=bash-status reason=temp-file-unavailable'
  exit 0
fi
trap 'rm -f -- "$STATUS_FILE"' EXIT
GIT_OPTIONAL_LOCKS=0 git -C "$HQ_ROOT" status --porcelain=v1 -z --untracked-files=all >"$STATUS_FILE" 2>/dev/null
STATUS_RC=$?
if [[ "$STATUS_RC" -ne 0 ]]; then
  log_line "FAIL stage=bash-status exit=$STATUS_RC"
  exit 0
fi

CHANGED_COUNT=0
CANDIDATE_PATHS=()
while IFS= read -r -d '' ENTRY; do
  XY="${ENTRY:0:2}"
  REL_PATH="${ENTRY:3}"
  CHANGED_COUNT=$((CHANGED_COUNT + 1))
  # Rename/copy records include a second NUL-delimited source path.
  if [[ "$XY" == *R* || "$XY" == *C* ]]; then
    IFS= read -r -d '' _RENAME_SOURCE || true
    continue
  fi
  if [[ "$XY" == '??' ]]; then
    CANDIDATE_PATHS+=("$REL_PATH")
  elif [[ "${XY:0:1}" == ' ' && "${XY:1:1}" != ' ' && "${XY:1:1}" != D ]]; then
    CANDIDATE_PATHS+=("$REL_PATH")
  fi
done <"$STATUS_FILE"

if [[ "$CHANGED_COUNT" -gt "$MAX_CHANGED_PATHS" ]]; then
  log_line "SKIP stage=bash-sweep reason=path-cap changed=$CHANGED_COUNT cap=$MAX_CHANGED_PATHS"
  exit 0
fi
[[ "${#CANDIDATE_PATHS[@]}" -gt 0 ]] || exit 0

for REL_PATH in "${CANDIDATE_PATHS[@]}"; do
  case "$REL_PATH" in
    /*|..|../*|*/../*)
      log_line 'SKIP stage=bash-sweep reason=unsafe-path'
      continue
      ;;
  esac
  if git -C "$HQ_ROOT" check-ignore -q --no-index -- "$REL_PATH" 2>/dev/null; then
    log_line 'SKIP stage=bash-sweep reason=ignored-path'
    continue
  else
    IGNORE_RC=$?
    if [[ "$IGNORE_RC" -ne 1 ]]; then
      log_line "SKIP stage=bash-sweep reason=ignore-check-failed exit=$IGNORE_RC"
      continue
    fi
  fi
  [[ -e "$HQ_ROOT/$REL_PATH" || -L "$HQ_ROOT/$REL_PATH" ]] || continue

  # Delegate one explicit path to the established autosave implementation. It
  # owns the .git/repos/worktree/knowledge/control-character exclusions, lock,
  # staged-set isolation, and commit-failure reporting.
  PAYLOAD="$(jq -cn --arg path "$HQ_ROOT/$REL_PATH" --arg session "$SESSION_KEY" \
    '{tool_name:"Write",session_id:$session,tool_input:{file_path:$path}}' 2>/dev/null)"
  if [[ -z "$PAYLOAD" ]]; then
    log_line 'FAIL stage=bash-sweep reason=payload-encode-failed'
    continue
  fi
  printf '%s' "$PAYLOAD" | CLAUDE_PROJECT_DIR="$HQ_ROOT" bash "$SCRIPT_DIR/hq-autocommit.sh"
done
exit 0
