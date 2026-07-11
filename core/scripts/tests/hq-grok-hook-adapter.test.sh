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

[ -x "$ADAPTER" ] || chmod +x "$ADAPTER"
[ -x "$BRIDGE" ] || chmod +x "$BRIDGE"

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

echo
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
