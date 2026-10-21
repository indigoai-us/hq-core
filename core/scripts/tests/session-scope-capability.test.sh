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

call_multi_company_flag() {
  local root="$1" primary="$2"
  bash -c '. "$1"; if session_scope_multi_company_enabled "$2" "$3"; then printf on; else printf off; fi' \
    _ "$LIB" "$root" "$primary"
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

session_scope_mint "$TMP" "sess-clear" "indigo"
session_scope_mint "$TMP" "sess-clear" "indigo" "agent-C"
clear_cap="$TMP/workspace/sessions/sess-clear/scope-capability.json"
session_scope_clear "$TMP" "sess-clear"
[ ! -e "$clear_cap" ] || fail "clear left the main capability behind"
assert_eq "$(session_scope_read "$TMP" "sess-clear")" "" "read after clear"
assert_eq "$(session_scope_read "$TMP" "sess-clear" "agent-C")" "indigo" "clear of main leaves agent capability"
session_scope_clear "$TMP" "sess-clear" || fail "clearing an absent capability should succeed"
if session_scope_clear "$TMP" "../evil" 2>/dev/null; then
  fail "clear with invalid session id should be rejected"
fi

# The lock flag is a kill switch. Only an explicit false may disable it.
fallback_failures=0
expect_default_on() {
  local actual="$1" name="$2"
  if [ "$actual" = on ]; then
    printf 'PASS: %s\n' "$name"
  else
    printf 'FAIL: %s (got %s)\n' "$name" "$actual" >&2
    fallback_failures=$((fallback_failures + 1))
  fi
}
mkdir -p "$TMP/no-cache/.codex/hooks" "$TMP/no-script/core/scripts"
cp "$TMP/.codex/hooks/codex-explicit-path-flag.cjs" "$TMP/no-cache/.codex/hooks/"
cp "$TMP/core/scripts/hqd-hook-flag-cache-lib.sh" "$TMP/no-script/core/scripts/"
expect_default_on "$(call_multi_company_flag "$TMP/no-cache" indigo)" "missing cache library defaults on"
expect_default_on "$(call_multi_company_flag "$TMP/no-script" indigo)" "missing flag script defaults on"
expect_default_on "$(call_multi_company_flag "$TMP" "")" "missing primary defaults on"
saved_home="$HOME"
unset HOME
expect_default_on "$(call_multi_company_flag "$TMP" indigo)" "missing HOME defaults on"
export HOME="$saved_home"

mkdir -p "$TMP/fail-bin" "$TMP/false-bin"
cat >"$TMP/fail-bin/node" <<'SH'
#!/bin/sh
exit 1
SH
cat >"$TMP/false-bin/node" <<'SH'
#!/bin/sh
printf 'false\n'
SH
chmod +x "$TMP/fail-bin/node" "$TMP/false-bin/node"
flag_cache="$HOME/.hq/hook-flag.multi-company-session-lock.indigo"
cache_now="$(cut -d. -f1 /proc/uptime)"
printf 'true %s\n' "$((cache_now - 61))" >"$flag_cache"
expect_default_on "$(PATH="$TMP/fail-bin:$PATH" call_multi_company_flag "$TMP" indigo)" "network failure after expired cache defaults on"
printf 'malformed cache\n' >"$flag_cache"
expect_default_on "$(PATH="$TMP/fail-bin:$PATH" call_multi_company_flag "$TMP" indigo)" "malformed cache plus failed refresh defaults on"
[ "$fallback_failures" -eq 0 ] || fail "$fallback_failures multi-company default-on fallback cases failed"
printf 'false %s\n' "$cache_now" >"$flag_cache"
if [ "$(call_multi_company_flag "$TMP" indigo)" != off ]; then
  fail "fresh explicit false cache must disable the flag"
fi
rm -f "$flag_cache"
if [ "$(PATH="$TMP/false-bin:$PATH" call_multi_company_flag "$TMP" indigo)" != off ]; then
  fail "live explicit false must disable the flag"
fi
session_scope_mint_set "$TMP" "sess-a" "indigo,otherco"
assert_eq "$(PATH="$TMP/false-bin:$PATH" session_scope_read_companies "$TMP" sess-a)" "indigo" "explicit false keeps singleton lock"

# Task subagents get no SessionStart, so their tuple is pinned from the parent's
# main-thread capability on first use (feedback_284bc210).
mkdir -p "$TMP/workspace/sessions/sess-inherit"
session_scope_mint "$TMP" "sess-inherit" "indigo"
session_scope_inherit_parent "$TMP" "sess-inherit" "agent-C" || fail "inherit from parent capability should mint"
assert_eq "$(session_scope_read "$TMP" "sess-inherit" "agent-C")" "indigo" "child inherits parent company"
assert_eq "$(jq -r '.agent_id' "$TMP/workspace/sessions/sess-inherit/agents/agent-C/scope-capability.json")" \
  "agent-C" "inherited tuple names the child"
session_scope_mint "$TMP" "sess-inherit" "otherco"
if session_scope_inherit_parent "$TMP" "sess-inherit" "agent-C"; then
  fail "inherit must not overwrite an existing tuple"
fi
assert_eq "$(session_scope_read "$TMP" "sess-inherit" "agent-C")" "indigo" "parent rebind does not move a pinned child"
mkdir -p "$TMP/workspace/sessions/sess-metaonly"
printf 'company_slug: indigo\n' >"$TMP/workspace/sessions/sess-metaonly/meta.yaml"
if session_scope_inherit_parent "$TMP" "sess-metaonly" "agent-D"; then
  fail "meta.yaml alone must not bind a subagent"
fi
[ ! -e "$TMP/workspace/sessions/sess-metaonly/agents/agent-D/scope-capability.json" ] \
  || fail "no tuple may be minted without a parent capability"
if session_scope_inherit_parent "$TMP" "sess-inherit" "../agent-E"; then
  fail "invalid agent_id must not inherit"
fi

if session_scope_mint "$TMP" "sess-a" "../evil" 2>/dev/null; then
  fail "invalid slug should be rejected"
fi

# DEV-4034 (c): session_scope_inherit_parent_session proves the parent before
# it creates anything. Every refused parent leaves no child folder behind.
expect_no_inherit() {
  local child="$1" parent="$2" label="$3"
  if session_scope_inherit_parent_session "$TMP" "$child" "" "$parent"; then
    fail "$label: inherit should be refused"
  fi
  [ ! -e "$TMP/workspace/sessions/$child" ] || fail "$label: child folder was created"
}
session_scope_mint "$TMP" "sess-p-ok" "otherco"
expect_no_inherit "sess-c-missing" "sess-p-missing" "parent with no session folder"
mkdir -p "$TMP/workspace/sessions/sess-p-nocap"
expect_no_inherit "sess-c-nocap" "sess-p-nocap" "parent with no capability"
mkdir -p "$TMP/workspace/sessions/sess-p-wrongid"
printf '{"session_id":"someone-else","company_slug":"otherco"}\n' \
  >"$TMP/workspace/sessions/sess-p-wrongid/scope-capability.json"
expect_no_inherit "sess-c-wrongid" "sess-p-wrongid" "parent capability for another session"
mkdir -p "$TMP/workspace/sessions/sess-p-badslug"
printf '{"session_id":"sess-p-badslug","company_slug":"../x"}\n' \
  >"$TMP/workspace/sessions/sess-p-badslug/scope-capability.json"
expect_no_inherit "sess-c-badslug" "sess-p-badslug" "parent capability with an invalid company"
# A symlinked parent folder or capability could point anywhere.
mkdir -p "$TMP/elsewhere/sess-p-dirlink"
printf '{"session_id":"sess-p-dirlink","company_slug":"otherco"}\n' \
  >"$TMP/elsewhere/sess-p-dirlink/scope-capability.json"
ln -s "$TMP/elsewhere/sess-p-dirlink" "$TMP/workspace/sessions/sess-p-dirlink"
expect_no_inherit "sess-c-dirlink" "sess-p-dirlink" "symlinked parent folder"
mkdir -p "$TMP/workspace/sessions/sess-p-caplink"
printf '{"session_id":"sess-p-caplink","company_slug":"otherco"}\n' >"$TMP/elsewhere/cap.json"
ln -s "$TMP/elsewhere/cap.json" "$TMP/workspace/sessions/sess-p-caplink/scope-capability.json"
expect_no_inherit "sess-c-caplink" "sess-p-caplink" "symlinked parent capability"
for bad in '../sess-p-ok' 'a/b' '..' '.' ''; do
  expect_no_inherit "sess-c-path" "$bad" "parent id '$bad'"
done
# The child's own folder must not be a symlink either.
mkdir -p "$TMP/elsewhere/child-target"
ln -s "$TMP/elsewhere/child-target" "$TMP/workspace/sessions/sess-c-link"
if session_scope_inherit_parent_session "$TMP" "sess-c-link" "" "sess-p-ok"; then
  fail "inherit wrote through a symlinked child folder"
fi
[ ! -e "$TMP/elsewhere/child-target/scope-capability.json" ] || fail "capability written through a child symlink"
mkdir -p "$TMP/workspace/sessions/sess-c-agentlink"
ln -s "$TMP/elsewhere/child-target" "$TMP/workspace/sessions/sess-c-agentlink/agents"
if session_scope_inherit_parent_session "$TMP" "sess-c-agentlink" "agent-L" "sess-p-ok"; then
  fail "inherit wrote through a symlinked agents folder"
fi
[ ! -e "$TMP/elsewhere/child-target/agent-L" ] || fail "agent tuple written through an agents symlink"
# A real parent still passes on its lock set.
session_scope_inherit_parent_session "$TMP" "sess-c-ok" "" "sess-p-ok" || fail "valid parent should be inherited"
assert_eq "$(session_scope_read "$TMP" "sess-c-ok")" "otherco" "child inherits the parent's company"

echo "PASS: session-scope-capability.test.sh"
