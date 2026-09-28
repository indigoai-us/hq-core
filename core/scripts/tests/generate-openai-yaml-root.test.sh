#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SOURCE_SCRIPT="$ROOT/core/scripts/generate-openai-yaml.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/generate-openai-yaml-root.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

FIXTURE="$WORK/hq"
mkdir -p "$FIXTURE/core/scripts" "$FIXTURE/.claude/skills/sample-skill" "$FIXTURE/.claude/skills/long-description" "$FIXTURE/.claude/skills/comma-boundary"
cp "$SOURCE_SCRIPT" "$FIXTURE/core/scripts/generate-openai-yaml.sh"
long_prefix="$(printf '%108s' '' | tr ' ' x): \"quoted\""
printf '%s\n' \
  '---' \
  'name: sample-skill' \
  "description: ${long_prefix}  trailing text" \
  '---' \
  '' \
  '# Sample skill' > "$FIXTURE/.claude/skills/sample-skill/SKILL.md"
cat > "$FIXTURE/.claude/skills/long-description/SKILL.md" <<'EOF'
---
name: long-description
description: This sample description is deliberately long to test the truncation boundary safely: "quoted text" remains part of the source.
---

# Long description skill
EOF
cat > "$FIXTURE/.claude/skills/comma-boundary/SKILL.md" <<'EOF'
---
name: comma-boundary
description: This fixture includes enough words to make final boundary comma, and extra words after the cut point.
---

# Comma boundary skill
EOF

output="$(bash "$FIXTURE/core/scripts/generate-openai-yaml.sh" --dry-run)"
if ! grep -Fq 'sample-skill:' <<< "$output"; then
  echo "FAIL: generator did not scan the HQ root .claude/skills directory" >&2
  printf '%s\n' "$output" >&2
  exit 1
fi
grep -Fq 'Summary: 3 generated, 0 already existed, 0 symlinks skipped' <<< "$output" || {
  echo "FAIL: generator did not report the fixture skill" >&2
  printf '%s\n' "$output" >&2
  exit 1
}

bash "$FIXTURE/core/scripts/generate-openai-yaml.sh" >/dev/null
[[ -f "$FIXTURE/.claude/skills/sample-skill/agents/openai.yaml" ]] || {
  echo "FAIL: generator did not write the fixture openai.yaml" >&2
  exit 1
}
grep -Fq 'short_description: >-' "$FIXTURE/.claude/skills/sample-skill/agents/openai.yaml" || {
  echo "FAIL: generated metadata must safely use a folded YAML scalar" >&2
  exit 1
}
long_description_yaml="$FIXTURE/.claude/skills/long-description/agents/openai.yaml"
[[ -f "$long_description_yaml" ]] || {
  echo "FAIL: generator did not write metadata for the long-description fixture" >&2
  exit 1
}
generated_description="$(sed -n '/^  short_description: >-$/ { n; s/^    //; p; }' "$long_description_yaml")"
description_length=${#generated_description}
if (( description_length < 25 || description_length > 64 )); then
  echo "FAIL: generated description length ${description_length} is outside Codex's 25-64 character range" >&2
  printf 'Generated description: %s\n' "$generated_description" >&2
  exit 1
fi
[[ "$generated_description" == 'This sample description is deliberately long to test the' ]] || {
  echo "FAIL: generated description was not truncated at the last word boundary within 64 characters" >&2
  printf 'Generated description: %s\n' "$generated_description" >&2
  exit 1
}
comma_description_yaml="$FIXTURE/.claude/skills/comma-boundary/agents/openai.yaml"
[[ -f "$comma_description_yaml" ]] || {
  echo "FAIL: generator did not write metadata for the comma-boundary fixture" >&2
  exit 1
}
comma_description="$(sed -n '/^  short_description: >-$/ { n; s/^    //; p; }' "$comma_description_yaml")"
[[ "$comma_description" == 'This fixture includes enough words to make final boundary comma' ]] || {
  echo "FAIL: generated description retained punctuation at the truncation boundary" >&2
  printf 'Generated description: %s\n' "$comma_description" >&2
  exit 1
}
comma_description_length=${#comma_description}
if (( comma_description_length < 25 || comma_description_length > 64 )); then
  echo "FAIL: punctuation-trimmed description length ${comma_description_length} is outside Codex's 25-64 character range" >&2
  printf 'Generated description: %s\n' "$comma_description" >&2
  exit 1
fi
if grep -n '[[:blank:]]$' "$FIXTURE/.claude/skills/sample-skill/agents/openai.yaml"; then
  echo "FAIL: generated metadata contains trailing whitespace" >&2
  exit 1
fi

echo "PASS: generator scans the HQ root and writes missing OpenAI skill metadata"
