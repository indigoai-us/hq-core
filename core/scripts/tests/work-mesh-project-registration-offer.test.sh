#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SCRIPT="$ROOT/core/scripts/work-mesh-project-registration-offer.sh"
REGISTER_SCRIPT="$ROOT/core/scripts/register-project.sh"
FLAG_READER="$ROOT/.claude/hooks/work-mesh-project-registration-offer-flag.cjs"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
[ -f "$SCRIPT" ] || fail "project registration offer helper is missing"
[ -f "$REGISTER_SCRIPT" ] || fail "project registration script is missing"
[ -f "$FLAG_READER" ] || fail "project registration flag reader is missing"
TEST_COMPANY="fixture-co"
TEST_PROJECT="fixture-co-proj-001"
mkdir -p "$TMP/bin" "$TMP/hq/.claude/hooks" "$TMP/hq/core/scripts" "$TMP/hq/companies/$TEST_COMPANY" \
  "$TMP/home/.hq/work-mesh/cache/projects/cmp_fixtureco"
cp "$SCRIPT" "$REGISTER_SCRIPT" "$TMP/hq/core/scripts/"
cp "$FLAG_READER" "$TMP/hq/.claude/hooks/"
printf 'companies:\r\n  %s:\r\n    cloud_uid: cmp_fixtureco\r\n' "$TEST_COMPANY" \
  > "$TMP/hq/companies/manifest.yaml"
cat > "$TMP/hq/companies/$TEST_COMPANY/board.json" <<JSON
{"company":"$TEST_COMPANY","projects":[{"id":"$TEST_PROJECT","title":"Fixture project","description":"Test only","status":"exploring"}]}
JSON
cat > "$TMP/bin/node" <<'SH'
#!/usr/bin/env bash
echo called >> "$TEST_NODE_LOG"
if [ "${BLOCK_NODE:-}" = "1" ]; then
  exit 91
fi
printf '%s\n' "${TEST_FLAG_VALUE:-false}"
SH
chmod +x "$TMP/bin/node"
cat > "$TMP/bin/hq" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TEST_HQ_LOG"
[ "$1" = mesh ] && [ "$2" = project ] && [ "$3" = set ] && [ "${11:-}" = --create ] || exit 92
printf '%s\n' '{"registration":{"threadId":"thr_fixture","channelId":"chn_fixture"}}'
SH
chmod +x "$TMP/bin/hq"
: > "$TMP/node.log"
export TEST_NODE_LOG="$TMP/node.log"
: > "$TMP/hq.log"
export TEST_HQ_LOG="$TMP/hq.log"

check_offer() {
  PATH="$TMP/bin:$PATH" TEST_FLAG_VALUE="${TEST_FLAG_VALUE:-false}" \
    HQ_ROOT="$TMP/hq" HOME="$TMP/home" HQ_FLAGS_API_URL="https://flags.invalid" \
    HQ_COMPANY_UID="cmp_fixtureco" HQ_COMPANY_SLUG="$TEST_COMPANY" \
    bash "$TMP/hq/core/scripts/work-mesh-project-registration-offer.sh" --check "$TEST_COMPANY" "$TEST_PROJECT"
}

crlf_on="$(PATH="$TMP/bin:$PATH" HOME="$TMP/home" HQ_ROOT="$TMP/hq" \
  HQ_FLAGS_API_URL="https://flags.invalid" TEST_FLAG_VALUE=true \
  bash "$TMP/hq/core/scripts/work-mesh-project-registration-offer.sh" --check "$TEST_COMPANY" "$TEST_PROJECT")"
[ "$crlf_on" = "offer" ] || fail "CRLF manifest cloud_uid should enable the offer lookup, got: $crlf_on"
echo "PASS: offer lookup resolves a cloud UID from a CRLF manifest"

off="$(TEST_FLAG_VALUE=false check_offer)"
[ "$off" = "off" ] || fail "default-off flag should not offer creation, got: $off"
echo "PASS: flag off does not offer Work Mesh registration"

on="$(TEST_FLAG_VALUE=true check_offer)"
[ "$on" = "offer" ] || fail "cloud-backed unregistered project should offer creation, got: $on"
echo "PASS: flag on offers registration for an unregistered cloud project"

