#!/usr/bin/env bash
# Pins the super-conductor loop-arming contract: the watch loop (background
# link waiter + ScheduleWakeup at the resolved present interval) is armed right
# after the link opens, before adoption and comms work; the owner is told the
# loop is running and at what cadence; the conductor never substitutes its own
# interval; and every wakeup re-arms both before asking decisions.
set -euo pipefail

ROOT="${HQ_TEST_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
SC="$ROOT/.claude/skills/super-conductor/SKILL.md"
fail=0

need() { # pattern message
  if ! grep -Eq -- "$1" "$SC"; then
    echo "FAIL: $2 ($SC)" >&2
    fail=1
  fi
}

need '^## Step 2b: Arm the watch loop now' 'Step 2b arms the loop right after the link opens'
need 'before Step 3' 'loop is armed before adoption (Step 3)'
need 'delaySeconds: <resolved present>' 'first wakeup uses the resolved present interval'
need 'Watching every <N> seconds' 'owner is told the loop is running and its cadence'
need 'Never pick a different cadence' 'conductor may not substitute its own interval'
need 're-arm both before asking' 'each wakeup re-arms before asking decisions'
need 'loop: armed' 'status reports loop state'

# Step 2b must appear before Step 3 in the file.
a=$(grep -n '^## Step 2b: Arm the watch loop now' "$SC" | head -1 | cut -d: -f1 || true)
b=$(grep -n '^## Step 3: Adopt every open session' "$SC" | head -1 | cut -d: -f1 || true)
if [[ -z "$a" || -z "$b" || "$a" -ge "$b" ]]; then
  echo "FAIL: Step 2b must come before Step 3 ($SC)" >&2
  fail=1
fi

[[ "$fail" -eq 0 ]] || exit 1
echo "super-conductor loop arm contract: ok"
