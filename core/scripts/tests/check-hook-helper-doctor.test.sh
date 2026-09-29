#!/usr/bin/env bash
set -euo pipefail

# Synthetic-root coverage for the Wave 8 helper availability checks.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
SOURCE_CHECKER="$ROOT/core/scripts/check-hq-hooks.sh"
FIX="$TMP/hq"
BIN="$TMP/bin"
mkdir -p "$FIX/.claude/hooks" "$FIX/core/scripts/lib" "$FIX/core/hooks/SessionStart" \
  "$FIX/core/hooks/Stop" "$BIN" "$TMP/home"
cp "$SOURCE_CHECKER" "$FIX/core/scripts/check-hq-hooks.sh"
CHECKER="$FIX/core/scripts/check-hq-hooks.sh"
cp "$ROOT/core/scripts/lib/hook-command-scan.sh" "$ROOT/core/scripts/lib/hq-cli-floor.sh" \
  "$FIX/core/scripts/lib/"
printf 'requiresHqCli: ">=1.0.0"\n' > "$FIX/core/core.yaml"

cat > "$FIX/.claude/settings.json" <<'JSON'
{"hooks":{
  "SessionStart":[{"hooks":[{"type":"command","command":"echo session-start"}]}],
  "PreToolUse":[{"hooks":[{"type":"command","command":"echo pre-tool"}]}]
}}
JSON

cat > "$FIX/.claude/hooks/hook-registry.json" <<'JSON'
{"entries":[
  {"script":".claude/hooks/block-on-active-run.sh"},
  {"script":".claude/hooks/check-repo-active-runs.sh"},
  {"script":".claude/hooks/hq-auto-acl-suggest.sh"},
  {"script":".claude/hooks/inject-policy-on-trigger.sh"},
  {"script":".claude/hooks/journal-due.sh"},
  {"script":".claude/hooks/journal-precompact.sh"},
  {"script":".claude/hooks/native-plan-project-sync.sh"},
  {"script":".claude/hooks/repair-stale-review-base.sh"},
  {"script":".claude/hooks/session-title.sh"},
  {"script":".claude/hooks/validate-policy-frontmatter.sh"},
  {"script":"core/scripts/migrate-policy-triggers.sh"}
]}
JSON

for hook in \
  .claude/hooks/block-on-active-run.sh \
  .claude/hooks/check-repo-active-runs.sh \
  .claude/hooks/hq-auto-acl-suggest.sh \
  .claude/hooks/inject-policy-on-trigger.sh \
  .claude/hooks/journal-due.sh \
  .claude/hooks/journal-precompact.sh \
  .claude/hooks/native-plan-project-sync.sh \
  .claude/hooks/repair-stale-review-base.sh \
  .claude/hooks/session-title.sh \
  .claude/hooks/validate-policy-frontmatter.sh \
  core/hooks/SessionStart/35-work-mesh-session-start.sh \
  core/hooks/Stop/40-auto-acl-share-suggestion.sh \
  core/hooks/Stop/50-after-turn-suggestions.sh; do
  mkdir -p "$FIX/$(dirname "$hook")"
  : > "$FIX/$hook"
done

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

result="$(run_check 99.0.0)"
rc="${result%%$'\n'*}"
output="${result#*$'\n'}"
[ "$rc" = 0 ] || fail "all registered helpers present should pass: $output"
[[ "$output" == *'HQ hook health: PASS'* ]] || fail "healthy helper set did not pass: $output"
pass "all registered helpers present"

migrate_entry="$FIX/core/scripts/migrate-policy-triggers.sh"
mv "$migrate_entry" "$migrate_entry.missing"
result="$(run_check 99.0.0)"
rc="${result%%$'\n'*}"
output="${result#*$'\n'}"
[ "$rc" = 2 ] || fail "a missing registered helper entry should fail: $output"
[[ "$output" == *'hook core/scripts/migrate-policy-triggers.sh cannot run helper core/scripts/migrate-policy-triggers.sh because it is missing'* ]] \
  || fail "missing migration entry was not attributed to its registration: $output"
mv "$migrate_entry.missing" "$migrate_entry"
pass "a missing registered helper entry is reported"

rm "$FIX/core/scripts/share-suggestion-state.sh"
result="$(run_check 99.0.0)"
rc="${result%%$'\n'*}"
output="${result#*$'\n'}"
[ "$rc" = 2 ] || fail "a missing registered helper should fail: $output"
missing_count="$(printf '%s\n' "$output" | grep -F -c 'cannot run helper core/scripts/share-suggestion-state.sh because it is missing' || true)"
[ "$missing_count" = 3 ] || fail "expected one missing-helper line for each registered caller, found $missing_count: $output"
pass "one missing helper reports each of its three registered hooks"

printf '#!/usr/bin/env bash\nexit 0\n' > "$FIX/core/scripts/share-suggestion-state.sh"
chmod 644 "$FIX/core/scripts/share-suggestion-state.sh"
result="$(run_check 99.0.0)"
rc="${result%%$'\n'*}"
output="${result#*$'\n'}"
[ "$rc" = 2 ] || fail "a non-executable registered helper should fail: $output"
nonexec_count="$(printf '%s\n' "$output" | grep -F -c 'cannot run helper core/scripts/share-suggestion-state.sh because it is not executable' || true)"
[ "$nonexec_count" = 3 ] || fail "expected one non-executable-helper line for each registered caller, found $nonexec_count: $output"
pass "one non-executable helper reports each of its three registered hooks"

chmod +x "$FIX/core/scripts/share-suggestion-state.sh"
cat > "$FIX/core/scripts/session-project.sh" <<'FLOOR'
#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib/hq-cli-floor.sh"
hq_cli_floor_check "session-project.sh" "5.78.0"
FLOOR
chmod +x "$FIX/core/scripts/session-project.sh"
result="$(run_check 1.0.0)"
rc="${result%%$'\n'*}"
output="${result#*$'\n'}"
[ "$rc" = 2 ] || fail "a forwarder whose CLI floor fails should fail the doctor: $output"
[[ "$output" == *'hook .claude/hooks/native-plan-project-sync.sh cannot run helper core/scripts/session-project.sh: session-project.sh: this script needs hq-cli >= 5.78.0 (found 1.0.0)'* ]] \
  || fail "forwarder CLI-floor failure was not attributed to its hook: $output"
pass "a forwarder whose sourced F1 CLI-floor check returns 127 is reported"

echo "PASS: hook helper doctor check"