HQ_ROOT="$TMP/hq" TEST_FLAG_VALUE=true bash "$TMP/hq/core/scripts/work-mesh-project-registration-offer.sh" --defer "$TEST_COMPANY" "$TEST_PROJECT"
deferred="$(TEST_FLAG_VALUE=true check_offer)"
[ "$deferred" = "deferred" ] || fail "Not now must suppress later offers, got: $deferred"
echo "PASS: Not now records a single deferral"
calls_before_deferred_check="$(wc -l < "$TEST_NODE_LOG")"
BLOCK_NODE=1 deferred_again="$(TEST_FLAG_VALUE=true check_offer)"
[ "$deferred_again" = "deferred" ] || fail "deferred project should not need a flag lookup, got: $deferred_again"
[ "$(wc -l < "$TEST_NODE_LOG")" -eq "$calls_before_deferred_check" ] || fail "deferred project performed an unnecessary flag lookup"
echo "PASS: deferred project skips the flag lookup"

HQ_ROOT="$TMP/hq" TEST_FLAG_VALUE=true bash "$TMP/hq/core/scripts/work-mesh-project-registration-offer.sh" --accept "$TEST_COMPANY" "$TEST_PROJECT"
accepted="$(TEST_FLAG_VALUE=true check_offer)"
[ "$accepted" = "accepted" ] || fail "accepted registration can resume without another prompt, got: $accepted"
echo "PASS: accepted registration does not ask again"

registration_output="$(PATH="$TMP/bin:$PATH" HOME="$TMP/home" HQ_ROOT="$TMP/hq" \
  bash "$TMP/hq/core/scripts/register-project.sh" --brainstorm "$TEST_COMPANY" "$TEST_PROJECT")"
[ "$registration_output" = "registered $TEST_COMPANY/$TEST_PROJECT thread=thr_fixture channel=chn_fixture" ] \
  || fail "accepted project was not registered through the existing CLI path: $registration_output"
grep -q 'mesh project set fixture-co-proj-001 --company fixture-co .* --create --json' "$TEST_HQ_LOG" \
  || fail "brainstorm registration did not use hq mesh project set --create"
echo "PASS: accepted brainstorm offer creates and verifies the Work Mesh registration"

registered="$(TEST_FLAG_VALUE=true check_offer)"
[ "$registered" = "registered" ] || fail "registered project should not be offered, got: $registered"
echo "PASS: registered project is not offered again"
calls_before_registered_check="$(wc -l < "$TEST_NODE_LOG")"
BLOCK_NODE=1 registered_again="$(TEST_FLAG_VALUE=true check_offer)"
[ "$registered_again" = "registered" ] || fail "registered project should remain registered, got: $registered_again"
[ "$(wc -l < "$TEST_NODE_LOG")" -eq "$calls_before_registered_check" ] || fail "registered project performed an unnecessary flag lookup"
echo "PASS: registered project skips the flag lookup"

node - "$FLAG_READER" <<'NODE' || fail "hq-flags reader contract failed"
const assert = require("node:assert/strict");
const { DEFAULT_VALUE, FLAG_KEY, enabled } = require(process.argv[2]);
(async () => {
  assert.equal(DEFAULT_VALUE, false);
  assert.equal(FLAG_KEY, "workmesh.offer-project-create-on-brainstorm");
  assert.equal(await enabled({ env: {} }), false);
  const active = await enabled({
    env: { HQ_FLAGS_API_URL: "https://flags.invalid", HQ_COMPANY_UID: "cmp_fixtureco" },
    createClient: () => ({ ready: async () => {}, snapshot: () => ({ flags: { [FLAG_KEY]: true } }), close() {} }),
    loadCachedTokens: () => ({ idToken: "test-token" }),
  });
  assert.equal(active, true);
})().catch((error) => { console.error(error); process.exitCode = 1; });
NODE
echo "PASS: offer flag is defined through hq-flags with a false default"

# /prd keeps its finalize steps in the shared file it references.
grep -Fq '_shared/prd-finalize.md' "$ROOT/.claude/skills/prd/SKILL.md" \
  || fail ".claude/skills/prd/SKILL.md does not reference _shared/prd-finalize.md"
for skill in .claude/skills/_shared/prd-finalize.md; do
  grep -Fq 'work-mesh-project-registration-offer.sh --check {co} {board-project-id}' "$ROOT/$skill" \
    || fail "$skill does not check the registration offer state"
  grep -Fq 'stop here and do not run' "$ROOT/$skill" \
    || fail "$skill can continue registration after a deferred offer"
  grep -Fq '`accepted` result retries registration' "$ROOT/$skill" \
    || fail "$skill does not resume accepted registration"
done
echo "PASS: /prd honors persisted registration offer states"
