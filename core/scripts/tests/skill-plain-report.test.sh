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

echo "skill-plain-report: ok"
