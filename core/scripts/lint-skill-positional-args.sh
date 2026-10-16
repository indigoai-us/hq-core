#!/usr/bin/env bash
# lint-skill-positional-args.sh — flag skill-body text that Claude Code would
# replace with the skill's arguments.
#
# When a skill runs, Claude Code substitutes argument placeholders anywhere in
# the SKILL.md body, fenced code included (verified on Claude Code 2.1.300):
#   $ARGUMENTS        all arguments
#   $ARGUMENTS[N]     argument N (0-based)
#   $N                argument N (0-based; $0 is the first, $10 is index 10)
# A placeholder whose index has no argument is left as is, so a snippet looks
# right when the skill is run with no arguments and breaks once it has some:
# `local stage="$1"` becomes `local stage="<second arg>"`, `awk '{print $1}'`
# prints an argument, and "$10 a month" changes with the argument count.
#
# Rules (body only; frontmatter is not substituted):
#   1. A bare dollar-digit is an error anywhere in the body. Use a braced
#      shell parameter (${1}), a named variable, awk's $(1) field form, or
#      cut. In prose, escape the dollar sign (\$10), which Claude Code
#      documents as the literal form and renders as "$10".
#   2. $ARGUMENTS or $ARGUMENTS[N] inside a fenced code block is an error,
#      unless the skill is listed in ALLOW_FENCED_ARGUMENTS below because the
#      snippet is meant to receive the arguments. In prose it is the normal
#      way to show the input and is allowed.
# A dollar sign preceded by exactly one backslash is escaped. Two backslashes
# do not escape it (Claude Code keeps both and still substitutes).
#
# Usage: lint-skill-positional-args.sh [skills-dir]   (default .claude/skills)
# Exit 0 clean · 1 violations found · 2 bad usage.

set -euo pipefail

SKILLS_DIR="${1:-.claude/skills}"
[[ -d "$SKILLS_DIR" ]] || { echo "lint-skill-positional-args: no skills dir: $SKILLS_DIR" >&2; exit 2; }

# Skills whose fenced snippets take $ARGUMENTS on purpose, with the reason.
#   convert-codex  passes the user's flags straight to convert-codex.sh
#   hq-bug         body template quotes the user's message verbatim
#   hq-heal        report template records the triggering input
#   hq-sync        parses the user's flags into direction/on-conflict
#   resumework     reads the thread id argument
ALLOW_FENCED_ARGUMENTS=" convert-codex hq-bug hq-heal hq-sync resumework "

status=0
found_any=0
for skill_md in "$SKILLS_DIR"/*/SKILL.md; do
  [[ -f "$skill_md" ]] || continue
  found_any=1
  skill="$(basename "$(dirname "$skill_md")")"
  allow_fenced=0
  case "$ALLOW_FENCED_ARGUMENTS" in *" $skill "*) allow_fenced=1 ;; esac

  if ! out="$(awk -v file="$skill_md" -v allow_fenced="$allow_fenced" '
    # unescaped(line, start): true when the "$" at position start is not
    # escaped by exactly one backslash.
    function unescaped(line, start,   n, i) {
      n = 0
      for (i = start - 1; i >= 1 && substr(line, i, 1) == "\\"; i--) n++
      return n != 1
    }
    NR == 1 && $0 ~ /^---[ \t]*$/ { in_fm = 1; next }
    in_fm { if ($0 ~ /^---[ \t]*$/) in_fm = 0; next }
    /^[ \t]*(```|~~~)/ { in_fence = !in_fence; next }
    {
      line = $0
      for (pos = 1; pos <= length(line); pos++) {
        if (substr(line, pos, 1) != "$" || !unescaped(line, pos)) continue
        rest = substr(line, pos + 1)
        if (rest ~ /^[0-9]/) {
          tok = rest; sub(/[^0-9].*$/, "", tok)
          printf "%s:%d: bare $%s is replaced by a skill argument: %s\n", file, NR, tok, line
          bad = 1
        } else if (in_fence && !allow_fenced && rest ~ /^ARGUMENTS/) {
          printf "%s:%d: $ARGUMENTS in a fenced block is replaced by the skill arguments: %s\n", file, NR, line
          bad = 1
        }
      }
    }
    END { exit bad ? 1 : 0 }
  ' "$skill_md")"; then
    printf '%s\n' "$out" >&2
    status=1
  fi

  if [[ "$allow_fenced" == 1 ]] && ! awk '
    NR == 1 && $0 ~ /^---[ \t]*$/ { in_fm = 1; next }
    in_fm { if ($0 ~ /^---[ \t]*$/) in_fm = 0; next }
    /^[ \t]*(```|~~~)/ { in_fence = !in_fence; next }
    in_fence && index($0, "$ARGUMENTS") { hit = 1 }
    END { exit hit ? 0 : 1 }
  ' "$skill_md"; then
    echo "$skill_md: listed in ALLOW_FENCED_ARGUMENTS but has no fenced \$ARGUMENTS; remove it from the list" >&2
    status=1
  fi
done

[[ "$found_any" == 1 ]] || { echo "lint-skill-positional-args: no SKILL.md under $SKILLS_DIR" >&2; exit 2; }
[[ "$status" == 0 ]] && echo "OK: no argument placeholders in skill code under $SKILLS_DIR"
exit "$status"
