#!/usr/bin/env bash
# hq-core: public
# US-402 P1: hq-agent-session fail-closed entrypoint tests
# Covers: valid request, missing companySlug, symlinked HQ root, traversal slug.

set -euo pipefail

SRC_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
SCRIPT="$SRC_ROOT/core/scripts/hq-agent-session.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }
pass() { echo "  ok: $1"; }

# Fixture HQ root with one present company
FIXTURE="$TMP/hq"
mkdir -p "$FIXTURE/core" "$FIXTURE/companies/indigo/settings" \
  "$FIXTURE/workspace/sessions" "$FIXTURE/.claude/hooks" \
  "$FIXTURE/core/knowledge/public/hq-core" \
  "$FIXTURE/core/scripts"
# core.yaml + schemas + scripts linked from real tree
cp "$SRC_ROOT/core/core.yaml" "$FIXTURE/core/core.yaml"
mkdir -p "$FIXTURE/core/schemas"
cp "$SRC_ROOT/core/schemas/"*.json "$FIXTURE/core/schemas/"
# Point script deps at real lib/ + hooks (absolute via env HQ_AGENT_WORKDIR for root only)
# We copy/symlink the scripts the entrypoint needs.
cp "$SCRIPT" "$FIXTURE/core/scripts/hq-agent-session.sh"
cp -R "$SRC_ROOT/core/scripts/lib" "$FIXTURE/core/scripts/lib"
cp "$SRC_ROOT/core/scripts/hq-session.sh" "$FIXTURE/core/scripts/hq-session.sh"
cp "$SRC_ROOT/.claude/hooks/master-hook.sh" "$FIXTURE/.claude/hooks/master-hook.sh"
cp "$SRC_ROOT/core/knowledge/public/hq-core/channel-writing-formats.md" \
  "$FIXTURE/core/knowledge/public/hq-core/channel-writing-formats.md" 2>/dev/null || \
  printf '# Channel Writing Formats\n\n## slack\n\nslack format\n' \
    > "$FIXTURE/core/knowledge/public/hq-core/channel-writing-formats.md"
printf '# AGENTS\nfixture charter\n' > "$FIXTURE/AGENTS.md"
printf '# Company\nindigo charter\n' > "$FIXTURE/companies/indigo/CLAUDE.md"
chmod +x "$FIXTURE/core/scripts/hq-agent-session.sh" \
  "$FIXTURE/core/scripts/hq-session.sh" \
  "$FIXTURE/.claude/hooks/master-hook.sh"
chmod +x "$FIXTURE/core/scripts/lib/"*.sh

export HOME="$TMP/home"
mkdir -p "$HOME"
export HQ_AGENT_WORKDIR="$FIXTURE"
export HQ_AGENT_SESSION_SKIP_PROVIDER=1

valid_req() {
  jq -nc \
    --arg co "${1:-indigo}" \
    --arg msg "${2:-hello}" \
    '{
      contractVersion: 1,
      agentUid: "agt_test",
      companySlug: $co,
      channel: "slack",
      convKey: "agt_test#slack:C1",
      messageText: $msg,
      provider: "claude",
      sender: {verified: true}
    }'
}

assert_envelope() {
  local body="$1"
  echo "$body" | jq -e '
    has("contractVersion") and has("disposition") and has("text") and has("artifacts")
    and (.disposition | type == "string")
    and (.artifacts | type == "array")
  ' >/dev/null || fail "response envelope invalid: $body"
}

# ── 1. valid request ────────────────────────────────────────────────────────
OUT="$(valid_req | bash "$FIXTURE/core/scripts/hq-agent-session.sh" 2>"$TMP/err1")" || RC=$?
RC="${RC:-0}"
[ "$RC" -eq 0 ] || fail "valid request exit $RC stderr=$(cat "$TMP/err1")"
assert_envelope "$OUT"
echo "$OUT" | jq -e '.disposition == "reply" and (.runDir | type == "string" and length > 0)' >/dev/null \
  || fail "valid request envelope missing runDir/reply: $OUT"
RUNDIR="$(echo "$OUT" | jq -r .runDir)"
[ -d "$RUNDIR" ] || fail "runDir does not exist: $RUNDIR"
# GNU stat first, BSD second — see the note in hq-agent-session-resume.test.sh.
# GNU's `-f` succeeds on Linux and prints a filesystem dump instead of failing
# over to `-c`, so the reversed order silently compares against the wrong thing.
MODE="$(stat -c %a "$RUNDIR" 2>/dev/null || stat -f %Lp "$RUNDIR" 2>/dev/null)"
[ "$MODE" = "700" ] || fail "runDir mode not 700: $MODE"
pass "valid request"

