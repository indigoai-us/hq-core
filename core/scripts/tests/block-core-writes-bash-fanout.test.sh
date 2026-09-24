#!/usr/bin/env bash
# hq-core: public
# Regression: the Bash write guard must classify a protected target without
# spawning sed/grep once per path or token. Wired into pr-checks.yml's
# core-write-protection job because these shell tests are explicitly enumerated.
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
HOOK="$ROOT/.claude/hooks/block-core-writes-bash.sh"
. "$ROOT/core/scripts/hook-lib.sh"
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not available"; exit 0; }

TMP_BASE="$(mktemp -d "${TMPDIR:-/tmp}/block-core-fanout.XXXXXX")"
TMP="${TMP_BASE%/*}//${TMP_BASE##*/}"
trap 'rm -rf "$TMP"' EXIT
FIX="$TMP/hq+(fanout-fixture)"
BIN="$TMP/bin"
mkdir -p "$FIX/.claude" "$FIX/core" "$BIN"
printf '{}' > "$FIX/.claude/settings.local.json"
fixture_command="touch \"$FIX/core/protected.txt\""
normalized_fixture_root="$(hq_normpath "$FIX")"
expected_record="touch"$'\037'"$FIX/core/protected.txt"
parsed_record="$(hq_shell_simple_commands "$fixture_command")"
parsed_record_display="${parsed_record//$'\037'/<US>}"
if [ "$parsed_record" != "$expected_record" ]; then
  printf 'FAIL: shell parser changed protected target on %s Bash %s; root=%s parsed=%s\n' \
    "$(uname -s)" "$BASH_VERSION" "$FIX" "$parsed_record_display" >&2
  exit 1
fi
REAL_BASH="$(command -v bash)"
REAL_GREP="$(command -v grep)"
REAL_SED="$(command -v sed)"
if "$REAL_GREP" -Fq 'CORE_ABS_ESC' "$HOOK"; then
  echo 'FAIL: absolute project roots must not be interpolated into EREs' >&2
  exit 1
fi
if ! "$REAL_GREP" -Fq 'absolute_root_path_matches' "$HOOK"; then
  echo 'FAIL: guard does not perform literal absolute-root matching' >&2
  exit 1
fi
export HQ_TEST_GREP_CALLS="$TMP/grep-calls"
export HQ_TEST_SED_CALLS="$TMP/sed-calls"
export HQ_TEST_REAL_GREP="$REAL_GREP"
export HQ_TEST_REAL_SED="$REAL_SED"
: > "$HQ_TEST_GREP_CALLS"
: > "$HQ_TEST_SED_CALLS"
cat > "$BIN/grep" <<'EOF'
#!/bin/sh
printf 'grep\n' >> "$HQ_TEST_GREP_CALLS"
exec "$HQ_TEST_REAL_GREP" "$@"
EOF
cat > "$BIN/sed" <<'EOF'
#!/bin/sh
printf 'sed\n' >> "$HQ_TEST_SED_CALLS"
exec "$HQ_TEST_REAL_SED" "$@"
EOF
chmod +x "$BIN/grep" "$BIN/sed"

payload="$(jq -n --arg cmd "$fixture_command" '{tool_input: {command: $cmd}}')"
errfile="$TMP/hook.err"
rc=0
printf '%s' "$payload" | env \
  CLAUDE_PROJECT_DIR="$FIX" \
  PATH="$BIN:$PATH" \
  "$REAL_BASH" "$HOOK" >/dev/null 2>"$errfile" || rc=$?

if [ "$rc" -ne 2 ]; then
  printf 'FAIL: protected write expected exit 2, got %s on %s Bash %s; root=%s normalized=%s\n' \
    "$rc" "$(uname -s)" "$BASH_VERSION" "$FIX" "$normalized_fixture_root" >&2
  [ ! -s "$errfile" ] || { printf 'guard stderr:\n' >&2; cat "$errfile" >&2; }
  tracefile="$TMP/hook.xtrace"
  trace_rc=0
  printf '%s' "$payload" | env \
    CLAUDE_PROJECT_DIR="$FIX" \
    PATH="$BIN:$PATH" \
    "$REAL_BASH" -x "$HOOK" >/dev/null 2>"$tracefile" || trace_rc=$?
  printf 'guard trace (exit=%s):\n' "$trace_rc" >&2
  "$REAL_GREP" -E 'PROJECT_DIR=|CORE_ABS=|token_re=|targets\[|write_targets_match|target_matches_re|raw_token_matches_re|absolute_root_path_matches|WRITE_TARGET' \
    "$tracefile" >&2 || true
  exit 1
fi

grep_calls="$(wc -l < "$HQ_TEST_GREP_CALLS" | tr -d '[:space:]')"
sed_calls="$(wc -l < "$HQ_TEST_SED_CALLS" | tr -d '[:space:]')"
if [ "$grep_calls" -gt 2 ] || [ "$sed_calls" -gt 2 ]; then
  echo "FAIL: guard process fanout too high (grep=$grep_calls sed=$sed_calls)" >&2
  exit 1
fi
if "$REAL_GREP" -Eq '^(grep|sed):' "$errfile"; then
  echo "FAIL: guard leaked grep/sed diagnostics" >&2
  exit 1
fi

printf 'block-core-writes-bash-fanout: protected write blocked; platform=%s bash=%s grep=%s sed=%s\n' \
  "$(uname -s)" "${BASH_VERSION%%(*}" "$grep_calls" "$sed_calls"
