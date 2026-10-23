#!/usr/bin/env bash
# Pins the super-conductor loop-arming contract: the watch loop (a persistent
# hq monitor heartbeat at the resolved present interval, with ScheduleWakeup
# only as a fallback) is armed right after the link opens, before adoption and
# comms work; the owner is told the loop is running, at what cadence, and on
# which channels; the conductor never substitutes its own interval; every
# wakeup confirms and re-arms the heartbeat before asking decisions; and
# wakeups that arrive while an owner picker is open are handled after it.
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
need 'hq monitor start --persistent' 'Step 2b arms a persistent hq monitor heartbeat'
need 'super-conductor-heartbeat\.sh' 'heartbeat runs the shared heartbeat script'
need '--target "session:claude:\$CLAUDE_CODE_SESSION_ID"' 'heartbeat targets this session explicitly (desktop cannot auto-detect)'
need '--interval auto' 'heartbeat follows the work-day schedule by default'
need '--interval <resolved\s*$' 'a per-run override still passes seconds'
need '--message-watch' 'heartbeat starts the message wake'
need 'Only if `hq monitor start` fails' 'ScheduleWakeup is a fallback, not the primary loop'
need 'delaySeconds: <resolved present>' 'fallback wakeup uses the resolved present interval'
need 'Watching <channels> every <N>' 'owner is told the loop, cadence, and channels'
need 'Never pick a different cadence' 'conductor may not substitute its own interval'
need 'confirm the heartbeat is running with `hq monitor list --json`' 'each wakeup checks the heartbeat'
need 're-arm it before asking any owner decision' 'each wakeup re-arms before asking decisions'
need 'Never run two heartbeats' 'one heartbeat per link'
need 'This session never waits on the owner: it opens no' 'the conductor never holds its turn on a picker'
need 'Every `Agent` call is `run_in_background: true`' 'no foreground agents in a conductor wakeup'
need 'loop: armed' 'status reports loop state'
need 'hq monitor stop <heartbeat\.monitor_id' 'off stops the heartbeat'

# Step 2b must appear before Step 3 in the file.
a=$(grep -n '^## Step 2b: Arm the watch loop now' "$SC" | head -1 | cut -d: -f1 || true)
b=$(grep -n '^## Step 3: Adopt every open session' "$SC" | head -1 | cut -d: -f1 || true)
if [[ -z "$a" || -z "$b" || "$a" -ge "$b" ]]; then
  echo "FAIL: Step 2b must come before Step 3 ($SC)" >&2
  fail=1
fi

[[ "$fail" -eq 0 ]] || exit 1
echo "super-conductor loop arm contract: ok"
