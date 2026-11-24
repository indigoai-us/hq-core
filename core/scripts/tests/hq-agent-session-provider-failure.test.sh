#!/usr/bin/env bash
# hq-core: public
# A provider that exits non-zero must leave its own error in the session text,
# and only its error.
#
# The claude CLI writes API errors such as "Failed to authenticate. API Error:
# 401" to stdout with exit 1 and an empty stderr. A company Outpost job that
# failed that way reported only "provider failed (exit 1)", and the run home
# holding provider.stdout was removed with the run, so the cause was lost.
# Other adapters (grok, sometimes codex) print the model's answer on stdout and
# still exit non-zero; that answer must never become the failure reason.

set -euo pipefail

SRC_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
SESSION_SH="$SRC_ROOT/core/scripts/hq-agent-session.sh"
# shellcheck source=../lib/session-parity-fixtures.sh
. "$SRC_ROOT/core/scripts/lib/session-parity-fixtures.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }
pass() { echo "  ok: $1"; }

PLAIN="hq-agent-session: provider failed (exit 1)"

# ── helper: session_provider_failure_text ───────────────────────────────────
for fn in session_failure_strip_controls session_failure_utf8_cut session_claude_cli_error_line session_provider_failure_text; do
  eval "$(sed -n '/^'"$fn"'() {/,/^}/p' "$SESSION_SH")"
  command -v "$fn" >/dev/null 2>&1 || fail "$fn not found in hq-agent-session.sh"
done

RD="$TMP/rd"
mkdir -p "$RD"
reset_rd() { rm -f "$RD/provider.stdout" "$RD/provider.stderr"; : > "$RD/provider.stderr"; }

reset_rd
printf 'Failed to authenticate. API Error: 401 Invalid bearer token\n' > "$RD/provider.stdout"
got="$(session_provider_failure_text "$RD" 1 claude)"
[ "$got" = "$PLAIN: Failed to authenticate. API Error: 401 Invalid bearer token" ] \
  || fail "claude: empty stderr must fall back to the CLI error on stdout (got: $got)"
pass "claude: empty stderr falls back to the CLI error on stdout"

reset_rd
printf "You've hit your session limit \xc2\xb7 resets 3pm (UTC)\n" > "$RD/provider.stdout"
got="$(session_provider_failure_text "$RD" 1 claude)"
[ "$got" = "$PLAIN: You've hit your session limit · resets 3pm (UTC)" ] \
  || fail "claude: usage-limit line must be kept (got: $got)"
pass "claude: usage-limit line is kept"

reset_rd
printf 'Here is the answer: Acme Corp owes 4,200 to Jane Doe\n' > "$RD/provider.stdout"
got="$(session_provider_failure_text "$RD" 1 grok)"
[ "$got" = "$PLAIN" ] || fail "grok: answer on stdout must not become the reason (got: $got)"
pass "grok: non-zero exit with an answer on stdout keeps the plain reason"

reset_rd
printf 'Error: the customer list follows\nJane Doe, jane@example.com\n' > "$RD/provider.stdout"
got="$(session_provider_failure_text "$RD" 1 codex)"
[ "$got" = "$PLAIN" ] || fail "codex: stdout must not become the reason (got: $got)"
got="$(session_provider_failure_text "$RD" 1)"
[ "$got" = "$PLAIN" ] || fail "no provider: stdout must not become the reason (got: $got)"
pass "codex and unnamed providers keep the plain reason"

reset_rd
printf 'The report is done and lists three accounts.\n' > "$RD/provider.stdout"
got="$(session_provider_failure_text "$RD" 1 claude)"
[ "$got" = "$PLAIN" ] || fail "claude: a line that is not a CLI error must be ignored (got: $got)"
pass "claude: a non-error stdout line is ignored"

reset_rd
printf 'Partial answer with Jane Doe\n\nAPI Error: 529 Overloaded\n\n  \n' > "$RD/provider.stdout"
got="$(session_provider_failure_text "$RD" 1 claude)"
[ "$got" = "$PLAIN: API Error: 529 Overloaded" ] \
  || fail "claude: only the last non-empty line may be kept (got: $got)"
pass "claude: only the last non-empty line is kept"

while IFS= read -r cli_line; do
  reset_rd
  printf '%s\n' "$cli_line" > "$RD/provider.stdout"
  got="$(session_provider_failure_text "$RD" 1 claude)"
  [ "$got" = "$PLAIN: $cli_line" ] || fail "claude: real CLI line must be kept: $cli_line (got: $got)"
