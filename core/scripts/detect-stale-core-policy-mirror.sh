#!/usr/bin/env bash
# detect-stale-core-policy-mirror.sh — find leftover core/policies/ copies of a
# personal/policies/ twin from before the personal→core policy mirror was
# retired.
#
# Background: HQ used to symlink personal/policies/<slug>.md into
# core/policies/<slug>.md at reindex time. That mirror is retired — the policy
# trigger hook (.claude/hooks/inject-policy-on-trigger.sh) now reads
# personal/policies/ DIRECTLY, ahead of core/policies/, and dedups by policy id.
# But an install upgraded across the retirement can still carry stale REGULAR
# FILE copies of personal policies inside core/policies/. Those copies are
# release-owned scaffold: /update-hq will not refresh them from personal/, and a
# copy that is missing the when:/on: trigger frontmatter its personal twin has
# gained (via migrate-policy-triggers.sh) can shadow or diverge from the live
# rule in confusing ways.
#
# This tool classifies every core/policies twin of a personal policy:
#   identical  — byte-identical to the personal twin: an orphaned mirror copy,
#                behavior-neutral to remove (the personal twin still loads, and
#                /update-hq restores any genuinely release-shipped file).
#   symlink    — a leftover personal→core mirror symlink: resolves back to
#                personal, so also a behavior-neutral orphan.
#   diverged   — content differs from the personal twin. DRIFT CAN RUN EITHER
#                DIRECTION (the core copy may be the newer, genericized one).
#                These are NEVER pruned — a human must classify each.
#
# Modes:
#   (default)          human-readable report; always exit 0.
#   --json             machine-readable JSON array; exit 0.
#   --check            exit 0 if no twins, 1 if any twin exists (advisory gate).
#   --prune-identical  remove ONLY identical + leftover-symlink orphans; never
#                      touch diverged; print each action; exit 0.
#
# It never writes to personal/, never syncs personal→core, and never removes a
# core/policies file that has no personal twin (release-shipped policies are
# left untouched by construction).

set -euo pipefail

MODE="report"
case "${1:-}" in
  "")                 MODE="report" ;;
  --json)             MODE="json" ;;
  --check)            MODE="check" ;;
  --prune-identical)  MODE="prune" ;;
  -h|--help)
    sed -n '2,45p' "$0"
    exit 0 ;;
  *)
    printf 'detect-stale-core-policy-mirror: unknown argument: %s\n' "$1" >&2
    printf 'usage: %s [--json|--check|--prune-identical]\n' "$0" >&2
    exit 2 ;;
esac

# Resolve HQ root: explicit env wins, else the tree this script ships in.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HQ_ROOT="${HQ_ROOT:-${CLAUDE_PROJECT_DIR:-$(cd "$SCRIPT_DIR/../.." && pwd)}}"

PERSONAL_DIR="$HQ_ROOT/personal/policies"
CORE_DIR="$HQ_ROOT/core/policies"

# Collect twins into parallel arrays (bash 3.2-safe; no associative arrays).
names=()
statuses=()

if [ -d "$PERSONAL_DIR" ]; then
  for pf in "$PERSONAL_DIR"/*.md; do
    [ -e "$pf" ] || continue          # no-glob-match guard (nullglob-free)
    base="$(basename "$pf")"
    case "$base" in example-policy.md|README.md) continue ;; esac
    cf="$CORE_DIR/$base"
    [ -e "$cf" ] || [ -L "$cf" ] || continue   # no core twin → nothing to flag
    if [ -L "$cf" ]; then
      status="symlink"
    elif cmp -s "$pf" "$cf"; then
      status="identical"
    else
      status="diverged"
    fi
    names+=("$base")
    statuses+=("$status")
  done
fi

total="${#names[@]}"

# Tally.
n_identical=0; n_symlink=0; n_diverged=0
i=0
while [ "$i" -lt "$total" ]; do
  case "${statuses[$i]}" in
    identical) n_identical=$((n_identical + 1)) ;;
    symlink)   n_symlink=$((n_symlink + 1)) ;;
    diverged)  n_diverged=$((n_diverged + 1)) ;;
  esac
  i=$((i + 1))
done
n_orphan=$((n_identical + n_symlink))

json_escape() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

emit_json() {
  printf '['
  local i=0 sep=""
  while [ "$i" -lt "$total" ]; do
    printf '%s{"policy":"%s","status":"%s","core_path":"core/policies/%s","personal_path":"personal/policies/%s"}' \
      "$sep" "$(json_escape "${names[$i]}")" "${statuses[$i]}" \
      "$(json_escape "${names[$i]}")" "$(json_escape "${names[$i]}")"
    sep=","
    i=$((i + 1))
  done
  printf ']\n'
}

case "$MODE" in
  json)
    emit_json
    exit 0 ;;

  check)
    if [ "$total" -eq 0 ]; then
      echo "detect-stale-core-policy-mirror: clean (no core/policies twins of a personal policy)"
      exit 0
    fi
    printf 'detect-stale-core-policy-mirror: %s twin(s) found — %s prunable orphan(s), %s diverged (need human classification)\n' \
      "$total" "$n_orphan" "$n_diverged" >&2
    exit 1 ;;

  prune)
    if [ "$total" -eq 0 ]; then
      echo "detect-stale-core-policy-mirror: nothing to prune (no twins)"
      exit 0
    fi
    removed=0; skipped=0
    i=0
    while [ "$i" -lt "$total" ]; do
      base="${names[$i]}"; st="${statuses[$i]}"
      case "$st" in
        identical|symlink)
          rm -f "$CORE_DIR/$base"
          printf 'pruned  (%s): core/policies/%s\n' "$st" "$base"
          removed=$((removed + 1)) ;;
        diverged)
          printf 'SKIPPED (diverged, needs human classification): core/policies/%s\n' "$base"
          skipped=$((skipped + 1)) ;;
      esac
      i=$((i + 1))
    done
    printf 'detect-stale-core-policy-mirror: pruned %s orphan(s); left %s diverged twin(s) for review.\n' \
      "$removed" "$skipped"
    exit 0 ;;

  report|*)
    if [ "$total" -eq 0 ]; then
      echo "detect-stale-core-policy-mirror: clean — no core/policies copies shadow a personal twin."
      exit 0
    fi
    printf 'Stale personal→core policy mirror copies in core/policies/ (%s twin(s)):\n\n' "$total"
    if [ "$n_orphan" -gt 0 ]; then
      printf 'Orphaned mirror copies (behavior-neutral — remove with --prune-identical):\n'
      i=0
      while [ "$i" -lt "$total" ]; do
        case "${statuses[$i]}" in
          identical) printf '  identical  core/policies/%s\n' "${names[$i]}" ;;
          symlink)   printf '  symlink    core/policies/%s\n' "${names[$i]}" ;;
        esac
        i=$((i + 1))
      done
      printf '\n'
    fi
    if [ "$n_diverged" -gt 0 ]; then
      printf 'Diverged copies (DRIFT MAY RUN EITHER DIRECTION — classify by hand, do NOT blind-sync):\n'
      i=0
      while [ "$i" -lt "$total" ]; do
        if [ "${statuses[$i]}" = "diverged" ]; then
          printf '  diverged   core/policies/%s   (diff: git diff --no-index personal/policies/%s core/policies/%s)\n' \
            "${names[$i]}" "${names[$i]}" "${names[$i]}"
        fi
        i=$((i + 1))
      done
      printf '\n'
    fi
    printf 'Summary: %s orphan(s), %s diverged.\n' "$n_orphan" "$n_diverged"
    exit 0 ;;
esac
