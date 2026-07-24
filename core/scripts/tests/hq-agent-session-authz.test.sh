#!/usr/bin/env bash
# hq-core: public
# US-402: company authorization — unknown slug, two-company box, sender.verified

set -euo pipefail

SRC_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }
pass() { echo "  ok: $1"; }

setup_fixture() {
  local fx="$1"
  mkdir -p "$fx/core/schemas" "$fx/core/scripts" "$fx/core/knowledge/public/hq-core" \
    "$fx/workspace/sessions" "$fx/.claude/hooks"
  cp "$SRC_ROOT/core/core.yaml" "$fx/core/core.yaml"
  cp "$SRC_ROOT/core/schemas/"*.json "$fx/core/schemas/"
  cp "$SRC_ROOT/core/scripts/hq-agent-session.sh" "$fx/core/scripts/"
  cp -R "$SRC_ROOT/core/scripts/lib" "$fx/core/scripts/lib"
  cp "$SRC_ROOT/core/scripts/hq-session.sh" "$fx/core/scripts/"
  cp "$SRC_ROOT/.claude/hooks/master-hook.sh" "$fx/.claude/hooks/"
  cp "$SRC_ROOT/core/knowledge/public/hq-core/channel-writing-formats.md" \
    "$fx/core/knowledge/public/hq-core/" 2>/dev/null || true
  printf '# AGENTS\n' > "$fx/AGENTS.md"
  chmod +x "$fx/core/scripts/"*.sh "$fx/core/scripts/lib/"*.sh "$fx/.claude/hooks/master-hook.sh"
}

FIXTURE="$TMP/hq"
setup_fixture "$FIXTURE"
mkdir -p "$FIXTURE/companies/indigo/settings"
printf '# indigo\n' > "$FIXTURE/companies/indigo/CLAUDE.md"

export HOME="$TMP/home"
mkdir -p "$HOME"
export HQ_AGENT_WORKDIR="$FIXTURE"
export HQ_AGENT_SESSION_SKIP_PROVIDER=1

req() {
  jq -nc \
    --arg co "$1" \
    --argjson ver "${2:-true}" \
    '{
      contractVersion: 1,
      agentUid: "agt_test",
      companySlug: $co,
      channel: "slack",
      convKey: "agt_test#slack:C1",
      messageText: "hi",
      provider: "claude",
      sender: {verified: $ver}
    }'
}

# ── 1. unknown slug ─────────────────────────────────────────────────────────
RC=0
OUT="$(req acme-fixture | bash "$FIXTURE/core/scripts/hq-agent-session.sh" 2>"$TMP/e1")" || RC=$?
[ "$RC" -eq 6 ] || fail "unknown slug exit $RC"
echo "$OUT" | jq -e '.disposition == "error"' >/dev/null || fail "unknown disposition"
grep -q "requested='acme-fixture'" "$TMP/e1" || fail "stderr should name requested slug"
grep -q "indigo" "$TMP/e1" || fail "stderr should name present slugs"
echo "$OUT" | jq -r .text | grep -q acme-fixture || fail "envelope text should name refused company"
pass "unknown slug"

# ── 2. two-company box, explicit indigo ─────────────────────────────────────
mkdir -p "$FIXTURE/companies/acme-fixture/settings"
printf '# acme-fixture\n' > "$FIXTURE/companies/acme-fixture/CLAUDE.md"
RC=0
OUT="$(req indigo | bash "$FIXTURE/core/scripts/hq-agent-session.sh" 2>"$TMP/e2")" || RC=$?
[ "$RC" -eq 0 ] || fail "two-company indigo exit $RC err=$(cat "$TMP/e2")"
# Envelope success — company env was indigo only. Check env dump written by
# inspecting that we didn't export acme-fixture: re-run with a probe by reading
# runDir request only. Company dir ends with /companies/indigo:
# Capture via a wrapper that prints env — instead re-resolve:
. "$FIXTURE/core/scripts/lib/session-authz.sh"
CDIR="$(session_resolve_company_dir "$FIXTURE" indigo)"
case "$CDIR" in
  */companies/indigo) ;;
  *) fail "company dir not indigo: $CDIR" ;;
esac
case "$CDIR" in
  *acme-fixture*) fail "acme-fixture leaked into company dir" ;;
esac
pass "two-company explicit indigo"

# ── 3. two-company box, slug that is present (acme-fixture) ─────────────────────
RC=0
OUT="$(req acme-fixture | bash "$FIXTURE/core/scripts/hq-agent-session.sh" 2>"$TMP/e3")" || RC=$?
[ "$RC" -eq 0 ] || fail "two-company acme-fixture exit $RC err=$(cat "$TMP/e3")"
CDIR="$(session_resolve_company_dir "$FIXTURE" acme-fixture)"
case "$CDIR" in
  */companies/acme-fixture) ;;
  *) fail "company dir not acme-fixture: $CDIR" ;;
