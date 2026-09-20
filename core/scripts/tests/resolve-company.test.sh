#!/usr/bin/env bash
# hq-core: public
# Regression coverage for prompt, session, and device-default company routing.
# Kept compatible with macOS /bin/bash 3.2.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }
assert_eq() {
  [ "$1" = "$2" ] || fail "$3: expected '$2', got '$1'"
}

mkdir -p "$TMP/core/scripts/lib" "$TMP/companies" "$TMP/workspace/sessions" "$TMP/bin"
cp "$ROOT/core/scripts/resolve-company.sh" "$TMP/core/scripts/"
cp "$ROOT/core/scripts/hq-session.sh" "$TMP/core/scripts/"
cp -R "$ROOT/core/scripts/lib/." "$TMP/core/scripts/lib/"
chmod +x "$TMP/core/scripts/resolve-company.sh" "$TMP/core/scripts/hq-session.sh"

cat > "$TMP/companies/manifest.yaml" <<'YAML'
companies:
  _template:
    name: Template
  acme:
    name: Acme Corp
  globex:
    name: Globex
  holler:
    name: Holler
  zeta:
    name: Zeta
  zeta-labs:
    name: Zeta Labs
YAML

cat > "$TMP/bin/hq" <<'HQ'
#!/usr/bin/env bash
if [ "$1" = "mesh" ] && [ "$2" = "context" ] && [ "$3" = "default" ] && [ "$4" = "get" ] && [ "$5" = "--json" ]; then
  if [ "${HQ_SLOW_DEFAULT:-}" = "1" ]; then
    sleep 8
  fi
  printf '%s\n' "${HQ_DEFAULT_COMPANY_JSON:-}"
