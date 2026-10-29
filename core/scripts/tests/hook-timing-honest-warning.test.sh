#!/usr/bin/env bash
# hq-core: public
# hook-timing-honest-warning.test.sh
#
# Regression contract for feedback_5ec0fd09.
#   [1] The master-hook timeout breadcrumb text reports measured elapsed time
#       and never says the hook was or is about to be killed: the relative
#       watchdog fires a lead time BEFORE the configured timeout (10 s on a
#       30 s Codex timeout) and has no proof the harness stopped anything.
#       A breadcrumb whose timeout was not found in the harness config says
#       so instead of naming the assumed 30 s default as the timeout.
#   [3] The master relative warning fires at 80% of the timeout by default
#       (24 s of 30 s), never at 10 s of 30 s as the old fixed 20 s lead did,
#       in both the watchdog and master-hook's copy of the threshold.
#   [4] A breadcrumb from an earlier run (no written_at, or older than the
#       max age) is dropped, not reported as a current warning; a fresh one
#       says how long ago it was recorded.
#   [5] The real watchdog writes the relative breadcrumb with written_at.
#   [2] Hooks the Codex/Grok adapters dispatch themselves (master-hook skips
#       its registry pass there) are written to the same per-session timing
#       journal master-hook uses, one row per hook with its elapsed time.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
MASTER="${HQ_TEST_MASTER_HOOK:-$ROOT/.claude/hooks/master-hook.sh}"
WATCHDOG="${HQ_TEST_WATCHDOG:-$ROOT/.claude/hooks/hook-timeout-watchdog.sh}"
ADAPTER_CORE="${HQ_TEST_ADAPTER_CORE:-$ROOT/core/scripts/lib/hook-adapter-core.sh}"
command -v jq >/dev/null || { echo "jq required"; exit 2; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
failures=0
passes=0
ok() { printf 'ok   %s\n' "$1"; passes=$((passes + 1)); }
bad() { printf 'FAIL %s\n' "$1"; failures=$((failures + 1)); }

# The breadcrumb renderer is the jq program in master-hook.sh that turns a
# watchdog record into additionalContext. Extract it from the script so the
# test exercises the shipped text, then feed it records.
extract_renderer() {
  awk '
    /text="\$\(jq -r .*'\''$/ { on = 1; next }
    on && /^    '\'' 2>\/dev\/null < "\$claim"/ { exit }
    on { print }
  ' "$MASTER"
}
RENDERER="$(extract_renderer)"
[ -n "$RENDERER" ] || { echo "could not find the breadcrumb renderer in $MASTER"; exit 2; }
NOW="$(date +%s)"
render() {
  printf '%s' "$1" | jq -r --argjson now "$NOW" --argjson max_age "${2:-86400}" "$RENDERER"
}

echo "[1] the relative warning reports measured time, never a kill"
master_path="/x/.claude/hooks/master-hook.sh"
codex_record="$(jq -cn --arg p "$master_path" '{hook_path:$p,hook_event:"PreToolUse",threshold:"relative",invocation_id:"i1",elapsed_ms:24400,declared_timeout_ms:30000,declared_timeout_source:"config",written_at:'"$NOW"'}')"
out="$(render "$codex_record")"
case "$out" in *'<hq-hook-timeout-escalation>'*) ok "a relative record still renders an escalation" ;; *) bad "no escalation rendered: $out" ;; esac
if printf '%s' "$out" | grep -Ei 'kill|discard' >/dev/null; then
  bad "the warning before the 30 s timeout claims a kill: $out"
else
  ok "no kill or discard wording below the configured timeout"
fi
case "$out" in *'had run for 24s of its configured 30s timeout budget'*) ok "the text reports measured time against the configured budget" ;; *) bad "elapsed-of-budget wording missing: $out" ;; esac
default_record="$(jq -cn --arg p "$master_path" '{hook_path:$p,hook_event:"PreToolUse",threshold:"relative",invocation_id:"i2",elapsed_ms:24400,declared_timeout_ms:30000,declared_timeout_source:"default",written_at:'"$NOW"'}')"
out="$(render "$default_record")"
case "$out" in
  *'24s of an assumed 30s timeout budget (no configured timeout was found for it)'*) ok "an assumed default timeout is not stated as the real timeout" ;;
  *) bad "default-timeout record still names a timeout: $out" ;;
esac
if printf '%s' "$out" | grep -Ei 'kill|discard' >/dev/null; then bad "default-timeout warning claims a kill: $out"; else ok "default-timeout warning has no kill wording"; fi

# The watchdog writes the source field the renderer reads.
grep -q 'declared_timeout_source: \$declared_timeout_source' "$WATCHDOG" \
  && ok "the watchdog breadcrumb records where the timeout came from" \
  || bad "the watchdog breadcrumb does not record declared_timeout_source"

