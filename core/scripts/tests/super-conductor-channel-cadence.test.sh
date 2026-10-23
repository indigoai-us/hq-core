#!/usr/bin/env bash
# Pins per-channel sweep cadence for /super-conductor:
#   - `super-conductor-prefs.mjs cadence` defaults to constant sessions, hq_dms,
#     slack and hourly email, hq_channels, github, x, teammates; a map in
#     channel_cadence overrides it and a free-text value keeps the defaults;
#   - `super-conductor-sweep-check.mjs due` lists every constant target and
#     only the hourly targets whose last sweep is over an hour old;
#   - `verify` accepts an hourly target swept within the hour even when it was
#     not swept this wakeup, and flags it once the hour has passed;
#   - the status line names hourly targets that are not due yet.
# Owner, 2026-10-19: "only hq dms and slack need constant monitoring"; email
# only every hour.
set -uo pipefail

ROOT="${HQ_TEST_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
PREFS="$ROOT/core/scripts/super-conductor-prefs.mjs"
SWEEP="$ROOT/core/scripts/super-conductor-sweep-check.mjs"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fail=0
check() { # description condition-exit-code
  if [[ "$2" -ne 0 ]]; then echo "FAIL: $1" >&2; fail=1; fi
}
expect() { # description expected actual
  if [[ "$2" != "$3" ]]; then echo "FAIL: $1 (expected '$2', got '$3')" >&2; fail=1; fi
}
export SC_PREFS_FILE="$tmp/p.yaml"

# 1. Defaults, with a free-text owner note in channel_cadence.
cat >"$tmp/p.yaml" <<'EOF'
channels: [hq_dms, hq_channels, slack, email, github, x]
slack_workspaces: [alpha]
email_accounts: [a@example.com]
channel_cadence: "Constant: hq dms and slack. Hourly: email."
EOF
expect "default cadence" \
  '{"constant":["sessions","hq_dms","slack"],"hourly":["email","hq_channels","github","x","teammates"],"hourly_seconds":3600}' \
  "$(node "$PREFS" cadence)"
node "$PREFS" get | grep -q '"_channel_cadence_note": "Constant: hq dms and slack. Hourly: email."'
check "a free-text channel_cadence is kept as a note" $?

# 2. Sweep evidence: hq_dms and slack swept 10 minutes ago; email swept 10
# minutes ago; hq_channels 70 minutes ago; x 64 minutes ago; github never.
NOW=2026-10-19T20:00:00Z
cat >"$tmp/state.json" <<'EOF'
{"sweep": {
  "sessions":         {"status": "swept", "last_swept_at": "2026-10-19T19:50:00Z", "cursor": "c"},
  "hq_dms":           {"status": "swept", "last_swept_at": "2026-10-19T19:50:00Z", "cursor": "c"},
  "slack:alpha":      {"status": "swept", "last_swept_at": "2026-10-19T19:50:00Z", "cursor": "c"},
  "email:a@example.com": {"status": "swept", "last_swept_at": "2026-10-19T19:50:00Z", "cursor": "c"},
  "hq_channels":      {"status": "swept", "last_swept_at": "2026-10-19T18:50:00Z", "cursor": "c"},
  "x":                {"status": "swept", "last_swept_at": "2026-10-19T18:56:00Z", "cursor": "c"}
}}
EOF
due="$(node "$SWEEP" due --state "$tmp/state.json" --now $NOW | tr '\n' ' ')"
expect "due: constant targets always, hourly only when over an hour old or never swept" \
  "sessions hq_dms hq_channels slack:alpha github x " "$due"

# 3. verify for a wakeup that started at 19:55: constant targets swept at 19:50
# are missing; email (hourly, 10 min old) is fine; hq_channels (65 min old at
# the wakeup start) is due. x was 59 minutes old when the wakeup started, so
# `due` did not list it then; its hour running out by 20:00 must not flag it
# (regression: an hourly target went SWEEP-INCOMPLETE once an hour).
out="$(node "$SWEEP" verify --state "$tmp/state.json" --since 2026-10-19T19:55:00Z --now $NOW)"; rc=$?
expect "verify fails while constant or due targets are unswept" 1 "$rc"
grep -q 'hq_dms (not swept since' <<<"$out"; check "a constant target must be swept every wakeup ($out)" $?
grep -q 'hq_channels (hourly sweep due' <<<"$out"; check "an hourly target over an hour old is flagged ($out)" $?
grep -q 'Hourly, not due: email:a@example.com (in 50m)' <<<"$out"; check "a recent hourly target is listed as not due ($out)" $?
! grep -q 'NOT SWEPT:.*email:a@example.com' <<<"$out"; check "a recent hourly target is not flagged ($out)" $?
! grep -q 'NOT SWEPT:.*\bx (' <<<"$out"; check "an hourly target not due at the wakeup start is not flagged when its hour runs out before verify ($out)" $?
grep -q 'Hourly, not due: .*x (in 0m)' <<<"$out"; check "it is listed as due now (in 0m) ($out)" $?

# 4. After sweeping only what `due` listed, verify passes.
for t in sessions hq_dms hq_channels slack:alpha github x; do
  python3 - "$tmp/state.json" "$t" <<'PY'
import json, sys
p, t = sys.argv[1], sys.argv[2]
s = json.load(open(p))
s["sweep"][t] = {"status": "swept", "last_swept_at": "2026-10-19T19:58:00Z", "cursor": "c"}
json.dump(s, open(p, "w"))
PY
done
node "$SWEEP" verify --state "$tmp/state.json" --since 2026-10-19T19:55:00Z --now $NOW >/dev/null
check "sweeping exactly the due targets passes verify" $?

# 5. A channel_cadence map overrides the defaults; with email constant again
# it is due on every wakeup.
cat >"$tmp/p.yaml" <<'EOF'
channels: [hq_dms, email]
email_accounts: [a@example.com]
channel_cadence:
  constant: [sessions, hq_dms, email]
  hourly: []
EOF
due="$(node "$SWEEP" due --state "$tmp/state.json" --now $NOW | tr '\n' ' ')"
expect "an owner map makes email constant" "sessions hq_dms email:a@example.com " "$due"

# 5b. A constant list without an hourly list takes those channels out of the
# default hourly list; comma-separated strings work the same as YAML lists.
printf 'channel_cadence:\n  constant: [sessions, hq_dms, email]\n' >"$tmp/p.yaml"
expect "constant alone removes email from the default hourly list" \
  '{"constant":["sessions","hq_dms","email"],"hourly":["hq_channels","github","x","teammates"],"hourly_seconds":3600}' \
  "$(node "$PREFS" cadence)"
printf 'channels: [hq_dms, github]\nchannel_cadence:\n  hourly: "github, x"\n' >"$tmp/p.yaml"
due="$(node "$SWEEP" due --state "$tmp/state.json" --now 2026-10-19T20:30:00Z | tr '\n' ' ')"
expect "a comma-separated hourly string is honored by due" "sessions hq_dms " "$due"

# 6. Skill contract.
SC="$ROOT/.claude/skills/super-conductor/SKILL.md"
grep -q 'super-conductor-sweep-check.mjs due' "$SC"; check "skill sweeps the due targets" $?
grep -q '^channel_cadence:' "$SC"; check "settings block documents channel_cadence" $?

[[ "$fail" -eq 0 ]] || exit 1
echo "super-conductor-channel-cadence: ok"
