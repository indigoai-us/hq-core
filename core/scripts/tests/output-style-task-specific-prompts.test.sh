#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
STYLE="$ROOT/.claude/output-styles/hq.md"
WORKFLOW="$ROOT/.github/workflows/pr-checks.yml"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

grep -Fq 'even when the task asks for brevity or a strict format' "$STYLE" \
  || fail 'HQ style does not keep Auto-Clarity prose complete under task formatting requests'
grep -Fq 'task-specific direction' "$STYLE" \
  || fail 'HQ style does not allow a task-specific prompt to guide this reply'
grep -Fq 'Apply the request only to that task or reply' "$STYLE" \
  || fail 'HQ style does not keep task-specific direction scoped'
grep -Fq 'do not infer' "$STYLE" \
  || fail 'HQ style does not reject inferring preferences from one-off prompts'
grep -Fq 'lasting style preference' "$STYLE" \
  || fail 'HQ style does not guard against storing a one-off preference'
grep -Fq 'Task-specific directions never override Auto-Clarity cases' "$STYLE" \
  || fail 'HQ style lets task-specific formatting suppress Auto-Clarity'
grep -Fq 'run: bash core/scripts/tests/output-style-task-specific-prompts.test.sh' "$WORKFLOW" \
  || fail 'PR checks do not run the task-specific prompts regression test'

printf 'output-style task-specific prompts: ok\n'
