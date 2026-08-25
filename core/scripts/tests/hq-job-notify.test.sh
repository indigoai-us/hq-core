#!/usr/bin/env bash
# hq-core: public
# Regression: hq-job-notify.sh dm delivery + 24h collapse (US-006).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
NOTIFY="$ROOT/core/scripts/hq-job-notify.sh"

[ -f "$NOTIFY" ] || { echo "FAIL: missing $NOTIFY" >&2; exit 1; }
[ -x "$NOTIFY" ] || chmod +x "$NOTIFY"
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not available"; exit 0; }
command -v yq >/dev/null 2>&1 || { echo "SKIP: yq not available"; exit 0; }

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "  ok: $*"; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/hq-job-notify-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

HQ="$TMP/hqroot"
HOME_DIR="$TMP/home"
BIN="$TMP/bin"
mkdir -p "$HQ/personal/settings" "$HOME_DIR/.hq/jobs" "$BIN"
export HOME="$HOME_DIR"
export HQ_ROOT="$HQ"
export HQ_JOB_ALERT_DIR="$HOME_DIR/.hq/jobs/alerts"
export PATH="$BIN:$PATH"

DM_LOG="$TMP/dm.log"
: >"$DM_LOG"
cat >"$BIN/hq" <<STUB
#!/usr/bin/env bash
if [ "\${1:-}" = "dm" ]; then
  recipient="\$2"
  headline="\$3"
  details=""
  shift 3 || true
  while [ \$# -gt 0 ]; do
    case "\$1" in
      --details) details="\$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  printf 'recipient=%s\nheadline=%s\ndetails=%s\n---\n' \
    "\$recipient" "\$headline" "\$details" >>"$DM_LOG"
  exit 0
fi
echo "hq stub unexpected: \$*" >&2
exit 2
STUB
chmod +x "$BIN/hq"

# Default dm profile
cat >"$HQ/personal/settings/schedule-alerts.yaml" <<'YAML'
channel: dm
updated_at: "2026-08-23T18:00:00Z"
YAML

export HQ_JOB_NOTIFY_NOW_EPOCH=1000000
export HQ_JOB_NOTIFY_COLLAPSE_SEC=86400

common=(
  --hq-root "$HQ"
  --job-id digest-job
  --job-name "Daily digest"
  --owner owner@example.com
  --notify profile
  --duration 12
  --log-path "$HOME_DIR/.hq/jobs/logs/digest-job/x.log"
)

# 1) ok → one dm
: >"$DM_LOG"
out="$(bash "$NOTIFY" "${common[@]}" --outcome ok --summary "completed ok")"
echo "$out" | jq -e '.delivered == true' >/dev/null || fail "ok should deliver: $out"
grep -q "Daily digest" "$DM_LOG" || fail "ok dm missing job name"
grep -Eqi 'ok' "$DM_LOG" || fail "ok dm missing ok status"
pass "exit-ok sends one dm"

# 2) first failure → dm with class + next action
: >"$DM_LOG"
out="$(bash "$NOTIFY" "${common[@]}" --outcome failed --failure-class agent_error \
  --summary "exit=1 class=agent_error" --next-action "inspect the job log")"
echo "$out" | jq -e '.delivered == true' >/dev/null || fail "first failure should deliver"
grep -qi 'agent_error' "$DM_LOG" || fail "failure dm missing classification"
grep -qi 'inspect the job log' "$DM_LOG" || fail "failure dm missing next action"
pass "first failure dm includes class + next action"

# 3) consecutive failures within 24h → collapsed (exactly one failure dm so far)
: >"$DM_LOG"
export HQ_JOB_NOTIFY_NOW_EPOCH=1003600  # +1h
out="$(bash "$NOTIFY" "${common[@]}" --outcome failed --failure-class agent_error \
  --summary "exit=1 again")"
echo "$out" | jq -e '.delivered == false and .reason == "collapsed_24h"' >/dev/null \
  || fail "expected collapse: $out"
[ ! -s "$DM_LOG" ] || fail "collapsed failure must not send dm"
pass "consecutive failure collapsed within 24h"

# 4) third failure still collapsed
: >"$DM_LOG"
export HQ_JOB_NOTIFY_NOW_EPOCH=1007200
out="$(bash "$NOTIFY" "${common[@]}" --outcome failed --failure-class agent_error \
  --summary "exit=1 third")"
echo "$out" | jq -e '.reason == "collapsed_24h"' >/dev/null || fail "third should collapse: $out"
pass "third consecutive failure still collapsed"

# 5) recovery → recovered dm
: >"$DM_LOG"
export HQ_JOB_NOTIFY_NOW_EPOCH=1010000
out="$(bash "$NOTIFY" "${common[@]}" --outcome ok --summary "completed ok")"
echo "$out" | jq -e '.delivered == true and .kind == "recovered"' >/dev/null \
  || fail "expected recovered: $out"
grep -qi 'recovered' "$DM_LOG" || fail "recovered dm text missing"
pass "recovery sends recovered dm"

# 6) slack profile → dm fallback + channel_unimplemented
cat >"$HQ/personal/settings/schedule-alerts.yaml" <<'YAML'
channel: slack
destination:
  workspace: acme
  channel: "#alerts"
updated_at: "2026-08-23T18:00:00Z"
YAML
: >"$DM_LOG"
export HQ_JOB_NOTIFY_NOW_EPOCH=1020000
out="$(bash "$NOTIFY" "${common[@]}" --outcome ok --summary "ok again" 2>"$TMP/slack.err")"
echo "$out" | jq -e '.delivered == true and .channel_unimplemented == true' >/dev/null \
  || fail "slack should dm-fallback: $out"
grep -q 'channel_unimplemented=slack' "$TMP/slack.err" || fail "expected channel_unimplemented log"
pass "slack profile falls back to dm + logs channel_unimplemented"

# 7) notify=none → no dm
: >"$DM_LOG"
out="$(bash "$NOTIFY" "${common[@]}" --notify none --outcome failed --summary "x")"
echo "$out" | jq -e '.reason == "notify_none"' >/dev/null || fail "notify none: $out"
[ ! -s "$DM_LOG" ] || fail "notify=none must not dm"
pass "notify=none skips delivery"

# 8) dm delivery failure never exits non-zero
cat >"$BIN/hq" <<'STUB'
#!/usr/bin/env bash
exit 99
STUB
chmod +x "$BIN/hq"
set +e
bash "$NOTIFY" "${common[@]}" --notify dm --outcome ok --summary "x" >"$TMP/fail.out" 2>"$TMP/fail.err"
rc=$?
set -e
[ "$rc" -eq 0 ] || fail "notify must exit 0 on dm failure, got $rc"
pass "dm delivery failure exits 0"

echo "ALL PASSED (hq-job-notify)"
