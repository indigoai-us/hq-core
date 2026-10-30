#!/usr/bin/env bash
# hq-core: public
# hq-agent-session-guard-parity.test.sh — a Slack, DM or job agent session runs
# the same in-turn guard hooks as an interactive Claude Code session in the HQ
# root.
#
# The claude adapter used to pass --settings pointing at an empty {} file and
# start claude from the company project directory, where Claude Code does not
# load the HQ root .claude/settings.json. No PreToolUse or PostToolUse hook ran
# inside the turn, so the credential guard and the cross-company scope guard
# never saw a tool call.
#
# This drives the real hq-agent-session.sh end to end against a copy of the
# real .claude/ and core/ trees, with a stub `claude` on PATH. The stub does
# what Claude Code does with --settings: it runs each hook command under
# `sh -c`, from the session cwd, with CLAUDE_PROJECT_DIR set to that cwd and
# its own session id (not the wrapper's run id) in the payload.

set -euo pipefail

SRC_ROOT="$(cd "$(dirname "$0")/../../.." && pwd -P)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/hq-agent-guard-parity.XXXXXX")"
TMP="$(cd "$TMP" && pwd -P)"
# Hook children that detach (CLI state refreshers) can still be writing into
# $TMP when the body ends; a failed removal must not fail the test.
cleanup() {
  rm -rf "$TMP" 2>/dev/null || { sleep 1; rm -rf "$TMP" 2>/dev/null || true; }
}
trap cleanup EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }
pass() { echo "  ok: $1"; }

command -v jq >/dev/null 2>&1 || fail "jq is required"

# Keep the fixture authoritative over any ambient session or root.
unset HQ_SESSION_ID CLAUDE_CODE_SESSION_ID CLAUDE_SESSION_ID \
      CODEX_SESSION_ID CODEX_THREAD_ID GROK_SESSION_ID \
      HQ_ROOT CLAUDE_PROJECT_DIR HQ_PARENT_SESSION_ID \
      HQ_SPAWN_COMPANY HQ_SPAWN_COMPANIES || true

FIXTURE="$TMP/hq"
mkdir -p "$FIXTURE/workspace/sessions"
cp -R "$SRC_ROOT/core" "$FIXTURE/core"
cp -R "$SRC_ROOT/.claude" "$FIXTURE/.claude"
rm -f "$FIXTURE/.claude/settings.local.json"
printf '# AGENTS\n' > "$FIXTURE/AGENTS.md"
mkdir -p "$FIXTURE/companies/indigo/settings" "$FIXTURE/companies/indigo/knowledge" \
  "$FIXTURE/companies/otherco/settings"
printf '# indigo\n' > "$FIXTURE/companies/indigo/CLAUDE.md"
printf 'fixture: indigo\n' > "$FIXTURE/companies/indigo/settings/marker.yaml"
printf 'fixture: otherco\n' > "$FIXTURE/companies/otherco/settings/marker.yaml"
printf 'indigo note\n' > "$FIXTURE/companies/indigo/knowledge/note.md"
printf 'otherco note\n' > "$FIXTURE/companies/otherco/CLAUDE.md"
printf 'companies:\n  indigo:\n    name: Indigo\n  otherco:\n    name: otherco\n' \
  > "$FIXTURE/companies/manifest.yaml"

export HOME="$TMP/home"
mkdir -p "$HOME"
# Fake credential file. The guard decides on the path; the content is a fixture.
printf 'registry=https://registry.example.invalid/\n' > "$HOME/.npmrc"

export HQ_AGENT_WORKDIR="$FIXTURE"
export HQ_HOOK_DEDUPE=0 HQ_HOOK_TIMEOUT_SENTRY=0 HQ_NO_UPDATE_CHECK=1
STUB_DIR="$TMP/stub"
mkdir -p "$STUB_DIR" "$TMP/bin"
export STUB_DIR

# ── stub claude ─────────────────────────────────────────────────────────────
cat > "$TMP/bin/claude" <<'STUB'
#!/usr/bin/env bash
# Stub Claude Code: runs --settings hooks the way the real CLI does.
set -u
settings="" prev=""
for a in "$@"; do
  [ "$prev" = "--settings" ] && settings="$a"
  prev="$a"
