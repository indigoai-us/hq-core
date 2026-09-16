#!/usr/bin/env bash
# Regression: a hook that exits before it reads its payload must still drain
# stdin, so the process WRITING that payload is never killed by SIGPIPE.
#
# core/scripts/hook-lib.sh now records PIPESTATUS[1], so a current HQ install
# reports the hook's own status either way. This test defends the other half of
# the contract: an OLD dispatcher (a fleet box still on hq-core 15.0.139, or any
# third-party runner that writes the payload with a bare `printf | hook` under
# `set -o pipefail`) must not be able to see 141 from these hooks. That is the
# shape that failed 2 of 3 v1->v2 fleet-migration probes:
#
#   PROBE_FAIL - pre-bind: first company read on a fresh session was refused
#   (rc=141): Hook 'conduct-lane-inbox' exited 141.
#
# Each case pipes 1 MiB (over every platform pipe buffer) into the hook with the
# guard condition that makes it exit early, and asserts the PIPELINE status —
# under pipefail, that is 141 if the writer was killed.
set -euo pipefail
ROOT="$(git rev-parse --show-toplevel)"
fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "  ok: $*"; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
head -c 1048576 /dev/zero | tr '\0' 'x' > "$TMP/filler"
# Valid JSON payload over 1 MiB: hooks that do read stdin must still parse it.
jq -n --rawfile p "$TMP/filler" \
  '{hook_event_name:"PreToolUse", tool_name:"Bash", tool_input:{command:$p}}' > "$TMP/payload.json"
[ "$(wc -c < "$TMP/payload.json")" -gt 1048576 ] || fail "payload fixture is under 1 MiB"

# A PATH with the coreutils this test needs but (normally) no hq, so the
# "hq is absent" guards are the ones under test. Skip rather than lie if the
# host installs hq into a system bin dir.
BARE_PATH="/usr/bin:/bin"
hq_absent_from_bare_path=1
PATH="$BARE_PATH" command -v hq >/dev/null 2>&1 && hq_absent_from_bare_path=0

echo "[1] conduct-lane-inbox: no HQ_CONDUCT_RUN_DIR, 1 MiB stdin, exits 0 without SIGPIPE"
st="$(env -u HQ_CONDUCT_RUN_DIR bash -c '
  set -o pipefail
  cat "$1" | bash "$2" PreToolUse >/dev/null 2>&1
' _ "$TMP/payload.json" "$ROOT/.claude/hooks/conduct-lane-inbox.sh" && echo 0 || echo $?)"
[ "$st" = "0" ] \
  || fail "conduct-lane-inbox.sh made its writer die (pipeline status $st); the HQ_CONDUCT_RUN_DIR guard exits before draining stdin"
pass "conduct-lane-inbox drains stdin on the unset-run-dir guard"

echo "[2] conduct-lane-inbox: run dir set but no pending inbox still drains"
mkdir -p "$TMP/run"
st="$(HQ_CONDUCT_RUN_DIR="$TMP/run" bash -c '
  set -o pipefail
  cat "$1" | bash "$2" PreToolUse >/dev/null 2>&1
' _ "$TMP/payload.json" "$ROOT/.claude/hooks/conduct-lane-inbox.sh" && echo 0 || echo $?)"
[ "$st" = "0" ] \
  || fail "conduct-lane-inbox.sh made its writer die on the missing-inbox guard (pipeline status $st)"
pass "conduct-lane-inbox drains stdin on the missing-inbox guard"

echo "[3] block-foreground-timeout-over-harness-ceiling: no hq on PATH, still drains"
if [ "$hq_absent_from_bare_path" -eq 0 ]; then
  echo "  skip: hq resolves from $BARE_PATH on this host, so the absent-hq guard cannot be exercised"
else
st="$(PATH="$BARE_PATH" bash -c '
  set -o pipefail
  cat "$1" | bash "$2" >/dev/null 2>&1
' _ "$TMP/payload.json" "$ROOT/.claude/hooks/block-foreground-timeout-over-harness-ceiling.sh" && echo 0 || echo $?)"
[ "$st" = "0" ] \
  || fail "block-foreground-timeout-over-harness-ceiling.sh made its writer die when hq was absent (pipeline status $st)"
pass "timeout-ceiling hook drains stdin when hq is missing"
fi

echo "[4] checkpoint-stop-gate: kill switch set, still drains"
st="$(HQ_CHECKPOINT_GATE_NO_CLI=1 bash -c '
  set -o pipefail
  cat "$1" | bash "$2" >/dev/null 2>&1
' _ "$TMP/payload.json" "$ROOT/.claude/hooks/checkpoint-stop-gate.sh" && echo 0 || echo $?)"
[ "$st" = "0" ] \
  || fail "checkpoint-stop-gate.sh made its writer die under its kill switch (pipeline status $st)"
pass "checkpoint-stop-gate drains stdin under its kill switch"

echo "[5] checkpoint-stop-gate: no hq on PATH, still drains"
if [ "$hq_absent_from_bare_path" -eq 0 ]; then
  echo "  skip: hq resolves from $BARE_PATH on this host"
else
st="$(PATH="$BARE_PATH" bash -c '
  set -o pipefail
  cat "$1" | bash "$2" >/dev/null 2>&1
' _ "$TMP/payload.json" "$ROOT/.claude/hooks/checkpoint-stop-gate.sh" && echo 0 || echo $?)"
[ "$st" = "0" ] \
  || fail "checkpoint-stop-gate.sh made its writer die when hq was absent (pipeline status $st)"
pass "checkpoint-stop-gate drains stdin when hq is missing"
fi

echo "ALL PASS: hooks-drain-stdin-before-early-exit"
