#!/usr/bin/env bash
# Isolated regressions for chained and unresolved protected write targets.
set -euo pipefail

ROOT="$(git -C "$PWD" rev-parse --show-toplevel)"
HOOK="$ROOT/.claude/hooks/block-core-writes-bash.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

command -v jq >/dev/null 2>&1 || { echo 'FAIL: jq is required' >&2; exit 1; }

mkdir -p "$TMP/.claude" "$TMP/core"
PASS=0
FAIL=0

run() {
  local expect="$1" cmd="$2" label="$3" rc=0 payload errfile err
  payload="$(jq -n --arg cmd "$cmd" '{tool_input: {command: $cmd}}')"
  errfile="$(mktemp)"
  printf '%s' "$payload" | CLAUDE_PROJECT_DIR="$TMP" bash "$HOOK" >/dev/null 2>"$errfile" || rc=$?
  err="$(cat "$errfile")"
  rm -f "$errfile"
  if [[ "$rc" -eq "$expect" ]]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    printf 'FAIL [%s]: expected exit %s, got %s\n' "$label" "$expect" "$rc" >&2
  fi
  if [[ "$err" == *'grep: warning'* ]]; then
    FAIL=$((FAIL + 1))
    printf 'FAIL [%s]: hook leaked grep warning on stderr\n' "$label" >&2
  else
    PASS=$((PASS + 1))
  fi
}

run 2 'C=core; D=$C; echo x > "$D/file"' \
  'chained assignment from bare core root + redirect blocked'
run 2 'C=core; D="$C"; echo x > "$D/file"' \
  'quoted chained assignment from bare core root + redirect blocked'
run 2 'C=core; D=${C}; echo x > "$D/file"' \
  'braced chained assignment from bare core root + redirect blocked'
run 2 'C=core; D="${C}/sub"; echo x > "$D/file"' \
  'braced chained assignment with suffix + redirect blocked'
run 0 'D="$(resolve-path)"; echo core/file > "$D/file"' \
  'protected-looking command output does not classify an unrelated target'
run 2 'D="$(echo core)"; echo x > "$D/file"' \
  'quoted protected-root command substitution blocked'
run 2 'D=$(echo core); echo x > "$D/file"' \
  'unquoted protected-root command substitution blocked'
run 0 'D="$(resolve-path)"; echo x > "$D/file"' \
  'unresolved expansion without protected path hint allowed'
run 0 'OUT="$HOME/output.txt"; echo x > "$OUT"' \
  'unprotected environment expansion remains writable'
run 0 'OUT="$(mktemp)"; echo hi > "$OUT"' \
  'mktemp file target remains writable'
run 0 'TMP="$(mktemp -d)"; cp a.txt "$TMP/"' \
  'mktemp directory target remains writable'
run 0 'ROOT="$(git rev-parse --show-toplevel)"; echo x >> "$ROOT/workspace/log.md"' \
  'git repository root target remains writable'
run 0 'F=`mktemp`; date > $F' \
  'backtick mktemp target remains writable'

printf 'block-core-writes-bash-chained-vars: %s passed, %s failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
