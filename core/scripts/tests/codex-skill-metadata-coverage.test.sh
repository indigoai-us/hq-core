#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
MISSING=()

for skill_dir in "$ROOT"/.claude/skills/*/; do
  [[ -d "$skill_dir" ]] || continue
  [[ -L "$skill_dir" ]] && continue
  [[ -f "$skill_dir/SKILL.md" ]] || continue

  skill_name="$(basename "$skill_dir")"
  [[ -f "$skill_dir/agents/openai.yaml" ]] || MISSING+=("$skill_name")
done

if (( ${#MISSING[@]} > 0 )); then
  printf 'FAIL: root skills missing agents/openai.yaml: %s\n' "${MISSING[*]}" >&2
  exit 1
fi

echo "PASS: every in-scope root skill has Codex OpenAI metadata"
