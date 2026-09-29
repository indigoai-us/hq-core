#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
MISSING=()
IMPLICIT=()

for skill_dir in "$ROOT"/.claude/skills/*/; do
  [[ -d "$skill_dir" ]] || continue
  [[ -L "$skill_dir" ]] && continue
  [[ -f "$skill_dir/SKILL.md" ]] || continue

  skill_name="$(basename "$skill_dir")"
  [[ -f "$skill_dir/agents/openai.yaml" ]] || MISSING+=("$skill_name")

  # A user-only Claude skill must also be user-only in Codex, which ignores
  # disable-model-invocation and reads policy.allow_implicit_invocation instead.
  fm="$(awk 'NR==1&&/^---$/{f=1;next} f&&/^---$/{exit} f' "$skill_dir/SKILL.md")"
  if grep -qE '^disable-model-invocation:[[:space:]]*true[[:space:]]*$' <<<"$fm"; then
    awk '/^policy:/{p=1;next} /^[^[:space:]]/{p=0} p&&/^[[:space:]]+allow_implicit_invocation:[[:space:]]*false[[:space:]]*$/{found=1} END{exit !found}' \
      "$skill_dir/agents/openai.yaml" 2>/dev/null || IMPLICIT+=("$skill_name")
  fi
done

if (( ${#IMPLICIT[@]} > 0 )); then
  printf 'FAIL: user-only skills missing policy.allow_implicit_invocation: false in agents/openai.yaml: %s\n' "${IMPLICIT[*]}" >&2
  exit 1
fi

if (( ${#MISSING[@]} > 0 )); then
  printf 'FAIL: root skills missing agents/openai.yaml: %s\n' "${MISSING[*]}" >&2
  exit 1
fi

echo "PASS: every in-scope root skill has Codex OpenAI metadata, and user-only skills disable implicit invocation"