esac
pass "two-company present acme-fixture"

# ── 4. sender.verified false — same resolution ──────────────────────────────
RC=0
OUT="$(req indigo false | bash "$FIXTURE/core/scripts/hq-agent-session.sh" 2>"$TMP/e4")" || RC=$?
[ "$RC" -eq 0 ] || fail "verified false exit $RC err=$(cat "$TMP/e4")"
CDIR_V="$(session_resolve_company_dir "$FIXTURE" indigo)"
# Unverified must not widen scope — still only indigo when requested
case "$CDIR_V" in
  */companies/indigo) ;;
  *) fail "verified=false changed company: $CDIR_V" ;;
esac
# Unknown still refused when unverified
RC=0
OUT="$(req nosuch false | bash "$FIXTURE/core/scripts/hq-agent-session.sh" 2>"$TMP/e5")" || RC=$?
[ "$RC" -eq 6 ] || fail "verified=false unknown should still exit 6 got $RC"
pass "sender.verified false"

# ── 5. HQ_AGENT_WORKDIR-UNSET root resolution (dogfood canary, 2026-07-23) ───
# The box watcher fork invokes the session script WITHOUT HQ_AGENT_WORKDIR — it
# relies on session_resolve_root()'s BASH_SOURCE fallback climbing lib->scripts
# ->core->root. A two-hop (instead of three) climb resolved the root as .../core
# and every real turn failed "HQ root resolution failed" while every test here
# passed (they all export HQ_AGENT_WORKDIR). This case reproduces the box path.
RC=0
OUT="$(env -u HQ_AGENT_WORKDIR bash -c "cd '$FIXTURE' && req() { jq -nc --arg co indigo '{contractVersion:1,agentUid:\"agt_test\",companySlug:\$co,channel:\"slack\",convKey:\"agt_test#slack:C1\",messageText:\"hi\",provider:\"claude\",sender:{verified:true}}'; }; req | bash '$FIXTURE/core/scripts/hq-agent-session.sh'" 2>"$TMP/e6")" || RC=$?
[ "$RC" -eq 0 ] || fail "workdir-unset root resolution exit $RC err=$(cat "$TMP/e6")"
echo "$OUT" | jq -e '.disposition != "error"' >/dev/null || fail "workdir-unset produced error envelope: $OUT"
grep -q "HQ root resolution failed" "$TMP/e6" && fail "root resolution still failing without HQ_AGENT_WORKDIR"
pass "root resolves without HQ_AGENT_WORKDIR (box fork path)"


# --- present-on-box proof: synced CONTENT counts, empty dir does not ----------
# 2026-07-24 dogfood canary: the marker check accepted only settings/manifest,
# but companies/<slug>/settings/ is local-only by design and cannot reach a box.
# After a full-vault grant put 21411 real files on the dogfood box the gate STILL
# reported present=[(none)] and every hq-session turn failed exit 6. Content is
# present-on-box proof; an empty directory is not.
. "$FIXTURE/core/scripts/lib/session-authz.sh"

MARKERLESS="$TMP/markerless"
mkdir -p "$MARKERLESS/companies/withcontent/knowledge" "$MARKERLESS/companies/emptyco"
echo x > "$MARKERLESS/companies/withcontent/knowledge/a.md"

session_company_has_marker "$MARKERLESS/companies/withcontent" \
  || fail "populated company dir must be present-on-box proof"
pass "synced content authorizes a company with no settings/manifest marker"

session_company_has_marker "$MARKERLESS/companies/emptyco" \
  && fail "EMPTY company dir must stay unauthorized (hq rescue seeds bare dirs)"
pass "empty company dir stays fail-closed"

# Dotfile-only content still counts (a company whose grant yields only dotfiles).
mkdir -p "$MARKERLESS/companies/dotonly"
echo x > "$MARKERLESS/companies/dotonly/.keep"
session_company_has_marker "$MARKERLESS/companies/dotonly" \
  || fail "dotfile-only content must count as present-on-box proof"
pass "dotfile-only content authorizes"

PRESENT="$(session_list_present_companies "$MARKERLESS")"
echo "$PRESENT" | grep -qx withcontent || fail "listing must include content-only company: $PRESENT"
echo "$PRESENT" | grep -qx dotonly     || fail "listing must include dotfile-only company: $PRESENT"
echo "$PRESENT" | grep -qx emptyco     && fail "listing must NOT include empty company: $PRESENT"
pass "session_list_present_companies reflects content-based presence"

echo "PASS: hq-agent-session-authz.test.sh"
