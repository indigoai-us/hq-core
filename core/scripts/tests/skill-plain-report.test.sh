#!/usr/bin/env bash
# /handoff, /learn, and /checkpoint must not dump operator Report fields when
# the default HQ plain-language output style is on (feedback 2286).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_contains() {
  local file="$1" needle="$2" label="$3"
  grep -qF "$needle" "$file" || fail "$label: missing '$needle' in ${file#$ROOT/}"
}

HANDOFF="$ROOT/.claude/skills/handoff/SKILL.md"
LEARN="$ROOT/.claude/skills/learn/SKILL.md"
CHECKPOINT="$ROOT/.claude/skills/checkpoint/SKILL.md"
AUDIENCE="$ROOT/core/policies/hq-audience-mode.md"
QUIET="$ROOT/core/policies/quiet-by-default-narration.md"
STYLE="$ROOT/.claude/output-styles/hq.md"

for f in "$HANDOFF" "$LEARN" "$CHECKPOINT" "$AUDIENCE" "$QUIET" "$STYLE"; do
  [ -f "$f" ] || fail "missing $(basename "$f"): $f"
done

# Shared contract: conversation report follows audience; operator fields stay
# in the operator template only.
for skill in "$HANDOFF" "$LEARN" "$CHECKPOINT"; do
  name="$(basename "$(dirname "$skill")")"
  assert_contains "$skill" \
    "Chat report follows the active output style" \
    "$name names the audience-aware chat report"
  assert_contains "$skill" \
    "Do not print Scope, Dedup, Action, file paths, thread IDs, or PIDs" \
    "$name forbids operator Report fields in the default HQ chat line"
  assert_contains "$skill" \
    "/output-style hq-operator" \
    "$name keeps the operator report behind hq-operator"
done

assert_contains "$HANDOFF" \
  "All saved. To pick up later, open a new chat and paste what's on your clipboard." \
  "handoff default HQ example is a short plain resume line"
assert_contains "$HANDOFF" \
  "Handoff ready." \
  "handoff operator template is still present"
assert_contains "$HANDOFF" \
  "WARN: Follow-up recovery required" \
  "handoff recovery warning is still present"

assert_contains "$LEARN" \
  "Saved. I'll remember that next time." \
  "learn default HQ example is a short plain line"
assert_contains "$LEARN" \
  "Learning captured:" \
  "learn operator template is still present"
assert_contains "$LEARN" \
  "Record the dedup action for the Step 9 report. Do not print it to the user in the default HQ style." \
  "learn does not print mid-pipeline Dedup in default HQ"

assert_contains "$CHECKPOINT" \
  "Progress saved. Keep going here, or open a new chat later and I'll pick this up." \
  "checkpoint default HQ example is a short plain line"
assert_contains "$CHECKPOINT" \
  "Thread saved:" \
  "checkpoint operator template is still present"

assert_contains "$AUDIENCE" \
  "chat reports follow the active audience" \
  "hq-audience-mode covers command chat reports"
assert_contains "$QUIET" \
  "completion reports (plain summary in the default audience" \
  "quiet-by-default lists the three command reports as audience-gated"
assert_contains "$STYLE" \
  "Command report templates" \
  "HQ output style says skill Report fields do not override it"

DETAILS_HOOK="$ROOT/core/hooks/UserPromptSubmit/50-command-report-details.sh"
DETAILS_FLAG="$ROOT/.claude/hooks/command-report-details-flag.cjs"
assert_contains "$STYLE" \
  "When trusted command-report details context is present" \
  "HQ style gates expandable command diagnostics"
assert_contains "$HANDOFF" \
  "When trusted command-report details context is present" \
  "handoff allows expandable details only behind the gate"
assert_contains "$LEARN" \
  "When trusted command-report details context is present" \
  "learn allows expandable details only behind the gate"
assert_contains "$CHECKPOINT" \
  "When trusted command-report details context is present" \
  "checkpoint allows expandable details only behind the gate"
assert_contains "$HANDOFF" \
  "command-report-details-flag.cjs" \
  "handoff checks the flag at report time when routing omitted prompt context"
assert_contains "$LEARN" \
  "command-report-details-flag.cjs" \
  "learn checks the flag at report time when routing omitted prompt context"