done <<'LINES'
Failed to authenticate. API Error: 401 Invalid bearer token
Failed to authenticate: OAuth token revoked. Please log in again or contact your admin
API Error: 529 Overloaded
Error: Reached max turns (1)
Invalid API key · Please run /login
Invalid auth token · Fix external auth token
Not logged in · Please run /login
OAuth token revoked · Please run /login
OAuth token has expired
Credit balance is too low
Claude AI usage limit reached|999999999
You've hit your limit · resets 3pm (UTC)
You've hit your session limit · resets 3pm (UTC)
Prompt is too long
Request rejected (429)
LINES
pass "claude: real CLI error lines are kept"

while IFS= read -r answer_line; do
  reset_rd
  printf '%s\n' "$answer_line" > "$RD/provider.stdout"
  got="$(session_provider_failure_text "$RD" 1 claude)"
  [ "$got" = "$PLAIN" ] || fail "claude: answer line must not become the reason: $answer_line (got: $got)"
done <<'LINES'
the deploy step returned Error: 403 for user bob@example.com
Your daily limit reached 80%; customer Jane Doe owes $4,200.
Customer login Failed to authenticate for jane@example.com
Summary: OAuth token rotation is scheduled for Acme Corp
The invoice says Credit balance is too low for Acme Corp
Note: Prompt is too long for the Jane Doe report
LINES
pass "claude: answer lines that contain error words mid-line keep the plain reason"

reset_rd
{
  printf 'Here is the deploy summary for Acme Corp.\n'
  printf 'Step one finished for jane@example.com.\n'
  printf 'Step two finished for bob@example.com.\n'
  printf 'The final step returned Error: 403 for user bob@example.com\n'
} > "$RD/provider.stdout"
got="$(session_provider_failure_text "$RD" 1 claude)"
[ "$got" = "$PLAIN" ] || fail "claude: a multi-line answer must keep the plain reason (got: $got)"
reset_rd
printf 'Answer line one\nAnswer line two\nAPI Error: 529 Overloaded\n' > "$RD/provider.stdout"
got="$(session_provider_failure_text "$RD" 1 claude)"
[ "$got" = "$PLAIN" ] || fail "claude: stdout with three non-empty lines must keep the plain reason (got: $got)"
pass "claude: multi-line stdout keeps the plain reason"

reset_rd
{ head -c 1100 /dev/zero | tr '\0' 'a'; printf '\nAPI Error: 529 Overloaded\n'; } > "$RD/provider.stdout"
got="$(session_provider_failure_text "$RD" 1 claude)"
[ "$got" = "$PLAIN" ] || fail "claude: stdout over 1024 bytes must keep the plain reason (got: ${got:0:120})"
pass "claude: stdout over 1024 bytes keeps the plain reason"

reset_rd
printf '\033[2KAPI Error: 500 Internal path a/b\\c\033[0m\033]0;title\007\033]8;;https://example.com/x\033\\ link\r\a\b\n' > "$RD/provider.stdout"
got="$(session_provider_failure_text "$RD" 1 claude)"
[ "$got" = "$PLAIN: API Error: 500 Internal path a/b\\c link" ] \
  || fail "claude: control characters and ESC sequences must be stripped (got: $(printf '%s' "$got" | od -c | head -4))"
printf 'bad\033[1m thing\a\r\nsecond\tline\n' > "$RD/provider.stderr"
got="$(session_provider_failure_text "$RD" 1 claude)"
[ "$got" = "$PLAIN: bad thing secondline" ] \
  || fail "stderr: control characters and ESC sequences must be stripped (got: $(printf '%s' "$got" | od -c | head -3))"
pass "control characters and ESC sequences are stripped from stdout and stderr"

reset_rd
{ printf 'API Error: '; for _ in $(seq 1 200); do printf '\xc3\xa9'; done; printf '\n'; } > "$RD/provider.stdout"
got="$(session_provider_failure_text "$RD" 1 claude)"
detail="${got#"$PLAIN: "}"
[ "$detail" != "$got" ] || fail "claude: long error line was dropped (got: ${got:0:80})"
bytes="$(printf '%s' "$detail" | wc -c | tr -d ' ')"
[ "$bytes" -le 300 ] || fail "claude: detail must be at most 300 bytes (got $bytes)"
[ "$bytes" -ge 290 ] || fail "claude: detail cut too short ($bytes bytes)"
printf '%s' "$detail" | iconv -f UTF-8 -t UTF-8 >/dev/null 2>&1 \
  || fail "claude: cut detail must be valid UTF-8"
pass "claude: long line is cut to 300 bytes on a UTF-8 boundary ($bytes bytes)"

reset_rd
printf 'stderr reason\nsecond line\n' > "$RD/provider.stderr"
printf 'API Error: 401\n' > "$RD/provider.stdout"
got="$(session_provider_failure_text "$RD" 2 claude)"
[ "$got" = "hq-agent-session: provider failed (exit 2): stderr reason second line" ] \
  || fail "non-empty stderr must win over stdout (got: $got)"
pass "non-empty stderr still wins"

