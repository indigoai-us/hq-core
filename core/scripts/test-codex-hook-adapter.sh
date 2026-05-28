#!/bin/bash
# hq-core: public
# Focused regression tests for .codex/hooks/hq-codex-hook-adapter.sh.

set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/.codex/hooks" "$TMP/.claude/hooks"
cp "$ROOT/.codex/hooks/hq-codex-hook-adapter.sh" "$TMP/.codex/hooks/hq-codex-hook-adapter.sh"
chmod +x "$TMP/.codex/hooks/hq-codex-hook-adapter.sh"

git -C "$TMP" init -q

cat > "$TMP/.claude/hooks/hook-gate.sh" <<'SH'
#!/bin/bash
set -euo pipefail
hook_id="$1"
script="$2"
shift 2
echo "$hook_id" >> "$TEST_LOG"
"$script" "$@"
SH
chmod +x "$TMP/.claude/hooks/hook-gate.sh"

cat > "$TMP/.claude/hooks/detect-secrets.sh" <<'SH'
#!/bin/bash
input="$(cat)"
if printf '%s' "$input" | grep -q 'sk-testSECRET'; then
  echo "blocked secret" >&2
  exit 2
fi
exit 0
SH

cat > "$TMP/.claude/hooks/block-core-writes-bash.sh" <<'SH'
#!/bin/bash
cat >/dev/null
echo "bash-core-write-check" >> "$TEST_LOG"
exit 0
SH

cat > "$TMP/.claude/hooks/block-hq-root-git-mutation.sh" <<'SH'
#!/bin/bash
input="$(cat)"
command="$(printf '%s' "$input" | jq -r '.tool_input.command // empty')"
echo "root-git-check" >> "$TEST_LOG"
if printf '%s' "$command" | grep -q 'git push'; then
  echo "blocked root git mutation" >&2
  exit 2
fi
exit 0
SH

cat > "$TMP/.claude/hooks/block-on-active-run.sh" <<'SH'
#!/bin/bash
input="$(cat)"
path="$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty')"
[ -n "$path" ] && echo "active-run:$path" >> "$TEST_LOG"
if [ "$path" = "blocked.txt" ]; then
  echo "blocked active run" >&2
  exit 2
fi
exit 0
SH

cat > "$TMP/.claude/hooks/block-unsafe-package-install.sh" <<'SH'
#!/bin/bash
cat >/dev/null
echo "unsafe-package-check" >> "$TEST_LOG"
exit 0
SH

cat > "$TMP/.claude/hooks/protect-core.sh" <<'SH'
#!/bin/bash
input="$(cat)"
path="$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty')"
echo "protect:$path" >> "$TEST_LOG"
if [ "$path" = ".claude/settings.json" ]; then
  echo "blocked core" >&2
  exit 2
fi
exit 0
SH

