#!/usr/bin/env bash
# codex-sandbox-danger-full-access.test.sh — regression battery for harness
# finding 2.3 ("Codex sandbox prevents required host operations", 851 events).
#
# Root cause: HQ ships `sandbox_mode = "danger-full-access"` in .codex/config.toml
# (HQ's safety boundary is its hooks, not the Codex sandbox), but HQ's own launch
# paths forced `codex exec --full-auto`. `--full-auto` (renamed `--approve-for-me`
# in newer Codex) force-enables the *workspace-write* sandbox, which OVERRIDES the
# config and:
#   - denies /tmp + $TMPDIR + ~/.cache writes and local socket binds on macOS
#     (git/Xcode cache, zsh/asdf heredoc temp files, agent-browser sockets), and
#   - cannot initialize bubblewrap networking on some Linux hosts
#     (`bwrap: loopback: Failed RTM_NEWADDR: Operation not permitted`).
#
# This test pins the fix: no HQ-shipped Codex launch path may force the
# workspace-write sandbox, every shipped Codex config must declare
# danger-full-access, and `codex-preflight.sh sandbox` must flag a broken posture.
#
# Explicitly wired into .github/workflows/pr-checks.yml — tests here are NOT
# auto-discovered (indigo-hq-core-staging-pr-mechanics rule 3).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "ok   [$1]"; }
fail() { FAIL=$((FAIL+1)); echo "FAIL [$1]: $2"; }

# Launch paths that instruct/emit a `codex exec` invocation. Comments that merely
# name the old flag are fine; an actual forced-sandbox invocation is not.
LAUNCH_PATHS=(
  ".claude/scripts/run-project.sh"
  ".claude/skills/execute-task/SKILL.md"
  "core/scripts/convert-codex.sh"
  "core/workers/public/dev-team"
)

echo "== 1. No HQ launch path forces the workspace-write sandbox =="
# Match real invocations only: `codex exec ... --full-auto`, a flag-array append
# `codex_flags+=(--full-auto` / `(--approve-for-me`, or a bare `--approve-for-me`
# command flag. Prose/comments referencing the name (`# --full-auto ...`) are
# excluded by requiring a command context.
HITS="$(cd "$ROOT" && grep -rnE \
  'codex exec[^#]*--(full-auto|approve-for-me)|codex_flags\+=\(--(full-auto|approve-for-me)' \
  "${LAUNCH_PATHS[@]}" 2>/dev/null)"
if [ -z "$HITS" ]; then
  ok "no forced workspace-write (--full-auto/--approve-for-me) in launch paths"
else
  fail "forced workspace-write present" "$(printf '%s' "$HITS" | tr '\n' '|' | cut -c1-400)"
fi

echo "== 2. run-project.sh permissions-on branch uses danger-full-access =="
if grep -qF 'codex_flags+=(--sandbox danger-full-access)' "$ROOT/.claude/scripts/run-project.sh"; then
  ok "run-project.sh appends --sandbox danger-full-access"
else
  fail "run-project.sh danger-full-access" "expected codex_flags+=(--sandbox danger-full-access)"
fi

echo "== 3. Shipped Codex configs declare danger-full-access =="
CFG="$ROOT/.codex/config.toml"
if grep -qE '^[[:space:]]*sandbox_mode[[:space:]]*=[[:space:]]*"danger-full-access"' "$CFG"; then
  ok ".codex/config.toml sandbox_mode=danger-full-access"
else
  fail ".codex/config.toml posture" "expected sandbox_mode = \"danger-full-access\""
fi
# convert-codex.sh writes the Codex config for older Claude-first roots — it must
# not seed the broken workspace-write default.
if grep -qE 'sandbox_mode = "danger-full-access"' "$ROOT/core/scripts/convert-codex.sh" \
   && ! grep -qE 'sandbox_mode = "workspace-write"' "$ROOT/core/scripts/convert-codex.sh"; then
  ok "convert-codex.sh seeds danger-full-access (not workspace-write)"
else
  fail "convert-codex.sh posture" "expected danger-full-access, found workspace-write"
fi

echo "== 4. codex-preflight.sh sandbox: OK on danger-full-access config =="
OUT_OK="$( (cd "$ROOT" && bash core/scripts/codex-preflight.sh sandbox) 2>&1 )"; RC_OK=$?
if [ "$RC_OK" -eq 0 ] && printf '%s' "$OUT_OK" | grep -qi 'danger-full-access (OK'; then
  ok "sandbox probe reports OK (exit 0) for danger-full-access posture"
