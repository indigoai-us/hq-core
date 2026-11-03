#!/usr/bin/env bash
# Work Mesh registration happens at the start of /brainstorm and /prd, right
# after the Board entry is written: always-on for cloud-backed companies, no
# flag, no prompt. This test covers the check helper, the --board registration
# path, and the skill text that wires them in at the start.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SCRIPT="$ROOT/core/scripts/work-mesh-project-registration-offer.sh"
REGISTER_SCRIPT="$ROOT/core/scripts/register-project.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
unset HQ_COMPANY_SLUG
[ -f "$SCRIPT" ] || fail "project registration check helper is missing"
[ -f "$REGISTER_SCRIPT" ] || fail "project registration script is missing"
[ ! -e "$ROOT/.claude/hooks/work-mesh-project-registration-offer-flag.cjs" ] \
  || fail "the registration offer flag reader should be gone; registration is always-on"
TEST_COMPANY="fixture-co"
TEST_PROJECT="fixture-co-proj-001"
LOCAL_COMPANY="local-co"
mkdir -p "$TMP/bin" "$TMP/hq/core/scripts" "$TMP/hq/companies/$TEST_COMPANY" "$TMP/hq/companies/$LOCAL_COMPANY" \
  "$TMP/home/.hq/work-mesh/cache/projects/cmp_fixtureco"
cp "$SCRIPT" "$REGISTER_SCRIPT" "$TMP/hq/core/scripts/"
printf 'companies:\r\n  %s:\r\n    cloud_uid: cmp_fixtureco\r\n  %s:\r\n    name: Local only\r\n' "$TEST_COMPANY" "$LOCAL_COMPANY" \
  > "$TMP/hq/companies/manifest.yaml"
cat > "$TMP/hq/companies/$TEST_COMPANY/board.json" <<JSON
{"company":"$TEST_COMPANY","projects":[{"id":"$TEST_PROJECT","title":"Fixture project","description":"Test only","status":"exploring"}]}
JSON
cat > "$TMP/hq/companies/$LOCAL_COMPANY/board.json" <<JSON
{"company":"$LOCAL_COMPANY","projects":[{"id":"local-co-proj-001","title":"Local project","description":"Test only","status":"exploring"}]}
JSON
cat > "$TMP/bin/node" <<'SH'
#!/usr/bin/env bash
echo called >> "$TEST_NODE_LOG"
exit 93
SH
chmod +x "$TMP/bin/node"
cat > "$TMP/bin/hq" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TEST_HQ_LOG"
printf '%s\n' "${HQ_COMPANY_UID:-}" >> "$TEST_HQ_UID_LOG"
[ "$1" = mesh ] && [ "$2" = project ] && [ "$3" = set ] && [ "${11:-}" = --create ] || exit 92
printf '%s\n' '{"registration":{"threadId":"thr_fixture","channelId":"chn_fixture"}}'
SH
chmod +x "$TMP/bin/hq"
: > "$TMP/node.log"
export TEST_NODE_LOG="$TMP/node.log"
: > "$TMP/hq.log"
export TEST_HQ_LOG="$TMP/hq.log"
: > "$TMP/hq-uid.log"
export TEST_HQ_UID_LOG="$TMP/hq-uid.log"

check() {
  PATH="$TMP/bin:$PATH" HQ_ROOT="$TMP/hq" HOME="$TMP/home" \
    bash "$TMP/hq/core/scripts/work-mesh-project-registration-offer.sh" --check "$1" "$2"
}

needs="$(check "$TEST_COMPANY" "$TEST_PROJECT")"
[ "$needs" = "register" ] || fail "cloud-backed unregistered project must register without a flag, got: $needs"
[ ! -s "$TEST_NODE_LOG" ] || fail "the check helper must not call node for a flag lookup"
echo "PASS: cloud-backed unregistered project registers with no flag and no prompt"

local_result="$(check "$LOCAL_COMPANY" "local-co-proj-001")"
[ "$local_result" = "local" ] || fail "company without cloud_uid should be local, got: $local_result"
echo "PASS: company without a cloud uid is local"

