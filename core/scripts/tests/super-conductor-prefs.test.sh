#!/usr/bin/env bash
# Pins the super-conductor personal-preferences contract:
#   - personal/settings/super-conductor.yaml is an extension layer over the core
#     skill's defaults, read on every start and every wakeup;
#   - unknown keys are carried through, never dropped;
#   - a durable preference write extends (adds to a list or sets one scalar)
#     and never rewrites another key's lines;
#   - the heartbeat takes its channels from the settings file when --channels
#     is omitted, re-read on every wake;
#   - the skill documents slack_workspaces, hq_channels, email_accounts, and
#     surface as first-class keys.
set -euo pipefail

ROOT="${HQ_TEST_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
PREFS="$ROOT/core/scripts/super-conductor-prefs.mjs"
HB="$ROOT/core/scripts/super-conductor-heartbeat.sh"
SC="$ROOT/.claude/skills/super-conductor/SKILL.md"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fail=0
check() { # description condition-exit-code
  if [[ "$2" -ne 0 ]]; then echo "FAIL: $1" >&2; fail=1; fi
}
prefs() { SC_PREFS_FILE="$tmp/p.yaml" node "$PREFS" "$@"; }

cat >"$tmp/p.yaml" <<'EOF'
# Owner prefs (comment kept verbatim)
channels:
  - hq_dms
  - slack   # inline comment kept

slack_workspaces:
  - alpha

hq_channels: all
surface: needs_attention

watch_interval:
  present: 600   # ten minutes
  away: 1500

# A key this release does not know, nested.
future_feature:
  mode: loud
  targets:
    - one
    - two
vip_senders: [a@example.com, b@example.com]
EOF
cp "$tmp/p.yaml" "$tmp/orig.yaml"

# 1. get: defaults overlaid, unknown keys carried through and flagged.
out="$(prefs get)"
grep -q '"future_feature"' <<<"$out"; check "get keeps an unknown nested key" $?
grep -q '"loud"' <<<"$out"; check "get keeps an unknown key's nested value" $?
grep -q '"b@example.com"' <<<"$out"; check "get keeps an unknown flow-list key" $?
node -e 'const j=JSON.parse(require("fs").readFileSync(0,"utf8")); process.exit(j._extension_keys.join()==="future_feature,vip_senders"?0:1)' <<<"$out"
check "get lists unknown keys in _extension_keys" $?
node -e 'const j=JSON.parse(require("fs").readFileSync(0,"utf8")); process.exit(j.watch_interval.present===600&&j.watch_interval.away===1500?0:1)' <<<"$out"
check "get overlays settings on defaults" $?
[[ "$(prefs channels)" == "sessions,hq_dms,slack" ]]; check "channels CSV starts with sessions (got $(prefs channels))" $?
[[ "$(SC_PREFS_FILE="$tmp/missing.yaml" node "$PREFS" channels)" == "sessions,hq_dms" ]]; check "missing settings file falls back to defaults" $?

# 2. A durable list preference extends: only added lines in the diff.
prefs add slack_workspaces beta >/dev/null
d="$(diff "$tmp/orig.yaml" "$tmp/p.yaml" || true)"
[[ "$(grep -c '^<' <<<"$d" || true)" -eq 0 ]]; check "add removes or rewrites no line" $?
grep -q '^>   - beta$' <<<"$d"; check "add appends the new item under its key" $?
prefs add slack_workspaces beta >/dev/null
[[ "$(grep -c -- '- beta' "$tmp/p.yaml")" -eq 1 ]]; check "add does not duplicate an existing item" $?

# 3. A new key is appended; the original text stays as a prefix.
cp "$tmp/p.yaml" "$tmp/before-new.yaml"
prefs add email_accounts owner@example.com >/dev/null
head -c "$(wc -c <"$tmp/before-new.yaml")" "$tmp/p.yaml" | cmp -s - "$tmp/before-new.yaml"
check "new key leaves the existing file as an untouched prefix" $?
grep -q '^email_accounts:$' "$tmp/p.yaml"; check "new list key written" $?

# 4. set changes one nested scalar and nothing else.
cp "$tmp/p.yaml" "$tmp/before-set.yaml"
prefs set watch_interval.present 300 >/dev/null
d="$(diff "$tmp/before-set.yaml" "$tmp/p.yaml" || true)"
[[ "$(grep -c '^[<>]' <<<"$d")" -eq 2 ]] && grep -q '^>   present: 300' <<<"$d"
check "set rewrites only the one scalar line" $?

# 5. Every unknown key and comment survives all writes.
for line in '# Owner prefs (comment kept verbatim)' '  - slack   # inline comment kept' \
  'future_feature:' '  mode: loud' '    - two' 'vip_senders: [a@example.com, b@example.com]'; do
  grep -qxF -- "$line" "$tmp/p.yaml"; check "write preserved: $line" $?