else
  fail "sandbox probe OK path" "rc=$RC_OK out=$(printf '%s' "$OUT_OK" | tr '\n' ' ' | cut -c1-300)"
fi

echo "== 5. codex-preflight.sh sandbox: flags a workspace-write posture =="
TMPCFG="$(mktemp -d)"; printf 'sandbox_mode = "workspace-write"\n' > "$TMPCFG/config.toml"
OUT_BAD="$( (cd "$ROOT" && HQ_CODEX_CONFIG="$TMPCFG/config.toml" bash core/scripts/codex-preflight.sh sandbox) 2>&1 )"; RC_BAD=$?
rm -rf "$TMPCFG"
if [ "$RC_BAD" -ne 0 ] && printf '%s' "$OUT_BAD" | grep -qi 'BROKEN'; then
  ok "sandbox probe flags workspace-write (non-zero + actionable message)"
else
  fail "sandbox probe bad path" "rc=$RC_BAD out=$(printf '%s' "$OUT_BAD" | tr '\n' ' ' | cut -c1-300)"
fi

echo "== 6. Deliberate read-only analysis mode is preserved =="
# codex-debugger analysis skills intentionally use --sandbox read-only; the fix
# must not have swept those away.
if grep -rqF -- '--sandbox read-only' "$ROOT/core/workers/public/dev-team/codex-debugger"; then
  ok "codex-debugger read-only analysis mode intact"
else
  fail "read-only preserved" "expected --sandbox read-only in codex-debugger skills"
fi

echo "== 7. Worker/execute-task commands keep HQ hooks (the safety boundary) on =="
# danger-full-access grants host access, so hooks MUST run even in untrusted
# target repos: every codex-exec COMMAND line (those with -c model=) must carry
# --dangerously-bypass-hook-trust.
BADHOOK="$(cd "$ROOT" && grep -rnE 'codex exec (--sandbox (danger-full-access|read-only)) -c' \
  core/workers/public/dev-team .claude/skills/execute-task/SKILL.md 2>/dev/null \
  | grep -v -- '--dangerously-bypass-hook-trust')"
if [ -z "$BADHOOK" ]; then
  ok "all codex-exec command lines carry --dangerously-bypass-hook-trust"
else
  fail "hook-trust on command lines" "$(printf '%s' "$BADHOOK" | tr '\n' '|' | cut -c1-400)"
fi

echo "== 8. run-project.sh permissions-on branch already carries hook-trust =="
if grep -qE 'codex_flags=\(exec --dangerously-bypass-hook-trust' "$ROOT/.claude/scripts/run-project.sh"; then
  ok "run-project.sh builder passes --dangerously-bypass-hook-trust"
else
  fail "run-project hook-trust" "expected --dangerously-bypass-hook-trust in codex_flags"
fi

echo "== 9. convert-codex seeds approval_policy=never with danger-full-access =="
if grep -qE '^approval_policy = "never"' "$ROOT/core/scripts/convert-codex.sh"; then
  ok "convert-codex seeds approval_policy=never"
else
  fail "convert-codex approval_policy" "expected approval_policy = \"never\" in generated config"
fi

echo "== 10. convert-codex migrates a legacy workspace-write config in place =="
# Source the script's functions without executing main (guarded by BASH_SOURCE).
MIGDIR="$(mktemp -d)"
cat > "$MIGDIR/config.toml" <<'EOF'
sandbox_mode = "workspace-write"

[shell_environment_policy]
inherit = "core"

[sandbox_workspace_write]
network_access = true
EOF
(
  # is_legacy_* / migrate_* are pure helpers; pull them out and run against the fixture.
  # shellcheck disable=SC1090
  eval "$(sed -n '/^is_legacy_workspace_write_config()/,/^}/p;/^migrate_legacy_workspace_write_config()/,/^}/p' "$ROOT/core/scripts/convert-codex.sh")"
  if is_legacy_workspace_write_config "$MIGDIR/config.toml" \
     && migrate_legacy_workspace_write_config "$MIGDIR/config.toml"; then
    exit 0
  fi
  exit 1
)
MIGRC=$?
if [ "$MIGRC" -eq 0 ] \
   && grep -qE '^sandbox_mode = "danger-full-access"' "$MIGDIR/config.toml" \
   && grep -qE '^approval_policy = "never"' "$MIGDIR/config.toml" \
   && ! grep -qE 'workspace-write"' "$MIGDIR/config.toml"; then
  ok "legacy workspace-write config migrated to danger-full-access + approval_policy"