rm -f "$RD/provider.stdout" "$RD/provider.stderr"
got="$(session_provider_failure_text "$RD" 1 claude)"
[ "$got" = "$PLAIN" ] || fail "missing files must keep the plain reason (got: $got)"
pass "no provider output keeps the plain reason"

# ── end to end through hq-agent-session with a claude stub ──────────────────
FIXTURE="$TMP/hq"
FIXTURE_SRC="$(session_parity_fixtures_dir)"
mkdir -p "$FIXTURE/core/schemas" "$FIXTURE/core/scripts" \
  "$FIXTURE/core/knowledge/public/hq-core/agent-session-constants" \
  "$FIXTURE/workspace/sessions" "$FIXTURE/.claude/hooks" \
  "$FIXTURE/companies/indigo/settings" \
  "$FIXTURE/personal/knowledge/public/agent-capabilities"
cp "$SRC_ROOT/core/core.yaml" "$FIXTURE/core/core.yaml"
cp "$SRC_ROOT/core/schemas/"*.json "$FIXTURE/core/schemas/"
cp "$SESSION_SH" "$FIXTURE/core/scripts/"
cp -R "$SRC_ROOT/core/scripts/lib" "$FIXTURE/core/scripts/lib"
cp "$SRC_ROOT/core/scripts/hq-session.sh" "$FIXTURE/core/scripts/"
cp "$SRC_ROOT/.claude/hooks/master-hook.sh" "$FIXTURE/.claude/hooks/"
cp "$SRC_ROOT/.claude/hooks/hook-timeout-probe.sh" "$FIXTURE/.claude/hooks/"
cp "$SRC_ROOT/core/knowledge/public/hq-core/channel-writing-formats.md" \
  "$FIXTURE/core/knowledge/public/hq-core/" 2>/dev/null || \
  printf '# Channel Writing Formats\n\n## slack\n\nslack\n' \
    > "$FIXTURE/core/knowledge/public/hq-core/channel-writing-formats.md"
cp "$SRC_ROOT/core/knowledge/public/hq-core/agent-session-constants/"*.txt \
  "$FIXTURE/core/knowledge/public/hq-core/agent-session-constants/"
cp "$FIXTURE_SRC/agent-contract/hq-agent-contract.md" \
  "$FIXTURE/personal/knowledge/public/agent-capabilities/hq-agent-contract.md"
printf '# AGENTS\nprovider failure fixture charter\n' > "$FIXTURE/AGENTS.md"
printf '# Company\nindigo provider failure charter\n' > "$FIXTURE/companies/indigo/CLAUDE.md"
printf '{"hooks":{"PreToolUse":[{"matcher":"*","hooks":[{"type":"command","command":"true"}]}]}}\n' \
  > "$FIXTURE/.claude/settings.json"
chmod +x "$FIXTURE/core/scripts/"*.sh "$FIXTURE/core/scripts/lib/"*.sh \
  "$FIXTURE/.claude/hooks/master-hook.sh"

export HOME="$TMP/home"
mkdir -p "$HOME"

REQ="$TMP/request.json"
cat > "$REQ" <<'JSON'
{"contractVersion":1,"agentUid":"agt_provider_failure_test","companySlug":"indigo","channel":"job","convKey":"company-job:provider-failure-test","messageText":"count files","provider":"claude","sender":{"verified":true}}
JSON

STUB="$TMP/stub-bin"
mkdir -p "$STUB"
cat > "$STUB/claude" <<'STUBEOF'
#!/usr/bin/env bash
echo "Failed to authenticate. API Error: 401 Invalid bearer token"
exit 1
STUBEOF
chmod +x "$STUB/claude"

set +e
( cd "$FIXTURE" && PATH="$STUB:$PATH" HQ_AGENT_WORKDIR="$FIXTURE" \
  bash core/scripts/hq-agent-session.sh < "$REQ" > "$TMP/engine.out" 2> "$TMP/engine.err" )
rc=$?
set -e
[ "$rc" -eq 1 ] || fail "failed provider must exit the session with 1 (got $rc): $(tail -c 300 "$TMP/engine.err")"
text="$(jq -r '.text' "$TMP/engine.out" 2>/dev/null || true)"
disposition="$(jq -r '.disposition' "$TMP/engine.out" 2>/dev/null || true)"
[ "$disposition" = "error" ] || fail "failed provider must reply with disposition error (got: $(cat "$TMP/engine.out"))"
[ "$text" = "$PLAIN: Failed to authenticate. API Error: 401 Invalid bearer token" ] \
  || fail "session text must carry the claude CLI error (got: $text; stderr: $(tail -c 300 "$TMP/engine.err"))"
pass "claude session reply carries the CLI's stdout error"

echo "hq-agent-session-provider-failure: all passed"
