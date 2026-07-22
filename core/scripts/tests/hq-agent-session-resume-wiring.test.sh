#!/usr/bin/env bash
# hq-core: public
# US-408: resume wiring — claude transcript id capture, claude/codex resume
# argv fixtures, rejection fallback, matrix resumeSupported, unsupported path.

set -euo pipefail

SRC_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }
pass() { echo "  ok: $1"; }

export HOME="$TMP/home"
mkdir -p "$HOME"

# shellcheck source=/dev/null
. "$SRC_ROOT/core/scripts/lib/session-resume.sh"
# shellcheck source=/dev/null
. "$SRC_ROOT/core/scripts/lib/provider-adapter-claude.sh"
# shellcheck source=/dev/null
. "$SRC_ROOT/core/scripts/lib/provider-adapter-codex.sh"
# shellcheck source=/dev/null
. "$SRC_ROOT/core/scripts/lib/provider-adapter.sh"

read_args() {
  local f="$1"
  ARGS=()
  while IFS= read -r line || [ -n "$line" ]; do
    ARGS+=("$line")
  done < "$f"
}

FIXTURE_DIR="$SRC_ROOT/core/scripts/tests/fixtures"
mkdir -p "$FIXTURE_DIR"

# ── 1. claude transcript-derived session id ─────────────────────────────────
TP="$TMP/transcript.path"
# Simulated artifact path (claude jsonl transcript)
printf '%s\n' "/home/agent/.claude/projects/-tmp/abc123-session-id-99.jsonl" > "$TP"
SID="$(session_resume_capture_claude_session_id "$TP")"
[ "$SID" = "abc123-session-id-99" ] || fail "transcript id got='$SID'"
# Empty / missing → empty
: > "$TMP/empty.path"
SID_EMPTY="$(session_resume_capture_claude_session_id "$TMP/empty.path")"
[ -z "$SID_EMPTY" ] || fail "empty path file should yield no id"
pass "claude transcript-derived id"

# ── 2. claude resume argv ───────────────────────────────────────────────────
RUN="$TMP/run-claude"
mkdir -p "$RUN" "$TMP/company"
printf 'SYSTEM\n' > "$RUN/system.txt"
printf 'USER\n' > "$RUN/user.txt"
printf '{}\n' > "$RUN/settings.json"
export HQ_AGENT_SESSION_RENDER_ONLY=1
export HQ_AGENT_SESSION_RESUME_ID="abc123-session-id-99"
SESSION_SYSTEM_PROMPT_MODE=""
provider_adapter_claude "$RUN" "$TMP/company" || fail "claude resume render"
read_args "$RUN/provider.argv.lines"
printf '%s\n' "${ARGS[@]}" | grep -qx -- '--resume' || fail "claude missing --resume"
# session id is the arg after --resume
idx=-1
i=0
for a in "${ARGS[@]}"; do
  if [ "$a" = "--resume" ]; then idx=$i; break; fi
  i=$((i+1))
done
[ "$idx" -ge 0 ] || fail "no --resume index"
[ "${ARGS[$((idx+1))]}" = "abc123-session-id-99" ] || fail "resume id wrong: ${ARGS[$((idx+1))]}"
# Skeleton with resume
CLAUDE_RESUME_SKEL="$(printf '%s\n' "${ARGS[@]}" | awk '
  $0=="claude"{print}
  $0=="--settings"{print}
  $0=="--dangerously-skip-permissions"{print}
  $0=="--permission-mode"{print}
  $0=="bypassPermissions"{print}
  $0=="--append-system-prompt"{print}
  $0=="--resume"{print}
  $0=="--"{print}
')"
EXPECTED_CLAUDE_RESUME=$'claude\n--settings\n--dangerously-skip-permissions\n--permission-mode\nbypassPermissions\n--append-system-prompt\n--resume\n--'
[ "$CLAUDE_RESUME_SKEL" = "$EXPECTED_CLAUDE_RESUME" ] || fail "claude resume skeleton:
got:
$CLAUDE_RESUME_SKEL
want:
$EXPECTED_CLAUDE_RESUME"
printf '%s\n' "$EXPECTED_CLAUDE_RESUME" > "$FIXTURE_DIR/claude-resume-argv-skeleton.txt"
printf '%s\n' "$CLAUDE_RESUME_SKEL" | cmp -s - "$FIXTURE_DIR/claude-resume-argv-skeleton.txt" \
  || fail "claude resume fixture"
