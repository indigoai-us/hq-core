#!/usr/bin/env bash
set -euo pipefail

ROOT="${US146_TEST_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
SKILL="$ROOT/.claude/skills/knowledge-pulse/SKILL.md"
SPEC="$ROOT/core/knowledge/public/hq-core/policies-spec.md"
failures=0

if [[ ! -f "$SKILL" || ! -f "$SPEC" ]]; then
  echo 'FAIL: knowledge-pulse skill or policy spec is missing' >&2
  exit 1
fi

spec_fields="$(awk '
  /^## Required Fields$/ { in_required = 1; next }
  /^## Optional Fields$/ { in_required = 0 }
  in_required && /^\| `[^`]+` \|/ {
    line = $0
    sub(/^\| `/, "", line)
    sub(/`.*/, "", line)
    fields = fields (fields == "" ? "" : ", ") line
  }
  END { print fields }
' "$SPEC" | paste -sd ', ' -)"

if [[ "$spec_fields" != 'id, title, when, on, enforcement, version, created, updated' ]]; then
  echo "FAIL: unexpected required policy fields in policies-spec: $spec_fields" >&2
  failures=$((failures + 1))
fi

if ! sed -n '/^## File Format$/,/^## Required Fields$/p' "$SPEC" | grep -Fxq 'public: false'; then
  echo 'FAIL: policy frontmatter template no longer includes public' >&2
  failures=$((failures + 1))
fi

required_line="$(grep -F 'Check required fields per policies-spec:' "$SKILL" || true)"
actual_fields="$(printf '%s\n' "$required_line" | sed -E 's/.*policies-spec: //; s/`//g')"
expected_fields='id, title, when, on, enforcement, version, created, updated, public'
if [[ "$actual_fields" != "$expected_fields" ]]; then
  echo "FAIL: knowledge-pulse required fields differ from policy format: ${actual_fields:-missing} (expected $expected_fields)" >&2
  failures=$((failures + 1))
else
  echo 'ok: knowledge-pulse required fields match the current policy format'
fi

if [[ "$failures" -ne 0 ]]; then
  echo "knowledge-pulse policy schema failures: $failures" >&2
  exit 1
fi
echo 'knowledge-pulse policy schema contract passed'
