#!/usr/bin/env bash
# hq-core: public
# Regression: hq_bash_strip_core_yaml_exclude_tokens must not spawn sed once
# per core.yaml rules.exclude entry, and the guard must keep blocking protected
# writes even when sed is unavailable.
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
LIB="$ROOT/core/scripts/hook-lib.sh"
HOOK="$ROOT/.claude/hooks/block-core-writes-bash.sh"
[ -f "$LIB" ] || { echo "FAIL: hook-lib.sh missing at $LIB" >&2; exit 1; }
[ -f "$HOOK" ] || { echo "FAIL: hook missing at $HOOK" >&2; exit 1; }

# shellcheck source=core/scripts/hook-lib.sh
. "$LIB"

PASS=0
FAIL=0
pass() { printf '  ok   %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '  FAIL %s\n' "$1" >&2; FAIL=$((FAIL + 1)); }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/hook-lib-strip-exclude.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# --- a long command token stays inside the core-write hook's hot-path budget --
printf -v long_token '%20000s' ''
long_token="${long_token// /x}"
long_command="echo $long_token && true"
SECONDS=0
long_token_result="$(hq_strip_tokens_containing_literals "$long_command" /never-present)"
long_token_seconds="$SECONDS"
if [ "$long_token_result" != "$long_command" ]; then
  fail '20 KB token or its surrounding command text changed when no needle matched'
elif [ "$long_token_seconds" -ge 10 ]; then
  fail "20 KB token scan exceeded the 10-second hook budget (${long_token_seconds}s)"
else
  pass "20 KB token scan completed within the 10-second hook budget (${long_token_seconds}s)"
fi

empty_needle_command='echo keep-this | cat'
empty_needle_result="$(hq_strip_tokens_containing_literals "$empty_needle_command" '')"
if [ "$empty_needle_result" = "$empty_needle_command" ]; then
  pass 'empty exclude needle leaves the command unchanged'
else
  fail 'empty exclude needle changed the command'
fi

mkdir -p "$TMP/hq/core" "$TMP/bins"
CMD='rm -rf core/ && echo x > .claude/settings.local.json'

# Stub mikefarah-style `yq eval '.rules.exclude[]'` so this suite does not
# depend on yq being installed (the bug only fires when yq *is* present).
cat > "$TMP/bins/yq" <<'EOF'
#!/bin/sh
yaml=""
for arg in "$@"; do
  yaml="$arg"
done
[ -n "$yaml" ] && [ -f "$yaml" ] || exit 0
awk '
  /^[[:space:]]*-[[:space:]]+/ {
    line = $0
    sub(/^[[:space:]]*-[[:space:]]+/, "", line)
    sub(/[[:space:]]+#.*$/, "", line)
    sub(/[[:space:]]+$/, "", line)
    if (line != "") print line
  }
' "$yaml"
EOF
chmod +x "$TMP/bins/yq"

REAL_SED="$(command -v sed)"
export HQ_TEST_SED_CALLS="$TMP/sed-calls"
export HQ_TEST_REAL_SED="$REAL_SED"
: > "$HQ_TEST_SED_CALLS"
cat > "$TMP/bins/sed" <<'EOF'
#!/bin/sh
printf 'sed\n' >> "$HQ_TEST_SED_CALLS"
exec "$HQ_TEST_REAL_SED" "$@"
EOF
chmod +x "$TMP/bins/sed"

write_excludes() {
  local n="$1" yaml="$2" i=1
  {
    printf 'rules:\n  exclude:\n'
    while [ "$i" -le "$n" ]; do
      printf '    - .claude/exclude-%02d.dat\n' "$i"
      i=$((i + 1))
    done
  } > "$yaml"
}

# --- 40 exclude entries: Bash stripping keeps protected tokens, no sed -----
write_excludes 40 "$TMP/hq/core/core.yaml"
errfile="$TMP/many.err"
out="$(
  PATH="$TMP/bins:$PATH"
  hq_bash_strip_core_yaml_exclude_tokens "$CMD" "$TMP/hq" "$TMP/hq/core/core.yaml" 2>"$errfile"
)" || true
if [ -z "$out" ]; then
  fail '40 excludes: helper returned empty (fail-open)'
elif ! printf '%s' "$out" | grep -q 'core/'; then
  fail '40 excludes: stripped command lost the protected core/ token'
else
  pass '40 excludes: helper keeps protected tokens'
fi
if [ -s "$HQ_TEST_SED_CALLS" ]; then
  fail '40 excludes: helper spawned sed'
else
  pass '40 excludes: helper did not spawn sed'
fi
if grep -q '^sed:' "$errfile"; then
  fail '40 excludes: sed stderr leaked'
else
  pass '40 excludes: no sed stderr leak'
fi

allow_cmd='echo x > .claude/exclude-01.dat'
allow_out="$(
  PATH="$TMP/bins:$PATH"
  hq_bash_strip_core_yaml_exclude_tokens "$allow_cmd" "$TMP/hq" "$TMP/hq/core/core.yaml" 2>/dev/null
)" || true
if printf '%s' "$allow_out" | grep -q 'exclude-01'; then
  fail 'successful strip still left the exclude path in the command'
