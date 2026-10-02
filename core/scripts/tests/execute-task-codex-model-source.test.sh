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
grep -Fq 'workers.codex-model-overrides' "$SKILL" || {
  echo "FAIL: model overlay resolution must be gated by the default-off hq-flags key" >&2
  exit 1
}
grep -Fq 'personal/workers/{worker-id}/worker.yaml' "$SKILL" || {
  echo "FAIL: personal worker model overlay path must be documented" >&2
  exit 1
}
grep -Fq 'companies/{active-company}/workers/{worker-id}/worker.yaml' "$SKILL" || {
  echo "FAIL: company worker model overlay path must be documented" >&2
  exit 1
}
grep -Fq 'codex_flags' "$SKILL" || {
  echo "FAIL: model overlays must leave the core worker CLI flags pinned" >&2
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