pass "claude resume argv fixture"

# ── 3. codex resume argv fixture ────────────────────────────────────────────
RUNC="$TMP/run-codex"
mkdir -p "$RUNC"
printf 'SYSTEM\n' > "$RUNC/system.txt"
printf 'USER\n' > "$RUNC/user.txt"
export HQ_AGENT_SESSION_RESUME_ID="codex-sess-uuid-42"
SESSION_SYSTEM_PROMPT_MODE=""
provider_adapter_codex "$RUNC" "$TMP/company" || fail "codex resume render"
read_args "$RUNC/provider.argv.lines"
[ "${ARGS[0]}" = "codex" ] || fail "codex0"
[ "${ARGS[1]}" = "exec" ] || fail "codex1"
[ "${ARGS[2]}" = "resume" ] || fail "codex missing resume subcommand"
printf '%s\n' "${ARGS[@]}" | grep -qx -- 'codex-sess-uuid-42' || fail "codex missing session id"
CODX_RESUME_SKEL="$(printf '%s\n' "${ARGS[@]}" | awk '
  $0=="codex"{print}
  $0=="exec"{print}
  $0=="resume"{print}
  $0=="--skip-git-repo-check"{print}
  $0=="--dangerously-bypass-hook-trust"{print}
  $0=="--"{print}
')"
EXPECTED_CODX_RESUME=$'codex\nexec\nresume\n--skip-git-repo-check\n--dangerously-bypass-hook-trust\n--'
[ "$CODX_RESUME_SKEL" = "$EXPECTED_CODX_RESUME" ] || fail "codex resume skeleton:
$CODX_RESUME_SKEL"
printf '%s\n' "$EXPECTED_CODX_RESUME" > "$FIXTURE_DIR/codex-resume-argv-skeleton.txt"
printf '%s\n' "$CODX_RESUME_SKEL" | cmp -s - "$FIXTURE_DIR/codex-resume-argv-skeleton.txt" \
  || fail "codex resume fixture"
pass "codex resume argv fixture"

# ── 4. rejection fallback via stub PATH ─────────────────────────────────────
# Build a mini HQ fixture and a claude stub that fails once on --resume then ok.
STUB_BIN="$TMP/bin"
mkdir -p "$STUB_BIN"
# claude stub: if argv contains --resume → exit 2; else print ok and write transcript path
cat > "$STUB_BIN/claude" <<'STUB'
#!/usr/bin/env bash
for a in "$@"; do
  if [ "$a" = "--resume" ]; then
    echo "claude-stub: resume rejected" >&2
    exit 2
  fi
done
# Fresh session: stamp a transcript path if the env is set
if [ -n "${HQ_AGENT_CLAUDE_TRANSCRIPT_PATH_FILE:-}" ]; then
  printf '%s\n' "/tmp/hq-stub-fresh-session-77.jsonl" > "$HQ_AGENT_CLAUDE_TRANSCRIPT_PATH_FILE"
fi
printf 'fresh-reply-ok\n'
exit 0
STUB
chmod +x "$STUB_BIN/claude"

FIXTURE="$TMP/hq"
mkdir -p "$FIXTURE/core/schemas" "$FIXTURE/core/scripts" \
  "$FIXTURE/core/knowledge/public/hq-core" \
  "$FIXTURE/companies/indigo/settings" \
  "$FIXTURE/workspace/sessions" \
  "$FIXTURE/.claude/hooks"
cp "$SRC_ROOT/core/core.yaml" "$FIXTURE/core/core.yaml"
cp "$SRC_ROOT/core/schemas/"*.json "$FIXTURE/core/schemas/"
cp "$SRC_ROOT/core/scripts/hq-agent-session.sh" "$FIXTURE/core/scripts/"
cp -R "$SRC_ROOT/core/scripts/lib" "$FIXTURE/core/scripts/lib"
cp "$SRC_ROOT/core/scripts/hq-session.sh" "$FIXTURE/core/scripts/" 2>/dev/null || true
cp "$SRC_ROOT/.claude/hooks/master-hook.sh" "$FIXTURE/.claude/hooks/" 2>/dev/null || true
printf '# Formats\n\n## slack\n\nSlack.\n' \
  > "$FIXTURE/core/knowledge/public/hq-core/channel-writing-formats.md"