else
  pass 'successful strip still honours rules.exclude'
fi

# --- sed unavailable must not affect literal token stripping ---------------
cat > "$TMP/bins/sed" <<'EOF'
#!/bin/sh
echo 'sed: intentionally unavailable' >&2
exit 127
EOF
chmod +x "$TMP/bins/sed"

write_excludes 10 "$TMP/hq/core/core.yaml"
errfile="$TMP/fail.err"
allow_and_protected='echo x > .claude/exclude-01.dat && rm -rf core/'
out="$(
  PATH="$TMP/bins:$PATH"
  hq_bash_strip_core_yaml_exclude_tokens "$allow_and_protected" "$TMP/hq" "$TMP/hq/core/core.yaml" 2>"$errfile"
)" || true
if printf '%s' "$out" | grep -q 'exclude-01'; then
  fail 'sed unavailable: excluded path token was not stripped'
else
  pass 'sed unavailable: excluded path token is stripped'
fi
if ! printf '%s' "$out" | grep -q 'core/'; then
  fail 'sed unavailable: stripping lost the protected core/ token'
else
  pass 'sed unavailable: protected core/ token remains'
fi
if grep -q '^sed:' "$errfile"; then
  fail 'sed unavailable: unexpected sed invocation leaked stderr'
else
  pass 'sed unavailable: no sed invocation leaked stderr'
fi

# --- hook: unavailable sed must still block a core/ write -----------------
if command -v jq >/dev/null 2>&1; then
  FIX="$TMP/live"
  mkdir -p "$FIX/.claude" "$FIX/core"
  printf '{}' > "$FIX/.claude/settings.local.json"
  write_excludes 40 "$FIX/core/core.yaml"
  payload="$(jq -n --arg cmd "echo x > $FIX/core/FAILOPEN-PROBE.txt" '{tool_input: {command: $cmd}}')"
  rc=0
  errfile="$TMP/hook.err"
  printf '%s' "$payload" | CLAUDE_PROJECT_DIR="$FIX" PATH="$TMP/bins:$PATH" bash "$HOOK" >/dev/null 2>"$errfile" || rc=$?
  if [ "$rc" -eq 2 ]; then
    pass 'hook blocks core/ write when sed is unavailable'
  else
    fail "hook fail-open: expected exit 2, got $rc"
  fi
  if grep -q '^sed:' "$errfile"; then
    fail 'hook unexpectedly invoked sed'
  else
    pass 'hook does not invoke sed'
  fi

  # Same hook, real sed, 40 excludes; it must remain blocked.
  rm -f "$TMP/bins/sed"
  rc=0
  payload="$(jq -n --arg cmd "rm -rf $FIX/core/" '{tool_input: {command: $cmd}}')"
  printf '%s' "$payload" | CLAUDE_PROJECT_DIR="$FIX" PATH="$TMP/bins:$PATH" bash "$HOOK" >/dev/null 2>"$errfile" || rc=$?
  if [ "$rc" -eq 2 ]; then
    pass 'hook blocks rm -rf core/ with 40 exclude entries'
  else
    fail "40 excludes: hook expected exit 2 for rm -rf core/, got $rc"
  fi
else
  echo "SKIP: hook integration (jq not available)"
fi

echo "hook-lib-strip-exclude-tokens: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