elif [ "$1" = "mesh" ] && [ "$2" = "context" ] && [ "$3" = "reconcile" ] && [ "$4" = "--observation-json" ] && [ "$6" = "--machine" ] && [ "$7" = "--offline" ]; then
  if [ "${HQ_SLOW_VALIDATOR:-}" = "1" ]; then
    sleep 8
  fi
  [ "${HQ_FAIL_VALIDATOR:-}" = "1" ] && exit 1
  session_id="$(printf '%s' "$5" | sed -nE 's/.*"sessionId":"([^"]+)".*/\1/p')"
  operation_id="$(printf '%s' "$5" | sed -nE 's/.*"clientOperationId":"([^"]+)".*/\1/p')"
  output="${HQ_DEFAULT_PREFLIGHT_JSON:-}"
  output="${output//__SID__/$session_id}"
  output="${output//__OP__/$operation_id}"
  printf '%s\n' "$output"
fi
HQ
chmod +x "$TMP/bin/hq"

unset HQ_SESSION_ID CLAUDE_CODE_SESSION_ID CLAUDE_SESSION_ID CODEX_SESSION_ID CODEX_THREAD_ID
export HQ_HQ_SESSION_NO_CLI=1

resolve() {
  PATH="$TMP/bin:$PATH" bash "$TMP/core/scripts/resolve-company.sh" --root "$TMP" --prompt "$1" </dev/null
}
company_of() { printf '%s' "$1" | sed -E 's/.*"company":"([^"]*)".*/\1/'; }
source_of() { printf '%s' "$1" | sed -E 's/.*"source":"([^"]*)".*/\1/'; }

unset HQ_DEFAULT_COMPANY_JSON HQ_AGENT_WORKDIR HQ_AGENT_COMPANY_DIR HQ_AGENT_IDENTITY_FILE HQ_AGENT_ROOT_PREFIX || true

out="$(resolve 'fix the globex morning flash renderer bug')"
assert_eq "$(company_of "$out")" "globex" "whole-token prompt slug"
assert_eq "$(source_of "$out")" "prompt" "prompt source"
pass "explicit prompt company resolves"

out="$(resolve 'rewrite the globexes page')"
assert_eq "$(company_of "$out")" "" "substring does not resolve"
assert_eq "$(source_of "$out")" "none" "substring source"
pass "prompt matching stays whole-token only"

out="$(resolve 'compare zeta and zeta-labs numbers')"
assert_eq "$(company_of "$out")" "zeta-labs" "longest prompt slug wins"
pass "longest explicit prompt slug wins"

printf 'sess-1\n' > "$TMP/workspace/sessions/.current"
mkdir -p "$TMP/workspace/sessions/sess-1"
printf 'company_slug: holler\n' > "$TMP/workspace/sessions/sess-1/meta.yaml"
HQ_DEFAULT_COMPANY_JSON='{"ok":true,"slug":"acme","enabled":true,"needsChoice":false,"source":"configured"}'
export HQ_DEFAULT_COMPANY_JSON

out="$(resolve 'no explicit company in this request')"
assert_eq "$(company_of "$out")" "holler" "bound session beats device default"
assert_eq "$(source_of "$out")" "session" "session source"
pass "bound session company beats device default"

out="$(resolve 'please plan the globex migration')"
assert_eq "$(company_of "$out")" "globex" "explicit prompt beats session"
assert_eq "$(source_of "$out")" "prompt" "explicit prompt source"
pass "explicit prompt company beats ambient session"

printf '' > "$TMP/workspace/sessions/sess-1/meta.yaml"
HQ_DEFAULT_PREFLIGHT_JSON='{"contractVersion":1,"kind":"queued","classification":"needs_project","delivery":"queued","lifecycle":"open","sessionId":"__SID__","clientOperationId":"__OP__","companySlug":"acme","companyUid":"cmp_acme"}'
export HQ_DEFAULT_PREFLIGHT_JSON
out="$(resolve 'plan the default-backed migration')"
assert_eq "$(company_of "$out")" "acme" "enabled default resolves"
assert_eq "$(source_of "$out")" "device_default" "default source"
pass "active device-default membership resolves"

HQ_DEFAULT_PREFLIGHT_JSON='{"contractVersion":1,"kind":"needs_company","classification":"needs_company","delivery":"clean","lifecycle":"open","sessionId":"__SID__","clientOperationId":"__OP__"}'
out="$(resolve 'plan the default-backed migration')"
assert_eq "$(company_of "$out")" "" "revoked default does not resolve"
assert_eq "$(source_of "$out")" "none" "revoked default source is none"
pass "revoked device-default membership fails closed"

HQ_DEFAULT_PREFLIGHT_JSON='not-json'
out="$(resolve 'plan the default-backed migration')"
assert_eq "$(company_of "$out")" "" "malformed validation does not resolve"
assert_eq "$(source_of "$out")" "none" "malformed validation source is none"
pass "malformed device-default validation fails closed"

HQ_DEFAULT_PREFLIGHT_JSON='{"contractVersion":1,"kind":"queued","classification":"needs_project","delivery":"queued","lifecycle":"open","sessionId":"__SID__","clientOperationId":"__OP__","companySlug":"acme","companyUid":"cmp_acme"}'
started_ms="$(node -e 'process.stdout.write(String(Date.now()))')"
out="$(HQ_SLOW_VALIDATOR=1 resolve 'plan the default-backed migration')"
finished_ms="$(node -e 'process.stdout.write(String(Date.now()))')"
elapsed_ms=$((finished_ms - started_ms))
[ "$elapsed_ms" -lt 4500 ] || fail "resolver membership validation did not stop before the delayed validator (${elapsed_ms}ms)"
assert_eq "$(company_of "$out")" "" "timed-out validation does not resolve"
assert_eq "$(source_of "$out")" "none" "timed-out validation source is none"
pass "membership validation watchdog fails closed"

out="$(HQ_FAIL_VALIDATOR=1 resolve 'plan the default-backed migration')"
assert_eq "$(company_of "$out")" "" "unavailable validation does not resolve"
assert_eq "$(source_of "$out")" "none" "unavailable validation source is none"
pass "unavailable device-default validation fails closed"

HQ_DEFAULT_COMPANY_JSON='{"ok":true,"slug":"acme","enabled":false,"needsChoice":false,"source":"disabled"}'
out="$(resolve 'plan the default-backed migration')"
assert_eq "$(company_of "$out")" "" "disabled default does not resolve"
assert_eq "$(source_of "$out")" "none" "disabled source is none"
pass "disabled device default falls through to picker"

HQ_DEFAULT_COMPANY_JSON='{"ok":true,"slug":"acme","enabled":true,"needsChoice":true,"source":"configured"}'
out="$(resolve 'plan the default-backed migration')"
assert_eq "$(company_of "$out")" "" "needsChoice does not resolve"
pass "needsChoice falls through to picker"

HQ_DEFAULT_COMPANY_JSON='{"ok":true,"slug":"acme","enabled":true,"needsChoice":false,"source":"configured"}'
HQ_AGENT_IDENTITY_FILE="$TMP/fleet-identity.json"
export HQ_AGENT_IDENTITY_FILE
out="$(resolve 'plan the default-backed migration')"
assert_eq "$(company_of "$out")" "" "fleet identity cannot use device default"
pass "fleet identity cannot resolve a device default"

unset HQ_AGENT_IDENTITY_FILE
mkdir -p "$TMP/fake-root/var/lib/hq-agent"
printf '{}\n' > "$TMP/fake-root/var/lib/hq-agent/identity.json"
HQ_AGENT_ROOT_PREFIX="$TMP/fake-root"
export HQ_AGENT_ROOT_PREFIX
out="$(resolve 'plan the default-backed migration')"
assert_eq "$(company_of "$out")" "" "canonical fleet identity path blocks device default"
assert_eq "$(source_of "$out")" "none" "canonical fleet identity source"
pass "canonical /var/lib/hq-agent/identity.json blocks resolver default"
unset HQ_AGENT_ROOT_PREFIX

started_ms="$(node -e 'process.stdout.write(String(Date.now()))')"
HQ_SLOW_DEFAULT=1 resolve 'plan the default-backed migration' >/dev/null
finished_ms="$(node -e 'process.stdout.write(String(Date.now()))')"
elapsed_ms=$((finished_ms - started_ms))
[ "$elapsed_ms" -lt 4500 ] || fail "resolver default lookup did not stop before the delayed command (${elapsed_ms}ms)"
pass "resolver default watchdog enforces a wall-clock ceiling"

unset HQ_AGENT_IDENTITY_FILE HQ_DEFAULT_COMPANY_JSON
echo "resolve-company: all passed"