# ── 2. missing companySlug ──────────────────────────────────────────────────
BAD="$(valid_req | jq 'del(.companySlug)')"
RC=0
OUT="$(printf '%s' "$BAD" | bash "$FIXTURE/core/scripts/hq-agent-session.sh" 2>"$TMP/err2")" || RC=$?
[ "$RC" -eq 2 ] || fail "missing companySlug expected exit 2 got $RC"
grep -q 'hq-agent-session: invalid request' "$TMP/err2" || fail "missing stderr invalid request"
assert_envelope "$OUT"
echo "$OUT" | jq -e '.disposition == "error"' >/dev/null || fail "missing companySlug disposition"
pass "missing companySlug"

# ── 3. missing convKey (E2E schema) ─────────────────────────────────────────
BAD="$(valid_req | jq 'del(.convKey)')"
RC=0
OUT="$(printf '%s' "$BAD" | bash "$FIXTURE/core/scripts/hq-agent-session.sh" 2>"$TMP/err2b")" || RC=$?
[ "$RC" -eq 2 ] || fail "missing convKey expected exit 2 got $RC"
grep -q 'hq-agent-session: invalid request' "$TMP/err2b" || fail "convKey stderr"
pass "missing convKey"

# ── 4. symlinked HQ root ────────────────────────────────────────────────────
LINK="$TMP/hq-link"
ln -s "$FIXTURE" "$LINK"
RC=0
OUT="$(HQ_AGENT_WORKDIR="$LINK" valid_req | HQ_AGENT_WORKDIR="$LINK" bash "$FIXTURE/core/scripts/hq-agent-session.sh" 2>"$TMP/err3")" || RC=$?
[ "$RC" -eq 3 ] || fail "symlink root expected exit 3 got $RC out=$OUT err=$(cat "$TMP/err3")"
assert_envelope "$OUT"
pass "symlinked HQ root"

# ── 5. traversal slug ../other ──────────────────────────────────────────────
# Create a sibling dir that traversal might try to reach
mkdir -p "$FIXTURE/other/settings"
RC=0
OUT="$(valid_req '../other' | bash "$FIXTURE/core/scripts/hq-agent-session.sh" 2>"$TMP/err4")" || RC=$?
# Traversal fails charset or path guards → exit 6
[ "$RC" -eq 6 ] || fail "traversal slug expected exit 6 got $RC err=$(cat "$TMP/err4")"
assert_envelope "$OUT"
echo "$OUT" | jq -e '.disposition == "error"' >/dev/null || fail "traversal disposition"
pass "traversal slug ../other"

# ── 6. provider CLI resolves from a per-user bin dir ────────────────────────
# Regression: hq-agent-session is dispatched from a NON-login shell
# (systemd unit -> sudo -u <agent> bash -c), whose PATH is system-only.
# Provider CLIs install per-user — grok under ~/.grok/bin — and every adapter
# invokes its binary by BARE NAME. Before the entrypoint prepended the
# per-user bin dirs, every grok-box turn died at `grok: command not found`
# (exit 127); codex boxes survived only because codex happens to sit in
# /usr/local/bin. Assert the entrypoint resolves a CLI that exists ONLY under
# $HOME/.grok/bin and is not otherwise on PATH.
GROK_BIN="$HOME/.grok/bin"
SENTINEL="$TMP/grok-was-executed"
mkdir -p "$GROK_BIN"
# POSITIVE proof: the fake CLI records that it actually ran. Asserting only the
# ABSENCE of "command not found" would pass vacuously whenever the run errors
# before provider dispatch is ever reached.
printf '#!/usr/bin/env bash\ntouch %s\nexit 0\n' "$SENTINEL" > "$GROK_BIN/grok"
chmod +x "$GROK_BIN/grok"
case ":$PATH:" in
  *":$GROK_BIN:"*) fail "fixture invalid: $GROK_BIN already on PATH" ;;
esac
rm -f "$SENTINEL"
RC=0
OUT="$(valid_req | jq '.provider = "grok"' \
  | HQ_AGENT_SESSION_SKIP_PROVIDER=0 bash "$FIXTURE/core/scripts/hq-agent-session.sh" \
    2>"$TMP/err6")" || RC=$?
[ -f "$SENTINEL" ] || fail "provider CLI in \$HOME/.grok/bin was never executed (PATH regression) rc=$RC err=$(cat "$TMP/err6")"
grep -q 'command not found' "$TMP/err6" && fail "provider CLI not resolved: $(cat "$TMP/err6")"
assert_envelope "$OUT"
pass "provider CLI resolves from per-user bin dir"

echo "PASS: hq-agent-session.test.sh"
