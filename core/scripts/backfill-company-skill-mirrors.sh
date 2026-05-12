#!/bin/bash
# backfill-company-skill-mirrors.sh
#
# One-shot, idempotent. Walks every company under companies/{co}/skills/ and
# companies/{co}/commands/ and ensures a mirror symlink exists at
# .claude/skills/{prefix}-{name}/ (or .claude/commands/{prefix}-{name}.md).
#
# Logic is delegated to .claude/hooks/auto-mirror-company-skill.sh — this
# script just discovers candidate paths and feeds them in. Re-run safely.
#
# Usage:  bash core/scripts/backfill-company-skill-mirrors.sh

set -euo pipefail

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
HOOK="$PROJECT_DIR/.claude/hooks/auto-mirror-company-skill.sh"

if [[ ! -x "$HOOK" ]]; then
  echo "ERROR: auto-mirror hook not found or not executable: $HOOK" >&2
  exit 1
fi

cd "$PROJECT_DIR"

CREATED=0
SKIPPED=0

emit() {
  local rel_path="$1"
  rel_path="${rel_path//\/\//\/}"
  local out
  out=$(echo "{\"tool_input\":{\"file_path\":\"$rel_path\"}}" | CLAUDE_PROJECT_DIR="$PROJECT_DIR" bash "$HOOK" 2>&1 || true)
  if [[ -n "$out" ]]; then
    echo "$out"
    if [[ "$out" == *"linked"* ]]; then
      CREATED=$((CREATED + 1))
    else
      SKIPPED=$((SKIPPED + 1))
    fi
  fi
}

shopt -s nullglob
for co_dir in companies/*/; do
  co="${co_dir%/}"
  co="${co##*/}"

  # Skip if no manifest entry (defensive — shouldn't happen).
  [[ -d "$co_dir" ]] || continue

  # Top-level skills: directory form (skills/{name}/SKILL.md) and flat-file form (skills/{name}.md).
  if [[ -d "$co_dir/skills" ]]; then
    for skill_md in "$co_dir/skills"/*/SKILL.md; do
      [[ -f "$skill_md" ]] || continue
      emit "$skill_md"
    done
    for flat_md in "$co_dir/skills"/*.md; do
      [[ -f "$flat_md" ]] || continue
      emit "$flat_md"
    done
  fi

  # Top-level commands: commands/{name}.md
  if [[ -d "$co_dir/commands" ]]; then
    for cmd_md in "$co_dir/commands"/*.md; do
      [[ -f "$cmd_md" ]] || continue
      emit "$cmd_md"
    done
  fi
done

echo ""
echo "backfill complete: $CREATED linked, $SKIPPED skipped (already-correct or no-prefix)"
