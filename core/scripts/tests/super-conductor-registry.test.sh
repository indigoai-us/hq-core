#!/usr/bin/env bash
# Pins named super-conductors:
#   - super-conductor-registry.mjs (profiles, questionnaire, routing, claims,
#     rendered prefs read by super-conductor-prefs.mjs), via node --test in
#     super-conductor-registry.test.mjs, all in throwaway directories;
#   - the /super-conductor skill documents the start picker, the
#     questionnaire, ownership between conductors, and the two decision
#     settings (own-window mode, child asks in their window).
set -uo pipefail

ROOT="${HQ_TEST_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
SKILL="$ROOT/.claude/skills/super-conductor/SKILL.md"
fail=0
check() { if [[ "$2" -ne 0 ]]; then echo "FAIL: $1" >&2; fail=1; fi; }

node --test "$ROOT/core/scripts/tests/super-conductor-registry.test.mjs"
check "registry unit tests" $?

for needle in \
  "## Named conductors: profiles and the registry" \
  "## Start: pick the conductor" \
  "### New conductor questionnaire" \
  "## Step 3b: Ownership between conductors" \
  "### Child asks in their window" \
  "### Own-window mode" \
  "super-conductor-registry.mjs claim" \
  "super-conductor-registry.mjs render-prefs" \
  "SC_PREFS_FILE=" \
  "no_forward_to" \
  "conductor_name"; do
  grep -qF -- "$needle" "$SKILL"
  check "skill mentions: $needle" $?
done

if [[ "$fail" -ne 0 ]]; then exit 1; fi
echo "ok: super-conductor-registry"
