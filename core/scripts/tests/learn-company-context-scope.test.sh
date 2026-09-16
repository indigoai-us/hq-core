#!/usr/bin/env bash
# Regression coverage for /learn's active-session company routing contract.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SKILL="$ROOT/.claude/skills/learn/SKILL.md"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_contains() {
  local needle="$1" label="$2"
  grep -qF "$needle" "$SKILL" || fail "$label: missing '$needle'"
}

assert_not_contains() {
  local needle="$1" label="$2"
  if grep -qF "$needle" "$SKILL"; then
    fail "$label: found retired '$needle'"
  fi
}

[ -f "$SKILL" ] || fail "learn skill is missing: $SKILL"

assert_contains \
  'bash core/scripts/hq-session.sh get company_slug' \
  'scope resolver reads the persisted active company'
assert_contains \
  'default to this active company and target `companies/{co}/policies/`' \
  'free-text and hard learnings default to the active company'
assert_contains \
  'explicit `repo`, `command`, or `global` scope rather than the session default' \
  'explicit global, repo, and command scope override the active company'
assert_contains \
  'including the active session `company_slug`, exists in `companies/manifest.yaml`' \
  'active session company is manifest verified'
assert_contains \
  'explicit global scope targets `personal/policies/`' \
  'explicit global scope continues to route to personal policies'
assert_contains \
  'automatically checked by the `validate-policy-frontmatter.sh` write/edit hook' \
  'learn documents the current automatic policy validation path'
assert_contains \
  'when: vercel' \
  'learn routes stack-specific policy applicability through when'
assert_not_contains \
  '# applies_to:' \
  'learn policy template omits the removed applicability field'
assert_not_contains \
  'validate-policy-tags.sh' \
  'learn does not reference the retired policy-tag validator'
assert_not_contains \
  'scope: {company|repo|command|global}' \
  'learn policy template omits the removed scope field'
assert_not_contains \
  'trigger: {when this applies}' \
  'learn policy template omits the retired trigger field'

assert_contains \
  'qmd search "{rule text}" --json -n 5' \
  'in-turn learn dedup uses BM25 qmd search'
assert_not_contains \
  'qmd vsearch "{rule text}"' \
  'learn must not run in-turn qmd vsearch (GGUF download stall)'
assert_contains \
  'Never run `qmd vsearch`, `qmd query`, `qmd embed`, or `qmd pull` during `/learn`' \
  'learn forbids cold GGUF downloads in-turn'
assert_contains \
  'single `qmd search` call' \
  'batch learn dedup uses qmd search not vsearch'

echo "learn-company-context-scope: ok"
