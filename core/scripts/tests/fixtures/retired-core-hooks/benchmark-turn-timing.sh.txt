#!/usr/bin/env bash
# Isolate recorder cost from unrelated dispatcher work and scheduling noise.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/workspace"
. "$ROOT/.claude/hooks/turn-timing.sh"
REPO_ROOT="$TMP"
TURN_TIMING_SESSION=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
MASTER_INVOCATION_ID=benchmark
EVENT=Stop
TURN_TIMING_STARTED=100
master_now_ms() { MASTER_NOW_MS=110; }
TIMEFORMAT='%R'
printf 'seconds for 10000 child-record callbacks (divide by 10 for ms/call): '
time {
  for ((i=0; i<10000; i++)); do
    TURN_TIMING_BUFFER=""; TURN_TIMING_ROWS=0
    turn_timing_row child hook.sh 100 10
  done
}
printf 'seconds for 100 locked event flushes, excluding clock/hash (multiply by 10 for ms/flush): '
time {
  for ((i=0; i<100; i++)); do
    TURN_TIMING_FINISHED=0; TURN_TIMING_BUFFER=""; TURN_TIMING_ROWS=0
    turn_timing_finish
  done
}
