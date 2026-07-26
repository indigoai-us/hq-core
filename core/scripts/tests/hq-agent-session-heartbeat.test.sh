#!/usr/bin/env bash
# hq-core: public
# Provider liveness heartbeat.
#
# The dispatch supervisor counts progress as: stdout grew, stderr grew, or the
# agent-status text CHANGED. On the hq-session contract path the first two are
# structurally impossible while the provider runs — the caller redirects this
# script's stdout into the response envelope, and this script captures the
# provider's stdout AND stderr to files. A silent engine under the real
# supervisor therefore returned rc=124 timeoutReason=idle_no_progress (verified
# on a fleet box 2026-07-25). These tests assert on the OBSERVED file the
# supervisor reads, sampled while the provider is still running — not on the
# presence of the heartbeat code.

set -euo pipefail

SRC_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
# shellcheck source=../lib/session-parity-fixtures.sh
. "$SRC_ROOT/core/scripts/lib/session-parity-fixtures.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }
pass() { echo "  ok: $1"; }

# ── offline fixture HQ root (same shape as the runtime-env harness) ─────────
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
printf '# AGENTS\nheartbeat fixture charter\n' > "$FIXTURE/AGENTS.md"
printf '# Company\nindigo heartbeat charter\n' > "$FIXTURE/companies/indigo/CLAUDE.md"
chmod +x "$FIXTURE/core/scripts/"*.sh "$FIXTURE/core/scripts/lib/"*.sh \
  "$FIXTURE/.claude/hooks/master-hook.sh"

export HOME="$TMP/home"
mkdir -p "$HOME"

REQ="$TMP/request.json"
cat > "$REQ" <<'JSON'
{"contractVersion":1,"agentUid":"agt_heartbeat_test","companySlug":"indigo","channel":"slack","convKey":"agt_heartbeat_test#slack:C-heartbeat","messageText":"heartbeat turn","provider":"codex","sender":{"verified":true}}
JSON

STUB="$TMP/stub-bin"
mkdir -p "$STUB"

# Provider stub: works quietly for a while, exactly like a real long turn.
write_quiet_stub() {
  cat > "$STUB/codex" <<'STUBEOF'
#!/usr/bin/env bash
sleep 5
echo "OK"
STUBEOF
  chmod +x "$STUB/codex"
}

# Provider stub that sets its own status partway through, the way an agent
# calling agent-status does.
write_status_setting_stub() {
  cat > "$STUB/codex" <<'STUBEOF'
#!/usr/bin/env bash
sleep 2
printf 'reviewing tests' > "$HQ_AGENT_STATUS_FILE"
# The heartbeat must relay this status without rewriting the provider-owned
# source file. Read it back after several heartbeat ticks to prove ownership is
# separated rather than relying on a timing-sensitive read/write race.
sleep 3
head -c 80 "$HQ_AGENT_STATUS_FILE" > "$PROVIDER_STATUS_CAPTURE"
sleep 1
echo "OK"
STUBEOF
  chmod +x "$STUB/codex"
}

run_engine_bg() {
  # $1 = status file path (empty string => variable unset)
  local status_file="${1:-}"
  ENGINE_OUT="$TMP/engine.out"
  ENGINE_ERR="$TMP/engine.err"
  : > "$ENGINE_OUT"
  : > "$ENGINE_ERR"
  if [ -n "$status_file" ]; then
    : > "$status_file"
    ( cd "$FIXTURE" && \
      PATH="$STUB:$PATH" \
      HQ_AGENT_WORKDIR="$FIXTURE" \
      HQ_AGENT_STATUS_FILE="$status_file" \
      HQ_AGENT_STATUS_HEARTBEAT_SECONDS=1 \
      bash core/scripts/hq-agent-session.sh < "$REQ" \
        > "$ENGINE_OUT" 2> "$ENGINE_ERR" ) &
  else
    ( cd "$FIXTURE" && \
      PATH="$STUB:$PATH" \
      HQ_AGENT_WORKDIR="$FIXTURE" \
      env -u HQ_AGENT_STATUS_FILE \
      bash core/scripts/hq-agent-session.sh < "$REQ" \
        > "$ENGINE_OUT" 2> "$ENGINE_ERR" ) &
  fi
  ENGINE_PID=$!
}