assert_contains "$CHECKPOINT" \
  "command-report-details-flag.cjs" \
  "checkpoint checks the flag at report time when routing omitted prompt context"
[ -x "$DETAILS_HOOK" ] || fail "command report details hook is missing or not executable"
[ -f "$DETAILS_FLAG" ] || fail "command report details flag reader is missing"
assert_contains "$DETAILS_FLAG" \
  'const DEFAULT_VALUE = false;' \
  "command report details flag defaults off"

# Exercise the actual hook with a synthetic hq-flags client. No live service or
# cached credentials are used by this fixture.
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT
mkdir -p "$TMP/cli/bin" \
  "$TMP/cli/node_modules/@indigoai-us/hq-flags-client" \
  "$TMP/cli/node_modules/@indigoai-us/hq-cloud"
printf '%s\n' '#!/usr/bin/env node' > "$TMP/cli/bin/hq"
chmod +x "$TMP/cli/bin/hq"
printf '%s\n' '{"name":"@indigoai-us/hq-cli"}' > "$TMP/cli/package.json"
printf '%s\n' '{"name":"@indigoai-us/hq-flags-client","exports":"./index.js"}' \
  > "$TMP/cli/node_modules/@indigoai-us/hq-flags-client/package.json"
cat > "$TMP/cli/node_modules/@indigoai-us/hq-flags-client/index.js" <<'JS'
exports.createFlagClient = () => ({
  ready: async () => {
    if (process.env.HQ_TEST_COMMAND_REPORT_DETAILS === "error") throw new Error("synthetic lookup failure");
  },
  snapshot: () => ({ flags: {
    "output.command-report-details-expandable": process.env.HQ_TEST_COMMAND_REPORT_DETAILS === "true"
  } }),
  close: () => {}
});
JS
printf '%s\n' '{"name":"@indigoai-us/hq-cloud","exports":"./index.js"}' \
  > "$TMP/cli/node_modules/@indigoai-us/hq-cloud/package.json"
printf '%s\n' 'exports.loadCachedTokens = () => ({});' \
  > "$TMP/cli/node_modules/@indigoai-us/hq-cloud/index.js"

run_details_hook() {
  local prompt="$1" enabled="$2"
  printf '{"prompt":%s}\n' "$(jq -Rn --arg value "$prompt" '$value')" | \
    env PATH="$TMP/cli/bin:$PATH" \
      HQ_ROOT="$ROOT" \
      HQ_FLAGS_API_URL='https://flags.invalid' \
      HQ_COMPANY_UID='cmp_test123' \
      HQ_COMPANY_SLUG='indigo' \
      HQ_TEST_COMMAND_REPORT_DETAILS="$enabled" \
      bash "$DETAILS_HOOK" UserPromptSubmit
}

enabled_output="$(run_details_hook /handoff true)"
printf '%s\n' "$enabled_output" | jq -e '
  .hookSpecificOutput.hookEventName == "UserPromptSubmit" and
  (.hookSpecificOutput.additionalContext | contains("command-report details context") and contains("<details>") and contains("hq-operator") and contains("must not override"))
' >/dev/null || fail "enabled command report gate did not inject expandable details context"

disabled_output="$(run_details_hook /checkpoint false)"
[ -z "$disabled_output" ] || fail "disabled command report gate injected context"

unrelated_output="$(run_details_hook /startwork true)"
[ -z "$unrelated_output" ] || fail "command report details context leaked to an unrelated prompt"

failed_lookup_output="$(run_details_hook /learn error)"
[ -z "$failed_lookup_output" ] || fail "failed command report flag lookup did not stay default-off"

no_endpoint_output="$(printf '%s\n' '{"prompt":"/handoff"}' | \
  env -u HQ_FLAGS_API_URL \
    HQ_ROOT="$ROOT" \
    HQ_COMPANY_UID='cmp_test123' \
    HQ_COMPANY_SLUG='indigo' \
    HQ_CLI_BIN="$TMP/cli/bin/hq" \
    bash "$DETAILS_HOOK" UserPromptSubmit)"
[ -z "$no_endpoint_output" ] || fail "missing flag endpoint did not stay default-off"

echo "skill-plain-report: ok"
