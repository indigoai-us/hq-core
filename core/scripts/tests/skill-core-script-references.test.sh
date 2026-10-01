#!/usr/bin/env bash
# Every concrete core/scripts/<file> path documented in a shipped skill must
# exist, except for separately tracked missing references listed below.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
missing=0
allowlisted=0

for skill in "$ROOT"/.claude/skills/*/SKILL.md; do
  [[ -f "$skill" ]] || continue
  while IFS= read -r script_ref; do
    [[ -n "$script_ref" ]] || continue
    # References containing braces or globs describe a template/pattern rather
    # than one concrete script file (for example rebuild-{class}-index.sh).
    case "$script_ref" in *'{'*|*'}'*|*'*'*) continue ;; esac
    [[ -f "$ROOT/$script_ref" ]] && continue

    case "$script_ref" in
      # The goals skill documents this separate board migration, which is out
      # of scope for the PRD-to-Beads fix.
      core/scripts/migrate-board-v2.ts)
        allowlisted=$((allowlisted + 1))
        ;;
      # /run-pipeline's missing runner is a separate issue; keep its references
      # visible here without broadening this PR beyond prd-to-beads.
      core/scripts/run-pipeline.sh)
        allowlisted=$((allowlisted + 1))
        ;;
      *)
        printf 'FAIL: %s references missing %s\n' "${skill#"$ROOT"/}" "$script_ref" >&2
        missing=$((missing + 1))
        ;;
    esac
  done < <(grep -oE 'core/scripts/[[:alnum:]_./{}*?-]+' "$skill" | sort -u || true)
done

if [[ "$missing" -gt 0 ]]; then
  printf 'skill-core-script-references: %s missing reference(s), %s known allowlisted reference(s)\n' "$missing" "$allowlisted" >&2
  exit 1
fi

printf 'skill-core-script-references: PASS; no unallowlisted missing references (%s known allowlisted references)\n' "$allowlisted"
