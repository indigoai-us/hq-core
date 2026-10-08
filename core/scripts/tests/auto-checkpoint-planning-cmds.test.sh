#!/usr/bin/env bash
# Regression: /brainstorm and /prd must auto-checkpoint at the end of the
# command (Item 2 — auto-checkpoint after planning commands). These are
# instruction skills, so the contract is structural: each SKILL.md must carry
# the AUTO-CHECKPOINT-ON-COMPLETION marker AND a real lightweight-checkpoint
# instruction (an auto-checkpoint thread write under workspace/threads/).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }
MARKER="AUTO-CHECKPOINT-ON-COMPLETION"
for skill in brainstorm prd; do
  f="$ROOT/.claude/skills/$skill/SKILL.md"
  [ -f "$f" ] || fail "missing skill file: $f"
  grep -q "$MARKER" "$f" || fail "$skill: missing $MARKER final-step marker"
  grep -q 'type: "auto-checkpoint"' "$f" || fail "$skill: marker present but no auto-checkpoint thread instruction"
  grep -q 'workspace/threads/' "$f" || fail "$skill: no workspace/threads/ checkpoint path"
done
# /plan is a deprecated stub that forwards to /prd, so it inherits the prd
# checkpoint instead of carrying its own.
stub="$ROOT/.claude/skills/plan/SKILL.md"
[ "$(wc -l < "$stub")" -lt 20 ] || fail "plan: stub is 20 lines or more"
grep -qi 'deprecated' "$stub" || fail "plan: stub does not say deprecated"
grep -q 'prd' "$stub" || fail "plan: stub does not forward to the prd skill"
grep -q 'same arguments' "$stub" || fail "plan: stub does not pass its arguments to prd"
echo "auto-checkpoint-planning-cmds: ok (brainstorm + prd auto-checkpoint on completion; plan forwards to prd)"
