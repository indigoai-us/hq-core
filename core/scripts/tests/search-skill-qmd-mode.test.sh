#!/usr/bin/env bash
# Prompt contract: /search must not instruct a cold in-turn qmd vsearch/query.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SKILL="$ROOT/.claude/skills/search/SKILL.md"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_contains() {
  local needle="$1" label="$2"
  grep -qF "$needle" "$SKILL" || fail "$label: missing '$needle'"
}

[ -f "$SKILL" ] || fail "search skill is missing: $SKILL"

assert_contains \
  'qmd search "$QUERY" -n $N --json [-c $COLLECTION]' \
  'default in-turn search is BM25'
assert_contains \
  'ls "$MODELS"/*.gguf' \
  'vsearch/query gated on an existing GGUF cache'
assert_contains \
  'hq index background' \
  'cold embeddings go through background index'
assert_contains \
  'Never run `qmd pull`, `qmd embed`, or a cold `qmd vsearch`/`qmd query` in the foreground' \
  'search forbids foreground GGUF downloads'
assert_contains \
  'keep this probe and the search in **one** Bash call' \
  'Windows sequential spawn warning'
assert_contains \
  '## Empty Result Escalation' \
  'empty BM25 escalates before grep'
assert_contains \
  'rerun as `qmd query "$QUERY" -n $N --json [-c $COLLECTION]`' \
  'empty BM25 retries hybrid when cached'
assert_contains \
  'If qmd is unavailable, errors, or the Empty Result Escalation above also returned nothing:' \
  'grep fallback gated on escalation'

# The escalation must come before the grep fallback.
esc_line=$(grep -nF '## Empty Result Escalation' "$SKILL" | cut -d: -f1)
fb_line=$(grep -nF '## Fallback' "$SKILL" | cut -d: -f1)
[ "$esc_line" -lt "$fb_line" ] || fail 'escalation section must precede Fallback'

echo "search-skill-qmd-mode: ok"
