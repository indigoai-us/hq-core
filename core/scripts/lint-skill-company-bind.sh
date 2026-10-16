#!/usr/bin/env bash
# lint-skill-company-bind.sh — flag skills that anchor a company and then read
# a company path before binding the session to that company.
#
# The company scope guard denies reads under companies/<co>/ until the session
# has a company_slug bound. A skill that anchors {co} (sets it or announces
# "Anchored on **{co}**") and then reads companies/{co}/... or loads policies
# with read-policy-frontmatter before it binds loses a turn to the denial
# (feedback_74bfcdbc). A bind placed above the anchor does not count: {co} is
# not known yet when it runs.
#
# Rules (body only; frontmatter is skipped):
#   anchor  first line containing "Set `{co}`" or "Anchored on **{co}**"
#   bind    work-mesh-live-bind-trusted.sh, hq-session.sh set company_slug,
#           hq core hq-session set company_slug (skills shipped in the Codex
#           pack cannot name core/ paths), or hq-session.sh add company
#   read    companies/{co}/ or read-policy-frontmatter
# After the anchor line, a bind must appear on or before the first read line.
# Skills with no anchor are not checked.
#
# Usage: lint-skill-company-bind.sh [skills-dir]   (default .claude/skills)
# Exit 0 clean · 1 violations found · 2 bad usage.

set -euo pipefail

SKILLS_DIR="${1:-.claude/skills}"
[[ -d "$SKILLS_DIR" ]] || { echo "lint-skill-company-bind: no skills dir: $SKILLS_DIR" >&2; exit 2; }

status=0
found_any=0
for skill_md in "$SKILLS_DIR"/*/SKILL.md; do
  [[ -f "$skill_md" ]] || continue
  found_any=1
  if ! out="$(awk -v file="$skill_md" '
    NR == 1 && $0 ~ /^---[ \t]*$/ { in_fm = 1; next }
    in_fm { if ($0 ~ /^---[ \t]*$/) in_fm = 0; next }
    done { next }
    !anchor && (index($0, "Set `{co}`") || index($0, "Anchored on **{co}**")) { anchor = NR }
    !anchor { next }
    index($0, "work-mesh-live-bind-trusted.sh") \
      || index($0, "hq-session.sh set company_slug") \
      || index($0, "hq-session set company_slug") \
      || index($0, "hq-session.sh add company") { done = 1; next }
    index($0, "companies/{co}/") || index($0, "read-policy-frontmatter") {
      printf "%s:%d: reads a company path before the session is bound (company anchored at line %d). Bind first: bash core/scripts/work-mesh-live-bind-trusted.sh --company \"{co}\"\n", file, NR, anchor
      bad = 1
      done = 1
    }
    END { exit bad ? 1 : 0 }
  ' "$skill_md")"; then
    printf '%s\n' "$out" >&2
    status=1
  fi
done

[[ "$found_any" == 1 ]] || { echo "lint-skill-company-bind: no SKILL.md under $SKILLS_DIR" >&2; exit 2; }
[[ "$status" == 0 ]] && echo "OK: every company anchor under $SKILLS_DIR binds before its first company read"
exit "$status"