done
printf '%s\n' "$settings" > "$STUB_DIR/settings.path"
[ -n "$settings" ] && cp "$settings" "$STUB_DIR/settings.json"
pwd -P > "$STUB_DIR/cwd"
sid="claude-child-sid"
cwd="$(pwd -P)"

run_event() {
  local name="$1" event="$2" payload="$3" cmd rc n=0
  : > "$STUB_DIR/$name.rc"
  : > "$STUB_DIR/$name.out"
  : > "$STUB_DIR/$name.err"
  jq -r --arg ev "$event" \
    '(.hooks[$ev] // [])[] | (.hooks // [])[] | select(.type == "command") | .command' \
    "$settings" > "$STUB_DIR/$name.cmds" 2>/dev/null || : > "$STUB_DIR/$name.cmds"
  while IFS= read -r cmd; do
    [ -n "$cmd" ] || continue
    n=$((n + 1))
    rc=0
    printf '%s' "$payload" | CLAUDE_PROJECT_DIR="$cwd" sh -c "$cmd" \
      >>"$STUB_DIR/$name.out" 2>>"$STUB_DIR/$name.err" || rc=$?
    printf '%s\n' "$rc" >> "$STUB_DIR/$name.rc"
  done < "$STUB_DIR/$name.cmds"
  printf '%s\n' "$n" > "$STUB_DIR/$name.count"
}

tool_payload() {
  jq -nc --arg sid "$sid" --arg cwd "$cwd" --arg tool "$1" --argjson input "$2" \
    '{session_id:$sid, cwd:$cwd, hook_event_name:"PreToolUse", tool_name:$tool, tool_input:$input}'
}

run_event session-start SessionStart \
  "$(jq -nc --arg sid "$sid" --arg cwd "$cwd" '{session_id:$sid, cwd:$cwd, hook_event_name:"SessionStart", source:"startup"}')"
run_event cred-read PreToolUse \
  "$(tool_payload Bash '{"command":"cat ~/.npmrc"}')"
run_event foreign-read PreToolUse \
  "$(tool_payload Read "$(jq -nc --arg p "$HQ_FIXTURE_ROOT/companies/otherco/CLAUDE.md" '{file_path:$p}')")"
run_event own-read PreToolUse \
  "$(tool_payload Read "$(jq -nc --arg p "$HQ_FIXTURE_ROOT/companies/indigo/knowledge/note.md" '{file_path:$p}')")"
run_event post-tool PostToolUse \
  "$(jq -nc --arg sid "$sid" --arg cwd "$cwd" '{session_id:$sid, cwd:$cwd, hook_event_name:"PostToolUse", tool_name:"Bash", tool_input:{command:"echo ok"}, tool_response:{stdout:"ok"}}')"
echo "stub reply"
STUB
chmod +x "$TMP/bin/claude"
export PATH="$TMP/bin:$PATH"
export HQ_FIXTURE_ROOT="$FIXTURE"

blocked() {
  # A PreToolUse block is exit 2, or exit 0 with a deny decision on stdout.
  local name="$1"
  grep -qx 2 "$STUB_DIR/$name.rc" && return 0
  grep -q '"permissionDecision"[[:space:]]*:[[:space:]]*"deny"' "$STUB_DIR/$name.out" && return 0
  return 1
}

req() {
  jq -nc '{
    contractVersion: 1,
    agentUid: "agt_test",
    companySlug: "indigo",
    channel: "slack",
    convKey: "agt_test#slack:C1",
    messageText: "read the note",
    provider: "claude",
    sender: {verified: true}
  }'
}

# ── 1. a real agent turn reaches the stub ───────────────────────────────────
RC=0
OUT="$(req | bash "$FIXTURE/core/scripts/hq-agent-session.sh" 2>"$TMP/session.err")" || RC=$?
[ -s "$STUB_DIR/settings.path" ] \
  || fail "stub claude never ran (rc=$RC): $(head -c 800 "$TMP/session.err")"
