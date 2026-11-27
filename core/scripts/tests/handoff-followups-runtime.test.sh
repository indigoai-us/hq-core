#!/usr/bin/env bash
# Regression coverage for durable, cross-runtime handoff follow-ups.
#
# Agent/Task/Skill dispatch is an instruction-surface contract, so the runtime
# selection, installed-skill gate, and failure warning are verified structurally.
# Native handoff finalize/post runtime behavior is covered in hq-cli.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SKILL="$ROOT/.claude/skills/handoff/SKILL.md"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

[[ -f "$SKILL" ]] || fail "handoff skill missing"

# Handoff is routine closeout work, so Claude Code must run only this skill on
# the bounded model/effort override instead of inheriting expensive session
# defaults. Skill-scoped frontmatter restores those defaults after invocation.
SKILL_FRONTMATTER=$(awk 'NR == 1 && $0 == "---" { inside = 1; next }
  inside && $0 == "---" { exit }
  inside { print }' "$SKILL")
grep -qx 'model: sonnet' <<<"$SKILL_FRONTMATTER" \
  || fail "handoff skill must use the Sonnet model override"
grep -qx 'effort: low' <<<"$SKILL_FRONTMATTER" \
  || fail "handoff skill must use the low effort override"

# Cross-runtime dispatch must not stop at Codex, and the last fallback must be
# synchronous only after the finalizer has written the durable learning array.
grep -q 'Codex:.*`spawn_agent`' "$SKILL" \
  || fail "Codex spawn_agent dispatch route missing"
grep -q 'Claude Code:.*`Task` or `Agent`' "$SKILL" \
  || fail "Claude Task/Agent dispatch route missing"
grep -q 'Skill.*synchronously' "$SKILL" \
  || fail "synchronous Skill fallback missing"
grep -q -- '--learnings-json-file "{learnings_file path from Step 2}"' "$SKILL" \
  || fail "handoff run does not receive the Step 2 learnings file"
if sed -n '/^### 3\./,/^### 4\./p' "$SKILL" | grep -q 'rm -f.*learnings_file'; then
  fail "Step 3 removes the Step 2 learnings file before Step 4.5"
fi
grep -q 'WARN: Follow-up recovery required' "$SKILL" \
  || fail "forced-dispatch-failure recovery warning missing"
grep -q 'Run exactly: /learn {learnings_json}' "$SKILL" \
  || fail "manual learning recovery command missing"
grep -q 'Run exactly: /document-release {thread_path}' "$SKILL" \
  || fail "manual document-release recovery command missing"
grep -q 'skill-installed.sh document-release' "$SKILL" \
  || fail "document-release follow-up does not check the installed skill catalog"
grep -q 'document-release: skipped (skill not installed)' "$SKILL" \
  || fail "missing document-release skill skip label absent"
grep -q 'Only when document-release is installed' "$SKILL" \
  || fail "document-release dispatch and recovery must require the installed skill"
grep -q 'omit the document-release recovery entry and command' "$SKILL" \
  || fail "missing skill must suppress its Run exactly recovery command"
grep -q 'Run applicable follow-ups sequentially in this order: `/learn` first, then `/document-release`; wait for each result before starting the next' "$SKILL" \
  || fail "handoff follow-ups must run one at a time in a documented order"
grep -q 'tell the user a rough expected duration for the applicable work' "$SKILL" \
  || fail "handoff must show a rough expected duration before dispatch"
grep -qi 'label it as an estimate, not a promise' "$SKILL" \
  || fail "handoff duration must be labeled as an estimate"

echo "handoff follow-ups runtime: ok"