# Sample the status file for as long as the engine LIVES, rather than for a
# fixed number of seconds. A fixed window is measured from process launch, so
# it silently includes the engine's setup time (fixture reads, prompt assembly)
# — on a slow CI runner most of the window elapses before the provider even
# starts and too few heartbeat ticks land inside it. Bounded by a safety cap so
# a hung engine still fails the run rather than hanging it.
sample_while_running() {
  # $1 = status file, $2 = samples out file, $3 = safety cap in seconds
  local status="$1" out="$2" max="${3:-40}" i=0
  : > "$out"
  while kill -0 "$ENGINE_PID" 2>/dev/null && [ "$i" -lt "$max" ]; do
    sleep 1
    i=$((i + 1))
    head -c 80 "$status" 2>/dev/null >> "$out" || true
    printf '\n' >> "$out"
  done
}

# ── 1. status text CHANGES while the provider is still running ──────────────
# A repeated identical string does not register as progress, so distinctness
# is the property under test, not merely "the file is non-empty".
write_quiet_stub
STATUS="$TMP/status.txt"
run_engine_bg "$STATUS"
SEEN="$TMP/seen.txt"
sample_while_running "$STATUS" "$SEEN"
wait "$ENGINE_PID" || fail "engine failed: $(tail -c 300 "$ENGINE_ERR")"
DISTINCT="$(grep -c . "$SEEN" 2>/dev/null | tr -d '[:space:]' || echo 0)"
UNIQ="$(sort -u "$SEEN" | grep -c . || true)"
[ "${UNIQ:-0}" -ge 2 ] \
  || fail "status text never changed while the provider ran (uniq=$UNIQ, samples=$DISTINCT): $(tr '\n' '|' < "$SEEN")"
grep -q 'working' "$SEEN" || fail "heartbeat text missing: $(tr '\n' '|' < "$SEEN")"
printf '%s' "$(cat "$ENGINE_OUT")" | jq -e '.disposition == "reply"' >/dev/null 2>&1 \
  || fail "heartbeat turn did not reply: $(cat "$ENGINE_OUT")"
pass "status text changes while the provider runs ($UNIQ distinct samples)"

# ── 2. the heartbeat never discards a status the agent set itself ───────────
write_status_setting_stub
STATUS2="$TMP/status2.txt"
export PROVIDER_STATUS_CAPTURE="$TMP/provider-status-after.txt"
run_engine_bg "$STATUS2"
SEEN2="$TMP/seen2.txt"
sample_while_running "$STATUS2" "$SEEN2"
wait "$ENGINE_PID" || fail "engine failed: $(tail -c 300 "$ENGINE_ERR")"
grep -q 'reviewing tests' "$SEEN2" \
  || fail "agent-set status was discarded: $(tr '\n' '|' < "$SEEN2")"
# It must still CHANGE after adoption, or progress stalls at the agent's line.
ADOPTED_UNIQ="$(grep 'reviewing tests' "$SEEN2" | sort -u | grep -c . || true)"
[ "${ADOPTED_UNIQ:-0}" -ge 2 ] \
  || fail "status froze on the agent's line (uniq=$ADOPTED_UNIQ): $(tr '\n' '|' < "$SEEN2")"
pass "agent-set status is preserved and still advances ($ADOPTED_UNIQ variants)"
[ "$(cat "$PROVIDER_STATUS_CAPTURE" 2>/dev/null || true)" = "reviewing tests" ] \
  || fail "heartbeat rewrote the provider-owned status source: $(cat "$PROVIDER_STATUS_CAPTURE" 2>/dev/null || true)"
pass "provider-owned status source remains unchanged"

# ── 3. the loop never outlives the turn ─────────────────────────────────────
AFTER_A="$(head -c 80 "$STATUS2" 2>/dev/null || true)"
sleep 3
AFTER_B="$(head -c 80 "$STATUS2" 2>/dev/null || true)"
[ "$AFTER_A" = "$AFTER_B" ] \
  || fail "heartbeat still writing after the turn ended ('$AFTER_A' -> '$AFTER_B')"
pass "heartbeat stops when the turn ends (no orphaned writer)"

# ── 4. no status file configured is a clean no-op ───────────────────────────
write_quiet_stub
run_engine_bg ""
wait "$ENGINE_PID" || fail "engine failed with HQ_AGENT_STATUS_FILE unset: $(tail -c 300 "$ENGINE_ERR")"
printf '%s' "$(cat "$ENGINE_OUT")" | jq -e '.disposition == "reply"' >/dev/null 2>&1 \
  || fail "unset-status turn did not reply: $(cat "$ENGINE_OUT")"
pass "turn completes normally with no status file configured"

echo "hq-agent-session-heartbeat: all tests passed"
