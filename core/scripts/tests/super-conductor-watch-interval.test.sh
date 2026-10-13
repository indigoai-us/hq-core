#!/usr/bin/env bash
# Pins the super-conductor watch_interval contract: documented setting,
# defaults, clamp range, per-run override, save-file field, and /overnight
# using the away value instead of a hard-coded cadence.
set -euo pipefail

ROOT="${HQ_TEST_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
SC="$ROOT/.claude/skills/super-conductor/SKILL.md"
ON="$ROOT/.claude/skills/overnight/SKILL.md"
fail=0

need() { # file pattern message
  if ! grep -Eq -- "$2" "$1"; then
    echo "FAIL: $3 ($1)" >&2
    fail=1
  fi
}
forbid() { # file pattern message
  if grep -Eq -- "$2" "$1"; then
    echo "FAIL: $3 ($1)" >&2
    fail=1
  fi
}

need "$SC" '^watch_interval:' 'settings block documents watch_interval'
need "$SC" '^  present: 60 ' 'present default is 60 seconds'
need "$SC" '^  away: 1500 ' 'away default is 1500 seconds'
need "$SC" '30–3600 seconds' 'clamp range 30-3600 documented'
need "$SC" '`interval <seconds>`' 'per-run override argument documented'
need "$SC" 'wins over (the settings file|everything else)' 'per-run override wins'
need "$SC" '^- `watch_interval`: `\{present, away, source\}`' 'save file records watch_interval'
need "$SC" 'ScheduleWakeup` every `watch_interval\.present` seconds' 'Step 7 reads present setting'
need "$SC" 'every `watch_interval\.away` seconds' 'Step 7 reads away setting'
forbid "$SC" 'ScheduleWakeup` every 60 seconds' 'Step 7 still hard-codes 60 seconds'

need "$ON" 'delaySeconds: watch_interval\.away' '/overnight uses the away interval'
forbid "$ON" 'delaySeconds: 900 to 1200' '/overnight still hard-codes 900-1200'

if [[ "$fail" -ne 0 ]]; then
  exit 1
fi
echo "super-conductor watch interval contract: ok"
