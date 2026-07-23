#!/usr/bin/env bash
# hq-core: public
# US-411: assembly timing budget — phase sum + slow phase without abort.

set -euo pipefail

SRC_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }
pass() { echo "  ok: $1"; }

FIXTURE="$TMP/hq"
mkdir -p "$FIXTURE/core/schemas" "$FIXTURE/core/scripts" \
  "$FIXTURE/core/knowledge/public/hq-core/agent-session-constants" \
  "$FIXTURE/workspace/sessions" "$FIXTURE/.claude/hooks" \
  "$FIXTURE/companies/indigo/settings"
cp "$SRC_ROOT/core/core.yaml" "$FIXTURE/core/core.yaml"
cp "$SRC_ROOT/core/schemas/"*.json "$FIXTURE/core/schemas/"
cp "$SRC_ROOT/core/scripts/hq-agent-session.sh" "$FIXTURE/core/scripts/"
cp -R "$SRC_ROOT/core/scripts/lib" "$FIXTURE/core/scripts/lib"
cp "$SRC_ROOT/core/scripts/hq-session.sh" "$FIXTURE/core/scripts/"
cp "$SRC_ROOT/.claude/hooks/master-hook.sh" "$FIXTURE/.claude/hooks/"
cp "$SRC_ROOT/core/knowledge/public/hq-core/channel-writing-formats.md" \
  "$FIXTURE/core/knowledge/public/hq-core/" 2>/dev/null || \
  printf '# Channel Writing Formats\n\n## slack\n\nslack format\n' \
    > "$FIXTURE/core/knowledge/public/hq-core/channel-writing-formats.md"
if [ -d "$SRC_ROOT/core/knowledge/public/hq-core/agent-session-constants" ]; then
  cp "$SRC_ROOT/core/knowledge/public/hq-core/agent-session-constants/"*.txt \
    "$FIXTURE/core/knowledge/public/hq-core/agent-session-constants/" 2>/dev/null || true
fi
printf '# AGENTS\nfixture charter\n' > "$FIXTURE/AGENTS.md"
printf '# Company\nindigo charter\n' > "$FIXTURE/companies/indigo/CLAUDE.md"
chmod +x "$FIXTURE/core/scripts/"*.sh "$FIXTURE/core/scripts/lib/"*.sh \
  "$FIXTURE/.claude/hooks/master-hook.sh"

export HOME="$TMP/home"
mkdir -p "$HOME"
export HQ_AGENT_WORKDIR="$FIXTURE"
export HQ_AGENT_SESSION_SKIP_PROVIDER=1

valid_req() {
  jq -nc '{
    contractVersion: 1,
    agentUid: "agt_timing",
    companySlug: "indigo",
    channel: "slack",
    convKey: "agt_timing#slack:C1",
    messageText: "hello timing",
    provider: "claude",
    sender: {verified: true}
  }'
}

PHASE_KEYS='["system-prompt","hooks","policy","rehydrate","skill-catalog","worker-catalog"]'

# ── 1. Normal budget: assemblyMs keys + sum within 50ms of total ────────────
unset HQ_SESSION_TIMING_STUB_PHASE HQ_SESSION_TIMING_STUB_ADD_MS HQ_SESSION_TIMING_STUB_SLEEP_MS
export HQ_SESSION_ASSEMBLY_BUDGET_MS=20000
OUT="$(valid_req | bash "$FIXTURE/core/scripts/hq-agent-session.sh" 2>"$TMP/err1")" || RC=$?
RC="${RC:-0}"
[ "$RC" -eq 0 ] || fail "normal turn exit $RC stderr=$(cat "$TMP/err1")"
echo "$OUT" | jq -e '.disposition == "reply"' >/dev/null || fail "expected reply: $OUT"

echo "$OUT" | jq -e 'has("assemblyMs") and (.assemblyMs | type == "object")' >/dev/null \
  || fail "missing assemblyMs: $OUT"

for k in system-prompt hooks policy rehydrate skill-catalog worker-catalog total; do
  echo "$OUT" | jq -e --arg k "$k" '.assemblyMs | has($k) and (.[$k] | type == "number")' >/dev/null \
    || fail "assemblyMs missing integer key $k: $(echo "$OUT" | jq .assemblyMs)"
