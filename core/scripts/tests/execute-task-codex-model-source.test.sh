#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SKILL="$ROOT/.claude/skills/execute-task/SKILL.md"

if grep -Fq 'gpt-5.4' "$SKILL"; then
  echo "FAIL: execute-task still hardcodes a Codex model fallback" >&2
  exit 1
fi
grep -Fq 'codex_model = task.codex_model_hint || worker.execution.codex_model' "$SKILL" || {
  echo "FAIL: Codex model resolution must use the existing worker profile field" >&2
  exit 1
}
grep -Fq 'A missing `worker.execution.codex_model` is a configuration error' "$SKILL" || {
  echo "FAIL: missing worker profile model must be reported as configuration error" >&2
  exit 1
}
grep -Fq '{codex_model} — the resolved value from the story override or worker profile' "$SKILL" || {
  echo "FAIL: worker prompt must use the resolved model without a second fallback" >&2
  exit 1
}

echo "PASS: execute-task Codex model resolution comes from the task override or worker profile"
