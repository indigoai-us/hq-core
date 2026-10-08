#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SCRIPT="$ROOT/core/scripts/update-hq-install-offer.sh"
FIXTURE="$ROOT/core/scripts/tests/hq-anywhere-flag-fixture.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
[[ -x "$SCRIPT" ]] || fail "offer helper is missing or not executable"
source "$FIXTURE"

setup_case() {
  local name="$1" enabled="${2:-true}"
  CASE="$TMP/$name"
  mkdir -p "$CASE/home" "$CASE/cli"
  hq_anywhere_flag_fixture "$CASE/cli"
  mkdir -p "$CASE/hq/core/scripts" "$CASE/hq/companies/indigo" "$CASE/cli/dist/lib"
  cat > "$CASE/hq/core/scripts/hq-session.sh" <<'SH'
#!/usr/bin/env bash
[ "$1" = get ] && [ "$2" = company_slug ] && printf indigo
SH
  printf '%s\n' 'cmp_indigo123' > "$CASE/hq/companies/indigo/.company-uid"
  printf '%s\n' '{"name":"@indigoai-us/hq-cli","version":"0.0.0","type":"module"}' \
    > "$CASE/cli/package.json"
  printf '%s\n' 'export const FLAG_REGISTRY_DEFAULT_ENDPOINT = "https://flags.test";' \
    > "$CASE/cli/dist/lib/flag-registry-endpoint.js"
  hq_anywhere_flag_env "$CASE/cli" "$enabled"
  export HQ_TEST_HQ_LOG="$CASE/hq.log"
  : > "$HQ_TEST_HQ_LOG"
  cat > "$CASE/cli/bin/hq" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$HQ_TEST_HQ_LOG"
SH
  chmod +x "$CASE/cli/bin/hq"
  export PATH="$CASE/cli/bin:$PATH" HOME="$CASE/home"
}

check() { bash "$SCRIPT" --check; }
accept() { bash "$SCRIPT" --accept; }
decline() { bash "$SCRIPT" --decline; }

setup_case accept
[[ "$(check)" == offer ]] || fail "enabled flag should produce the first offer"
[[ "$(accept)" == accepted ]] || fail "accept should be recorded"
[[ "$(check)" == answered ]] || fail "accepted offer should not repeat"
[[ "$(cat "$HOME/.hq/anywhere/update-hq-install-offer.json")" == *'"answer":"accepted"'* ]] || fail "accepted state has the wrong answer"
[[ "$(stat -c '%a' "$HOME/.hq/anywhere")" == 700 ]] || fail "state directory must be owner-only"
[[ "$(stat -c '%a' "$HOME/.hq/anywhere/update-hq-install-offer.json")" == 600 ]] || fail "state file must be owner-only"
echo "PASS: enabled flag offers once and records acceptance"

setup_case decline
[[ "$(check)" == offer ]] || fail "enabled flag should offer before decline"
[[ "$(decline)" == declined ]] || fail "decline should be recorded"
[[ "$(check)" == answered ]] || fail "declined offer should not repeat"
[[ "$(cat "$HOME/.hq/anywhere/update-hq-install-offer.json")" == *'"answer":"declined"'* ]] || fail "declined state has the wrong answer"
echo "PASS: decline is persisted and suppresses later offers"

# A headless skill run follows its documented default-no branch and records a
# decline. The helper has no install path, and the test hq binary records calls.
setup_case headless
grep -q 'headless, non-interactive, or' "$ROOT/.claude/skills/update-hq/SKILL.md" || fail "skill must define the headless case"
grep -Fq "run \`--decline\`; do not install" "$ROOT/.claude/skills/update-hq/SKILL.md" || fail "headless path must default to decline"
[[ "$(decline)" == declined ]] || fail "headless default should record decline"
[[ ! -e "$HOME/.hq/anywhere/claude-install.json" && ! -e "$HOME/.hq/anywhere/codex-install.json" ]] || fail "headless decline must not install"
[[ ! -s "$HQ_TEST_HQ_LOG" ]] || fail "headless decline must not invoke hq install"
echo "PASS: headless path defaults to decline without installing"

setup_case flag-off false
[[ "$(check)" == off ]] || fail "flag off should suppress the offer"
[[ ! -e "$HOME/.hq/anywhere" ]] || fail "flag-off check must write no state"
echo "PASS: flag off suppresses offer and leaves no state"

setup_case already-installed
mkdir -p "$HOME/.hq/anywhere"
printf '%s\n' '{}' > "$HOME/.hq/anywhere/codex-install.json"
[[ "$(check)" == installed ]] || fail "recorded global install should suppress the offer"
[[ ! -e "$HOME/.hq/anywhere/update-hq-install-offer.json" ]] || fail "already-installed check must not write offer state"
echo "PASS: existing global install suppresses the offer without writing state"

setup_case old-cli
rm -rf "$CASE/cli/node_modules/@indigoai-us/hq-flags-client"
[[ "$(check)" == offer ]] || fail "CLI without the flag reader package should use the flag's on fallback"
echo "PASS: missing flag support defaults on"

setup_case resolved-context
cat > "$CASE/cli/node_modules/@indigoai-us/hq-flags-client/index.js" <<'JS'
import fs from "node:fs";
export function createFlagClient(config) {
  fs.writeFileSync(process.env.HQ_TEST_CONTEXT_LOG, JSON.stringify({
    endpoint: config.endpoint,
    companyUid: config.companyUid,
    companyIdentifiers: config.companyIdentifiers,
  }));
  return { ready: async () => {}, snapshot: () => ({ flags: { "hq-anywhere-runtime": true } }), close() {} };
}
JS
export HQ_TEST_CONTEXT_LOG="$CASE/context.json"
resolved="$(env -u HQ_FLAGS_API_URL -u HQ_COMPANY_UID -u HQ_COMPANY_SLUG \
  HQ_ROOT="$CASE/hq" bash "$SCRIPT" --check)"
[[ "$resolved" == offer ]] || fail "missing environment should resolve the bound company and CLI endpoint"
grep -q '"endpoint":"https://flags.test"' "$HQ_TEST_CONTEXT_LOG" || fail "default flag endpoint was not resolved from hq-cli"
grep -q '"companyUid":"cmp_indigo123"' "$HQ_TEST_CONTEXT_LOG" || fail "company UID did not come from the bound session"
echo "PASS: missing environment resolves the CLI endpoint and bound company"

setup_case unbound-context
cat > "$CASE/hq/core/scripts/hq-session.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
unbound="$(env -u HQ_FLAGS_API_URL -u HQ_COMPANY_UID -u HQ_COMPANY_SLUG \
  HQ_ROOT="$CASE/hq" bash "$SCRIPT" --check)"
[[ "$unbound" == off ]] || fail "missing bound company must fail closed"
[[ ! -e "$HOME/.hq/anywhere" ]] || fail "unbound company check must not write state"
echo "PASS: unbound company, including person-only override, remains off"

setup_case persistence-error
mkdir -p "$CASE/bin"
cat > "$CASE/bin/mv" <<'SH'
#!/usr/bin/env bash
exit 44
SH
chmod +x "$CASE/bin/mv"
export PATH="$CASE/bin:$PATH"
if accept > "$CASE/out" 2> "$CASE/err"; then
  fail "a failed atomic rename must return a failure"
fi
grep -q 'could not persist the answer' "$CASE/err" || fail "persistence failure must be reported"
[[ ! -e "$HOME/.hq/anywhere/update-hq-install-offer.json" ]] || fail "failed persistence must not create answer state"
echo "PASS: failed answer persistence is reported and does not claim success"
