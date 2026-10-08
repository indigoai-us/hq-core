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
# The deprecated /plan stub was removed in hq-core 16.0.0; /prd is the
# planning command and carries the checkpoint. A reappearing stub would
# need its own checkpoint contract, so its absence is asserted here.
[ ! -e "$ROOT/.claude/skills/plan" ] || fail "plan: the deprecated stub was removed in 16.0.0; /prd is the planning command"
echo "auto-checkpoint-planning-cmds: ok (brainstorm + prd auto-checkpoint on completion; no /plan stub)"