cat > "$TMP/.claude/hooks/block-core-writes.sh" <<'SH'
#!/bin/bash
input="$(cat)"
path="$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty')"
echo "core-write:$path" >> "$TEST_LOG"
if [[ "$path" == core/* ]]; then
  echo "blocked core write" >&2
  exit 2
fi
exit 0
SH

cat > "$TMP/.claude/hooks/auto-checkpoint-trigger.sh" <<'SH'
#!/bin/bash
cat >/dev/null
echo "AUTO-CHECKPOINT REQUIRED"
SH

cat > "$TMP/.claude/hooks/hq-autocommit.sh" <<'SH'
#!/bin/bash
input="$(cat)"
path="$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty')"
echo "autosave:$path" >> "$TEST_LOG"
exit 0
SH

cat > "$TMP/.claude/hooks/master-sync.sh" <<'SH'
#!/bin/bash
cat >/dev/null
echo "master-sync" >> "$TEST_LOG"
exit 0
SH

cat > "$TMP/.claude/hooks/auto-capture-registry.sh" <<'SH'
#!/bin/bash
cat >/dev/null
exit 0
SH

cat > "$TMP/.claude/hooks/load-policies-for-session.sh" <<'SH'
#!/bin/bash
cat >/dev/null
echo "POLICY"
SH

cat > "$TMP/.claude/hooks/inject-local-context.sh" <<'SH'
#!/bin/bash
cat >/dev/null
echo "LOCAL"
SH

cat > "$TMP/.claude/hooks/auto-startwork.sh" <<'SH'
#!/bin/bash
cat >/dev/null
echo "AUTO-STARTWORK"
SH

cat > "$TMP/.claude/hooks/observe-patterns.sh" <<'SH'
#!/bin/bash
cat >/dev/null
echo "OBSERVE"
SH

cat > "$TMP/.claude/hooks/cleanup-mcp-processes.sh" <<'SH'
#!/bin/bash
cat >/dev/null
exit 0
SH

cat > "$TMP/.claude/hooks/context-warning-50.sh" <<'SH'
#!/bin/bash
cat >/dev/null
exit 0
SH

cat > "$TMP/.claude/hooks/capture-estimates.sh" <<'SH'
#!/bin/bash
cat >/dev/null
exit 0
SH

cat > "$TMP/.claude/hooks/precompact-thrashing-detector.sh" <<'SH'
#!/bin/bash
cat >/dev/null
exit 0
SH

cat > "$TMP/.claude/hooks/auto-checkpoint-precompact.sh" <<'SH'
#!/bin/bash
cat >/dev/null
echo "PRECOMPACT CHECKPOINT"
SH

cat > "$TMP/.claude/hooks/journal-precompact.sh" <<'SH'
#!/bin/bash
cat >/dev/null
exit 0
SH

# ----- parity-extension stubs (folded denies + remaining Claude-side hooks) -----

# SessionStart parity hooks (advisory, all return 0)
for name in check-claude-desktop-bridge-health check-repo-active-runs \
            check-core-yaml-parity load-journal-index-on-start check-hq-update; do
  cat > "$TMP/.claude/hooks/$name.sh" <<SH
#!/bin/bash
cat >/dev/null
echo "$name" >> "\$TEST_LOG"
exit 0
SH
done

# PreToolUse Bash parity (advisory)
cat > "$TMP/.claude/hooks/inject-policy-on-trigger.sh" <<'SH'
#!/bin/bash
cat >/dev/null
echo "inject-policy-on-trigger" >> "$TEST_LOG"
exit 0
SH

# PreToolUse Edit/Write parity (blocking, except inject-policy-on-trigger which is advisory)
for name in block-inline-story-impl env-file-no-trailing-newline \
            block-plans-dir-during-deep-plan; do
  cat > "$TMP/.claude/hooks/$name.sh" <<SH
#!/bin/bash
input="\$(cat)"
path="\$(printf '%s' "\$input" | jq -r '.tool_input.file_path // empty')"
echo "$name:\$path" >> "\$TEST_LOG"
exit 0
SH
done

# route-company-skill-creation is dispatched blocking — block when path contains BLOCK_SKILL_ROUTE.
cat > "$TMP/.claude/hooks/route-company-skill-creation.sh" <<'SH'
#!/bin/bash
input="$(cat)"
path="$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty')"
echo "route-company-skill-creation:$path" >> "$TEST_LOG"
if printf '%s' "$path" | grep -q 'BLOCK_SKILL_ROUTE'; then
  echo "blocked skill route" >&2
  exit 2
fi
exit 0
SH

# PostToolUse parity
cat > "$TMP/.claude/hooks/screenshot-resize-trigger.sh" <<'SH'
#!/bin/bash
cat >/dev/null
echo "screenshot-resize-trigger" >> "$TEST_LOG"
exit 0
SH

cat > "$TMP/.claude/hooks/journal-due.sh" <<'SH'
#!/bin/bash
cat >/dev/null
echo "journal-due" >> "$TEST_LOG"
exit 0
SH

cat > "$TMP/.claude/hooks/auto-mirror-company-skill.sh" <<'SH'
#!/bin/bash
input="$(cat)"
path="$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty')"
echo "auto-mirror-company-skill:$path" >> "$TEST_LOG"
exit 0
SH

# UserPromptSubmit parity
for name in rewrite-resume-sentinel route-deep-plan-to-skill auto-session-project; do
  cat > "$TMP/.claude/hooks/$name.sh" <<SH
#!/bin/bash
cat >/dev/null
echo "$name" >> "\$TEST_LOG"
exit 0
SH
done

# Stop parity
cat > "$TMP/.claude/hooks/enforce-capability-link-render.sh" <<'SH'
#!/bin/bash
cat >/dev/null
echo "enforce-capability-link-render" >> "$TEST_LOG"
exit 0
SH

chmod +x "$TMP/.claude/hooks/"*.sh

ADAPTER="$TMP/.codex/hooks/hq-codex-hook-adapter.sh"
export TEST_LOG="$TMP/hook-calls.log"

run_adapter() {
  local payload="$1"
  (cd "$TMP" && printf '%s' "$payload" | "$ADAPTER")
}

assert_contains() {
  local haystack="$1"
  local needle="$2"
  if ! printf '%s' "$haystack" | grep -qF "$needle"; then
    echo "Expected output to contain: $needle" >&2
    echo "Actual output:" >&2
    printf '%s\n' "$haystack" >&2
    exit 1
  fi
}

payload_session='{"hook_event_name":"SessionStart","source":"startup","cwd":"'"$TMP"'","session_id":"s1","model":"test"}'
out="$(run_adapter "$payload_session")"
assert_contains "$out" "POLICY"
assert_contains "$out" "LOCAL"
assert_contains "$out" "AUTO-STARTWORK"

payload_secret='{"hook_event_name":"PreToolUse","tool_name":"Bash","cwd":"'"$TMP"'","tool_input":{"command":"echo sk-testSECRET1234567890"}}'
if err="$(run_adapter "$payload_secret" 2>&1 >/dev/null)"; then
  echo "Expected secret payload to be blocked" >&2
  exit 1
fi
assert_contains "$err" "blocked secret"

payload_bash_safe='{"hook_event_name":"PreToolUse","tool_name":"Bash","cwd":"'"$TMP"'","tool_input":{"command":"echo ok"}}'
run_adapter "$payload_bash_safe" >/dev/null
assert_contains "$(cat "$TEST_LOG")" "block-core-writes-bash"
assert_contains "$(cat "$TEST_LOG")" "block-hq-root-git-mutation"
assert_contains "$(cat "$TEST_LOG")" "block-unsafe-package-install"

payload_root_git='{"hook_event_name":"PreToolUse","tool_name":"Bash","cwd":"'"$TMP"'","tool_input":{"command":"git push origin main"}}'
if err="$(run_adapter "$payload_root_git" 2>&1 >/dev/null)"; then
  echo "Expected root git mutation payload to be blocked" >&2
  exit 1
fi
assert_contains "$err" "blocked root git mutation"

payload_patch_core='{"hook_event_name":"PreToolUse","tool_name":"apply_patch","cwd":"'"$TMP"'","tool_input":{"command":"*** Begin Patch\n*** Update File: .claude/settings.json\n@@\n x\n*** End Patch"}}'
if err="$(run_adapter "$payload_patch_core" 2>&1 >/dev/null)"; then
  echo "Expected protected apply_patch payload to be blocked" >&2
  exit 1
fi
assert_contains "$err" "blocked core"
assert_contains "$(cat "$TEST_LOG")" "protect:.claude/settings.json"

payload_patch_core_dir='{"hook_event_name":"PreToolUse","tool_name":"apply_patch","cwd":"'"$TMP"'","tool_input":{"command":"*** Begin Patch\n*** Update File: core/policies/test.md\n@@\n x\n*** End Patch"}}'
if err="$(run_adapter "$payload_patch_core_dir" 2>&1 >/dev/null)"; then
  echo "Expected core/ apply_patch payload to be blocked" >&2
  exit 1
fi
assert_contains "$err" "Edits to core/ are denied"

payload_patch_input='{"hook_event_name":"PreToolUse","tool_name":"apply_patch","cwd":"'"$TMP"'","tool_input":{"input":"*** Begin Patch\n*** Update File: blocked.txt\n@@\n x\n*** End Patch"}}'
if err="$(run_adapter "$payload_patch_input" 2>&1 >/dev/null)"; then
  echo "Expected tool_input.input apply_patch payload to be blocked" >&2
  exit 1
fi
assert_contains "$err" "blocked active run"

payload_post_patch='{"hook_event_name":"PostToolUse","tool_name":"apply_patch","cwd":"'"$TMP"'","tool_input":{"command":"*** Begin Patch\n*** Add File: docs/test.md\n+ok\n*** End Patch"},"tool_response":{"exit_code":0}}'
out="$(run_adapter "$payload_post_patch")"
printf '%s' "$out" | python3 -m json.tool >/dev/null
assert_contains "$out" "AUTO-CHECKPOINT REQUIRED"
assert_contains "$(cat "$TEST_LOG")" "master-sync"
assert_contains "$(cat "$TEST_LOG")" "autosave:docs/test.md"

payload_stop='{"hook_event_name":"Stop","cwd":"'"$TMP"'","last_assistant_message":"done"}'
out="$(run_adapter "$payload_stop")"
printf '%s' "$out" | python3 -m json.tool >/dev/null
assert_contains "$out" "OBSERVE"
assert_contains "$(cat "$TEST_LOG")" "context-warning-50"

payload_precompact='{"hook_event_name":"PreCompact","cwd":"'"$TMP"'","session_id":"s1"}'
out="$(run_adapter "$payload_precompact")"
printf '%s' "$out" | python3 -m json.tool >/dev/null
assert_contains "$out" "PRECOMPACT CHECKPOINT"

# ----- parity-extension assertions -----

# SessionStart parity hooks all fire.
: > "$TEST_LOG"
run_adapter "$payload_session" >/dev/null
log="$(cat "$TEST_LOG")"
for hk in check-claude-desktop-bridge-health check-repo-active-runs \
          check-core-yaml-parity load-journal-index-on-start check-hq-update; do
  assert_contains "$log" "$hk"
done

# PreToolUse Bash inject-policy-on-trigger fires (advisory).
: > "$TEST_LOG"
run_adapter "$payload_bash_safe" >/dev/null
assert_contains "$(cat "$TEST_LOG")" "inject-policy-on-trigger"

# PreToolUse apply_patch — every per-path edit-class parity hook fires.
: > "$TEST_LOG"
payload_patch_edit='{"hook_event_name":"PreToolUse","tool_name":"apply_patch","cwd":"'"$TMP"'","tool_input":{"command":"*** Begin Patch\n*** Add File: docs/parity.md\n+ok\n*** End Patch"}}'
run_adapter "$payload_patch_edit" >/dev/null
log="$(cat "$TEST_LOG")"
for hk in block-inline-story-impl env-file-no-trailing-newline \
          block-plans-dir-during-deep-plan route-company-skill-creation \
          inject-policy-on-trigger; do
  assert_contains "$log" "$hk"
done

# route-company-skill-creation is BLOCKING — a stub-blocked path must abort the adapter.
: > "$TEST_LOG"
payload_skill_block='{"hook_event_name":"PreToolUse","tool_name":"apply_patch","cwd":"'"$TMP"'","tool_input":{"command":"*** Begin Patch\n*** Add File: companies/acme/skills/BLOCK_SKILL_ROUTE.md\n+ok\n*** End Patch"}}'
if err="$(run_adapter "$payload_skill_block" 2>&1 >/dev/null)"; then
  echo "Expected route-company-skill-creation block to abort the adapter" >&2
  exit 1
fi
assert_contains "$err" "blocked skill route"

# PostToolUse Bash: screenshot + journal nudges fire.
: > "$TEST_LOG"
payload_post_bash='{"hook_event_name":"PostToolUse","tool_name":"Bash","cwd":"'"$TMP"'","tool_input":{"command":"echo ok"},"tool_response":{"exit_code":0}}'
run_adapter "$payload_post_bash" >/dev/null
log="$(cat "$TEST_LOG")"
assert_contains "$log" "screenshot-resize-trigger"
assert_contains "$log" "journal-due"

# PostToolUse apply_patch: auto-mirror-company-skill MUST run BEFORE hq-autocommit so any
# newly-mirrored skill files are picked up by autosave. journal-due also fires per-path.
: > "$TEST_LOG"
payload_post_patch_parity='{"hook_event_name":"PostToolUse","tool_name":"apply_patch","cwd":"'"$TMP"'","tool_input":{"command":"*** Begin Patch\n*** Add File: companies/acme/skills/new.md\n+ok\n*** End Patch"},"tool_response":{"exit_code":0}}'
run_adapter "$payload_post_patch_parity" >/dev/null
log="$(cat "$TEST_LOG")"
assert_contains "$log" "auto-mirror-company-skill:companies/acme/skills/new.md"
assert_contains "$log" "journal-due"
mirror_line=$(grep -n "^auto-mirror-company-skill:companies/acme/skills/new.md$" "$TEST_LOG" | head -1 | cut -d: -f1)
autosave_line=$(grep -n "^autosave:companies/acme/skills/new.md$" "$TEST_LOG" | head -1 | cut -d: -f1)
if [ -z "$mirror_line" ] || [ -z "$autosave_line" ] || [ "$mirror_line" -ge "$autosave_line" ]; then
  echo "Expected auto-mirror-company-skill BEFORE hq-autocommit (mirror=$mirror_line autosave=$autosave_line)" >&2
  cat "$TEST_LOG" >&2
  exit 1
fi

# Stop: enforce-capability-link-render fires.
: > "$TEST_LOG"
run_adapter "$payload_stop" >/dev/null
assert_contains "$(cat "$TEST_LOG")" "enforce-capability-link-render"

# UserPromptSubmit: routes to rewrite-resume-sentinel, route-deep-plan-to-skill, auto-session-project.
: > "$TEST_LOG"
payload_prompt='{"hook_event_name":"UserPromptSubmit","cwd":"'"$TMP"'","user_prompt":"hello"}'
run_adapter "$payload_prompt" >/dev/null
log="$(cat "$TEST_LOG")"
for hk in rewrite-resume-sentinel route-deep-plan-to-skill auto-session-project; do
  assert_contains "$log" "$hk"
done

# ----- folded sensitive-path deny (block_sensitive_read_if_needed inline) -----

# Bash command referencing a protected path is blocked (via $HOME absolute form).
payload_bash_ssh='{"hook_event_name":"PreToolUse","tool_name":"Bash","cwd":"'"$TMP"'","tool_input":{"command":"cat '"$HOME"'/.ssh/id_rsa"}}'
if err="$(run_adapter "$payload_bash_ssh" 2>&1 >/dev/null)"; then
  echo "Expected $HOME/.ssh/* Bash read to be blocked" >&2
  exit 1
fi
assert_contains "$err" "Sensitive home-dir path access denied"

# Bash command referencing a protected path via ~/ tilde form is also blocked.
payload_bash_tilde='{"hook_event_name":"PreToolUse","tool_name":"Bash","cwd":"'"$TMP"'","tool_input":{"command":"cat ~/.aws/credentials"}}'
if err="$(run_adapter "$payload_bash_tilde" 2>&1 >/dev/null)"; then
  echo "Expected ~/.aws/credentials Bash read to be blocked" >&2
  exit 1
fi
assert_contains "$err" "Sensitive home-dir path access denied"

# BYPASS-FIX: write-redirect via `>` was previously NOT in the START charset,
# so `echo secret >~/.env` slipped past the regex. The START set must now
# include `;|<>` so this gets caught.
payload_bash_redirect='{"hook_event_name":"PreToolUse","tool_name":"Bash","cwd":"'"$TMP"'","tool_input":{"command":"echo secret >~/.env"}}'
if err="$(run_adapter "$payload_bash_redirect" 2>&1 >/dev/null)"; then
  echo "Expected write-redirect bypass (>~/.env) to be blocked" >&2
  exit 1
fi
assert_contains "$err" "Sensitive home-dir path access denied"

# TOKEN-BOUNDARY REGRESSION: `.env.schema` (and friends like `.env.local`)
# must NOT match. The `.` after `.env` is not a token separator, so the
# regex correctly rejects sub-extension paths.
payload_bash_schema='{"hook_event_name":"PreToolUse","tool_name":"Bash","cwd":"'"$TMP"'","tool_input":{"command":"cat ~/.env.schema"}}'
run_adapter "$payload_bash_schema" >/dev/null 2>&1 || {
  echo "Expected ~/.env.schema (token-boundary regression) to be ALLOWED" >&2
  exit 1
}

# Read tool: file_path pointing at a sensitive home-dir path is blocked.
payload_read_block='{"hook_event_name":"PreToolUse","tool_name":"Read","cwd":"'"$TMP"'","tool_input":{"file_path":"'"$HOME"'/.netrc"}}'
if err="$(run_adapter "$payload_read_block" 2>&1 >/dev/null)"; then
  echo "Expected Read tool sensitive-path to be blocked" >&2
  exit 1
fi
assert_contains "$err" "Sensitive home-dir path access denied"

# Edit tool: file_path under ~/ sensitive paths is blocked.
payload_edit_sensitive='{"hook_event_name":"PreToolUse","tool_name":"Edit","cwd":"'"$TMP"'","tool_input":{"file_path":"'"$HOME"'/.bashrc"}}'
if err="$(run_adapter "$payload_edit_sensitive" 2>&1 >/dev/null)"; then
  echo "Expected Edit on $HOME/.bashrc to be blocked" >&2
  exit 1
fi
assert_contains "$err" "Sensitive home-dir path access denied"

# ----- folded companies/_template deny (block_template_edit_if_needed inline) -----

payload_patch_template='{"hook_event_name":"PreToolUse","tool_name":"apply_patch","cwd":"'"$TMP"'","tool_input":{"command":"*** Begin Patch\n*** Update File: companies/_template/foo.md\n+x\n*** End Patch"}}'
if err="$(run_adapter "$payload_patch_template" 2>&1 >/dev/null)"; then
  echo "Expected companies/_template/ edit to be blocked" >&2
  exit 1
fi
assert_contains "$err" "Edits to companies/_template/ are denied"

echo "codex hook adapter tests passed"
