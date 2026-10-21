#!/bin/bash
# hq-core: public
# Regression: the Codex adapter must hand edit content to the dotenv guard
# (env-file-no-trailing-newline). Before the fix the adapter rebuilt every
# edit payload as {file_path} only, so the guard saw no content and allowed a
# contaminated .env write. Now apply_patch "+" lines and native Edit/Write
# content reach the guard, and a dotenv edit whose content cannot be
# determined (rename into .env, path-only payload) is denied.
#
# Fixture-only: every .env file here is a synthetic file in a temp dir.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/.codex/hooks" "$TMP/.claude/hooks" "$TMP/core/scripts/lib" "$TMP/core/policies"
cp "$ROOT/.codex/hooks/hq-codex-hook-adapter.sh" "$TMP/.codex/hooks/hq-codex-hook-adapter.sh"
cp "$ROOT/.codex/hooks/codex-explicit-path-guard.cjs" "$TMP/.codex/hooks/codex-explicit-path-guard.cjs"
cat > "$TMP/.codex/hooks/codex-explicit-path-flag.cjs" <<'JS'
process.stdout.write("false\n");
JS
cp "$ROOT/core/scripts/lib/hook-adapter-core.sh" "$TMP/core/scripts/lib/hook-adapter-core.sh"
cp "$ROOT/.claude/settings.json" "$TMP/.claude/settings.json"
cp "$ROOT/.claude/hooks/hook-registry.json" "$TMP/.claude/hooks/hook-registry.json"
# The real guard under test. Every other registered hook is absent from the
# fixture and skipped by the adapter's missing-script guard.
cp "$ROOT/.claude/hooks/env-file-no-trailing-newline.sh" "$TMP/.claude/hooks/env-file-no-trailing-newline.sh"
chmod +x "$TMP/.claude/hooks/env-file-no-trailing-newline.sh"
git -C "$TMP" init -q

# Stub gate: run every hook regardless of profile, so this test checks the
# adapter-to-guard handoff. Profile membership is covered by
# gated-hook-profile-coverage.test.sh.
cat > "$TMP/.claude/hooks/hook-gate.sh" <<'SH'
#!/bin/bash
set -euo pipefail
if [ "${1:-}" = "--lib" ]; then
  return 0 2>/dev/null || exit 0
fi
hook_id="$1"
script="$2"
shift 2
echo "$hook_id" >> "$TEST_LOG"
"$script" "$@"
SH
chmod +x "$TMP/.claude/hooks/hook-gate.sh"

mkdir -p "$TMP/co-a" "$TMP/initech-test"
printf 'FIXTURE_FLAG=1\n' > "$TMP/co-a/.env.fixture-target"
ln -s ".env.fixture-target" "$TMP/co-a/link-notes"

ADAPTER="$TMP/.codex/hooks/hq-codex-hook-adapter.sh"
export TEST_LOG="$TMP/hook.log"

pass=0
fail=0
ok() { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; }

# run_case <name> <expect: block|allow|rc0> <json payload>
run_case() {
  local name="$1" expect="$2" payload="$3" rc=0 err
  : > "$TEST_LOG"
  err="$(cd "$TMP" && printf '%s' "$payload" | bash "$ADAPTER" 2>&1 >/dev/null)" || rc=$?
  case "$expect" in
    block)
      if [ "$rc" -eq 2 ]; then ok "$name (blocked)"; else bad "$name: expected rc 2, got $rc: $err"; fi
      ;;
    allow|rc0)
      if [ "$rc" -eq 0 ]; then ok "$name (allowed)"; else bad "$name: expected rc 0, got $rc: $err"; fi
      ;;
  esac
}

# patch_case <name> <expect> <patch body with \n escapes>
patch_case() {
  run_case "$1" "$2" '{"hook_event_name":"PreToolUse","tool_name":"apply_patch","cwd":"'"$TMP"'","tool_input":{"command":"*** Begin Patch\n'"$3"'*** End Patch"}}'
}

# Values are synthetic. The backslash-n cases put a literal two-character \n
# inside the quotes, which JSON spells as \\n.
BADN='FIXTURE_TOKEN=\"abc\\n\"'
BADSP='FIXTURE_TOKEN=\"abc \"'
GOOD='FIXTURE_TOKEN=\"abc\"'

# apply_patch Add/Update into dotenv files.
patch_case "apply_patch Add co-a/.env with literal \\n" block "*** Add File: co-a/.env\n+$BADN\n"
patch_case "apply_patch Add co-a/.env with trailing space" block "*** Add File: co-a/.env\n+$BADSP\n"
patch_case "apply_patch Update co-a/.env.local" block "*** Update File: co-a/.env.local\n@@\n-OLD=1\n+$BADN\n"
patch_case "apply_patch Add co-a/.env clean" allow "*** Add File: co-a/.env\n+$GOOD\n+PLAIN=value\n"
patch_case "apply_patch Add co-a/notes.md with the same line" allow "*** Add File: co-a/notes.md\n+$BADN\n"

# Case variants and suffix forms.
patch_case "apply_patch Add co-a/.ENV" block "*** Add File: co-a/.ENV\n+$BADN\n"
patch_case "apply_patch Add initech-test/prod.Env" block "*** Add File: initech-test/prod.Env\n+$BADSP\n"
patch_case "apply_patch Add initech-test/.Env.Production" block "*** Add File: initech-test/.Env.Production\n+$BADN\n"

# A removed line carrying the bad pattern is not new content.
patch_case "apply_patch Update removes a bad line" allow "*** Update File: co-a/.env.local\n@@\n-$BADN\n+$GOOD\n"

