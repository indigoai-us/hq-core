#!/bin/bash
# hq-core: public
# Focused regression tests for .codex/hooks/hq-codex-hook-adapter.sh.

set -euo pipefail

# HQ is not necessarily a git repo (and this suite is often run from a
# worktree), so fall back to the checkout this script lives in.
ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [ -z "$ROOT" ] || [ ! -d "$ROOT/.codex/hooks" ]; then
  ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
fi
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/.codex/hooks" "$TMP/.claude/hooks" "$TMP/core/scripts/lib"
cp "$ROOT/.codex/hooks/hq-codex-hook-adapter.sh" "$TMP/.codex/hooks/hq-codex-hook-adapter.sh"
chmod +x "$TMP/.codex/hooks/hq-codex-hook-adapter.sh"
# The adapter reads dispatch live from .claude/settings.json via the shared lib.
# Provide both so the fixture exercises the real dispatch table (hooks the
# fixture does not stub are skipped by the missing-script guard).
cp "$ROOT/core/scripts/lib/hook-adapter-core.sh" "$TMP/core/scripts/lib/hook-adapter-core.sh"
cp "$ROOT/.claude/settings.json" "$TMP/.claude/settings.json"

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

cat > "$TMP/.claude/hooks/mandatory-scope-authorizer.sh" <<'SH'
#!/bin/bash
input="$(cat)"
tool="$(printf '%s' "$input" | jq -r '.tool_name // empty')"
echo "mandatory-scope-authorizer:$tool" >> "$TEST_LOG"
path="$(printf '%s' "$input" | jq -r '.tool_input.file_path // .tool_input.path // empty')"
cmd="$(printf '%s' "$input" | jq -r '.tool_input.command // empty')"
if printf '%s' "$path$cmd" | grep -q 'companies/otherco/'; then
  echo "blocked scope" >&2
  exit 2
fi
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

# Reindex is the canonical post-write finalizer registered in settings.json.
cat > "$TMP/.claude/hooks/reindex.sh" <<'SH'
#!/bin/bash
input="$(cat)"
path="$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty')"
echo "reindex:$path" >> "$TEST_LOG"
exit 0
SH

# Codex-only SessionStart supplement (no Claude analog / not in settings.json).
cat > "$TMP/.claude/hooks/inject-codex-checkpoint-reprompt.sh" <<'SH'
#!/bin/bash
cat >/dev/null 2>&1 || true
exit 0
SH

cat > "$TMP/.claude/hooks/auto-capture-registry.sh" <<'SH'
#!/bin/bash
cat >/dev/null
exit 0
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

# block-foreground-timeout-over-harness-ceiling (finding 2.1): dispatched
# blocking on the Bash branch. Stub mirrors the real contract — block a
# foreground command declaring an over-ceiling `timeout <N>` — to prove the
# Codex adapter routes a Codex shell tool call through this guard.
cat > "$TMP/.claude/hooks/block-foreground-timeout-over-harness-ceiling.sh" <<'SH'
#!/bin/bash
input="$(cat)"
cmd="$(printf '%s' "$input" | jq -r '.tool_input.command // empty')"
echo "block-foreground-timeout-over-harness-ceiling" >> "$TEST_LOG"
if printf '%s' "$cmd" | grep -Eq 'timeout[[:space:]]+2400'; then
  echo "blocked foreground timeout" >&2
  exit 2
fi
exit 0
SH

# SessionStart + PreToolUse Bash parity (advisory). This hook is now the sole
# surface for SessionStart policy injection (the digest loader was retired), so
# it emits the "POLICY" marker the SessionStart parity assertion checks for.
cat > "$TMP/.claude/hooks/inject-policy-on-trigger.sh" <<'SH'
#!/bin/bash
cat >/dev/null
echo "inject-policy-on-trigger" >> "$TEST_LOG"
echo "POLICY"
exit 0
SH

# enforce-vault-write-access is dispatched blocking on BOTH the Bash branch
# (whole command) and the per-path edit branch, so it logs whichever of the two
# payload shapes it received.
cat > "$TMP/.claude/hooks/enforce-vault-write-access.sh" <<'SH'
#!/bin/bash
input="$(cat)"
tool="$(printf '%s' "$input" | jq -r '.tool_name // empty')"
path="$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty')"
if [ -n "$path" ]; then
  echo "enforce-vault-write-access:$path" >> "$TEST_LOG"
else
  echo "enforce-vault-write-access:$tool" >> "$TEST_LOG"
fi
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

# Use stock /bin/bash when it is the macOS 3.2 runtime under test. Linux CI
# exercises the same compatibility contract through Bash's 3.2 mode.
run_adapter_bash32() {
  local payload="$1"
  if /bin/bash -c '[ "${BASH_VERSINFO[0]}.${BASH_VERSINFO[1]}" = "3.2" ]'; then
    (cd "$TMP" && printf '%s' "$payload" | /bin/bash "$ADAPTER")
  else
    (cd "$TMP" && printf '%s' "$payload" | env BASH_COMPAT=3.2 bash "$ADAPTER")
  fi
}