echo "[3] the master relative warning fires near the real timeout"
WATCHDOG_WARN_FN="$(awk '/^master_relative_warn_seconds\(\) \{$/ { on = 1 } on { print } on && /^\}$/ { exit }' "$WATCHDOG")"
if [ -z "$WATCHDOG_WARN_FN" ]; then
  bad "the watchdog has no master_relative_warn_seconds threshold function"
else
  watchdog_warn() {
    env -u HQ_HOOK_TIMEOUT_MASTER_WARN_LEAD_SECONDS -u HQ_HOOK_TIMEOUT_MASTER_WARN_PERCENT "$@" bash -c '
      DEFAULT_MASTER_WARN_PERCENT=80
      is_nonnegative_integer() { [[ "${1:-}" =~ ^[0-9]+$ ]]; }
      eval "$1"; master_relative_warn_seconds "$2"
    ' _ "$WATCHDOG_WARN_FN" "$declared"
  }
  declared=30; got="$(watchdog_warn)"
  [ "$got" = 24 ] && ok "watchdog: a 30 s timeout warns at 24 s" || bad "watchdog: a 30 s timeout warns at ${got}s, want 24s"
  declared=600; got="$(watchdog_warn)"
  [ "$got" = 480 ] && ok "watchdog: a 600 s timeout warns at 480 s" || bad "watchdog: a 600 s timeout warns at ${got}s"
  declared=30; got="$(watchdog_warn HQ_HOOK_TIMEOUT_MASTER_WARN_PERCENT=junk)"
  [ "$got" = 24 ] && ok "watchdog: an invalid percent falls back to 80%" || bad "watchdog: invalid percent gave ${got}s"
  declared=30; got="$(watchdog_warn HQ_HOOK_TIMEOUT_MASTER_WARN_PERCENT=100)"
  [ "$got" = 29 ] && ok "watchdog: a 100% setting still warns before the timeout" || bad "watchdog: 100% gave ${got}s"
  declared=30; got="$(watchdog_warn HQ_HOOK_TIMEOUT_MASTER_WARN_LEAD_SECONDS=2)"
  [ "$got" = 28 ] && ok "watchdog: an explicit lead still sets a fixed lead" || bad "watchdog: explicit 2 s lead gave ${got}s"
fi
MASTER_WARN_FN="$(awk '/^master_watchdog_timeout_ms\(\) \{$/ { on = 1 } on { print } on && /^\}$/ { exit }' "$MASTER")"
master_warn_ms() {
  env -u HQ_HOOK_TIMEOUT_MASTER_WARN_LEAD_SECONDS -u HQ_HOOK_TIMEOUT_MASTER_WARN_PERCENT \
    -u HQ_HOOK_TIMEOUT_MASTER_ABSOLUTE_SECONDS "$@" bash -c '
    declared="$2"
    master_declared_timeout_ms() { printf "%s" "$declared"; }
    eval "$1"; master_watchdog_timeout_ms
  ' _ "$MASTER_WARN_FN" "$declared_ms"
}
declared_ms=30000; got="$(master_warn_ms)"
[ "$got" = 24000 ] && ok "master: a 30 s timeout warns at 24 s" || bad "master: a 30 s timeout warns at ${got} ms, want 24000"
declared_ms=600000; got="$(master_warn_ms)"
[ "$got" = 120000 ] && ok "master: the 120 s absolute cap still applies to long timeouts" || bad "master: 600 s timeout gave ${got} ms"
declared_ms=30000; got="$(master_warn_ms HQ_HOOK_TIMEOUT_MASTER_WARN_LEAD_SECONDS=2)"
[ "$got" = 28000 ] && ok "master: an explicit lead still sets a fixed lead" || bad "master: explicit lead gave ${got} ms"

echo "[4] a breadcrumb from an earlier run is not reported as current"
stale_record="$(jq -cn --arg p "$master_path" --argjson t "$((NOW - 2 * 86400))" '{hook_path:$p,hook_event:"PostToolUse",threshold:"relative",invocation_id:"old",elapsed_ms:24400,declared_timeout_ms:30000,declared_timeout_source:"config",written_at:$t}')"
out="$(render "$stale_record")"
[ -z "$out" ] && ok "a two-day-old breadcrumb renders nothing" || bad "stale breadcrumb rendered as a warning: $out"
legacy_record="$(jq -cn --arg p "$master_path" '{hook_path:$p,hook_event:"PostToolUse",threshold:"absolute",invocation_id:"old",elapsed_ms:120000,declared_timeout_ms:300000}')"
out="$(render "$legacy_record")"
[ -z "$out" ] && ok "a breadcrumb with no written_at renders nothing" || bad "undated breadcrumb rendered as a warning: $out"
late_record="$(jq -cn --arg p "$master_path" --argjson t "$((NOW - 45))" '{hook_path:$p,hook_event:"PostToolUse",threshold:"relative",invocation_id:"late",elapsed_ms:24400,declared_timeout_ms:30000,declared_timeout_source:"config",written_at:$t}')"
out="$(render "$late_record")"
case "$out" in *'recorded 45s ago'*) ok "a late breadcrumb says when it was recorded" ;; *) bad "late breadcrumb hides its age: $out" ;; esac
out="$(render "$late_record" 30)"
[ -z "$out" ] && ok "the max age bounds delivery" || bad "a 45 s old record passed a 30 s max age: $out"
grep -q 'written_at: \$written_at' "$WATCHDOG" \
  && ok "the watchdog breadcrumb records when it was written" \
  || bad "the watchdog breadcrumb has no written_at"