# Symlink whose name is not dotenv-like but whose target is.
patch_case "apply_patch Update symlink to a fixture .env" block "*** Update File: co-a/link-notes\n@@\n+$BADN\n"
patch_case "apply_patch Update symlink to a fixture .env, clean" allow "*** Update File: co-a/link-notes\n@@\n+$GOOD\n"

# Rename into a dotenv file: the full content is not in the patch, so deny.
patch_case "apply_patch Move to co-a/.env" block "*** Update File: co-a/notes.txt\n*** Move to: co-a/.env\n@@\n+$GOOD\n"
patch_case "apply_patch Move to co-a/.ENV.local" block "*** Update File: co-a/notes.txt\n*** Move to: co-a/.ENV.local\n@@\n+$GOOD\n"
# Renaming a dotenv file to a non-dotenv name is fine.
patch_case "apply_patch Move from co-a/.env to notes.txt" allow "*** Update File: co-a/.env\n*** Move to: co-a/notes.txt\n@@\n+$GOOD\n"

# Delete writes nothing.
patch_case "apply_patch Delete co-a/.env" allow "*** Delete File: co-a/.env\n"

# Multi-file patch: content is attributed to the right file.
patch_case "multi-file patch, bad line in notes.md only" allow "*** Add File: co-a/.env\n+$GOOD\n*** Add File: co-a/notes.md\n+$BADN\n"
patch_case "multi-file patch, bad line in .env section" block "*** Add File: co-a/notes.md\n+$GOOD\n*** Add File: co-a/.env\n+$BADN\n"

# Unicode content.
patch_case "apply_patch unicode value clean" allow "*** Add File: co-a/.env\n+FIXTURE_NAME=\\\"héllo\\\"\n"
patch_case "apply_patch unicode value trailing space" block "*** Add File: co-a/.env\n+FIXTURE_NAME=\\\"héllo \\\"\n"

# apply_patch that names a dotenv file but carries no content to inspect.
run_case "apply_patch file_path co-a/.env with no content" block \
  '{"hook_event_name":"PreToolUse","tool_name":"apply_patch","cwd":"'"$TMP"'","tool_input":{"file_path":"co-a/.env"}}'
run_case "apply_patch file_path co-a/notes.md with no content" allow \
  '{"hook_event_name":"PreToolUse","tool_name":"apply_patch","cwd":"'"$TMP"'","tool_input":{"file_path":"co-a/notes.md"}}'

# Native Edit and Write keep their own content fields.
run_case "Edit co-a/.env new_string bad" block \
  '{"hook_event_name":"PreToolUse","tool_name":"Edit","cwd":"'"$TMP"'","tool_input":{"file_path":"co-a/.env","old_string":"X","new_string":"'"$BADN"'"}}'
run_case "Edit co-a/.env new_string clean" allow \
  '{"hook_event_name":"PreToolUse","tool_name":"Edit","cwd":"'"$TMP"'","tool_input":{"file_path":"co-a/.env","old_string":"X","new_string":"'"$GOOD"'"}}'
run_case "Write co-a/.env content bad" block \
  '{"hook_event_name":"PreToolUse","tool_name":"Write","cwd":"'"$TMP"'","tool_input":{"file_path":"co-a/.env","content":"'"$BADSP"'\n"}}'
run_case "Write co-a/.env content clean" allow \
  '{"hook_event_name":"PreToolUse","tool_name":"Write","cwd":"'"$TMP"'","tool_input":{"file_path":"co-a/.env","content":"'"$GOOD"'\n"}}'
run_case "Write absolute symlink path, bad" block \
  '{"hook_event_name":"PreToolUse","tool_name":"Write","cwd":"'"$TMP"'","tool_input":{"file_path":"'"$TMP"'/co-a/link-notes","content":"'"$BADN"'\n"}}'
run_case "Edit co-a/.env edits[] bad" block \
  '{"hook_event_name":"PreToolUse","tool_name":"Edit","cwd":"'"$TMP"'","tool_input":{"file_path":"co-a/.env","edits":[{"old_string":"A","new_string":"'"$GOOD"'"},{"old_string":"B","new_string":"'"$BADN"'"}]}}'
run_case "Edit co-a/notes.md new_string bad" allow \
  '{"hook_event_name":"PreToolUse","tool_name":"Edit","cwd":"'"$TMP"'","tool_input":{"file_path":"co-a/notes.md","old_string":"X","new_string":"'"$BADN"'"}}'

# The guard must actually have run on a blocked dotenv case.
: > "$TEST_LOG"
(cd "$TMP" && printf '%s' '{"hook_event_name":"PreToolUse","tool_name":"apply_patch","cwd":"'"$TMP"'","tool_input":{"command":"*** Begin Patch\n*** Add File: co-a/.env\n+'"$BADN"'\n*** End Patch"}}' | bash "$ADAPTER" >/dev/null 2>&1) || true
if grep -qx 'env-file-no-trailing-newline' "$TEST_LOG"; then
  ok "guard ran for the apply_patch .env case"
else
  bad "guard did not run for the apply_patch .env case"
fi

# PostToolUse never denies: the write already happened.
run_case "PostToolUse Move to co-a/.env" rc0 \
  '{"hook_event_name":"PostToolUse","tool_name":"apply_patch","cwd":"'"$TMP"'","tool_input":{"command":"*** Begin Patch\n*** Update File: co-a/notes.txt\n*** Move to: co-a/.env\n@@\n+X=1\n*** End Patch"},"tool_response":{}}'
run_case "PostToolUse file_path co-a/.env with no content" rc0 \
  '{"hook_event_name":"PostToolUse","tool_name":"apply_patch","cwd":"'"$TMP"'","tool_input":{"file_path":"co-a/.env"},"tool_response":{}}'

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
