#!/usr/bin/env bash
# hq-core: public
# Regression tests for core/scripts/lib/session-scope-capability.sh

set -euo pipefail

LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/session-scope-capability.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_eq() {
  [ "$1" = "$2" ] || fail "$3: expected '$2', got '$1'"
}

# shellcheck source=../lib/session-scope-capability.sh
. "$LIB"

mkdir -p "$TMP/workspace/sessions/sess-a" "$TMP/companies/indigo" "$TMP/companies/otherco" "$TMP/.codex/hooks" "$TMP/core/scripts" "$TMP/home/.hq"
cp "$(dirname "$LIB")/../../../.codex/hooks/codex-explicit-path-flag.cjs" "$TMP/.codex/hooks/"
cp "$(dirname "$LIB")/../hqd-hook-flag-cache-lib.sh" "$TMP/core/scripts/"

cat >"$TMP/flag-on-node" <<'NODE'
#!/bin/sh
printf 'called\n' >>"$NODE_CALLS"
printf 'true\n'
NODE
chmod +x "$TMP/flag-on-node"

assert_eq "$(session_scope_read "$TMP" "sess-a")" "" "empty before mint"

session_scope_mint "$TMP" "sess-a" "indigo"
cap="$TMP/workspace/sessions/sess-a/scope-capability.json"
[ -f "$cap" ] || fail "capability file not created"

assert_eq "$(session_scope_read "$TMP" "sess-a")" "indigo" "read after mint"
assert_eq "$(jq -r '.session_id' "$cap")" "sess-a" "session_id stored"
assert_eq "$(jq -r '.company_slug' "$cap")" "indigo" "company_slug stored"
[ -n "$(jq -r '.minted_at' "$cap")" ] || fail "minted_at missing"

session_scope_mint "$TMP" "sess-a" "otherco"
assert_eq "$(session_scope_read "$TMP" "sess-a")" "otherco" "mint replaces prior slug"

# A resumed Task agent must keep the company bound to its exact tuple, even
# when shared session metadata has since moved to another company.
session_scope_mint "$TMP" "sess-a" "indigo" "agent-A"
assert_eq "$(session_scope_resolve_agent_company "$TMP" "sess-a" "agent-A" "otherco" "SessionStart")" \
  "indigo" "resumed agent keeps its existing company"
assert_eq "$(session_scope_resolve_agent_company "$TMP" "sess-a" "agent-new" "otherco" "PreToolUse")" \
  "" "unbound running agent remains unbound"
assert_eq "$(session_scope_resolve_agent_company "$TMP" "sess-a" "agent-new" "otherco" "SessionStart")" \
  "otherco" "new or restarted agent can bind from session metadata"

session_scope_mint_set "$TMP" "sess-a" "indigo,otherco"
assert_eq "$(jq -c '.company_slugs' "$cap")" '["indigo","otherco"]' "ordered lock set stored"
session_scope_mint_set "$TMP" "sess-a" "indigo,otherco" "agent-A"
mkdir -p "$TMP/bin"
cp "$TMP/flag-on-node" "$TMP/bin/node"
export HOME="$TMP/home" NODE_CALLS="$TMP/node-calls"
read_set="$(PATH="$TMP/bin:$PATH" session_scope_read_companies "$TMP" "sess-a")"
assert_eq "$read_set" $'indigo\notherco' "flag-on lock set read"
assert_eq "$(wc -l <"$NODE_CALLS" | tr -d ' ')" "1" "multi-company flag cache populated once"
read_set="$(PATH="$TMP/bin:$PATH" session_scope_read_companies "$TMP" "sess-a")"
assert_eq "$read_set" $'indigo\notherco' "cached flag-on lock set read"
assert_eq "$(wc -l <"$NODE_CALLS" | tr -d ' ')" "1" "cached multi-company flag avoids another Node call"
assert_eq "$(PATH="$TMP/bin:$PATH" session_scope_resolve_agent_companies "$TMP" "sess-a" "agent-A" "otherco,indigo" "SessionStart" | paste -sd, -)" "indigo,otherco" "agent tuple retains full lock set"

jq '.company_slugs = ["indigo", 7]' "$cap" >"$TMP/malformed.json"
cp "$TMP/malformed.json" "$cap"
assert_eq "$(PATH="$TMP/bin:$PATH" session_scope_read_companies "$TMP" "sess-a")" "" "malformed lock set fails closed"

if session_scope_mint "$TMP" "sess-a" "../evil" 2>/dev/null; then
  fail "invalid slug should be rejected"
fi

echo "PASS: session-scope-capability.test.sh"
