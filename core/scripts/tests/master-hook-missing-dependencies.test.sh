#!/usr/bin/env bash
# Missing dispatcher dependencies must never silently skip permission guards.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/hq/.claude/hooks" "$TMP/hq/core/scripts/lib" "$TMP/bin"
cp "$ROOT/.claude/hooks/master-hook.sh" "$ROOT/.claude/hooks/hook-timeout-probe.sh" "$ROOT/.claude/hooks/hook-gate.sh" "$TMP/hq/.claude/hooks/"
cp "$ROOT/core/scripts/lib/hook-adapter-core.sh" "$TMP/hq/core/scripts/lib/"
# An isolated PATH makes the absence real, including on developer machines with
# Homebrew jq. These installed tool markers keep the real PATH augmentation
# fast path from discovering host-specific directories outside the fixture.
for tool in node hq qmd; do ln -s /usr/bin/true "$TMP/bin/$tool"; done
for tool in bash awk cat date env mkdir mktemp mv rm tr sleep; do
  ln -s "$(command -v "$tool")" "$TMP/bin/$tool"
done
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
run_case() {
  local event="$1" missing="$2" want="$3" rc=0 started=$SECONDS
  printf '%s' '{"session_id":"missing-dependency","tool_name":"Bash","tool_input":{"command":"true"}}' |
    env PATH="$TMP/bin" HQ_HOOK_TIMEOUT_SENTRY=0 HQ_HOOK_DEDUPE=0 \
      /bin/bash "$TMP/hq/.claude/hooks/master-hook.sh" "$event" > "$TMP/out" 2> "$TMP/err" || rc=$?
  printf '%s missing %s: exit=%s stdout=%s stderr=%s\n' "$event" "$missing" "$rc" "$(cat "$TMP/out")" "$(cat "$TMP/err")"
  [ "$rc" = "$want" ] || fail "$event expected $want, got $rc"
  [ ! -s "$TMP/out" ] || fail 'unexpected stdout'
  grep -q "$missing" "$TMP/err" || fail 'missing dependency not named'
  grep -qi install "$TMP/err" || fail 'missing installation guidance'
  [ "$((SECONDS - started))" -lt 5 ] || fail 'dependency failure took five seconds or more'
  [ "$(wc -l < "$TMP/err" | tr -d ' ')" = 1 ] || fail 'expected one diagnostic line'
}
run_case PreToolUse jq 2
for event in SessionStart UserPromptSubmit PostToolUse Stop; do run_case "$event" jq 0; done
ln -s "$(command -v jq)" "$TMP/bin/jq"
for tool in bash awk cat date env mkdir mktemp mv rm tr; do
  rm "$TMP/bin/$tool"
  run_case PreToolUse "$tool" 2
  ln -s "$(command -v "$tool")" "$TMP/bin/$tool"
done
# Healthy PATH still dispatches a real directory guard and preserves its deny.
mkdir -p "$TMP/hq/core/hooks/PreToolUse"
printf '#!/bin/bash\nprintf "guard-denied\\n" >&2\nexit 2\n' > "$TMP/hq/core/hooks/PreToolUse/10-deny.sh"
chmod +x "$TMP/hq/core/hooks/PreToolUse/10-deny.sh"
rc=0
printf '%s' '{"tool_name":"Bash","tool_input":{"command":"true"}}' |
  env PATH="$TMP/bin" HQ_HOOK_TIMEOUT_SENTRY=0 HQ_HOOK_DEDUPE=0 \
  /bin/bash "$TMP/hq/.claude/hooks/master-hook.sh" PreToolUse > "$TMP/out" 2> "$TMP/err" || rc=$?
[ "$rc" = 2 ] || fail "healthy dispatch lost guard deny: $rc"
grep -q guard-denied "$TMP/err" || fail 'healthy dispatch skipped guard'
if grep -q 'required tool' "$TMP/err"; then fail 'healthy dispatch rejected dependencies'; fi
echo 'ALL PASS: master-hook-missing-dependencies'