done
pass "assemblyMs six phases + total"

SUM="$(echo "$OUT" | jq '[.assemblyMs["system-prompt"], .assemblyMs.hooks, .assemblyMs.policy,
  .assemblyMs.rehydrate, .assemblyMs["skill-catalog"], .assemblyMs["worker-catalog"]] | add')"
TOTAL="$(echo "$OUT" | jq '.assemblyMs.total')"
DIFF=$(( SUM > TOTAL ? SUM - TOTAL : TOTAL - SUM ))
[ "$DIFF" -le 50 ] || fail "phase sum $SUM vs total $TOTAL diff $DIFF > 50ms"
pass "phase sum within 50ms of total (sum=$SUM total=$TOTAL)"

# budget not exceeded under default
EXC="$(echo "$OUT" | jq -r '.assemblyBudgetExceeded // false')"
[ "$EXC" = "false" ] || fail "assemblyBudgetExceeded should be absent/false: $OUT"
# total under budget
[ "$(echo "$OUT" | jq '.assemblyMs.total')" -lt 20000 ] || fail "total unexpectedly huge"
pass "default budget not exceeded"

# ── 2. Slow phase: HQ_SESSION_ASSEMBLY_BUDGET_MS=1 + stub add → exceeded ─────
export HQ_SESSION_ASSEMBLY_BUDGET_MS=1
export HQ_SESSION_TIMING_STUB_PHASE=system-prompt
export HQ_SESSION_TIMING_STUB_ADD_MS=25
OUT2="$(valid_req | bash "$FIXTURE/core/scripts/hq-agent-session.sh" 2>"$TMP/err2")" || RC2=$?
RC2="${RC2:-0}"
[ "$RC2" -eq 0 ] || fail "slow turn must not abort (exit $RC2) stderr=$(cat "$TMP/err2")"
echo "$OUT2" | jq -e '.disposition == "reply"' >/dev/null \
  || fail "slow turn must still reply: $OUT2"
echo "$OUT2" | jq -e '.assemblyBudgetExceeded == true' >/dev/null \
  || fail "expected assemblyBudgetExceeded true: $OUT2"
# one stderr line per phase
PHASE_LINES="$(grep -c 'assembly phase' "$TMP/err2" || true)"
[ "$PHASE_LINES" -eq 6 ] || fail "expected 6 phase stderr lines, got $PHASE_LINES: $(cat "$TMP/err2")"
grep -q 'system-prompt=' "$TMP/err2" || fail "stderr missing system-prompt line"
pass "slow phase trips budget, turn still replies, 6 stderr phase lines"

# ── 3. Unit-level: session_timing sum helpers ───────────────────────────────
unset HQ_SESSION_TIMING_STUB_PHASE HQ_SESSION_TIMING_STUB_ADD_MS HQ_SESSION_TIMING_STUB_SLEEP_MS
export HQ_SESSION_ASSEMBLY_BUDGET_MS=20000
# shellcheck source=../lib/session-timing.sh
. "$SRC_ROOT/core/scripts/lib/session-timing.sh"
session_timing_init
session_timing_begin system-prompt
session_timing_end
session_timing_begin hooks
session_timing_end
session_timing_begin policy
session_timing_end
session_timing_begin rehydrate
session_timing_end
session_timing_begin skill-catalog
session_timing_end
session_timing_begin worker-catalog
session_timing_end
session_timing_finalize
USUM="$(session_timing_phase_sum)"
[ "$USUM" = "$SESSION_TIMING_TOTAL_MS" ] || fail "unit sum $USUM != total $SESSION_TIMING_TOTAL_MS"
echo "$SESSION_ASSEMBLY_MS_JSON" | jq -e '
  has("system-prompt") and has("hooks") and has("policy")
  and has("rehydrate") and has("skill-catalog") and has("worker-catalog")
  and has("total")
' >/dev/null || fail "unit assemblyMs json: $SESSION_ASSEMBLY_MS_JSON"
pass "unit phase accounting"

echo "PASS: hq-agent-session-timing.test.sh"
