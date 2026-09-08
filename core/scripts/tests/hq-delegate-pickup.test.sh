#!/usr/bin/env bash
# hq-core: public
# Regression tests for core/scripts/hq-delegate-pickup.sh (2026-09-07).
set -euo pipefail
ROOT="$(git rev-parse --show-toplevel)"; S="$ROOT/core/scripts/hq-delegate-pickup.sh"
FX="$(mktemp -d)"; trap 'rm -rf "$FX"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
mk() { # <status> <sentAt> [repo] [branch]
  jq -n --arg st "$1" --arg sa "$2" --arg repo "${3:-}" --arg br "${4:-}" \
    '{delegationId:"d1", status:$st, sentAt:(if $sa=="" then null else $sa end), to:{principal:"win@example.com", displayName:"Win"}, repo:{path:(if $repo=="" then null else $repo end), branch:(if $br=="" then null else $br end)}}' > "$FX/m.json"
}
echo "[1] --ack records picked-up"
mk sent 2026-09-01T00:00:00Z; bash "$S" --manifest "$FX/m.json" --ack "got it, starting today" >/dev/null || fail "ack rc"
[ "$(jq -r .status "$FX/m.json")" = picked-up ] && [ "$(jq -r .pickup.kind "$FX/m.json")" = ack ] || fail "ack state"
echo "[2] not-sent manifest is refused"
mk verified ""; rc=0; bash "$S" --manifest "$FX/m.json" --ack x >/dev/null 2>&1 || rc=$?; [ "$rc" = 2 ] || fail "expected 2, got $rc"
echo "[3] --check inside window waits (6)"
mk sent 2026-09-01T00:00:00Z; rc=0; HQ_DELEGATE_NOW=2026-09-02T00:00:00Z bash "$S" --manifest "$FX/m.json" --check >/dev/null || rc=$?; [ "$rc" = 6 ] || fail "expected 6, got $rc"
[ "$(jq -r .status "$FX/m.json")" = sent ] || fail "status must stay sent inside window"
echo "[4] --check past window fails (5) with a reason"
rc=0; err="$(HQ_DELEGATE_NOW=2026-09-05T00:00:00Z bash "$S" --manifest "$FX/m.json" --check 2>&1 >/dev/null)" || rc=$?
[ "$rc" = 5 ] || fail "expected 5, got $rc"; [ "$(jq -r .status "$FX/m.json")" = failed ] || fail "status failed"
grep -q 'no pickup evidence from Win' <<<"$err" || fail "reason: $err"
echo "[5] --check finds a recipient commit on the branch and records picked-up"
git -C "$FX" init -q repo; git -C "$FX/repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
git -C "$FX/repo" checkout -q -b feature/x; git -C "$FX/repo" -c user.email=win@example.com -c user.name=Win commit -q --allow-empty -m "win starts" --date="2026-09-03T12:00:00Z"
mk sent 2026-09-01T00:00:00Z "$FX/repo" feature/x
HQ_DELEGATE_NOW=2026-09-04T00:00:00Z bash "$S" --manifest "$FX/m.json" --check >/dev/null || fail "commit evidence rc"
[ "$(jq -r .pickup.kind "$FX/m.json")" = commit ] || fail "commit kind: $(cat "$FX/m.json")"
echo "[6] --status prints the state line"
bash "$S" --manifest "$FX/m.json" --status | grep -q 'picked-up' || fail "status line"
echo "hq-delegate-pickup: ok"
