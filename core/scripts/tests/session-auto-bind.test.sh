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

mkdir -p "$TMP/.claude/hooks" "$TMP/core/scripts/lib" "$TMP/bin" \
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

cat > "$TMP/bin/hq" <<'HQ'
#!/usr/bin/env bash
if [ "$1" = "mesh" ] && [ "$2" = "context" ] && [ "$3" = "default" ] && [ "$4" = "get" ] && [ "$5" = "--json" ]; then
  if [ "${HQ_SLOW_DEFAULT:-}" = "1" ]; then
    sleep 5
  fi
  printf '%s\n' "${HQ_DEFAULT_COMPANY_JSON:-}"
fi
HQ
chmod +x "$TMP/bin/hq"
PATH="$TMP/bin:$PATH"

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

echo "== device default binds only when unbound =="
unset HQ_SPAWN_COMPANY HQ_PARENT_SESSION_ID HQ_AGENT_WORKDIR HQ_AGENT_COMPANY_DIR HQ_AGENT_IDENTITY_FILE HQ_AGENT_ROOT_PREFIX || true
rm -rf "$TMP/workspace/sessions/child-sid"
HQ_DEFAULT_COMPANY_JSON='{"ok":true,"slug":"indigo","enabled":true,"needsChoice":false,"source":"configured"}' \
  session_auto_bind_apply "$TMP" "child-sid"
[ "$(session_auto_bind_meta_slug "$TMP" "child-sid")" = "indigo" ] \
  || fail "enabled device default did not bind indigo"
grep -qx 'company_source: device_default' "$TMP/workspace/sessions/child-sid/meta.yaml" \
  || fail "device-default source missing from meta.yaml"
grep -qx 'senior: user' "$TMP/workspace/sessions/child-sid/meta.yaml" \
  || fail "device-default bootstrap missing senior: user"
pass "unbound session binds the enabled device default with its source"

printf 'session_id: child-sid\ncompany_slug: otherco\ncompany_source: session\n' \
  > "$TMP/workspace/sessions/child-sid/meta.yaml"
HQ_DEFAULT_COMPANY_JSON='{"ok":true,"slug":"indigo","enabled":true,"needsChoice":false,"source":"configured"}' \
  session_auto_bind_apply "$TMP" "child-sid"
[ "$(session_auto_bind_meta_slug "$TMP" "child-sid")" = "otherco" ] \
  || fail "existing session company was overwritten by device default"
pass "existing session company beats the device default"

mkdir -p "$TMP/work-context/sessions"
printf '{"sessionId":"held-sid","contextStatus":"needs_company"}\n' \
  > "$TMP/work-context/sessions/held-sid.json"
rm -rf "$TMP/workspace/sessions/held-sid"
HQ_WORK_CONTEXT_ROOT="$TMP/work-context" \
  HQ_DEFAULT_COMPANY_JSON='{"defaultCompany":{"slug":"indigo","enabled":true,"repairHeldWithDefault":false}}' \
  session_auto_bind_apply "$TMP" "held-sid"
[ ! -f "$TMP/workspace/sessions/held-sid/meta.yaml" ] \
  || fail "held session was repaired without repairHeldWithDefault opt-in"
pass "held unbound session ignores non-opt-in default repair"

HQ_WORK_CONTEXT_ROOT="$TMP/work-context" \
  HQ_DEFAULT_COMPANY_JSON='{"defaultCompany":{"slug":"indigo","enabled":true,"repairHeldWithDefault":true}}' \
  session_auto_bind_apply "$TMP" "held-sid"
[ "$(session_auto_bind_meta_slug "$TMP" "held-sid")" = "indigo" ] \
  || fail "held session did not repair with explicit opt-in"
grep -qx 'company_source: device_default' "$TMP/workspace/sessions/held-sid/meta.yaml" \
  || fail "repaired session lost device_default confidence"
pass "held unbound session repairs only with explicit opt-in"

rm -rf "$TMP/workspace/sessions/canonical-fleet"
mkdir -p "$TMP/fake-root/var/lib/hq-agent"
printf '{}\n' > "$TMP/fake-root/var/lib/hq-agent/identity.json"
HQ_AGENT_ROOT_PREFIX="$TMP/fake-root" \
  HQ_DEFAULT_COMPANY_JSON='{"slug":"indigo","enabled":true,"needsChoice":false,"source":"configured"}' \
  session_auto_bind_apply "$TMP" "canonical-fleet"
[ ! -f "$TMP/workspace/sessions/canonical-fleet/meta.yaml" ] \
  || fail "canonical fleet identity path consumed a device default"
pass "canonical /var/lib/hq-agent/identity.json blocks device default"

started_ms="$(node -e 'process.stdout.write(String(Date.now()))')"
HQ_SLOW_DEFAULT=1 session_auto_bind_device_default "$TMP" >/dev/null || true
finished_ms="$(node -e 'process.stdout.write(String(Date.now()))')"
elapsed_ms=$((finished_ms - started_ms))
[ "$elapsed_ms" -lt 3000 ] \
  || fail "device-default lookup exceeded 2s watchdog (${elapsed_ms}ms)"
pass "device-default watchdog enforces a wall-clock ceiling"