case "$(cat "$STUB_DIR/cwd")" in
  "$FIXTURE"/companies/indigo/*) ;;
  *) fail "claude should start in the company project dir, got $(cat "$STUB_DIR/cwd")" ;;
esac
pass "agent turn launched claude from the company project dir"

# ── 2. settings carry the root guard events and nothing the wrapper owns ────
S="$STUB_DIR/settings.json"
for ev in PreToolUse PostToolUse SessionStart; do
  jq -e --arg ev "$ev" '(.hooks[$ev] // []) | length > 0' "$S" >/dev/null \
    || fail "--settings has no $ev hooks: $(head -c 400 "$S")"
done
for ev in UserPromptSubmit Stop; do
  jq -e --arg ev "$ev" '(.hooks[$ev] // []) | length == 0' "$S" >/dev/null \
    || fail "--settings must not carry $ev (the wrapper runs it, or it would stall a headless turn)"
done
pass "--settings carries SessionStart, PreToolUse and PostToolUse"

# ── 2b. disableAllHooks is pinned false in the generated settings ──────────
jq -e '.disableAllHooks == false' "$S" >/dev/null \
  || fail "--settings must set disableAllHooks false: $(head -c 400 "$S")"
pass "--settings pins disableAllHooks false"

# ── 2c. a project settings file in the agent cwd does not change --settings ─
AGENT_CWD="$(cat "$STUB_DIR/cwd")"
cp "$S" "$TMP/settings.before.json"
mkdir -p "$AGENT_CWD/.claude"
printf '{"disableAllHooks": true}\n' > "$AGENT_CWD/.claude/settings.json"
printf '{"disableAllHooks": true}\n' > "$AGENT_CWD/.claude/settings.local.json"
rm -f "$STUB_DIR/settings.path"
RC=0
req | bash "$FIXTURE/core/scripts/hq-agent-session.sh" >/dev/null 2>"$TMP/session-proj.err" || RC=$?
rm -f "$AGENT_CWD/.claude/settings.json" "$AGENT_CWD/.claude/settings.local.json"
[ -s "$STUB_DIR/settings.path" ] \
  || fail "turn with project disableAllHooks did not start (rc=$RC): $(head -c 400 "$TMP/session-proj.err")"
jq -S . "$TMP/settings.before.json" > "$TMP/settings.before.sorted"
jq -S . "$STUB_DIR/settings.json" > "$TMP/settings.after.sorted"
cmp -s "$TMP/settings.before.sorted" "$TMP/settings.after.sorted" \
  || fail "project disableAllHooks changed --settings: $(head -c 400 "$STUB_DIR/settings.json")"
jq -e '.disableAllHooks == false' "$STUB_DIR/settings.json" >/dev/null \
  || fail "project disableAllHooks true leaked into --settings"
pass "project .claude/settings.json with disableAllHooks true leaves --settings unchanged"

# ── 3. hook commands resolve from the HQ root, not the session cwd ──────────
for name in session-start cred-read foreign-read own-read post-tool; do
  [ "$(cat "$STUB_DIR/$name.count")" -ge 1 ] || fail "$name: no hook command ran"
  if grep -qx 127 "$STUB_DIR/$name.rc"; then
    fail "$name: hook command not found from the session cwd: $(head -c 300 "$STUB_DIR/$name.err")"
  fi
done
pass "hook commands run from the session cwd"

# ── 4. credential guard blocks a credential read inside the turn ────────────
blocked cred-read \
  || fail "credential read was not blocked: rc=$(tr '\n' ' ' < "$STUB_DIR/cred-read.rc") err=$(head -c 300 "$STUB_DIR/cred-read.err")"
grep -qi credential "$STUB_DIR/cred-read.err" "$STUB_DIR/cred-read.out" \
  || fail "credential read blocked by something other than the credential guard"
pass "credential guard blocks cat ~/.npmrc inside the agent turn"

# ── 5. scope guard binds the child session and enforces the company lock ────
grep -q 'company_slug: indigo' "$FIXTURE/workspace/sessions/claude-child-sid/meta.yaml" 2>/dev/null \
  || fail "claude's own session id was not bound to the dispatch company"
blocked foreign-read \
  || fail "cross-company read was not blocked: rc=$(tr '\n' ' ' < "$STUB_DIR/foreign-read.rc") err=$(head -c 300 "$STUB_DIR/foreign-read.err")"
if blocked own-read; then
  fail "own-company read was blocked: $(head -c 400 "$STUB_DIR/own-read.err") $(head -c 400 "$STUB_DIR/own-read.out")"
fi
pass "scope guard allows indigo and blocks otherco inside the agent turn"

# ── 6. no root settings: refuse to start claude, keep the resume record ─────
# A refusal must not look like a rejected --resume: the wrapper would delete
# the thread's resume record and retry a turn that can never start.
resume_lib() {
  # shellcheck source=../lib/session-resume.sh
  . "$FIXTURE/core/scripts/lib/session-resume.sh"
  "$@"
}
CONV="agt_test#slack:C1"
resume_lib session_resume_write "$CONV" claude "kept-session-id" >/dev/null \
  || fail "could not seed the resume record"
mv "$FIXTURE/.claude/settings.json" "$FIXTURE/.claude/settings.json.off"
rm -f "$STUB_DIR/settings.path"
RC=0
OUT="$(req | bash "$FIXTURE/core/scripts/hq-agent-session.sh" 2>"$TMP/session2.err")" || RC=$?
mv "$FIXTURE/.claude/settings.json.off" "$FIXTURE/.claude/settings.json"
[ ! -s "$STUB_DIR/settings.path" ] || fail "claude started without the HQ root guard settings"
[ "$RC" -ne 0 ] || fail "missing root settings should fail the turn: $OUT"
{ grep -q 'guard hooks' "$TMP/session2.err" || grep -q 'guard hooks' <<<"$OUT"; } \
  || fail "missing root settings error should name the guard hooks: $(head -c 400 "$TMP/session2.err") $OUT"
if grep -q 'resume rejected' "$TMP/session2.err"; then
  fail "a refusal was treated as a rejected resume: $(head -c 400 "$TMP/session2.err")"
fi
KEPT="$(resume_lib session_resume_read "$CONV" claude 2>/dev/null || true)"
[ "$KEPT" = "kept-session-id" ] || fail "refusal deleted the resume record (got '$KEPT')"
pass "missing root settings fails closed and keeps the resume record"

# ── 6b. rescue state: hooks moved into settings.local.json ──────────────────
# `hq rescue` can leave empty event arrays in settings.json and move the
# master-hook lines into settings.local.json (restore-hook-settings.sh).
# Claude Code merges both files; the adapter must too.
cp "$FIXTURE/.claude/settings.json" "$TMP/settings.json.orig"
jq '.hooks |= with_entries(.value = [])' "$TMP/settings.json.orig" > "$FIXTURE/.claude/settings.json"
jq '{hooks: .hooks}' "$TMP/settings.json.orig" > "$FIXTURE/.claude/settings.local.json"
rm -f "$STUB_DIR/settings.path"
RC=0
OUT="$(req | bash "$FIXTURE/core/scripts/hq-agent-session.sh" 2>"$TMP/session3.err")" || RC=$?
[ -s "$STUB_DIR/settings.path" ] \
  || fail "rescue-state settings refused the turn (rc=$RC): $(head -c 400 "$TMP/session3.err")"
blocked cred-read \
  || fail "credential read not blocked with hooks in settings.local.json"
pass "hooks in settings.local.json are loaded (rescue state)"

# ── 6c. hooks in both files are kept once ───────────────────────────────────
cp "$TMP/settings.json.orig" "$FIXTURE/.claude/settings.json"
rm -f "$STUB_DIR/settings.path"
RC=0
OUT="$(req | bash "$FIXTURE/core/scripts/hq-agent-session.sh" 2>"$TMP/session4.err")" || RC=$?
rm -f "$FIXTURE/.claude/settings.local.json"
[ -s "$STUB_DIR/settings.path" ] || fail "turn with both settings files did not start (rc=$RC)"
for ev in SessionStart PreToolUse PostToolUse; do
  want="$(jq --arg ev "$ev" '[.hooks[$ev][].hooks[].command] | unique | length' "$TMP/settings.json.orig")"
  got="$(jq --arg ev "$ev" '[.hooks[$ev][].hooks[].command] | length' "$STUB_DIR/settings.json")"
  [ "$got" = "$want" ] || fail "$ev commands duplicated across both files: got $got want $want"
done
pass "the same hooks in both files are kept once"

# ── 7. any HQ root path survives quoting into the hook command ──────────────
ODD="$TMP/hq o'brien \$HOME \"x\""
mkdir -p "$ODD/.claude" "$TMP/odd-run" "$TMP/odd-cwd"
jq -n '{hooks: {PreToolUse: [{matcher: "*", hooks: [{type: "command",
  command: "printf %s \"$CLAUDE_PROJECT_DIR\""}]}],
  UserPromptSubmit: [{hooks: [{type: "command", command: "true"}]}]}}' \
  > "$ODD/.claude/settings.json"
printf 'SYSTEM\n' > "$TMP/odd-run/system.txt"
printf 'USER\n' > "$TMP/odd-run/user.txt"
(
  # shellcheck source=../lib/provider-adapter-claude.sh
  . "$SRC_ROOT/core/scripts/lib/provider-adapter-claude.sh"
  HQ_ROOT="$ODD" HQ_AGENT_SESSION_RENDER_ONLY=1 \
    provider_adapter_claude "$TMP/odd-run" "$TMP/odd-cwd"
) || fail "render with an unusual HQ root path failed"
ODD_CMD="$(jq -r '.hooks.PreToolUse[0].hooks[0].command' "$TMP/odd-run/settings.json")"
ODD_GOT="$(cd "$TMP/odd-cwd" && CLAUDE_PROJECT_DIR="$TMP/odd-cwd" sh -c "$ODD_CMD")"
[ "$ODD_GOT" = "$ODD" ] || fail "hook saw CLAUDE_PROJECT_DIR='$ODD_GOT', want '$ODD'"
jq -e '.hooks | has("UserPromptSubmit") | not' "$TMP/odd-run/settings.json" >/dev/null \
  || fail "UserPromptSubmit leaked into --settings"
pass "hook commands see the HQ root as CLAUDE_PROJECT_DIR for any root path"

# ── 8. a command repeated under another matcher or timeout is kept once ─────
DUP="$TMP/hq-dup"
mkdir -p "$DUP/.claude" "$TMP/dup-run" "$TMP/dup-cwd"
jq -n '{hooks: {PreToolUse: [{matcher: "Bash", hooks: [{type: "command", command: "guard-a"}]}]}}' \
  > "$DUP/.claude/settings.json"
jq -n '{hooks: {PreToolUse: [{matcher: "*", hooks: [
  {type: "command", command: "guard-a", timeout: 60},
  {type: "command", command: "guard-b"}]}]}}' \
  > "$DUP/.claude/settings.local.json"
printf 'SYSTEM\n' > "$TMP/dup-run/system.txt"
printf 'USER\n' > "$TMP/dup-run/user.txt"
(
  # shellcheck source=../lib/provider-adapter-claude.sh
  . "$SRC_ROOT/core/scripts/lib/provider-adapter-claude.sh"
  HQ_ROOT="$DUP" HQ_AGENT_SESSION_RENDER_ONLY=1 \
    provider_adapter_claude "$TMP/dup-run" "$TMP/dup-cwd"
) || fail "render with repeated commands failed"
DUP_CMDS="$(jq -r '[.hooks.PreToolUse[].hooks[].command | sub("^.*; export CLAUDE_PROJECT_DIR; "; "")] | join(",")' \
  "$TMP/dup-run/settings.json")"
[ "$DUP_CMDS" = "guard-a,guard-b" ] || fail "repeated command not collapsed: got '$DUP_CMDS', want 'guard-a,guard-b'"
DUP_MATCHERS="$(jq -r '[.hooks.PreToolUse[].matcher] | join(",")' "$TMP/dup-run/settings.json")"
[ "$DUP_MATCHERS" = "Bash,*" ] || fail "first registration should win: matchers '$DUP_MATCHERS'"
pass "a command repeated across files under another matcher or timeout is kept once"

echo "PASS: hq-agent-session-guard-parity.test.sh"
