#!/usr/bin/env bash
set -euo pipefail
ROOT="${HQ_TIMING_TEST_ROOT:-$(cd "$(dirname "$0")/../../.." && pwd)}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/hq/.claude/hooks" "$TMP/hq/core/hooks/UserPromptSubmit" "$TMP/hq/core/scripts/lib" "$TMP/hq/workspace"
for file in master-hook.sh hook-timeout-probe.sh hook-timeout-watchdog.sh hook-gate.sh turn-timing.sh; do
  [ ! -f "$ROOT/.claude/hooks/$file" ] || cp "$ROOT/.claude/hooks/$file" "$TMP/hq/.claude/hooks/$file"
done
for file in resolve-hq-root.sh lib/perl-child-locale.sh lib/advisory-cap.sh; do
  [ ! -f "$ROOT/core/scripts/$file" ] || cp "$ROOT/core/scripts/$file" "$TMP/hq/core/scripts/$file"
done
printf '{"hooks":{}}\n' > "$TMP/hq/.claude/hooks/hook-registry.json"
printf 'hqVersion: "16.0.0"\n' > "$TMP/hq/core/core.yaml"
printf '#!/bin/sh\nsleep 0.02\n' > "$TMP/hq/core/hooks/UserPromptSubmit/10-slow.sh"
chmod +x "$TMP/hq/core/hooks/UserPromptSubmit/10-slow.sh"
payload="$(jq -cn --arg cwd "$TMP/hq" '{session_id:"timing-fixture",cwd:$cwd,prompt:"PRIVATE_PROMPT_SENTINEL",source:"startup"}')"
run_event() {
  (cd "$TMP/hq" && HQ_TURN_TIMING="$1" bash .claude/hooks/master-hook.sh "$2" <<<"$payload" >"$TMP/out" 2>"$TMP/err")
}
run_event 0 UserPromptSubmit
[ ! -e "$TMP/hq/workspace/.turn-timing" ] || { echo 'FAIL: flag-off recorded data'; exit 1; }
run_event 1 UserPromptSubmit
ledger="$TMP/hq/workspace/.turn-timing/events.tsv"
[ -s "$ledger" ] || { cat "$TMP/err"; echo 'FAIL: no timing ledger'; exit 1; }
awk -F '\t' '$4=="UserPromptSubmit" && $5=="child" && $6=="10-slow.sh" && $8>=10 {found=1} END {exit !found}' "$ledger"
awk -F '\t' '$5=="start" {s++} $5=="end" && $8>0 {e++} END {exit !(s==1 && e==1)}' "$ledger"
! grep -q 'PRIVATE_PROMPT_SENTINEL\|timing-fixture' "$ledger"
for event in SessionStart PreToolUse PostToolUse Stop PreCompact PostCompact; do run_event 1 "$event"; done
for event in SessionStart PreToolUse PostToolUse Stop PreCompact PostCompact; do
  awk -F '\t' -v e="$event" '$4==e && $5=="end" {found=1} END {exit !found}' "$ledger"
done
awk -F '\t' 'NF==9 {seen[$2]=1} END {for (s in seen) count++; exit count!=1}' "$ledger"
if [ -n "${HQ_TIMING_SAMPLE_DIR:-}" ]; then
  mkdir -p "$HQ_TIMING_SAMPLE_DIR/workspace/.turn-timing"
  cp "$ledger" "$HQ_TIMING_SAMPLE_DIR/workspace/.turn-timing/events.tsv"
  cp -R "$TMP/hq/.claude" "$TMP/hq/core" "$HQ_TIMING_SAMPLE_DIR/"
fi
# Rotation under the same writer; a dead process cannot leave a held flock.
perl -e 'print "x" x 1048500' > "$ledger"
run_event 1 Stop
[ -f "$ledger.1" ]
[ "$(wc -c < "$ledger")" -le 1048576 ]
[ "$(wc -c < "$ledger.1")" -le 1048576 ]
# Repeated flushes of one invocation are idempotent; injection-like names drop.
ROOT_FIXTURE="$TMP/hq" bash -c '
  . "$1/.claude/hooks/turn-timing.sh"
  REPO_ROOT="$ROOT_FIXTURE"; TURN_TIMING_SESSION=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  MASTER_INVOCATION_ID=test; EVENT=Stop; TURN_TIMING_STARTED=100
  master_now_ms() { MASTER_NOW_MS=110; }
  turn_timing_row child "bad name" 100 1
  [ "$TURN_TIMING_ROWS" = 0 ]
  turn_timing_finish; turn_timing_finish
' _ "$ROOT"
[ "$(grep -c $'\ttest\tStop\tend\t' "$ledger")" -eq 1 ]
ROOT_FIXTURE="$TMP/hq" bash -c '
  . "$1/.claude/hooks/turn-timing.sh"
  REPO_ROOT="$ROOT_FIXTURE"; TURN_TIMING_SESSION=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  MASTER_INVOCATION_ID=missing-perl; EVENT=Stop; TURN_TIMING_STARTED=100
  master_now_ms() { MASTER_NOW_MS=110; }
  perl() { return 127; }
  turn_timing_finish
' _ "$ROOT"
! grep -q missing-perl "$ledger"
for target in lock events.tsv; do
  fifo_root="$TMP/fifo-$target"
  mkdir -p "$fifo_root/workspace/.turn-timing"
  mkfifo "$fifo_root/workspace/.turn-timing/$target"
  ROOT_FIXTURE="$fifo_root" timeout 5 bash -c '
    . "$1/.claude/hooks/turn-timing.sh"
    REPO_ROOT="$ROOT_FIXTURE"; TURN_TIMING_SESSION=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
    MASTER_INVOCATION_ID=fifo; EVENT=Stop; TURN_TIMING_STARTED=100
    master_now_ms() { MASTER_NOW_MS=110; }
    turn_timing_finish
  ' _ "$ROOT"
done
HQ_HOOK_PARALLEL=1 run_event 1 UserPromptSubmit
printf '#!/bin/sh\nexit 2\n' > "$TMP/hq/core/hooks/UserPromptSubmit/10-slow.sh"
for flag in 0 1; do
  rc=0
  run_event "$flag" UserPromptSubmit || rc=$?
  [ "$rc" -eq 2 ] || { echo "FAIL: changed blocking exit ($rc)"; exit 1; }
done
echo 'PASS: flag-off, wrapper timings, all boundaries, privacy, rotation, idempotence'
