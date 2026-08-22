#!/usr/bin/env bash
# Hook timeout floor.
#
# Every hook budget in .claude/settings.json was written when hooks were pure
# bash. Several are now Node processes (the checkpoint Stop gate delegates to
# `hq core checkpoint-stop-gate`), and Node startup alone can exceed a 5s
# budget on a loaded box. A hook killed at its timeout emits nothing, and no
# output means ALLOW — so an expired budget silently disables the hook rather
# than failing loudly. Measured on a live session 2026-08-20: 217 kills of
# block-core-writes-bash (worst 15.2s), 74 of protect-core (14.9s), 25 of
# mandatory-scope-authorizer (10.8s), 12 of detect-secrets (10.0s), and 4 of
# checkpoint-stop-gate (7.4s) — every one of them a guard that failed open.
#
# This pins the floor so the next hook added cannot reintroduce a budget that
# a Node-backed hook cannot meet under load.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SETTINGS="$ROOT/.claude/settings.json"
FLOOR=30

fail() { echo "FAIL: $*" >&2; exit 1; }

[ -r "$SETTINGS" ] || fail "settings.json is not readable: $SETTINGS"
command -v jq >/dev/null 2>&1 || { echo "hook timeout floor: skipped (no jq)"; exit 0; }

# Collect every hook timeout below the floor, naming the command so a failure
# points straight at the offending registration.
violations="$(jq -r --argjson floor "$FLOOR" '
  .hooks // {}
  | to_entries[]
  | .key as $event
  | .value[]?
  | .hooks[]?
  | select((.timeout // 0) > 0 and (.timeout < $floor))
  | "\($event)\t\(.timeout)\t\(.command | tostring)"
' "$SETTINGS" 2>/dev/null || true)"

if [ -n "$violations" ]; then
  echo "Hooks below the ${FLOOR}s timeout floor:" >&2
  printf '%s\n' "$violations" >&2
  fail "a hook budget under ${FLOOR}s will be killed under load and fail open"
fi

echo "hook timeout floor: ok (no hook budget under ${FLOOR}s)"
