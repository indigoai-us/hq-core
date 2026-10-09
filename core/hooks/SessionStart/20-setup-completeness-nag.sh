#!/usr/bin/env bash
# SessionStart reminder for installs whose durable /setup artifacts are missing.
# Exit code: always 0. This hook is advisory and deliberately fail-open.

set -uo pipefail

{
  [ "${HQ_NO_SETUP_NAG:-}" = "1" ] && exit 0
  [ "${CI+x}" = "x" ] && exit 0
  command -v jq >/dev/null 2>&1 || exit 0

  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || exit 0
  REPO_ROOT="${CLAUDE_PROJECT_DIR:-$(cd "$SCRIPT_DIR/../../.." 2>/dev/null && pwd)}"
  [ -f "$REPO_ROOT/core/core.yaml" ] || exit 0

  STATUS_SCRIPT="$REPO_ROOT/core/scripts/setup-status.sh"
  [ -x "$STATUS_SCRIPT" ] || exit 0
  INTERVAL_HOURS="${HQ_SETUP_NAG_INTERVAL_HOURS:-24}"
  case "$INTERVAL_HOURS" in
    ''|*[!0-9]*) INTERVAL_HOURS=24 ;;
    *) INTERVAL_HOURS=$((10#$INTERVAL_HOURS)) ;;
  esac
  INTERVAL_SECONDS=$((INTERVAL_HOURS * 3600))

  STATE_HOME="${XDG_STATE_HOME:-${HOME:-/tmp}/.local/state}"
  STATE_DIR="${HQ_SETUP_NAG_STATE_DIR:-$STATE_HOME/hq}"
  STATE_KEY="$(printf '%s\n' "$REPO_ROOT" | cksum 2>/dev/null)"
  STATE_KEY="${STATE_KEY%% *}"
  [ -n "$STATE_KEY" ] || exit 0
  STATE_FILE="$STATE_DIR/setup-completeness-nag.$STATE_KEY.last"
  LOCK_DIR="$STATE_DIR/setup-completeness-nag.$STATE_KEY.lock"
  NOW="$(date +%s 2>/dev/null || true)"
  [ -n "$NOW" ] || exit 0

  mkdir -p "$STATE_DIR" 2>/dev/null || exit 0
  LAST_NAG="$(cat "$STATE_FILE" 2>/dev/null || true)"
  if [[ "$LAST_NAG" =~ ^[0-9]+$ ]]; then
    AGE=$((NOW - LAST_NAG))
    if [ "$AGE" -ge 0 ] && [ "$AGE" -lt "$INTERVAL_SECONDS" ]; then exit 0; fi
  fi

  # A hook normally holds this empty directory for milliseconds. Recover one
  # older than five minutes so an interrupted process cannot disable reminders.
  if [ -d "$LOCK_DIR" ]; then
    LOCK_MTIME="$(date -r "$LOCK_DIR" +%s 2>/dev/null || true)"
    if [[ "$LOCK_MTIME" =~ ^[0-9]+$ ]]; then
      LOCK_AGE=$((NOW - LOCK_MTIME))
      if [ "$LOCK_AGE" -ge 300 ]; then
        rmdir "$LOCK_DIR" 2>/dev/null || true
      fi
    fi
  fi
  mkdir "$LOCK_DIR" 2>/dev/null || exit 0
  # A sibling SessionStart may have completed its check while this process was
  # waiting for the lock. Re-read the stamp before doing the expensive scan.
  LAST_NAG="$(cat "$STATE_FILE" 2>/dev/null || true)"
  if [[ "$LAST_NAG" =~ ^[0-9]+$ ]]; then
    AGE=$((NOW - LAST_NAG))
    if [ "$AGE" -ge 0 ] && [ "$AGE" -lt "$INTERVAL_SECONDS" ]; then
      rmdir "$LOCK_DIR" 2>/dev/null || true
      exit 0
    fi
  fi

  STATUS_RC=0
  STATUS_JSON="$($STATUS_SCRIPT --root "$REPO_ROOT" --json 2>/dev/null)" || STATUS_RC=$?
  # Gate every completed status invocation, including an unavailable result,
  # so a broken setup probe cannot run on every SessionStart.
  printf '%s\n' "$NOW" > "$STATE_FILE" 2>/dev/null || true
  [ "$STATUS_RC" -eq 2 ] && { rmdir "$LOCK_DIR" 2>/dev/null || true; exit 0; }
  if printf '%s' "$STATUS_JSON" | jq -e '.complete == true' >/dev/null 2>&1; then
    rmdir "$LOCK_DIR" 2>/dev/null || true
    exit 0
  fi

  MISSING="$(printf '%s' "$STATUS_JSON" | jq -r '[.missingRequired[] | gsub("-"; " ")] | join(", ")' 2>/dev/null || true)"
  [ -n "$MISSING" ] || { rmdir "$LOCK_DIR" 2>/dev/null || true; exit 0; }

  CONTEXT="HQ setup is unfinished: missing ${MISSING}. Run /setup to finish it. Silence this reminder with HQ_NO_SETUP_NAG=1."
  jq -nc --arg context "$CONTEXT" \
    '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:$context}}' || {
      rmdir "$LOCK_DIR" 2>/dev/null || true
      exit 0
    }

  rmdir "$LOCK_DIR" 2>/dev/null || true
} 2>/dev/null || true

exit 0
