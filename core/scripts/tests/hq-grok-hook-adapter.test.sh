#!/usr/bin/env bash
# hq-core: public
# Unit tests for .grok/hooks/hq-grok-hook-adapter.sh (no network, no grok CLI).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
ADAPTER="${ROOT}/.grok/hooks/hq-grok-hook-adapter.sh"
BRIDGE="${ROOT}/.grok/hooks/hq-grok-user-bridge.sh"
PASS=0
FAIL=0

assert_contains() {
  local haystack="$1" needle="$2" label="$3"
  # Allow optional whitespace in JSON keys: "decision":"deny" or "decision": "deny"
  local flex
  flex="$(printf '%s' "$needle" | sed 's/":"/":[[:space:]]*"/g')"
  if printf '%s' "$haystack" | grep -Eq "$flex" || printf '%s' "$haystack" | grep -Fq "$needle"; then
    echo "PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "FAIL: $label (expected to contain: $needle)" >&2
    echo "  got: $haystack" >&2
    FAIL=$((FAIL + 1))
  fi
}

assert_exit() {
  local got="$1" want="$2" label="$3"
  if [ "$got" -eq "$want" ]; then
    echo "PASS: $label (exit $got)"
    PASS=$((PASS + 1))
  else
    echo "FAIL: $label (exit $got, want $want)" >&2
    FAIL=$((FAIL + 1))
  fi
}

run_adapter() {
  local payload="$1"
  local out err st
  out="$(mktemp)"; err="$(mktemp)"
  set +e
  printf '%s' "$payload" | "$ADAPTER" >"$out" 2>"$err"
  st=$?
  set -e
  ADAPTER_OUT="$(cat "$out")"
  ADAPTER_ERR="$(cat "$err")"
  ADAPTER_ST=$st
  rm -f "$out" "$err"
}

# Invoke the user bridge via a top-level pipeline (NOT a subshell): each pipeline
# element is forked directly from THIS test shell, so the bridge's $PPID is the
# stable test-shell PID across calls — the same shape as Grok being the bridge's
# stable parent in production. Wrapping in ( … ) would give each call a distinct
# subshell parent and defeat the stable-key assertion.
run_bridge() {
  local payload="$1" out err st
  out="$(mktemp)"; err="$(mktemp)"
  set +e
  printf '%s' "$payload" | "$BRIDGE" >"$out" 2>"$err"
  st=$?
  set -e
  BRIDGE_OUT="$(cat "$out")"
  BRIDGE_ST=$st
  rm -f "$out" "$err"
}

[ -x "$ADAPTER" ] || chmod +x "$ADAPTER"
[ -x "$BRIDGE" ] || chmod +x "$BRIDGE"

# block-hq-glob resolves the HQ root via `git rev-parse --show-toplevel`, which
# reads the *process* cwd. Pin cwd to the repo root so that resolution is
# deterministic (independent of where the test runner was launched).
cd "$ROOT"

file_mtime() {
  if stat -c %Y "$1" >/dev/null 2>&1; then
    stat -c %Y "$1"
  else
    stat -f %m "$1"
  fi
}

echo "== hq-grok-hook-adapter =="

# 1) Bare git push at HQ root → deny (git-mutation guard)
run_adapter '{"hookEventName":"PreToolUse","toolName":"Shell","toolInput":{"command":"git push origin main"},"cwd":"'"$ROOT"'"}'
assert_exit "$ADAPTER_ST" 2 "bare git push denied"
assert_contains "$ADAPTER_OUT" '"decision":"deny"' "deny JSON on git push"
assert_contains "$ADAPTER_OUT$ADAPTER_ERR" "git" "reason mentions git"

# 2) Anchored git in a nested path style command should still be checked by adapter path
#    (block-hq-root-git-mutation allows git -C <non-hq>)
run_adapter '{"hookEventName":"PreToolUse","toolName":"Shell","toolInput":{"command":"git -C /tmp status"},"cwd":"'"$ROOT"'"}'
# may allow (exit 0) — status is not a mutation; mutation hook only blocks mutations
assert_exit "$ADAPTER_ST" 0 "git -C status allowed"
assert_contains "$ADAPTER_OUT" '"decision":"allow"' "allow JSON for harmless bash"

# 3) Sensitive home path in command → deny
run_adapter '{"hookEventName":"PreToolUse","toolName":"Shell","toolInput":{"command":"cat ~/.ssh/id_rsa"},"cwd":"'"$ROOT"'"}'
assert_exit "$ADAPTER_ST" 2 "sensitive ~/.ssh denied"
assert_contains "$ADAPTER_OUT" '"decision":"deny"' "deny JSON for ~/.ssh"

# 4) Write under personal/ → allow (core protect not involved)
run_adapter '{"hookEventName":"PreToolUse","toolName":"Write","toolInput":{"file_path":"'"$ROOT"'/personal/tmp-grok-adapter-test.txt","content":"x"},"cwd":"'"$ROOT"'"}'
assert_exit "$ADAPTER_ST" 0 "write personal allowed"
assert_contains "$ADAPTER_OUT" '"decision":"allow"' "allow JSON for personal write"

