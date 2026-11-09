#!/usr/bin/env bash
# hq-core: public
# board-project-id.sh — allocate and check company Board project ids.
#
#   board-project-id.sh next  <company> [--prefix <p>]
#       Print the next free `<prefix>-proj-<NNN>` id: one more than the
#       HIGHEST number already used with that prefix anywhere in the board,
#       never "last entry + 1" (entries are not kept in id order). Zero-padded
#       to 3 digits. The prefix defaults to the one most entries use.
#   board-project-id.sh check <company>
#       Exit 1 and list every duplicate project id and every entry with an
#       empty title; exit 0 when the board is clean. Run it after writing
#       board.json and before registering the project.
#
# Reads companies/<company>/board.json under HQ_ROOT. Never writes it.
set -euo pipefail

ROOT="${HQ_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

die() {
  echo "board-project-id: $*" >&2
  exit 2
}

usage() {
  die "usage: board-project-id.sh next <company> [--prefix <p>] | check <company>"
}

command -v jq >/dev/null 2>&1 || die "jq is required"

mode="${1:-}"
company="${2:-}"
[ -n "$mode" ] && [ -n "$company" ] || usage
case "$company" in
  */*|.*|*..*) die "invalid company slug: $company" ;;
esac
shift 2
prefix=""
while [ $# -gt 0 ]; do
  case "$1" in
    --prefix)
      [ $# -ge 2 ] || usage
      prefix="$2"
      shift 2
      ;;
    *) usage ;;
  esac
done
if [ -n "$prefix" ]; then
  printf '%s' "$prefix" | grep -Eq '^[a-z0-9]+$' || die "invalid prefix: $prefix"
fi

board="$ROOT/companies/$company/board.json"

case "$mode" in
  next)
    if [ ! -f "$board" ]; then
      [ -n "$prefix" ] || die "no board at companies/$company/board.json; pass --prefix"
      printf '%s-proj-001\n' "$prefix"
      exit 0
    fi
    jq -e . "$board" >/dev/null 2>&1 || die "could not read companies/$company/board.json"
    # With no --prefix the prefix comes from existing ids. Say so plainly when
    # there are none, instead of the generic read error below.
    if [ -z "$prefix" ] && ! jq -e '[.projects[]? | .id? | strings | select(test("^[a-z0-9]+-proj-[0-9]+$"))] | length > 0' "$board" >/dev/null 2>&1; then
      die "no <prefix>-proj-<NNN> ids in companies/$company/board.json; pass --prefix <p>"
    fi
    jq -r --arg prefix "$prefix" '
      [ .projects[]? | .id? | strings
        | capture("^(?<p>[a-z0-9]+)-proj-(?<n>[0-9]+)$")? ] as $ids
      | (if $prefix != "" then $prefix
         elif ($ids | length) > 0 then ($ids | group_by(.p) | max_by(length) | .[0].p)
         else "" end) as $p
      | if $p == "" then error("no <prefix>-proj-<NNN> ids on this board; pass --prefix")
        else
          ([ $ids[] | select(.p == $p) | (.n | tonumber) ] | max // 0) + 1
          | tostring as $n
          | "\($p)-proj-\(if ($n | length) < 3 then ("000" + $n)[-3:] else $n end)"
        end
    ' "$board" 2>/dev/null | tr -d '\r' || die "could not read companies/$company/board.json"
    ;;
  check)
    [ -f "$board" ] || exit 0
    problems="$(jq -r '
      ([ .projects[]? | .id? | strings ] | group_by(.) | map(select(length > 1) | "duplicate project id: \(.[0]) (\(length) entries)")[]),
      ( .projects // [] | to_entries[]
        | select(((.value.title // "") | tostring | gsub("^\\s+|\\s+$"; "")) == "")
        | "projects[\(.key)]: missing title (id \(.value.id // "none"))")
    ' "$board" 2>/dev/null | tr -d '\r')" || die "could not read companies/$company/board.json"
    if [ -n "$problems" ]; then
      printf '%s\n' "$problems" >&2
      exit 1
    fi
    ;;
  *) usage ;;
esac