env_local="$(HQ_COMPANY_UID=cmp_fixtureco check "$LOCAL_COMPANY" "local-co-proj-001" 2>/dev/null)"
[ "$env_local" = "local" ] || fail "HQ_COMPANY_UID for another company must not make a local company register, got: $env_local"
env_other="$(HQ_COMPANY_UID=cmp_othercompany check "$TEST_COMPANY" "$TEST_PROJECT" 2>/dev/null)"
[ "$env_other" = "register" ] || fail "named company's own uid must decide, got: $env_other"
echo "PASS: the named company's uid wins over HQ_COMPANY_UID"
env_active="$(HQ_COMPANY_SLUG="$LOCAL_COMPANY" HQ_COMPANY_UID=cmp_localco check "$LOCAL_COMPANY" "local-co-proj-001" 2>/dev/null)"
[ "$env_active" = "register" ] || fail "HQ_COMPANY_UID for the active company must register a company with no recorded uid, got: $env_active"
env_foreign="$(HQ_COMPANY_SLUG="$LOCAL_COMPANY" HQ_COMPANY_UID=cmp_fixtureco check "$LOCAL_COMPANY" "local-co-proj-001" 2>/dev/null)"
[ "$env_foreign" = "local" ] || fail "an HQ_COMPANY_UID another company records must not register, got: $env_foreign"
env_inactive="$(HQ_COMPANY_SLUG="$TEST_COMPANY" HQ_COMPANY_UID=cmp_localco check "$LOCAL_COMPANY" "local-co-proj-001" 2>/dev/null)"
[ "$env_inactive" = "local" ] || fail "HQ_COMPANY_UID must not apply when another company is active, got: $env_inactive"
echo "PASS: with no recorded uid, HQ_COMPANY_UID counts only for the active company"

cp "$TMP/hq/companies/$TEST_COMPANY/board.json" "$TMP/board.bak"
jq --arg id "$TEST_PROJECT" '.projects |= map(if .id == $id then . + {mesh_registration_prompt_state:"deferred"} else . end)' \
  "$TMP/board.bak" > "$TMP/hq/companies/$TEST_COMPANY/board.json"
deferred="$(check "$TEST_COMPANY" "$TEST_PROJECT")"
[ "$deferred" = "deferred" ] || fail "an entry the user deferred earlier must not auto-register, got: $deferred"
cp "$TMP/board.bak" "$TMP/hq/companies/$TEST_COMPANY/board.json"
echo "PASS: an earlier deferral is honored"

missing="$(check "$TEST_COMPANY" "fixture-co-proj-999")"
[ "$missing" = "missing" ] || fail "unknown Board entry should be missing, got: $missing"
echo "PASS: unknown Board entry is reported missing"

if PATH="$TMP/bin:$PATH" HQ_ROOT="$TMP/hq" bash "$TMP/hq/core/scripts/work-mesh-project-registration-offer.sh" --accept "$TEST_COMPANY" "$TEST_PROJECT" 2>/dev/null; then
  fail "--accept should no longer exist; there is no prompt to record"
fi
if PATH="$TMP/bin:$PATH" HQ_ROOT="$TMP/hq" bash "$TMP/hq/core/scripts/work-mesh-project-registration-offer.sh" --defer "$TEST_COMPANY" "$TEST_PROJECT" 2>/dev/null; then
  fail "--defer should no longer exist; registration cannot be deferred"
fi
echo "PASS: accept and defer prompt states are gone"

# Wrong-board regression: --board (the always-on start path) must refuse an
# HQ_COMPANY_UID exported for another company, and must never reach hq mesh.
if HQ_COMPANY_UID=cmp_othercompany PATH="$TMP/bin:$PATH" HOME="$TMP/home" HQ_ROOT="$TMP/hq" \
  bash "$TMP/hq/core/scripts/register-project.sh" --board "$TEST_COMPANY" "$TEST_PROJECT" >/dev/null 2>&1; then
  fail "--board must refuse when HQ_COMPANY_UID names a different company"
fi
[ ! -s "$TEST_HQ_LOG" ] || fail "--board with a mismatched HQ_COMPANY_UID still reached hq mesh: $(cat "$TEST_HQ_LOG")"
echo "PASS: --board refuses an HQ_COMPANY_UID for another company"