assert_contains() {
  local haystack="$1"
  local needle="$2"
  # Here-string, not a pipe: `grep -q` exits on first match and closes the pipe,
  # so `printf` can take SIGPIPE (141) and — under `set -o pipefail` — turn a
  # SUCCESSFUL match into a failed assertion. That race made this suite
  # intermittently red on large haystacks.
  if ! grep -qF -- "$needle" <<<"$haystack"; then
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

# Regression: the settings-driven iterator previously emitted no records under
# Bash 3.2, silently skipping detect-secrets and every other configured guard.
if err="$(run_adapter_bash32 "$payload_secret" 2>&1 >/dev/null)"; then
  echo "Expected Bash 3.2-compatible dispatch to block the secret payload" >&2
  exit 1
fi
assert_contains "$err" "blocked secret"

payload_bash_safe='{"hook_event_name":"PreToolUse","tool_name":"Bash","cwd":"'"$TMP"'","tool_input":{"command":"echo ok"}}'
run_adapter "$payload_bash_safe" >/dev/null
assert_contains "$(cat "$TEST_LOG")" "block-core-writes-bash"
assert_contains "$(cat "$TEST_LOG")" "block-hq-root-git-mutation"
assert_contains "$(cat "$TEST_LOG")" "block-unsafe-package-install"
assert_contains "$(cat "$TEST_LOG")" "mandatory-scope-authorizer:Bash"
assert_contains "$(cat "$TEST_LOG")" "enforce-vault-write-access:Bash"
assert_contains "$(cat "$TEST_LOG")" "block-foreground-timeout-over-harness-ceiling"

# Codex shell tool call declaring an over-ceiling foreground timeout is blocked
# by the same guard Claude uses (finding 2.1 cross-backend coverage).
payload_fg_timeout='{"hook_event_name":"PreToolUse","tool_name":"Bash","cwd":"'"$TMP"'","tool_input":{"command":"timeout 2400s node run.mjs"}}'
if err="$(run_adapter "$payload_fg_timeout" 2>&1 >/dev/null)"; then
  echo "Expected Codex over-ceiling foreground timeout to be blocked" >&2
  exit 1
fi

payload_read_scope='{"hook_event_name":"PreToolUse","tool_name":"Read","cwd":"'"$TMP"'","tool_input":{"file_path":"'"$TMP"'/companies/otherco/settings/x.yaml"}}'
if err="$(run_adapter "$payload_read_scope" 2>&1 >/dev/null)"; then
  echo "Expected mandatory-scope-authorizer block on cross-company Read" >&2
  exit 1
fi
assert_contains "$err" "blocked scope"
assert_contains "$(cat "$TEST_LOG")" "mandatory-scope-authorizer:Read"

payload_grep_scope='{"hook_event_name":"PreToolUse","tool_name":"Grep","cwd":"'"$TMP"'","tool_input":{"pattern":"x","path":"'"$TMP"'/companies/otherco/settings"}}'
if err="$(run_adapter "$payload_grep_scope" 2>&1 >/dev/null)"; then
  echo "Expected mandatory-scope-authorizer block on cross-company Grep" >&2
  exit 1
fi
assert_contains "$err" "blocked scope"
assert_contains "$(cat "$TEST_LOG")" "mandatory-scope-authorizer:Grep"

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
# The adapter grew its own inline core/ guard, which short-circuits before the
# block-core-writes stub ever runs. Either layer refusing the write is a pass —
# what this case pins is that a core/ apply_patch never gets through.
case "$err" in
  *"blocked core write"*|*"Edits to core/ are denied"*) ;;
  *) echo "Expected a core/ denial, got: $err" >&2; exit 1 ;;
esac

payload_patch_input='{"hook_event_name":"PreToolUse","tool_name":"apply_patch","cwd":"'"$TMP"'","tool_input":{"input":"*** Begin Patch\n*** Update File: blocked.txt\n@@\n x\n*** End Patch"}}'
if err="$(run_adapter "$payload_patch_input" 2>&1 >/dev/null)"; then
  echo "Expected tool_input.input apply_patch payload to be blocked" >&2
  exit 1
fi
assert_contains "$err" "blocked active run"

payload_post_patch='{"hook_event_name":"PostToolUse","tool_name":"apply_patch","cwd":"'"$TMP"'","tool_input":{"command":"*** Begin Patch\n*** Add File: docs/test.md\n+ok\n*** End Patch"},"tool_response":{"exit_code":0}}'
out="$(run_adapter "$payload_post_patch")"
printf '%s' "$out" | jq -e . >/dev/null
assert_contains "$out" "AUTO-CHECKPOINT REQUIRED"
assert_contains "$(cat "$TEST_LOG")" "reindex"
assert_contains "$(cat "$TEST_LOG")" "autosave:docs/test.md"

