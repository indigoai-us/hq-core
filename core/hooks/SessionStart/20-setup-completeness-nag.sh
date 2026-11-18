#!/usr/bin/env bash
# SessionStart reminder for installs whose durable /setup artifacts are missing.
# Exit code: always 0. This hook is advisory and deliberately fail-open.
#
# The .last stamp does two jobs. After a probe that finds nothing to say
# (setup complete, or the status script unavailable) it throttles the probe to
# once per interval. After a reminder it is the delivery cooldown, and it is
# written only once the reminder has been printed.
#
# Machine-check collect-only (HQ_MACHINE_CHECK=1 and
# HQ_MACHINE_CHECK_COLLECT_ONLY=1, set by the hq-cli daemon batch when
# core/core.yaml advertises machineCheckCollectOnly): the reminder is printed
# for the batch to collect, but no delivery stamp is written, because nobody
# has seen it yet. The session that shows it writes the stamp. So the status
# probe still runs once per interval while a reminder is due, a collect-only
# run keeps the reminder in setup-completeness-nag.<key>.collected (a cache:
# the probe time, then the reminder) and reprints it from there until the
# interval passes. Delivery removes the cache.

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

  COLLECT_FILE="$STATE_DIR/setup-completeness-nag.$STATE_KEY.collected"
  COLLECT_ONLY=0
  if [ "${HQ_MACHINE_CHECK:-}" = "1" ] && [ "${HQ_MACHINE_CHECK_COLLECT_ONLY:-}" = "1" ]; then
    COLLECT_ONLY=1
  fi

  mkdir -p "$STATE_DIR" 2>/dev/null || exit 0
  LAST_NAG="$(cat "$STATE_FILE" 2>/dev/null || true)"
  if [[ "$LAST_NAG" =~ ^[0-9]+$ ]]; then
    AGE=$((NOW - LAST_NAG))
    if [ "$AGE" -ge 0 ] && [ "$AGE" -lt "$INTERVAL_SECONDS" ]; then exit 0; fi
  fi

  # Collect-only: a reminder collected inside the interval is reprinted
  # without probing again.
  if [ "$COLLECT_ONLY" -eq 1 ] && [ -f "$COLLECT_FILE" ]; then
    COLLECTED_AT=""
    COLLECTED=""
    { IFS= read -r COLLECTED_AT && IFS= read -r COLLECTED; } < "$COLLECT_FILE" 2>/dev/null || true
    if [[ "$COLLECTED_AT" =~ ^[0-9]+$ ]] && [ -n "$COLLECTED" ]; then
      AGE=$((NOW - COLLECTED_AT))
      if [ "$AGE" -ge 0 ] && [ "$AGE" -lt "$INTERVAL_SECONDS" ]; then
        printf '%s\n' "$COLLECTED"
        exit 0
      fi
    fi
  fi

  # A hook normally holds this empty directory for milliseconds. Recover one
  # older than five minutes so an interrupted process cannot disable reminders.
  if [ -d "$LOCK_DIR" ]; then
    if [[ "$OSTYPE" == darwin* ]]; then
      LOCK_MTIME="$(stat -f %m "$LOCK_DIR" 2>/dev/null || true)"
    else
      LOCK_MTIME="$(stat -c %Y "$LOCK_DIR" 2>/dev/null || true)"
    fi
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
  # Gate every completed status invocation that has nothing to show, including
  # an unavailable result, so a broken setup probe cannot run on every
  # SessionStart.
  throttle_and_exit() {
    printf '%s\n' "$NOW" > "$STATE_FILE" 2>/dev/null || true
    rm -f "$COLLECT_FILE" 2>/dev/null || true
    rmdir "$LOCK_DIR" 2>/dev/null || true
    exit 0
  }
  [ "$STATUS_RC" -eq 2 ] && throttle_and_exit
  if printf '%s' "$STATUS_JSON" | jq -e '.complete == true' >/dev/null 2>&1; then
    throttle_and_exit
  fi

  MISSING="$(printf '%s' "$STATUS_JSON" | jq -r '[.missingRequired[] | gsub("-"; " ")] | join(", ")' 2>/dev/null || true)"
  [ -n "$MISSING" ] || throttle_and_exit

  CONTEXT="HQ setup is unfinished: missing ${MISSING}. Run /setup to finish it. Silence this reminder with HQ_NO_SETUP_NAG=1."
  REMINDER="$(jq -nc --arg context "$CONTEXT" \
    '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:$context}}')" || REMINDER=""
  [ -n "$REMINDER" ] || throttle_and_exit

  # The delivery cooldown starts only once the reminder is out. A collect-only
  # batch run shows nobody anything, so it leaves the stamp alone.
  if printf '%s\n' "$REMINDER"; then
    if [ "$COLLECT_ONLY" -eq 1 ]; then
      COLLECT_TMP="$COLLECT_FILE.tmp.$$"
      if printf '%s\n%s\n' "$NOW" "$REMINDER" > "$COLLECT_TMP" 2>/dev/null; then
        mv -f "$COLLECT_TMP" "$COLLECT_FILE" 2>/dev/null || rm -f "$COLLECT_TMP" 2>/dev/null
      else
        rm -f "$COLLECT_TMP" 2>/dev/null
      fi
    else
      printf '%s\n' "$NOW" > "$STATE_FILE" 2>/dev/null || true
      rm -f "$COLLECT_FILE" 2>/dev/null || true
    fi
  fi

  rmdir "$LOCK_DIR" 2>/dev/null || true
} 2>/dev/null || true

exit 0