registration_output="$(env -u HQ_COMPANY_UID PATH="$TMP/bin:$PATH" HOME="$TMP/home" HQ_ROOT="$TMP/hq" \
  bash "$TMP/hq/core/scripts/register-project.sh" --board "$TEST_COMPANY" "$TEST_PROJECT")"
[ "$registration_output" = "registered $TEST_COMPANY/$TEST_PROJECT thread=thr_fixture channel=chn_fixture" ] \
  || fail "Board entry was not registered through the CLI path: $registration_output"
grep -q 'mesh project set fixture-co-proj-001 --company fixture-co .* --create --json' "$TEST_HQ_LOG" \
  || fail "--board registration did not use hq mesh project set --create"
[ "$(head -n1 "$TEST_HQ_UID_LOG")" = "cmp_fixtureco" ] \
  || fail "--board must pin the hq CLI to the named company's uid, got: '$(head -n1 "$TEST_HQ_UID_LOG")'"
jq -e --arg id "$TEST_PROJECT" 'any(.projects[]; .id == $id and .threadId == "thr_fixture" and .channelId == "chn_fixture" and (has("mesh_registration_prompt_state") | not))' \
  "$TMP/hq/companies/$TEST_COMPANY/board.json" >/dev/null \
  || fail "board.json entry missing registration ids or still carries a prompt state"
echo "PASS: --board registers a Board entry that has no prd.json yet"

alias_output="$(PATH="$TMP/bin:$PATH" HOME="$TMP/home" HQ_ROOT="$TMP/hq" \
  bash "$TMP/hq/core/scripts/register-project.sh" --brainstorm "$TEST_COMPANY" "$TEST_PROJECT")"
[ "$alias_output" = "registered $TEST_COMPANY/$TEST_PROJECT thread=thr_fixture channel=chn_fixture" ] \
  || fail "--brainstorm alias stopped working: $alias_output"
echo "PASS: --brainstorm remains an alias of --board"

registered="$(check "$TEST_COMPANY" "$TEST_PROJECT")"
[ "$registered" = "registered" ] || fail "registered project should report registered, got: $registered"
echo "PASS: registered project is not registered twice"

# Skill wiring: registration runs at the start of both skills, not at the end.
BRAINSTORM="$ROOT/.claude/skills/brainstorm/SKILL.md"
PRD="$ROOT/.claude/skills/prd/SKILL.md"
FINALIZE="$ROOT/.claude/skills/_shared/prd-finalize.md"
step_line() { grep -n -F "$2" "$1" | head -1 | cut -d: -f1; }

b_reg="$(step_line "$BRAINSTORM" 'register-project.sh --board {co} {board-project-id}')"
b_research="$(step_line "$BRAINSTORM" '## Step 2: HQ Research')"
[ -n "$b_reg" ] && [ -n "$b_research" ] && [ "$b_reg" -lt "$b_research" ] \
  || fail "/brainstorm must register the project before Step 2 research (register at $b_reg, research at $b_research)"
echo "PASS: /brainstorm registers the project before research and the interview"

p_reg="$(step_line "$PRD" 'register-project.sh --board {co} {board-project-id}')"
p_interview="$(step_line "$PRD" '## Step 4: Discovery Interview')"
[ -n "$p_reg" ] && [ -n "$p_interview" ] && [ "$p_reg" -lt "$p_interview" ] \
  || fail "/prd must register the project before the Step 4 interview (register at $p_reg, interview at $p_interview)"
echo "PASS: /prd registers the project before the interview"

grep -Fq '_shared/prd-finalize.md' "$PRD" || fail "/prd does not reference _shared/prd-finalize.md"
grep -Fq 'register-project.sh {co} {name}' "$FINALIZE" || fail "finalize no longer syncs stories onto the registered project"
for f in "$BRAINSTORM" "$PRD" "$FINALIZE"; do
  if grep -Eq 'offer-project-create-on-brainstorm|registration-offer.sh --(accept|defer)|Create the Work Mesh project now|Not now' "$f"; then
    fail "$f still carries the flag or prompt flow"
  fi
done
echo "PASS: no flag and no prompt remain in the skill text"
for f in "$BRAINSTORM" "$PRD" "$FINALIZE"; do
  grep -Fq '`deferred`' "$f" || fail "$f does not say what to do on `deferred`"
done
echo "PASS: every caller handles deferred"
