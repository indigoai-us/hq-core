#!/usr/bin/env bash
# feedback_a5c390e9 / Shepherd 2862: a hosted box with HQ_FLAGS_API_URL and
# HQ_COMPANY_UID set ran `node hq-anywhere-runtime-flag.cjs` on every hook
# event with no wall-clock bound. When that reader stuck (network or a broken
# node/npm toolchain), every PreToolUse stalled until the host hook timeout,
# so even `echo` failed. master-hook must bound the read, cache it, and let an
# unrelated command through.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SOURCE_ROOT="${HQ_TEST_SOURCE_ROOT:-$ROOT}"
TMP="$(mktemp -d)"
trap 'pkill -KILL -f "$TMP/bin/node" 2>/dev/null || true; rm -rf "$TMP"' EXIT

FAIL=0
fail() { printf 'FAIL: %s\n' "$*" >&2; FAIL=$((FAIL + 1)); }
pass() { printf 'PASS: %s\n' "$*"; }

root="$TMP/root"
mkdir -p "$root/.claude/hooks" "$root/core/scripts/lib" "$root/core/policies" \
  "$root/personal/policies" "$root/workspace" "$TMP/bin" "$TMP/home/.hq"
for rel in \
  .claude/hooks/master-hook.sh \
  .claude/hooks/hook-gate.sh \
  .claude/hooks/hook-timeout-probe.sh \
  .claude/hooks/hook-timeout-watchdog.sh \
  core/scripts/lib/hook-adapter-core.sh \
  core/scripts/hqd-hook-flag-cache-lib.sh \
  core/scripts/hq-anywhere-runtime-flag.cjs; do
  mkdir -p "$root/${rel%/*}"
  cp "$SOURCE_ROOT/$rel" "$root/$rel"
done
printf '{"hooks":{}}\n' > "$root/.claude/hooks/hook-registry.json"

# A node that hangs far past any sane hook budget, like a reader stuck on a
# network call. Each start is logged so the cache can be checked.
# NODE_MODE=hang (default) sleeps; NODE_MODE=true|false prints that value.
cat > "$TMP/bin/node" <<'SH'
#!/bin/sh
[ "${NODE_WARM:-}" = 1 ] && exit 0
printf 'called\n' >> "$NODE_CALLS"
case "${NODE_MODE:-hang}" in
  true|false) printf '%s\n' "$NODE_MODE"; exit 0 ;;
esac
exec sleep 30
SH
chmod 700 "$TMP/bin/node"
# The first exec of a new file can take ~1s on macOS; warm it so the budget
# below measures the reader, not the OS first-launch check.
NODE_WARM=1 "$TMP/bin/node"

run_hook() {
  local payload
  payload="$(jq -cn --arg cwd "$root" \
    '{session_id:"flag-bound",hook_event_name:"PreToolUse",tool_name:"Bash",cwd:$cwd,tool_input:{command:"echo hi"}}')"
  printf '%s' "$payload" | env \
    PATH="$TMP/bin:$PATH" HOME="$TMP/home" NODE_CALLS="$TMP/node-calls" \
    HQ_FLAGS_API_URL=https://flags.test HQ_COMPANY_UID=cmp_123456 \
    HQ_FLAG_READER_TIMEOUT_MS=1500 \
    HQ_HOOK_PROFILE=standard HQ_DISABLED_HOOKS= HQ_HOOK_TIMEOUT_SENTRY=0 \
    BASH_ENV=/dev/null \
    bash "$root/.claude/hooks/master-hook.sh" PreToolUse >/dev/null 2>"$TMP/err"
}

# Same as run_hook without the explicit budget override.
run_hook_default() {
  local payload
  payload="$(jq -cn --arg cwd "$root" \
    '{session_id:"flag-bound",hook_event_name:"PreToolUse",tool_name:"Bash",cwd:$cwd,tool_input:{command:"echo hi"}}')"
  printf '%s' "$payload" | env \
    PATH="$TMP/bin:$PATH" HOME="$TMP/home" NODE_CALLS="$TMP/node-calls" \
    HQ_FLAGS_API_URL=https://flags.test HQ_COMPANY_UID=cmp_123456 \
    HQ_HOOK_PROFILE=standard HQ_DISABLED_HOOKS= HQ_HOOK_TIMEOUT_SENTRY=0 \
    BASH_ENV=/dev/null \
    bash "$root/.claude/hooks/master-hook.sh" PreToolUse >/dev/null 2>"$TMP/err"
}

