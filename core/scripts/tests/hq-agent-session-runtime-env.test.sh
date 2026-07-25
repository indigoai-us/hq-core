#!/usr/bin/env bash
# hq-core: public
# Runtime-environment regressions from the first live fleet turn (2026-07-24):
#   1. HOME unset (systemd/service context) must not crash the engine —
#      set -u killed every live turn at run_dir derivation before this guard.
#   2. A provider helper process that outlives the CLI and holds stdout open
#      must not hang the turn — stdout is file-captured, never a pipe.

set -euo pipefail

SRC_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
# shellcheck source=../lib/session-parity-fixtures.sh
. "$SRC_ROOT/core/scripts/lib/session-parity-fixtures.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }
pass() { echo "  ok: $1"; }

# ── offline fixture HQ root (same shape as the parity harness) ──────────────
FIXTURE="$TMP/hq"
FIXTURE_SRC="$(session_parity_fixtures_dir)"
mkdir -p "$FIXTURE/core/schemas" "$FIXTURE/core/scripts" \
  "$FIXTURE/core/knowledge/public/hq-core/agent-session-constants" \
  "$FIXTURE/workspace/sessions" "$FIXTURE/.claude/hooks" \
  "$FIXTURE/companies/indigo/settings" \
  "$FIXTURE/personal/knowledge/public/agent-capabilities"
cp "$SRC_ROOT/core/core.yaml" "$FIXTURE/core/core.yaml"
cp "$SRC_ROOT/core/schemas/"*.json "$FIXTURE/core/schemas/"
cp "$SRC_ROOT/core/scripts/hq-agent-session.sh" "$FIXTURE/core/scripts/"
cp -R "$SRC_ROOT/core/scripts/lib" "$FIXTURE/core/scripts/lib"
cp "$SRC_ROOT/core/scripts/hq-session.sh" "$FIXTURE/core/scripts/"
cp "$SRC_ROOT/.claude/hooks/master-hook.sh" "$FIXTURE/.claude/hooks/"
cp "$SRC_ROOT/core/knowledge/public/hq-core/channel-writing-formats.md" \
  "$FIXTURE/core/knowledge/public/hq-core/" 2>/dev/null || \
  printf '# Channel Writing Formats\n\n## slack\n\nslack\n' \
    > "$FIXTURE/core/knowledge/public/hq-core/channel-writing-formats.md"
cp "$SRC_ROOT/core/knowledge/public/hq-core/agent-session-constants/"*.txt \
  "$FIXTURE/core/knowledge/public/hq-core/agent-session-constants/"
cp "$FIXTURE_SRC/agent-contract/hq-agent-contract.md" \
  "$FIXTURE/personal/knowledge/public/agent-capabilities/hq-agent-contract.md"
printf '# AGENTS\nruntime-env fixture charter\n' > "$FIXTURE/AGENTS.md"
printf '# Company\nindigo runtime-env charter\n' > "$FIXTURE/companies/indigo/CLAUDE.md"
chmod +x "$FIXTURE/core/scripts/"*.sh "$FIXTURE/core/scripts/lib/"*.sh \
  "$FIXTURE/.claude/hooks/master-hook.sh"

export HQ_AGENT_WORKDIR="$FIXTURE"

REQ="$TMP/request.json"
cat > "$REQ" <<'JSON'
{"contractVersion":1,"agentUid":"agt_runtime_env_test","companySlug":"indigo","channel":"slack","convKey":"agt_runtime_env_test#slack:C-runtime-env","messageText":"runtime env regression turn","provider":"codex","sender":{"verified":true}}
JSON

# ── 1. HOME unset must not crash (service/systemd context) ──────────────────
mkdir -p "$TMP/notmphome"
RC=0
OUT="$(cd "$FIXTURE" && env -u HOME \
  TMPDIR="$TMP/notmphome" \
  HQ_AGENT_WORKDIR="$FIXTURE" \
  HQ_AGENT_SESSION_SKIP_PROVIDER=1 \
  bash core/scripts/hq-agent-session.sh < "$REQ" 2>"$TMP/home-unset.err")" || RC=$?
[ "$RC" -eq 0 ] || fail "engine crashed with HOME unset (rc=$RC): $(tail -c 300 "$TMP/home-unset.err")"
printf '%s' "$OUT" | jq -e '.disposition == "reply"' >/dev/null 2>&1 \
  || fail "HOME-unset turn did not reply: $OUT"
grep -q 'HOME: unbound variable' "$TMP/home-unset.err" && fail "HOME unbound error still present"
pass "engine completes a turn with HOME unset"

# ── 2. orphaned provider helper holding stdout must not hang the turn ───────
STUB="$TMP/stub-bin"
mkdir -p "$STUB" "$TMP/home"
cat > "$STUB/codex" <<'STUBEOF'
#!/usr/bin/env bash
# Helper outlives the CLI and inherits stdout (MCP server / updater pattern).
sleep 25 &
echo "OK"
STUBEOF
chmod +x "$STUB/codex"
export HOME="$TMP/home"
START_EPOCH="$(date +%s)"
RC=0
OUT="$(cd "$FIXTURE" && \
  PATH="$STUB:$PATH" \
  HQ_AGENT_WORKDIR="$FIXTURE" \
  bash core/scripts/hq-agent-session.sh < "$REQ" 2>"$TMP/orphan.err")" || RC=$?
ELAPSED=$(( $(date +%s) - START_EPOCH ))
[ "$RC" -eq 0 ] || fail "orphan-helper turn failed (rc=$RC): $(tail -c 300 "$TMP/orphan.err")"
printf '%s' "$OUT" | jq -e '.disposition == "reply" and .text == "OK"' >/dev/null 2>&1 \
  || fail "orphan-helper turn wrong envelope: $OUT"
[ "$ELAPSED" -lt 20 ] || fail "turn blocked on orphaned helper stdout (${ELAPSED}s >= 20s)"
pass "turn completes while an orphaned helper holds stdout (${ELAPSED}s)"

echo "hq-agent-session-runtime-env: all tests passed"