payload_stop='{"hook_event_name":"Stop","cwd":"'"$TMP"'","last_assistant_message":"done"}'
out="$(run_adapter "$payload_stop")"
printf '%s' "$out" | jq -e . >/dev/null
assert_contains "$out" "OBSERVE"
assert_contains "$(cat "$TEST_LOG")" "context-warning-50"

payload_precompact='{"hook_event_name":"PreCompact","cwd":"'"$TMP"'","session_id":"s1"}'
out="$(run_adapter "$payload_precompact")"
printf '%s' "$out" | jq -e . >/dev/null
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
# Claude's settings.json does NOT register inject-policy-on-trigger on the
# Edit/Write PreToolUse branch (only Bash/SessionStart/UserPromptSubmit), so the
# settings-driven adapter no longer fires it here either. This is the drift the
# single-source design removes; the edit-class guards below still fire.
for hk in block-inline-story-impl env-file-no-trailing-newline \
          block-plans-dir-during-deep-plan route-company-skill-creation \
          enforce-vault-write-access; do
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

# PostToolUse apply_patch: canonical reindex MUST run BEFORE hq-autocommit so any
# generated namespaced wrappers are picked up by autosave. journal-due also fires per-path.
: > "$TEST_LOG"
payload_post_patch_parity='{"hook_event_name":"PostToolUse","tool_name":"apply_patch","cwd":"'"$TMP"'","tool_input":{"command":"*** Begin Patch\n*** Add File: companies/acme/skills/new.md\n+ok\n*** End Patch"},"tool_response":{"exit_code":0}}'
run_adapter "$payload_post_patch_parity" >/dev/null
log="$(cat "$TEST_LOG")"
assert_contains "$log" "reindex:companies/acme/skills/new.md"
assert_contains "$log" "journal-due"
reindex_line=$(grep -n "^reindex:companies/acme/skills/new.md$" "$TEST_LOG" | head -1 | cut -d: -f1)
autosave_line=$(grep -n "^autosave:companies/acme/skills/new.md$" "$TEST_LOG" | head -1 | cut -d: -f1)
if [ -z "$reindex_line" ] || [ -z "$autosave_line" ] || [ "$reindex_line" -ge "$autosave_line" ]; then
  echo "Expected reindex BEFORE hq-autocommit (reindex=$reindex_line autosave=$autosave_line)" >&2
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

# ----- context emission is ONE JSON document -----

# REGRESSION: Codex parses hook stdout as a single JSON document whenever it
# starts with "{", and rejects the whole thing if anything trails the object.
# HQ child hooks emit a mix of shapes — auto-session-project returns a
# Claude-style {"hookSpecificOutput": {...}} object, inject-policy-on-trigger
# returns bare text — and the adapter used to concatenate them verbatim. That
# produced JSON-then-text, which Codex failed wholesale ("UserPromptSubmit
# Failed"), silently dropping BOTH payloads. Every context-bearing event must
# emit exactly one well-formed object with both payloads folded in.
cat > "$TMP/.claude/hooks/auto-session-project.sh" <<'SH'
#!/bin/bash
cat >/dev/null
echo "auto-session-project" >> "$TEST_LOG"
printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":"<json-shaped-chunk>"}}'
exit 0
SH
cat > "$TMP/.claude/hooks/rewrite-resume-sentinel.sh" <<'SH'
#!/bin/bash
cat >/dev/null
echo "rewrite-resume-sentinel" >> "$TEST_LOG"
printf '%s\n' '<plain-text-chunk>'
exit 0
SH
chmod +x "$TMP/.claude/hooks/auto-session-project.sh" "$TMP/.claude/hooks/rewrite-resume-sentinel.sh"

out="$(run_adapter "$payload_prompt")"
printf '%s' "$out" | jq -e . >/dev/null || {
  echo "UserPromptSubmit stdout is not a single valid JSON document:" >&2
  printf '%s\n' "$out" >&2
  exit 1
}
ctx="$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext')"
assert_contains "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.hookEventName')" "UserPromptSubmit"
# Both shapes survive: the JSON chunk is unwrapped to its context, the text chunk
# is passed through — neither is dropped and neither corrupts the document.
assert_contains "$ctx" "<json-shaped-chunk>"
assert_contains "$ctx" "<plain-text-chunk>"
# The raw JSON wrapper of the child hook must NOT leak into the context string.
if printf '%s' "$ctx" | grep -qF 'hookSpecificOutput'; then
  echo "Child hook JSON wrapper leaked into additionalContext:" >&2
  printf '%s\n' "$ctx" >&2
  exit 1
fi

# SessionStart takes the same path and must also be a single JSON document.
out="$(run_adapter "$payload_session")"
printf '%s' "$out" | jq -e . >/dev/null || {
  echo "SessionStart stdout is not a single valid JSON document:" >&2
  printf '%s\n' "$out" >&2
  exit 1
}
assert_contains "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext')" "POLICY"

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
