#!/usr/bin/env bash
# hq-core: public
# Regression: hq_bash_strip_core_yaml_exclude_tokens must not fail open.
#
# On macOS, a long semicolon-joined sed script (one expression per
# core.yaml rules.exclude entry) errors ("unbalanced brackets" /
# "unterminated substitute"). The helper used to return empty stdout, and
# block-core-writes-bash then treated the command as touching no protected
# paths. A helper that cannot strip must hand back the original command.
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

# --- 40 exclude entries: sed must succeed and keep protected tokens --------
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

# --- sed failure must return the original command, not empty ---------------
REAL_SED="$(command -v sed)"
cat > "$TMP/bins/sed" <<EOF
#!/bin/sh
for arg in "\$@"; do
  case "\$arg" in
    *'s|[^[:space:]]*'*)
      echo 'sed: 1: "s|[^[:space:]]*...": unbalanced brackets ([])' >&2
      exit 1
      ;;
  esac
done
exec $REAL_SED "\$@"
EOF
chmod +x "$TMP/bins/sed"

write_excludes 10 "$TMP/hq/core/core.yaml"
errfile="$TMP/fail.err"
out="$(
  PATH="$TMP/bins:$PATH"
  hq_bash_strip_core_yaml_exclude_tokens "$CMD" "$TMP/hq" "$TMP/hq/core/core.yaml" 2>"$errfile"
)" || true
if [ "$out" != "$CMD" ]; then
  fail "sed failure: expected original command, got: ${out:-<empty>}"
else
  pass 'sed failure: helper returns the original command'
fi
if grep -q '^sed:' "$errfile"; then
  fail 'sed failure: sed stderr leaked'
else
  pass 'sed failure: no sed stderr leak'
fi

# --- hook: failing strip must still block a core/ write --------------------
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
    pass 'hook blocks core/ write when strip sed fails'
  else
    fail "hook fail-open: expected exit 2, got $rc"
  fi
  if grep -q '^sed:' "$errfile"; then
    fail 'hook leaked a sed error on stderr'
  else
    pass 'hook does not leak sed stderr'
  fi

  # Same hook, real sed, 40 excludes (BSD growth trigger).
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