start=$(date +%s)
status=0; run_hook || status=$?
elapsed=$(( $(date +%s) - start ))
if [ "$status" -eq 0 ]; then pass "echo allowed while the flag reader hangs"; else fail "master-hook exited $status"; fi
if [ "$elapsed" -le 5 ]; then pass "hook finished in ${elapsed}s (reader bounded)"; else fail "hook took ${elapsed}s; flag reader is unbounded"; fi

[ -s "$TMP/node-calls" ] && pass "flag reader was actually started" || fail "flag reader never started"
calls_before="$(wc -l < "$TMP/node-calls" | tr -d ' ')"
start=$(date +%s)
status=0; run_hook || status=$?
elapsed=$(( $(date +%s) - start ))
calls_after="$(wc -l < "$TMP/node-calls" | tr -d ' ')"
if [ "$status" -eq 0 ] && [ "$elapsed" -le 5 ]; then pass "second event also allowed quickly"; else fail "second event exit $status in ${elapsed}s"; fi
# A timed-out read writes a short negative cache, so the next event inside
# the window does not start the reader again (review on #1485).
if [ "$calls_after" -eq "$calls_before" ]; then pass "negative cache: no reader start right after a timeout"; else fail "reader started $((calls_after - calls_before)) times right after a timeout"; fi

# Default budget on the hot path is 2000 ms, not 5000 (no override set).
rm -f "$TMP/home/.hq/"*.timeout
start=$(date +%s)
status=0; HQ_FLAG_READER_TIMEOUT_MS= run_hook_default || status=$?
elapsed=$(( $(date +%s) - start ))
if [ "$status" -eq 0 ] && [ "$elapsed" -le 4 ]; then pass "default hot-path budget bounds the read (${elapsed}s)"; else fail "default budget: exit $status in ${elapsed}s"; fi

# Kill switch stays live: a true read then a false read inside the 60s
# snapshot TTL must give false at once (master-hook-double-dispatch contract).
LIB="$root/core/scripts/hqd-hook-flag-cache-lib.sh"
FLAG="$root/core/scripts/hq-anywhere-runtime-flag.cjs"
rm -f "$TMP/home/.hq/"*.timeout
live_read() {
  env PATH="$TMP/bin:$PATH" HOME="$TMP/home" NODE_CALLS="$TMP/node-calls" NODE_MODE="$1" \
    HQ_COMPANY_UID=cmp_123456 bash -c '. "$1"; hqd_hook_flag_cache_store_enabled; hq_anywhere_flag_live_read "$2"' _ "$LIB" "$FLAG"
}
v1="$(live_read true)"; v2="$(live_read false)"
if [ "$v1" = true ] && [ "$v2" = false ]; then pass "flag-off applies at once despite a fresh cached true"; else fail "flag flip true->false gave $v1 then $v2"; fi
# A reader that recovers clears the negative cache.
touch "$TMP/home/.hq/hq-anywhere-runtime.flag.cmp_123456.timeout"
printf '0\n' > "$TMP/home/.hq/hq-anywhere-runtime.flag.cmp_123456.timeout"
v3="$(live_read false)"
if [ "$v3" = false ] && [ ! -f "$TMP/home/.hq/hq-anywhere-runtime.flag.cmp_123456.timeout" ]; then pass "expired negative cache is retried and cleared"; else fail "expired negative cache: got $v3"; fi

if [ "$FAIL" -eq 0 ]; then echo "master-hook-flag-reader-bounded: all checks passed"; exit 0; fi
echo "master-hook-flag-reader-bounded: $FAIL failure(s)" >&2
exit 1
