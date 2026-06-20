#!/usr/bin/env bash
# hq-core: public
# Regression test for audit-log.sh.
#
# Covers: the `append` subcommand must create workspace/metrics/ on first use.
# On a clean install that directory does not exist yet, so without `mkdir -p`
# the `>> "$AUDIT_LOG"` redirect fails and the metric event is silently lost.
#
# Strategy: audit-log.sh derives its HQ_ROOT from BASH_SOURCE, so we copy it
# into a throwaway core/scripts/ tree whose root has NO workspace/metrics dir,
# then assert the first append succeeds and creates the log.

set -euo pipefail

command -v jq >/dev/null 2>&1 || { echo "audit-log-mkdir: skipped (jq missing)"; exit 0; }

SRC_ROOT="$(git rev-parse --show-toplevel)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/core/scripts"
cp "$SRC_ROOT/core/scripts/audit-log.sh" "$TMP/core/scripts/audit-log.sh"

LOG="$TMP/workspace/metrics/audit-log.jsonl"

if [[ -e "$TMP/workspace/metrics" ]]; then
  echo "FAIL: precondition — workspace/metrics already exists" >&2
  exit 1
fi

if ! bash "$TMP/core/scripts/audit-log.sh" append \
      --event task_started --project audit-log-mkdir-test >/dev/null 2>&1; then
  echo "FAIL: append exited non-zero on a clean tree (missing mkdir -p?)" >&2
  exit 1
fi

if [[ ! -f "$LOG" ]]; then
  echo "FAIL: append did not create $LOG" >&2
  exit 1
fi

if ! grep -q 'task_started' "$LOG"; then
  echo "FAIL: appended event not present in $LOG" >&2
  exit 1
fi

echo "audit-log-mkdir: 1 passed, 0 failed"
