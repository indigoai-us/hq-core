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
  STATUS_RC=0
  STATUS_JSON="$($STATUS_SCRIPT --root "$REPO_ROOT" --json 2>/dev/null)" || STATUS_RC=$?
  [ "$STATUS_RC" -eq 2 ] && exit 0
  printf '%s' "$STATUS_JSON" | jq -e '.complete == true' >/dev/null 2>&1 && exit 0

  MISSING="$(printf '%s' "$STATUS_JSON" | jq -r '[.missingRequired[] | gsub("-"; " ")] | join(", ")' 2>/dev/null || true)"
  [ -n "$MISSING" ] || exit 0

  INTERVAL_HOURS="${HQ_SETUP_NAG_INTERVAL_HOURS:-24}"
  case "$INTERVAL_HOURS" in
    ''|*[!0-9]*) INTERVAL_HOURS=24 ;;
    *) INTERVAL_HOURS=$((10#$INTERVAL_HOURS)) ;;
  esac
  INTERVAL_SECONDS=$((INTERVAL_HOURS * 3600))

  STATE_DIR="$REPO_ROOT/.claude/state"
  STATE_FILE="$STATE_DIR/setup-completeness-nag.last"
  LOCK_DIR="$STATE_DIR/setup-completeness-nag.lock"
  NOW="$(date +%s 2>/dev/null || true)"
  [ -n "$NOW" ] || exit 0

  mkdir -p "$STATE_DIR" 2>/dev/null || exit 0
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
  LAST_NAG="$(cat "$STATE_FILE" 2>/dev/null || true)"
  if [[ "$LAST_NAG" =~ ^[0-9]+$ ]]; then
    AGE=$((NOW - LAST_NAG))
    if [ "$AGE" -ge 0 ] && [ "$AGE" -lt "$INTERVAL_SECONDS" ]; then
      rmdir "$LOCK_DIR" 2>/dev/null || true
      exit 0
    fi
  fi

  CONTEXT="HQ setup is unfinished: missing ${MISSING}. Run /setup to finish it. Silence this reminder with HQ_NO_SETUP_NAG=1."
  jq -nc --arg context "$CONTEXT" \
    '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:$context}}' || {
      rmdir "$LOCK_DIR" 2>/dev/null || true
      exit 0
    }

  printf '%s\n' "$NOW" > "$STATE_FILE" 2>/dev/null || true
  rmdir "$LOCK_DIR" 2>/dev/null || true
} 2>/dev/null || true

exit 0
