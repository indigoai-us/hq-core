#!/usr/bin/env bash
# The /deep-plan HQ context scanner must stop after it writes the report and
# must read the company worker list plus that company's manifest entry.
# It must not be told to search the full worker registry line by line.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SKILL="$ROOT/.claude/skills/deep-plan/SKILL.md"

fail() { echo "FAIL: $*" >&2; exit 1; }

[[ -f "$SKILL" ]] || fail "missing $SKILL"

section="$(awk '
  /^#### Agent 2 — HQ Context Scanner$/ { p=1 }
  p && /^#### Agent 3 / { exit }
  p { print }
' "$SKILL")"

[[ -n "$section" ]] || fail "Agent 2 section missing"

printf '%s\n' "$section" | grep -F >/dev/null 'company worker list' \
  || fail "Agent 2 does not tell the scanner to read the company worker list"
printf '%s\n' "$section" | grep -F >/dev/null 'companies/{co}/workers/' \
  || fail "Agent 2 does not name the company worker directory"
printf '%s\n' "$section" | grep -F >/dev/null "company's manifest entry" \
  || fail "Agent 2 does not tell the scanner to read the manifest entry"
printf '%s\n' "$section" | grep -F >/dev/null 'Stop after the report file is written.' \
  || fail "Agent 2 does not tell the scanner to stop after writing the report"
printf '%s\n' "$section" | grep -F >/dev/null 'Do not open core/workers/registry.yaml or workers/registry.yaml' \
  || fail "Agent 2 does not forbid the full worker registry"
if printf '%s\n' "$section" | grep -F >/dev/null '+ workers/registry.yaml'; then
  fail "Agent 2 still tells the scanner to read workers/registry.yaml"
fi

echo "PASS deep-plan-hq-context-scanner"