echo "[5] the real watchdog writes a dated relative breadcrumb at the warn point"
WR="$TMP/watchdog-root"
mkdir -p "$WR/.claude/hooks" "$WR/workspace"
cp "$WATCHDOG" "$WR/.claude/hooks/hook-timeout-watchdog.sh"
cp "$(dirname "$WATCHDOG")/hook-timeout-probe.sh" "$WR/.claude/hooks/hook-timeout-probe.sh"
# A 4%
# warn point (2 s of the assumed 30 s) keeps the run short.
rm -f "$WR/status"
printf '{"session_id":"s5"}' | env -u HQ_HOOK_TIMEOUT_MASTER_WARN_LEAD_SECONDS \
  -u HQ_HOOK_TIMEOUT_SENTRY_TEST_TRIGGER_FILE HQ_HOOK_TIMEOUT_MASTER_WARN_PERCENT=4 \
  HQ_HOOK_TIMEOUT_SENTRY=1 HQ_HOOK_TIMEOUT_SENTRY_TEST_STATUS_FILE="$WR/status" \
  bash "$WR/.claude/hooks/hook-timeout-watchdog.sh" --root "$WR" --source master-dispatch \
    --hook-path "$WR/.claude/hooks/master-hook.sh" --event PreToolUse --threshold relative \
    --started-at "$(date +%s)" --invocation-id inv5r >/dev/null 2>&1 || true
relative_records="$(cat "$WR"/workspace/.hook-timeout-breadcrumbs/*/relative-*.json 2>/dev/null || true)"
printf '%s' "$relative_records" | jq -e 'select(.threshold == "relative" and .invocation_id == "inv5r" and (.written_at | type) == "number")' >/dev/null 2>&1 \
  && ok "the watchdog writes a relative breadcrumb with written_at" \
  || bad "no relative breadcrumb written (status: $(cat "$WR/status" 2>/dev/null))"

echo "[2] adapter-dispatched hook time is in the master timing journal"
R="$TMP/root"
mkdir -p "$R/.claude/hooks" "$R/workspace"
# A watchdog stand-in: the adapter only checks that it exists and launches it.
printf '#!/usr/bin/env bash\ncat >/dev/null\nexit 0\n' > "$R/.claude/hooks/hook-timeout-watchdog.sh"
journal_out="$(
  HQ_ROOT="$R" bash -c '
    set -euo pipefail
    . "$1"
    hqad_event_watchdog_start "$HQ_ROOT" PreToolUse "{}" test-session-1
    hqad_event_watchdog_child_start /some/dir/slow-guard.sh PreToolUse
    sleep 0.3
    hqad_event_watchdog_child_end
    hqad_event_watchdog_child_start /some/dir/fast-guard.sh PreToolUse
    hqad_event_watchdog_child_end
    hqad_event_watchdog_stop
    cat "$HQ_ROOT"/workspace/.hook-timeout-journal/*.tsv 2>/dev/null || true
  ' _ "$ADAPTER_CORE"
)"
slow_row="$(printf '%s\n' "$journal_out" | awk -F '\t' '$1 == "slow-guard.sh" && $2 == "PreToolUse"')"
[ -n "$slow_row" ] && ok "the adapter writes a journal row for the hook it ran" || bad "no journal row for the adapter-run hook: [$journal_out]"
slow_ms="$(printf '%s' "$slow_row" | awk -F '\t' '{print $3}')"
if [[ "$slow_ms" =~ ^[0-9]+$ ]] && [ "$slow_ms" -ge 250 ]; then
  ok "the row carries the measured elapsed time (${slow_ms} ms)"
else
  bad "elapsed ms missing or too small: [$slow_ms]"
fi
printf '%s\n' "$journal_out" | awk -F '\t' '$1 == "fast-guard.sh"' | grep -q . \
  && ok "every adapter-run hook gets its own row" || bad "second hook has no row"
fields="$(printf '%s' "$slow_row" | awk -F '\t' '{print NF}')"
[ "$fields" = 4 ] && ok "rows use the master journal shape (script, event, ms, invocation)" || bad "row has $fields fields: $slow_row"

printf '\n%s passed, %s failed\n' "$passes" "$failures"
[ "$failures" -eq 0 ]
