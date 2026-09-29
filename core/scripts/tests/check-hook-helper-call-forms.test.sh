#!/usr/bin/env bash
set -euo pipefail

# The checker distinguishes executable calls, bash-invoked helpers, and
# presence-only guards. A case selector lets each form run as an independent
# negative control against an older or deliberately mutated checker.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
CASE="${1:-all}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FIX="$TMP/hq"
BIN="$TMP/bin"
SOURCE_CHECKER="${HOOK_CHECKER_SOURCE:-$ROOT/core/scripts/check-hq-hooks.sh}"
mkdir -p "$FIX/.claude/hooks" "$FIX/core/scripts/lib" "$BIN" "$TMP/home"
cp "$SOURCE_CHECKER" "$FIX/core/scripts/check-hq-hooks.sh"
cp "$ROOT/core/scripts/lib/hook-command-scan.sh" "$ROOT/core/scripts/lib/hq-cli-floor.sh" \
  "$FIX/core/scripts/lib/"
CHECKER="$FIX/core/scripts/check-hq-hooks.sh"
printf 'requiresHqCli: ">=1.0.0"\n' > "$FIX/core/core.yaml"
cat > "$FIX/.claude/settings.json" <<'JSON'
{"hooks":{
  "SessionStart":[{"hooks":[{"type":"command","command":"echo session"}]}],
  "PreToolUse":[{"hooks":[{"type":"command","command":"echo tool"}]}]
}}
JSON
cat > "$FIX/.claude/hooks/hook-registry.json" <<'JSON'
{"entries":[
  {"script":".claude/hooks/inject-policy-on-trigger.sh"},
  {"script":".claude/hooks/session-title.sh"}
]}
JSON

for helper in \
  derive-trigger-facts eval-trigger session-title session-title-config \
  session-project session-journal share-suggestion-state repo-run-registry \
  detect-stale-review-base register-project migrate-policy-triggers work-mesh-live-rebind; do
  printf '#!/usr/bin/env bash\nexit 0\n' > "$FIX/core/scripts/$helper.sh"
  chmod +x "$FIX/core/scripts/$helper.sh"
done

cat > "$BIN/hq" <<'HQ'
#!/usr/bin/env bash
if [ "${1:-}" = "--version" ]; then
  printf '%s\n' "${HQ_TEST_VERSION:-99.0.0}"
  exit 0
fi
exit 1
HQ
chmod +x "$BIN/hq"

run_check() {
  local version="$1" output rc
  if output="$(env -u HQ_ROOT -u CLAUDE_PROJECT_DIR \
    PATH="$BIN:/usr/bin:/bin" HOME="$TMP/home" XDG_CACHE_HOME="$TMP/cache" \
    HQ_TEST_VERSION="$version" bash "$CHECKER" --root "$FIX" 2>&1)"; then
    rc=0
  else
    rc=$?
  fi
  printf '%s\n%s' "$rc" "$output"
}

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf '  ok: %s\n' "$*"; }
should_run() { [ "$CASE" = "all" ] || [ "$CASE" = "$1" ]; }
case "$CASE" in
  all|bash-non-executable|bash-missing|bash-floor|guard-floor|guard-missing) ;;
  *) fail "unknown call-form case: $CASE" ;;
esac

if should_run bash-non-executable; then
  chmod 644 "$FIX/core/scripts/derive-trigger-facts.sh"
  result="$(run_check 99.0.0)"
  rc="${result%%$'\n'*}"
  output="${result#*$'\n'}"
  [ "$rc" = 0 ] || fail "bash-invoked helper with no executable bit should pass: $output"
  [[ "$output" == *'HQ hook health: PASS'* ]] || fail "bash-invoked helper with no executable bit should not be reported: $output"
  pass "bash-invoked helper does not require executable mode"
fi

if should_run bash-missing; then
  rm "$FIX/core/scripts/derive-trigger-facts.sh"
  result="$(run_check 99.0.0)"
  rc="${result%%$'\n'*}"
  output="${result#*$'\n'}"
  [ "$rc" = 2 ] || fail "a missing bash-invoked helper should fail the checker: $output"
  [[ "$output" == *'hook .claude/hooks/inject-policy-on-trigger.sh cannot run helper core/scripts/derive-trigger-facts.sh because it is missing'* ]] \
    || fail "the missing bash-invoked helper was not attributed to its hook: $output"
  pass "bash-invoked call still reports a missing file"
fi

if should_run bash-floor; then
  cat > "$FIX/core/scripts/derive-trigger-facts.sh" <<'FLOOR'
#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib/hq-cli-floor.sh"
hq_cli_floor_check "derive-trigger-facts.sh" "5.78.0"
FLOOR
  chmod +x "$FIX/core/scripts/derive-trigger-facts.sh"
  result="$(run_check 1.0.0)"
  rc="${result%%$'\n'*}"
  output="${result#*$'\n'}"
  [ "$rc" = 2 ] || fail "a bash-invoked helper's failing CLI floor should fail the checker: $output"
  [[ "$output" == *'hook .claude/hooks/inject-policy-on-trigger.sh cannot run helper core/scripts/derive-trigger-facts.sh: derive-trigger-facts.sh: this script needs hq-cli >= 5.78.0 (found 1.0.0)'* ]] \
    || fail "a bash-invoked helper's CLI-floor failure was not attributed to its hook: $output"
  pass "bash-invoked call still checks a generated CLI floor"
fi

if should_run guard-floor; then
  printf '#!/usr/bin/env bash\nexit 0\n' > "$FIX/core/scripts/derive-trigger-facts.sh"
  chmod +x "$FIX/core/scripts/derive-trigger-facts.sh"
  cat > "$FIX/core/scripts/session-title-config.sh" <<'FLOOR'
#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib/hq-cli-floor.sh"
hq_cli_floor_check "session-title-config.sh" "5.78.0"
FLOOR
  chmod +x "$FIX/core/scripts/session-title-config.sh"
  result="$(run_check 1.0.0)"
  rc="${result%%$'\n'*}"
  output="${result#*$'\n'}"
  [ "$rc" = 0 ] || fail "a guard-only helper's CLI floor should not affect the checker: $output"
  [[ "$output" != *'session-title-config.sh'* ]] || fail "a guard-only helper's CLI floor was reported: $output"
  pass "guard-only call does not check executable mode or CLI floor"
fi

if should_run guard-missing; then
  rm "$FIX/core/scripts/session-title-config.sh"
  result="$(run_check 99.0.0)"
  rc="${result%%$'\n'*}"
  output="${result#*$'\n'}"
  [ "$rc" = 2 ] || fail "a missing guard-only helper should fail the checker: $output"
  [[ "$output" == *'hook .claude/hooks/session-title.sh cannot run helper core/scripts/session-title-config.sh because it is missing'* ]] \
    || fail "the missing guard-only helper was not attributed to its hook: $output"
  pass "guard-only call still reports a missing file"
fi

echo "PASS: hook helper call forms ($CASE)"
