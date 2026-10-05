#!/usr/bin/env bash
# Run the two independent timeout regressions concurrently and print each
# complete log under its own label so failures remain attributable.
set -uo pipefail

ROOT="$(git rev-parse --show-toplevel)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/hq-shell-smoke-timeout-tests.XXXXXX")"
FIRST_LABEL='Hook timeout Sentry watchdog'
SECOND_LABEL='Hook timeout attribution tags and compact sequence'
FIRST_TEST='core/scripts/tests/hook-timeout-sentry.test.sh'
SECOND_TEST='core/scripts/tests/hook-timeout-watchdog-attribution.test.sh'
FIRST_LOG="$TMP/first.log"
SECOND_LOG="$TMP/second.log"
FIRST_PID=''
SECOND_PID=''

cleanup() {
  [ -z "$FIRST_PID" ] || kill "$FIRST_PID" 2>/dev/null || true
  [ -z "$SECOND_PID" ] || kill "$SECOND_PID" 2>/dev/null || true
  [ -z "$FIRST_PID" ] || wait "$FIRST_PID" 2>/dev/null || true
  [ -z "$SECOND_PID" ] || wait "$SECOND_PID" 2>/dev/null || true
  rm -rf "$TMP"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

bash "$ROOT/$FIRST_TEST" > "$FIRST_LOG" 2>&1 &
FIRST_PID=$!
bash "$ROOT/$SECOND_TEST" > "$SECOND_LOG" 2>&1 &
SECOND_PID=$!

RESULT=0
if wait "$FIRST_PID"; then
  FIRST_STATUS=0
else
  FIRST_STATUS=$?
  RESULT=1
fi
FIRST_PID=''
if wait "$SECOND_PID"; then
  SECOND_STATUS=0
else
  SECOND_STATUS=$?
  RESULT=1
fi
SECOND_PID=''

printf '\n===== %s (exit %s) =====\n' "$FIRST_LABEL" "$FIRST_STATUS"
cat "$FIRST_LOG"
printf '\n===== %s (exit %s) =====\n' "$SECOND_LABEL" "$SECOND_STATUS"
cat "$SECOND_LOG"

exit "$RESULT"