else
  fail "legacy migration" "rc=$MIGRC content=$(tr '\n' ';' < "$MIGDIR/config.toml" | cut -c1-200)"
fi
# A user-customized workspace-write config must NOT be migrated.
printf 'sandbox_mode = "workspace-write"\nmodel = "gpt-5.4"\napproval_policy = "on-request"\n' > "$MIGDIR/custom.toml"
(
  # shellcheck disable=SC1090
  eval "$(sed -n '/^is_legacy_workspace_write_config()/,/^}/p' "$ROOT/core/scripts/convert-codex.sh")"
  is_legacy_workspace_write_config "$MIGDIR/custom.toml"
)
if [ $? -ne 0 ]; then
  ok "user-customized workspace-write config is left untouched"
else
  fail "migration over-reach" "customized config wrongly classified as legacy"
fi
rm -rf "$MIGDIR"

echo "== 11. Probe: missing sandbox_mode key does not crash (set -e safe) =="
TMPEMPTY="$(mktemp -d)"; printf 'model = "gpt-5.4"\n' > "$TMPEMPTY/config.toml"
OUT_E="$( (cd "$ROOT" && HQ_CODEX_CONFIG="$TMPEMPTY/config.toml" bash core/scripts/codex-preflight.sh sandbox) 2>&1 )"; RC_E=$?
rm -rf "$TMPEMPTY"
if [ "$RC_E" -ne 0 ] && printf '%s' "$OUT_E" | grep -qi 'no sandbox_mode found'; then
  ok "missing sandbox_mode reaches the empty-mode branch (non-zero + message)"
else
  fail "missing sandbox_mode branch" "rc=$RC_E out=$(printf '%s' "$OUT_E" | tr '\n' ' ' | cut -c1-300)"
fi

echo "== 12. Probe: broken bwrap under danger-full-access is informational, not a failure =="
MOCK="$(mktemp -d)"
cat > "$MOCK/bwrap" <<'EOF'
#!/usr/bin/env bash
echo "bwrap: loopback: Failed RTM_NEWADDR: Operation not permitted" >&2
exit 1
EOF
chmod +x "$MOCK/bwrap"
printf 'sandbox_mode = "danger-full-access"\n' > "$MOCK/config.toml"
OUT_B="$( (cd "$ROOT" && HQ_SANDBOX_OS=Linux HQ_CODEX_CONFIG="$MOCK/config.toml" PATH="$MOCK:$PATH" \
  bash core/scripts/codex-preflight.sh sandbox) 2>&1 )"; RC_B=$?
rm -rf "$MOCK"
if [ "$RC_B" -eq 0 ] && printf '%s' "$OUT_B" | grep -qi 'bypasses bubblewrap'; then
  ok "danger-full-access + broken bwrap => exit 0 (informational)"
else
  fail "bwrap informational path" "rc=$RC_B out=$(printf '%s' "$OUT_B" | tr '\n' ' ' | cut -c1-300)"
fi

echo "== 13. Probe: broken bwrap under workspace-write posture IS a failure =="
MOCK2="$(mktemp -d)"
cat > "$MOCK2/bwrap" <<'EOF'
#!/usr/bin/env bash
echo "bwrap: setting up uid map: Permission denied" >&2
exit 1
EOF
chmod +x "$MOCK2/bwrap"
printf 'sandbox_mode = "workspace-write"\n' > "$MOCK2/config.toml"
OUT_W="$( (cd "$ROOT" && HQ_SANDBOX_OS=Linux HQ_CODEX_CONFIG="$MOCK2/config.toml" PATH="$MOCK2:$PATH" \
  bash core/scripts/codex-preflight.sh sandbox) 2>&1 )"; RC_W=$?
rm -rf "$MOCK2"
if [ "$RC_W" -ne 0 ] && printf '%s' "$OUT_W" | grep -qi 'CANNOT initialize'; then
  ok "workspace-write + broken bwrap => non-zero (actionable)"
else
  fail "bwrap failure path" "rc=$RC_W out=$(printf '%s' "$OUT_W" | tr '\n' ' ' | cut -c1-300)"
fi

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