# 5) SessionStart is advisory (exit 0, no decision required)
run_adapter '{"hookEventName":"SessionStart","cwd":"'"$ROOT"'"}'
assert_exit "$ADAPTER_ST" 0 "SessionStart exit 0"

# 6) Outside HQ fail-open via bridge when no adapter found
OUTSIDE="$(mktemp -d)"
set +e
out="$(cd "$OUTSIDE" && printf '%s' '{"hookEventName":"PreToolUse","toolName":"Shell","toolInput":{"command":"echo hi"}}' | "$BRIDGE")"
st=$?
set -e
assert_exit "$st" 0 "bridge outside HQ allows"
assert_contains "$out" '"decision":"allow"' "bridge outside HQ allow JSON"
rm -rf "$OUTSIDE"

# 7) Bridge finds adapter inside HQ
set +e
out="$(cd "$ROOT" && printf '%s' '{"hookEventName":"PreToolUse","toolName":"Shell","toolInput":{"command":"git push origin main"},"cwd":"'"$ROOT"'"}' | "$BRIDGE")"
st=$?
set -e
assert_exit "$st" 2 "bridge inside HQ denies bare push"
assert_contains "$out" '"decision":"deny"' "bridge deny JSON"

# 8) Scoped list_dir maps to its target_directory, not a null-pattern root Glob.
#    Regression for harness-analysis 2026-08-10 (13 events): a scoped list_dir
#    was blocked as an "unscoped Glob from HQ root".
run_adapter '{"hookEventName":"PreToolUse","toolName":"list_dir","toolInput":{"target_directory":"'"$ROOT"'/workspace"},"cwd":"'"$ROOT"'"}'
assert_exit "$ADAPTER_ST" 0 "scoped list_dir allowed"
assert_contains "$ADAPTER_OUT" '"decision":"allow"' "allow JSON for scoped list_dir"

# 9) A list_dir whose target IS the HQ root still blocks (guard not defeated).
run_adapter '{"hookEventName":"PreToolUse","toolName":"list_dir","toolInput":{"target_directory":"'"$ROOT"'"},"cwd":"'"$ROOT"'"}'
assert_exit "$ADAPTER_ST" 2 "root list_dir still blocked"
assert_contains "$ADAPTER_OUT" '"decision":"deny"' "deny JSON for root list_dir"

# 10) A genuinely unscoped Glob (pattern only, no path, cwd = HQ root) still blocks.
run_adapter '{"hookEventName":"PreToolUse","toolName":"Glob","toolInput":{"pattern":"**/*.md"},"cwd":"'"$ROOT"'"}'
assert_exit "$ADAPTER_ST" 2 "unscoped root Glob still blocked"
assert_contains "$ADAPTER_OUT" '"decision":"deny"' "deny JSON for unscoped root Glob"

# 10a) A RELATIVE list_dir target that resolves to the HQ root still blocks. The
#      guard compares absolute paths, so "." (relative to cwd = HQ root) must be
#      canonicalized to the root before the guard sees it, not forwarded literally.
run_adapter '{"hookEventName":"PreToolUse","toolName":"list_dir","toolInput":{"target_directory":"."},"cwd":"'"$ROOT"'"}'
assert_exit "$ADAPTER_ST" 2 "relative '.' list_dir at root still blocked"
assert_contains "$ADAPTER_OUT" '"decision":"deny"' "deny JSON for relative '.' root list_dir"

# 10b) A list_dir target containing ".." that resolves to the root still blocks.
run_adapter '{"hookEventName":"PreToolUse","toolName":"list_dir","toolInput":{"target_directory":"workspace/.."},"cwd":"'"$ROOT"'"}'
assert_exit "$ADAPTER_ST" 2 "list_dir 'workspace/..' resolving to root still blocked"
assert_contains "$ADAPTER_OUT" '"decision":"deny"' "deny JSON for '..' root list_dir"

# 10c) A RELATIVE scoped list_dir (resolves under, not to, the root) is allowed.
run_adapter '{"hookEventName":"PreToolUse","toolName":"list_dir","toolInput":{"target_directory":"workspace"},"cwd":"'"$ROOT"'"}'
assert_exit "$ADAPTER_ST" 0 "relative scoped list_dir allowed"
assert_contains "$ADAPTER_OUT" '"decision":"allow"' "allow JSON for relative scoped list_dir"

