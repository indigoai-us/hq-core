#!/usr/bin/env bash
# hq-core: public
# Regression test for audit-log.sh.
#
# Covers: the `append` subcommand must create workspace/metrics/ on first use.
# On a clean install that directory does not exist yet, so without `mkdir -p`
# the `>> "$AUDIT_LOG"` redirect fails and the metric event is silently lost.
#
# Run the generated forwarder against a throwaway HQ root whose workspace has
# no metrics directory, then assert the command creates the log there.

set -euo pipefail

SRC_ROOT="$(git rev-parse --show-toplevel)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

command -v hq >/dev/null 2>&1 || { echo "FAIL: pinned hq CLI is not on PATH" >&2; exit 1; }
mkdir -p "$TMP/core/scripts/lib"
# When core-native-utilities is off, the pinned CLI runs the bundled shell
# companion, which keeps its source-time dependency on this scaffold library.
cp "$SRC_ROOT/core/scripts/lib/portable.sh" "$TMP/core/scripts/lib/portable.sh"

LOG="$TMP/workspace/metrics/audit-log.jsonl"

if [[ -e "$TMP/workspace/metrics" ]]; then
  echo "FAIL: precondition — workspace/metrics already exists" >&2
  exit 1
fi

if ! HQ_ROOT="$TMP" bash "$SRC_ROOT/core/scripts/audit-log.sh" append \
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
