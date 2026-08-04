#!/usr/bin/env bash
# hq-core: public
# Regression tests for .claude/hooks/surface-company-infra-policy.sh
#
# The hook surfaces the BOUND company's hard deploy/credential policies when an
# infra command is about to run. It used to resolve "the current session" from
# workspace/sessions/.current — a single global pointer that every hook event
# rewrites. With two sessions alive, .current names whichever fired most
# recently, so a session bound to company A could be shown company B's hard
# policies (a cross-company context leak) or shown nothing at all. The payload
# session_id is authoritative and must win.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
HOOK="$ROOT/.claude/hooks/surface-company-infra-policy.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

write_policy() {
  local co="$1" slug="$2" rule="$3"
  mkdir -p "$TMP/companies/$co/policies"
  cat > "$TMP/companies/$co/policies/$slug.md" <<EOF
---
id: $slug
enforcement: hard
---

## Rule

$rule
EOF
}

mkdir -p "$TMP/core/scripts/lib" "$TMP/workspace/sessions/sess-live" \
  "$TMP/workspace/sessions/sess-other"
cp "$ROOT/core/scripts/lib/session-id.sh" "$TMP/core/scripts/lib/"

write_policy indigo  indigo-aws-deploy  "Indigo deploys run through hq secrets exec."
write_policy otherco otherco-aws-deploy "Otherco deploys use its own vault path."

printf 'company_slug: indigo\n'  > "$TMP/workspace/sessions/sess-live/meta.yaml"
printf 'company_slug: otherco\n' > "$TMP/workspace/sessions/sess-other/meta.yaml"
# .current deliberately names the OTHER session — the wrong-session trap.
printf 'sess-other\n' > "$TMP/workspace/sessions/.current"

run_hook() {
  local sid="$1"
  local payload
  if [ -n "$sid" ]; then
    payload="$(jq -nc --arg sid "$sid" \
      '{session_id:$sid,tool_name:"Bash",tool_input:{command:"aws s3 ls"}}')"
  else
    payload='{"tool_name":"Bash","tool_input":{"command":"aws s3 ls"}}'
  fi
  printf '%s' "$payload" | env -u HQ_SESSION_ID -u CLAUDE_CODE_SESSION_ID \
    -u CLAUDE_SESSION_ID -u CODEX_SESSION_ID -u CODEX_THREAD_ID \
    HQ_ROOT="$TMP" bash "$HOOK" 2>/dev/null || true
}

echo "[1] payload session_id wins over .current"
out="$(run_hook sess-live)"
printf '%s' "$out" | grep -q 'co="indigo"' \
  || fail "expected the payload session's company (indigo), got: ${out:-<empty>}"
if printf '%s' "$out" | grep -q 'otherco'; then
  fail "leaked the .current session's company into this session: $out"
fi

echo "[2] the .current session still resolves to its own company"
rm -rf "$TMP/workspace/orchestrator"
out="$(run_hook sess-other)"
printf '%s' "$out" | grep -q 'co="otherco"' \
  || fail "expected otherco for sess-other, got: ${out:-<empty>}"

echo "[3] an unbound session surfaces nothing, even when .current is bound"
rm -rf "$TMP/workspace/orchestrator"
printf 'session_id: sess-unbound\n' > "$TMP/workspace/sessions/sess-live/meta.yaml"
out="$(run_hook sess-live)"
[ -z "$out" ] || fail "expected no output for an unbound session, got: $out"

echo "[4] dedupe still fires once per (session, company)"
printf 'company_slug: indigo\n' > "$TMP/workspace/sessions/sess-live/meta.yaml"
rm -rf "$TMP/workspace/orchestrator"
first="$(run_hook sess-live)"
[ -n "$first" ] || fail "expected a first-fire reminder"
second="$(run_hook sess-live)"
[ -z "$second" ] || fail "expected dedupe to suppress the second fire, got: $second"

echo "[5] non-infra commands are ignored"
rm -rf "$TMP/workspace/orchestrator"
out="$(printf '%s' '{"session_id":"sess-live","tool_name":"Bash","tool_input":{"command":"ls -la"}}' \
  | HQ_ROOT="$TMP" bash "$HOOK" 2>/dev/null || true)"
[ -z "$out" ] || fail "expected no output for a non-infra command, got: $out"

echo "PASS: surface-company-infra-policy.test.sh"