# 11) Per-session debounce of the advisory policy-injection scan on PreToolUse.
#     Regression for harness-analysis 2026-08-10 (135 events): the bridge added
#     ≥10s per tool call, dominated by inject-policy-on-trigger's re-scan. With a
#     large window the second Bash call inside the window must be debounced (the
#     stamp is not rewritten), while the block hooks still run every call.
DSID="grok-debounce-$$"
STAMP="$ROOT/workspace/orchestrator/hook-state/grok-debounce-inject-policy-on-trigger-${DSID}.stamp"
rm -f "$STAMP"
export HQ_GROK_POLICY_DEBOUNCE_SECS=3600
run_adapter '{"hookEventName":"PreToolUse","toolName":"Shell","toolInput":{"command":"echo hi"},"cwd":"'"$ROOT"'","session_id":"'"$DSID"'"}'
if [ -f "$STAMP" ]; then
  echo "PASS: debounce stamp created on first Bash call"; PASS=$((PASS + 1))
  MT1="$(file_mtime "$STAMP")"
  sleep 2
  run_adapter '{"hookEventName":"PreToolUse","toolName":"Shell","toolInput":{"command":"echo hi again"},"cwd":"'"$ROOT"'","session_id":"'"$DSID"'"}'
  MT2="$(file_mtime "$STAMP")"
  if [ "$MT1" = "$MT2" ]; then
    echo "PASS: second Bash call within window is debounced (scan skipped)"; PASS=$((PASS + 1))
  else
    echo "FAIL: second Bash call re-ran the policy scan (stamp rewritten $MT1 -> $MT2)" >&2; FAIL=$((FAIL + 1))
  fi
else
  echo "FAIL: debounce stamp not created on first Bash call" >&2; FAIL=$((FAIL + 1))
fi
unset HQ_GROK_POLICY_DEBOUNCE_SECS
rm -f "$STAMP"

# 12) Debounce disabled (=0) runs every call and writes no debounce stamp.
DSID0="grok-nodebounce-$$"
STAMP0="$ROOT/workspace/orchestrator/hook-state/grok-debounce-inject-policy-on-trigger-${DSID0}.stamp"
rm -f "$STAMP0"
export HQ_GROK_POLICY_DEBOUNCE_SECS=0
run_adapter '{"hookEventName":"PreToolUse","toolName":"Shell","toolInput":{"command":"echo hi"},"cwd":"'"$ROOT"'","session_id":"'"$DSID0"'"}'
if [ ! -f "$STAMP0" ]; then
  echo "PASS: debounce disabled writes no stamp (runs every call)"; PASS=$((PASS + 1))
else
  echo "FAIL: debounce disabled but stamp was written" >&2; FAIL=$((FAIL + 1))
fi
unset HQ_GROK_POLICY_DEBOUNCE_SECS
rm -f "$STAMP0"

# 13) Timeout ceiling raised so a legitimate slow scan is not killed (Item 1).
if grep -q '"timeout": 120' "$ROOT/.grok/hooks/hq-grok-user-bridge.json"; then
  echo "PASS: bridge PreToolUse timeout raised to 120s"; PASS=$((PASS + 1))
else
  echo "FAIL: bridge PreToolUse timeout not raised" >&2; FAIL=$((FAIL + 1))
fi

# 14) The debounce holds across the USER-BRIDGE path even with no session id in
#     the payload. The bridge exports a stable fallback session key derived from
#     its Grok parent, so two consecutive bridge calls share one debounce stamp
#     (otherwise every bridge call re-runs the ~2-4s scan — the exact latency the
#     analysis reported on the global bridge path).
STATE_DIR="$ROOT/workspace/orchestrator/hook-state"
mkdir -p "$STATE_DIR"
rm -f "$STATE_DIR"/grok-debounce-inject-policy-on-trigger-grok-bridge-*.stamp 2>/dev/null || true
export HQ_GROK_POLICY_DEBOUNCE_SECS=3600
run_bridge '{"hookEventName":"PreToolUse","toolName":"Shell","toolInput":{"command":"echo hi"},"cwd":"'"$ROOT"'"}'
BSTAMP="$(ls -t "$STATE_DIR"/grok-debounce-inject-policy-on-trigger-grok-bridge-*.stamp 2>/dev/null | head -1 || true)"
if [ -n "$BSTAMP" ] && [ -f "$BSTAMP" ]; then
  echo "PASS: bridge path created a stable-key debounce stamp"; PASS=$((PASS + 1))
  BMT1="$(file_mtime "$BSTAMP")"
  sleep 2
  run_bridge '{"hookEventName":"PreToolUse","toolName":"Shell","toolInput":{"command":"echo hi again"},"cwd":"'"$ROOT"'"}'
  BMT2="$(file_mtime "$BSTAMP")"
  if [ "$BMT1" = "$BMT2" ]; then
    echo "PASS: second bridge call shares the debounce key (scan skipped)"; PASS=$((PASS + 1))
  else
    echo "FAIL: bridge calls used different keys; debounce defeated ($BMT1 -> $BMT2)" >&2; FAIL=$((FAIL + 1))
  fi
else
  echo "FAIL: bridge path did not create a stable-key debounce stamp" >&2; FAIL=$((FAIL + 1))
fi
unset HQ_GROK_POLICY_DEBOUNCE_SECS
rm -f "$STATE_DIR"/grok-debounce-inject-policy-on-trigger-grok-bridge-*.stamp 2>/dev/null || true

# Leave the checkout clean: remove the runtime hook-state dir if the test emptied
# it (it is also gitignored, so residue never dirties a checkout regardless).
rmdir "$STATE_DIR" 2>/dev/null || true

echo
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
