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
need "$SC" 'heartbeat runs every `watch_interval\.present` seconds' 'Step 7 reads present setting'
need "$SC" 'every `watch_interval\.away` seconds' 'Step 7 reads away setting'
forbid "$SC" 'every 60 seconds' 'Step 7 still hard-codes 60 seconds'

# Channel selection and interval choice (Step 1b).
need "$SC" '^## Step 1b: Choose channels and cadence' 'Step 1b lets the owner pick channels and cadence'
need "$SC" '`channels <list>`' 'per-run channels argument documented'
need "$SC" 'one Yes/No step at a time' 'channel choices are serialized for the single-choice decision API'
need "$SC" 'HQ DMs, Slack, Email, X' 'all optional channel choices remain available'
need "$SC" '1 minute' 'interval choices include 1 minute'
need "$SC" '5 minutes, 10 minutes' 'interval choices include 5 and 10 minutes'
need "$SC" 'Save as default' 'owner can save the choice as default'
need "$SC" '^channels: ' 'settings block documents channels'
need "$SC" '^- `channels`: `\{selected, source, unavailable\}`' 'save file records channels'
need "$SC" '^- `heartbeat`: `\{monitor_id, interval, channels, started_at\}`' 'save file records the heartbeat'
need "$SC" 'A heartbeat wakeup is a full sweep' 'heartbeat wakeups sweep every selected channel'
for key in hq_dms slack email x; do
  need "$SC" "^\| \`$key\` \|" "channel table lists $key"
done

need "$ON" '--interval <watch_interval\.away>' '/overnight restarts the heartbeat at the away interval'
need "$ON" 'delaySeconds: watch_interval\.away' '/overnight fallback uses the away interval'
forbid "$ON" 'delaySeconds: 900 to 1200' '/overnight still hard-codes 900-1200'

if [[ "$fail" -ne 0 ]]; then
  exit 1
fi
echo "super-conductor watch interval contract: ok"
