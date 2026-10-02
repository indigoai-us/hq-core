#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
HANDOFF="$ROOT/.claude/skills/handoff/SKILL.md"
STARTWORK="$ROOT/.claude/skills/startwork/SKILL.md"
RESUMEWORK="$ROOT/.claude/skills/resumework/SKILL.md"
WORKFLOW="$ROOT/.github/workflows/pr-checks.yml"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

grep -Fq 'core/policies/hq-session-title-grammar.md' "$HANDOFF" \
  || fail 'handoff must point to the canonical session-title rule'
grep -Fq 'set_session_title' "$HANDOFF" \
  || fail 'handoff must apply the ready-to-resume session title'
grep -Fq '📤' "$HANDOFF" \
  || fail 'handoff must use the established handed-off status glyph'
grep -Fq 'core/policies/hq-session-title-grammar.md' "$STARTWORK" \
  || fail 'startwork must point to the canonical session-title rule'
grep -Fq 'set_session_title' "$STARTWORK" \
  || fail 'startwork must rename the session after resume context is resolved'
grep -Fq 'set_session_title' "$RESUMEWORK" \
  || fail 'resumework must carry the predecessor subject into the successor title'
grep -Fq 'core/policies/hq-session-title-grammar.md' "$RESUMEWORK" \
  || fail 'resumework must apply the canonical session-title rule'
grep -Fq '.manual' "$HANDOFF" \
  || fail 'handoff must check the session-title hook manual marker before renaming'
grep -Fq '.manual' "$RESUMEWORK" \
  || fail 'resumework must check the session-title hook manual marker before renaming'
grep -Fq 'optional title tool is unavailable' "$HANDOFF" \
  || fail 'handoff must skip the title update when the optional tool is unavailable'
grep -Fq 'optional title tool is unavailable' "$RESUMEWORK" \
  || fail 'resumework must skip the title update when the optional tool is unavailable'
grep -Fq 'bash core/scripts/tests/session-title-handoff-policy.test.sh' "$WORKFLOW" \
  || fail 'the session-title handoff policy regression must run in CI'

printf 'session-title handoff policy: ok\n'
