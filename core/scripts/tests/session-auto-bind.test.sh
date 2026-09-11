#!/usr/bin/env bash
# hq-core: public
# session-auto-bind + Grok SessionStart inherit + authorizer re-read.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
TMP="$(cd "$TMP" && pwd -P)"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "  PASS: $*"; }

mkdir -p "$TMP/.claude/hooks" "$TMP/core/scripts/lib" \
  "$TMP/companies/indigo/settings" "$TMP/companies/otherco/settings" \
  "$TMP/workspace/sessions/parent-sid" "$TMP/workspace/sessions/child-sid" \
  "$TMP/.grok/hooks"

cp "$ROOT/.claude/hooks/mandatory-scope-authorizer.sh" "$TMP/.claude/hooks/"
cp "$ROOT/.claude/hooks/hook-gate.sh" "$TMP/.claude/hooks/" 2>/dev/null || true
cp "$ROOT/core/scripts/lib/session-authz.sh" "$TMP/core/scripts/lib/"
cp "$ROOT/core/scripts/lib/session-scope-capability.sh" "$TMP/core/scripts/lib/"
cp "$ROOT/core/scripts/lib/session-id.sh" "$TMP/core/scripts/lib/"
cp "$ROOT/core/scripts/lib/session-auto-bind.sh" "$TMP/core/scripts/lib/"
cp "$ROOT/.grok/hooks/hq-grok-hook-adapter.sh" "$TMP/.grok/hooks/"
chmod +x "$TMP/.claude/hooks/mandatory-scope-authorizer.sh" "$TMP/.grok/hooks/hq-grok-hook-adapter.sh"
touch "$TMP/companies/indigo/settings/foo.yaml"
printf 'companies:\n  indigo:\n    name: Indigo\n  otherco:\n    name: otherco\n' \
  > "$TMP/companies/manifest.yaml"

# shellcheck source=../lib/session-scope-capability.sh
. "$TMP/core/scripts/lib/session-scope-capability.sh"
# shellcheck source=../lib/session-auto-bind.sh
. "$TMP/core/scripts/lib/session-auto-bind.sh"

run_auth() {
  local payload="$1"
  local rc=0
  : > "$TMP/err.txt"
  printf '%s' "$payload" | HQ_ROOT="$TMP" CLAUDE_PROJECT_DIR="$TMP" \
    bash "$TMP/.claude/hooks/mandatory-scope-authorizer.sh" 2>"$TMP/err.txt" || rc=$?
  printf '%s' "$rc"
}

echo "== spawn env binds an unbound sid =="
unset HQ_SPAWN_COMPANY HQ_PARENT_SESSION_ID || true
session_auto_bind_apply "$TMP" "child-sid"
[ -z "$(session_auto_bind_meta_slug "$TMP" "child-sid")" ] \
  || fail "unbound sid must stay unbound without a safe source"

HQ_SPAWN_COMPANY=indigo session_auto_bind_apply "$TMP" "child-sid"
[ "$(session_auto_bind_meta_slug "$TMP" "child-sid")" = "indigo" ] \
  || fail "HQ_SPAWN_COMPANY did not bind indigo"
[ "$(session_scope_read "$TMP" "child-sid")" = "indigo" ] \
  || fail "capability not minted"

payload='{"tool_name":"Read","session_id":"child-sid","cwd":"'"$TMP"'","tool_input":{"file_path":"'"$TMP"'/companies/indigo/settings/foo.yaml"}}'
rc="$(run_auth "$payload")"
[ "$rc" = "0" ] || fail "Read companies/indigo after spawn bind should allow, got $rc"
pass "unbound sid + HQ_SPAWN_COMPANY=indigo allows indigo Read"

echo "== parent inherit, never cwd guess =="
rm -rf "$TMP/workspace/sessions/child-sid"
mkdir -p "$TMP/workspace/sessions/child-sid"
printf 'session_id: parent-sid\ncompany_slug: indigo\n' > "$TMP/workspace/sessions/parent-sid/meta.yaml"
session_scope_mint "$TMP" "parent-sid" "indigo"

unset HQ_SPAWN_COMPANY
session_auto_bind_apply "$TMP" "child-sid"
[ -z "$(session_auto_bind_meta_slug "$TMP" "child-sid")" ] \
  || fail "cwd/companies fragments must not invent a tenant"

HQ_PARENT_SESSION_ID=parent-sid session_auto_bind_apply "$TMP" "child-sid"
[ "$(session_auto_bind_meta_slug "$TMP" "child-sid")" = "indigo" ] \
  || fail "child did not inherit parent indigo"
pass "child inherits parent company_slug"

echo "== Grok SessionStart side-effect bind =="
rm -rf "$TMP/workspace/sessions/grok-sid"
mkdir -p "$TMP/workspace/sessions/grok-sid"
# Adapter needs hook-gate.sh to not fail-open; create a stub gate that exits 0.
cat > "$TMP/.claude/hooks/hook-gate.sh" <<'GATE'
#!/usr/bin/env bash
exit 0
GATE
chmod +x "$TMP/.claude/hooks/hook-gate.sh"
printf '{}\n' > "$TMP/.claude/settings.json"

printf '{"hookEventName":"SessionStart","session_id":"grok-sid","cwd":"%s"}\n' "$TMP" \
  | HQ_SPAWN_COMPANY=indigo HQ_ROOT="$TMP" CLAUDE_PROJECT_DIR="$TMP" \
    bash "$TMP/.grok/hooks/hq-grok-hook-adapter.sh" >/dev/null 2>"$TMP/adapter.err" || true

[ "$(session_auto_bind_meta_slug "$TMP" "grok-sid")" = "indigo" ] \
  || fail "Grok SessionStart did not bind spawn company (err=$(cat "$TMP/adapter.err"))"
payload='{"tool_name":"Read","session_id":"grok-sid","cwd":"'"$TMP"'","tool_input":{"file_path":"'"$TMP"'/companies/indigo/settings/foo.yaml"}}'
rc="$(run_auth "$payload")"
[ "$rc" = "0" ] || fail "Grok SessionStart bind must unblock indigo Read, got $rc err=$(cat "$TMP/err.txt")"
pass "Grok SessionStart binds before Read"

echo "session-auto-bind: all passed"
