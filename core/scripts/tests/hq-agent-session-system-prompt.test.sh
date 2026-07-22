#!/usr/bin/env bash
# hq-core: public
# US-402 / US-403: system prompt assembly — order, determinism, separation, skip

set -euo pipefail

SRC_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }
pass() { echo "  ok: $1"; }

FIXTURE="$TMP/hq"
mkdir -p "$FIXTURE/core/schemas" "$FIXTURE/core/scripts" \
  "$FIXTURE/core/knowledge/public/hq-core" \
  "$FIXTURE/workspace/sessions" "$FIXTURE/.claude/hooks" \
  "$FIXTURE/companies/indigo/settings"
cp "$SRC_ROOT/core/core.yaml" "$FIXTURE/core/core.yaml"
cp "$SRC_ROOT/core/schemas/"*.json "$FIXTURE/core/schemas/"
cp "$SRC_ROOT/core/scripts/hq-agent-session.sh" "$FIXTURE/core/scripts/"
cp -R "$SRC_ROOT/core/scripts/lib" "$FIXTURE/core/scripts/lib"
cp "$SRC_ROOT/core/scripts/hq-session.sh" "$FIXTURE/core/scripts/"
cp "$SRC_ROOT/.claude/hooks/master-hook.sh" "$FIXTURE/.claude/hooks/"
cp "$SRC_ROOT/core/knowledge/public/hq-core/channel-writing-formats.md" \
  "$FIXTURE/core/knowledge/public/hq-core/"
printf 'CHARTER_BODY_UNIQUE\n' > "$FIXTURE/AGENTS.md"
printf 'COMPANY_BODY_UNIQUE\n' > "$FIXTURE/companies/indigo/CLAUDE.md"
# Intentionally omit personal/.../hq-agent-contract.md for skip test
chmod +x "$FIXTURE/core/scripts/"*.sh "$FIXTURE/core/scripts/lib/"*.sh \
  "$FIXTURE/.claude/hooks/master-hook.sh"

export HOME="$TMP/home"
mkdir -p "$HOME"
export HQ_AGENT_WORKDIR="$FIXTURE"
export HQ_AGENT_SESSION_SKIP_PROVIDER=1

REQ="$(jq -nc '{
  contractVersion: 1,
  agentUid: "agt_test",
  companySlug: "indigo",
  channel: "slack",
  convKey: "agt_test#slack:C1",
  messageText: "ship the report",
  provider: "claude",
  sender: {verified: true}
}')"

run_once() {
  local tag="$1"
  printf '%s' "$REQ" | bash "$FIXTURE/core/scripts/hq-agent-session.sh" 2>"$TMP/err-$tag"
}

OUT1="$(run_once a)" || fail "run1 failed $(cat "$TMP/err-a")"
RUN1="$(echo "$OUT1" | jq -r .runDir)"
[ -f "$RUN1/system.txt" ] || fail "missing system.txt"
[ -f "$RUN1/user.txt" ] || fail "missing user.txt"

# Delimiter order
ORDER="$(grep -n '<!-- hq-section:' "$RUN1/system.txt" | sed 's/.*hq-section: //;s/ -->//')"
# US-406 appends skill-catalog after policies; US-408 appends durable-writes last.
# Base five sections stay first.
EXPECTED=$'charter\nagent-contract\ncompany-charter\nchannel-format\npolicies\nskill-catalog\ndurable-writes'
[ "$ORDER" = "$EXPECTED" ] || fail "delimiter order:\n$ORDER\n!=\n$EXPECTED"
pass "delimiter ordering"

# Charter body equals AGENTS.md
# Extract body between charter and agent-contract delimiters
CHARTER_BODY="$(awk '
  /<!-- hq-section: charter -->/ {grab=1; next}
  /<!-- hq-section:/ {if(grab) exit}
  grab {print}
' "$RUN1/system.txt")"
# trim trailing blank lines for compare
printf '%s' "$CHARTER_BODY" | sed -e :a -e '/^\n*$/{$d;N;ba' -e '}' > "$TMP/cbody"
# AGENTS.md content should appear
grep -q 'CHARTER_BODY_UNIQUE' "$RUN1/system.txt" || fail "charter body missing from system.txt"
pass "charter source"

# Separation: different files, not symlinks to each other
[ "$RUN1/system.txt" != "$RUN1/user.txt" ] || fail "same path"
[ ! -L "$RUN1/system.txt" ] || fail "system.txt is symlink"
[ ! -L "$RUN1/user.txt" ] || fail "user.txt is symlink"
# user.txt must not contain section markers
if grep -q '<!-- hq-section:' "$RUN1/user.txt"; then
  fail "user.txt contains hq-section markers"
fi
grep -q 'UNTRUSTED' "$RUN1/user.txt" || fail "user.txt missing UNTRUSTED framing"
grep -q 'ship the report' "$RUN1/user.txt" || fail "user.txt missing messageText"
pass "system/user separation"

# Determinism
OUT2="$(run_once b)" || fail "run2 failed"
RUN2="$(echo "$OUT2" | jq -r .runDir)"
cmp -s "$RUN1/system.txt" "$RUN2/system.txt" || fail "system.txt not deterministic"
pass "determinism"

# Missing optional source skipped
grep -q 'skipped' "$TMP/err-a" || fail "expected skipped line on stderr for missing agent-contract"
grep -q 'hq-agent-contract.md' "$TMP/err-a" || fail "skipped path should name agent-contract"
# agent-contract delimiter still present
grep -q '<!-- hq-section: agent-contract -->' "$RUN1/system.txt" || fail "agent-contract delimiter missing"
pass "missing-source skip"

# systemPromptBytes
BYTES="$(echo "$OUT1" | jq -r .systemPromptBytes)"
ACTUAL="$(wc -c < "$RUN1/system.txt" | tr -d '[:space:]')"
[ "$BYTES" = "$ACTUAL" ] || fail "systemPromptBytes $BYTES != actual $ACTUAL"
pass "systemPromptBytes"

echo "PASS: hq-agent-session-system-prompt.test.sh"