rm -rf "$TMP/workspace/sessions/child-sid"
HQ_DEFAULT_COMPANY_JSON='{"ok":true,"slug":"indigo","enabled":false,"needsChoice":false,"source":"disabled"}' \
  session_auto_bind_apply "$TMP" "child-sid"
[ ! -f "$TMP/workspace/sessions/child-sid/meta.yaml" ] \
  || fail "disabled device default must not bind"
pass "disabled device default leaves the session unbound"

HQ_DEFAULT_COMPANY_JSON='{"ok":true,"slug":"indigo","enabled":true,"needsChoice":true,"source":"configured"}' \
  session_auto_bind_apply "$TMP" "child-sid"
[ ! -f "$TMP/workspace/sessions/child-sid/meta.yaml" ] \
  || fail "needsChoice device default must not bind"
pass "needsChoice device default leaves the session unbound"

rm -rf "$TMP/workspace/sessions/validated-sid"
HQ_DEFAULT_COMPANY_JSON='not valid json' \
  session_auto_bind_apply_validated_default "$TMP" "validated-sid" "indigo" "cmp_indigo" 0 false
[ "$(session_auto_bind_meta_slug "$TMP" "validated-sid")" = "indigo" ] \
  || fail "validated default did not bind the supplied slug"
[ "$(session_scope_read "$TMP" "validated-sid")" = "indigo" ] \
  || fail "validated default did not mint scope"
pass "validated default binds without a second device-default read"

# Inventory guard: every validated-default repair must receive both the
# historical-state bit and the opt-in. A held state without opt-in never gains
# meta or scope; with opt-in it carries the lower-confidence repair marker.
mkdir -p "$TMP/work-context/sessions"
printf '{"sessionId":"validated-held","contextStatus":"needs_company"}\n' > "$TMP/work-context/sessions/validated-held.json"
rm -rf "$TMP/workspace/sessions/validated-held"
session_auto_bind_apply_validated_default "$TMP" "validated-held" "indigo" "cmp_indigo" 1 false
[ ! -f "$TMP/workspace/sessions/validated-held/meta.yaml" ] \
  || fail "validated default relabeled a historical held session without opt-in"
session_auto_bind_apply_validated_default "$TMP" "validated-held" "indigo" "cmp_indigo" 1 true
grep -qx 'company_confidence: device_default_repair' "$TMP/workspace/sessions/validated-held/meta.yaml" \
  || fail "validated repair missing lower-confidence marker"
pass "validated historical repair is opt-in and marked lower confidence"

HQ_AGENT_IDENTITY_FILE="$TMP/fleet-identity.json" \
  HQ_DEFAULT_COMPANY_JSON='{"ok":true,"slug":"indigo","enabled":true,"needsChoice":false,"source":"configured"}' \
  session_auto_bind_apply "$TMP" "child-sid"
[ ! -f "$TMP/workspace/sessions/child-sid/meta.yaml" ] \
  || fail "fleet identity must not bind a device default"
pass "fleet identity leaves the session unbound"

unset HQ_DEFAULT_COMPANY_JSON

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

echo "== Codex SessionStart side-effect bind =="
rm -rf "$TMP/workspace/sessions/codex-sid"
mkdir -p "$TMP/workspace/sessions/codex-sid" "$TMP/.codex/hooks" "$TMP/core/scripts/lib"
cp "$ROOT/.codex/hooks/hq-codex-hook-adapter.sh" "$TMP/.codex/hooks/"
cp "$ROOT/core/scripts/lib/hook-adapter-core.sh" "$TMP/core/scripts/lib/" 2>/dev/null || true
cp "$ROOT/core/scripts/lib/session-auto-bind.sh" "$TMP/core/scripts/lib/"
cp "$ROOT/core/scripts/lib/session-scope-capability.sh" "$TMP/core/scripts/lib/"
chmod +x "$TMP/.codex/hooks/hq-codex-hook-adapter.sh"
printf '{}\n' > "$TMP/.claude/settings.json"
printf '[]\n' > "$TMP/.claude/hooks/hook-registry.json" 2>/dev/null || true

printf '{"hook_event_name":"SessionStart","session_id":"codex-sid","cwd":"%s"}\n' "$TMP" \
  | HQ_SPAWN_COMPANY=indigo HQ_PARENT_SESSION_ID=parent-sid HQ_ROOT="$TMP" CLAUDE_PROJECT_DIR="$TMP" \
    bash "$TMP/.codex/hooks/hq-codex-hook-adapter.sh" >/dev/null 2>"$TMP/codex-adapter.err" || true

[ "$(session_auto_bind_meta_slug "$TMP" "codex-sid")" = "indigo" ] \
  || fail "Codex SessionStart did not bind spawn company (err=$(cat "$TMP/codex-adapter.err"))"
payload='{"tool_name":"Read","session_id":"codex-sid","cwd":"'"$TMP"'","tool_input":{"file_path":"'"$TMP"'/companies/indigo/settings/foo.yaml"}}'
rc="$(run_auth "$payload")"
[ "$rc" = "0" ] || fail "Codex SessionStart bind must unblock indigo Read, got $rc err=$(cat "$TMP/err.txt")"
pass "Codex SessionStart binds before Read"

echo "session-auto-bind: all passed"