done

# 6. Wrong-shape writes are refused and leave the file alone.
cp "$tmp/p.yaml" "$tmp/before-bad.yaml"
set +e; prefs add hq_channels x >/dev/null 2>&1; rc=$?; set -e
check "add to a scalar key is refused with exit 3 (got $rc)" "$([[ $rc -eq 3 ]]; echo $?)"
set +e; prefs set channels x >/dev/null 2>&1; rc=$?; set -e
check "set on a list key is refused with exit 3 (got $rc)" "$([[ $rc -eq 3 ]]; echo $?)"
cmp -s "$tmp/before-bad.yaml" "$tmp/p.yaml"; check "refused writes leave the file unchanged" $?

# 6b. hq_channels_exclude round-trips: add extends the list, get returns it
# normalized (trimmed, lowercased, slug or id), exclude prints it as CSV, and
# it is a known key, not an extension.
prefs add hq_channels_exclude 'Project-Core-PR-Reviews-6e234042 ' chn_abc123 >/dev/null
out="$(prefs get)"
check "get returns hq_channels_exclude normalized and known (got: $(grep -A3 hq_channels_exclude <<<"$out" | tr -d '\n'))" \
  "$(node -e 'const j=JSON.parse(require("fs").readFileSync(0,"utf8")); process.exit(JSON.stringify(j.hq_channels_exclude)==="[\"project-core-pr-reviews-6e234042\",\"chn_abc123\"]"&&!j._extension_keys.includes("hq_channels_exclude")?0:1)' <<<"$out"; echo $?)"
check "exclude prints the list as CSV (got $(prefs exclude 2>/dev/null))" "$([[ "$(prefs exclude 2>/dev/null)" == "project-core-pr-reviews-6e234042,chn_abc123" ]]; echo $?)"
check "exclude is empty when unset" "$([[ "$(SC_PREFS_FILE="$tmp/missing.yaml" node "$PREFS" exclude 2>/dev/null)" == "" ]]; echo $?)"
printf 'hq_channels_exclude: chn_one, Chn_Two\n' >"$tmp/csv.yaml"
check "a comma-separated hq_channels_exclude string is accepted" "$([[ "$(SC_PREFS_FILE="$tmp/csv.yaml" node "$PREFS" exclude 2>/dev/null)" == "chn_one,chn_two" ]]; echo $?)"

# 7. Heartbeat reads channels from settings when --channels is omitted, on every wake.
export SC_HEARTBEAT_MIN_INTERVAL=1 SC_PREFS_FILE="$tmp/p.yaml"
out="$(bash "$HB" --interval 1 --once)"
grep -q 'channels: sessions,hq_dms,slack (from settings)' <<<"$out"; check "heartbeat uses settings channels (got: $out)" $?
prefs add channels email >/dev/null
out="$(bash "$HB" --interval 1 --once)"
grep -q 'channels: sessions,hq_dms,slack,email' <<<"$out"; check "heartbeat picks up a saved channel on the next wake" $?
out="$(bash "$HB" --interval 1 --channels hq_dms --once)"
grep -q 'channels: hq_dms |' <<<"$out"; check "--channels still wins over settings" $?
unset SC_PREFS_FILE

# 8. Skill contract.
need() { grep -Eq -- "$1" "$SC" || { echo "FAIL: skill: $2" >&2; fail=1; }; }
need '^## Owner preferences' 'has an Owner preferences section'
need 'per-run argument > personal settings > save file > defaults' 'states the precedence order'
need 'on every start and every wakeup' 'reads the settings file on every start and every wakeup'
need 'super-conductor-prefs\.mjs get' 'reads prefs through the helper'
need 'Unknown keys are carried through' 'carries unknown keys through'
need 'super-conductor-prefs\.mjs (add|set)' 'durable preferences are written through the helper'
need 'never rewrite' 'durable writes never rewrite other keys'
need '`slack_workspaces`' 'documents slack_workspaces'
need '`hq_channels`' 'documents the hq_channels channel key'
need '`hq_channels_exclude`' 'documents hq_channels_exclude'
need 'hq_channels_exclude: \[\]' 'the settings example lists hq_channels_exclude'
need 'hq channels list' 'hq_channels sweep uses hq channels'
need '`email_accounts`' 'documents email_accounts'
need 'every listed account' 'sweeps every listed email account'
need '`surface`' 'documents surface'
need 'needs_attention' 'documents surface: needs_attention'

[[ "$fail" -eq 0 ]] || exit 1
echo "super-conductor prefs contract: ok"