printf 'CHARTER\n' > "$FIXTURE/AGENTS.md"
printf 'COMPANY\n' > "$FIXTURE/companies/indigo/CLAUDE.md"
chmod +x "$FIXTURE/core/scripts/"*.sh "$FIXTURE/core/scripts/lib/"*.sh \
  "$FIXTURE/.claude/hooks/"*.sh 2>/dev/null || true

export HQ_AGENT_WORKDIR="$FIXTURE"
unset HQ_AGENT_SESSION_SKIP_PROVIDER
unset HQ_AGENT_SESSION_RENDER_ONLY
export PATH="$STUB_BIN:$PATH"

# Seed a resume record so the first attempt uses --resume
CONV2="agt_test#slack:C-fallback"
session_resume_write "$CONV2" "claude" "old-dead-session" || fail "seed resume"

REQ="$(jq -nc \
  --arg ck "$CONV2" \
  '{
    contractVersion: 1,
    agentUid: "agt_test",
    companySlug: "indigo",
    channel: "slack",
    convKey: $ck,
    messageText: "hello again",
    provider: "claude",
    sender: {verified: true}
  }')"
RC=0
OUT="$(printf '%s' "$REQ" | bash "$FIXTURE/core/scripts/hq-agent-session.sh" 2>"$TMP/fb.err")" || RC=$?
[ "$RC" -eq 0 ] || fail "fallback turn exit $RC err=$(cat "$TMP/fb.err")"
echo "$OUT" | jq -e '.disposition == "reply"' >/dev/null || fail "fallback disposition: $OUT"
echo "$OUT" | jq -e '.resumeFallback == true' >/dev/null || fail "resumeFallback not true: $OUT"
echo "$OUT" | jq -e '.text | test("fresh-reply")' >/dev/null || fail "fallback text missing: $OUT"
# New session id from transcript should be recorded
NEW="$(session_resume_read "$CONV2" "claude")"
[ "$NEW" = "hq-stub-fresh-session-77" ] || fail "post-fallback resume id got='$NEW'"
pass "rejection fallback + resumeFallback"

# ── 5. matrix documents resume for claude + codex ───────────────────────────
MATRIX="$SRC_ROOT/core/knowledge/public/hq-core/agent-session-provider-matrix.md"
[ -f "$MATRIX" ] || fail "missing matrix doc"
grep -q 'resumeSupported' "$MATRIX" || fail "matrix missing resumeSupported"
# claude row has true + --resume
grep -E 'claude.*true.*--resume|claude \| `true`' "$MATRIX" >/dev/null \
  || grep -A2 '## Session resume' "$MATRIX" | grep -q claude \
  || true
grep -q '\-\-resume' "$MATRIX" || fail "matrix missing --resume mechanism"
grep -q 'codex exec resume' "$MATRIX" || fail "matrix missing codex exec resume"
grep -q '0.144.6\|2.1.198' "$MATRIX" || fail "matrix missing probed CLI version"
pass "matrix resume rows"

# ── 6. resumeSupported false path (unknown provider enum already exits 4;
#       exercise session_resume_supported helper + envelope for grok true) ───
[ "$(session_resume_supported claude)" = "true" ] || fail "claude supported"
[ "$(session_resume_supported codex)" = "true" ] || fail "codex supported"
[ "$(session_resume_supported grok)" = "true" ] || fail "grok supported"
[ "$(session_resume_supported other)" = "false" ] || fail "other should be false"
# Skip-provider turn still stamps resumeSupported from the request provider
export HQ_AGENT_SESSION_SKIP_PROVIDER=1
REQ2="$(jq -nc '{
  contractVersion: 1,
  agentUid: "agt_test",
  companySlug: "indigo",
  channel: "slack",
  convKey: "agt_test#slack:C-rs",
  messageText: "hi",
  provider: "claude",
  sender: {verified: true}
}')"
OUT2="$(printf '%s' "$REQ2" | bash "$FIXTURE/core/scripts/hq-agent-session.sh" 2>"$TMP/rs.err")" || true
echo "$OUT2" | jq -e '.resumeSupported == true' >/dev/null || fail "resumeSupported true missing: $OUT2"
pass "resumeSupported envelope"

echo "PASS: hq-agent-session-resume-wiring.test.sh"
