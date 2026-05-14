#!/usr/bin/env bash
# session-journal.sh — minimal helper for session-level journal entries.
# Spec: core/knowledge/public/hq-core/session-journal-spec.md
#
# Usage:
#   session-journal.sh write "<title>" [--files f1,f2,...] [--body-file PATH]
#   session-journal.sh list [--date YYYY-MM-DD]
#   session-journal.sh read <NNN> [--date YYYY-MM-DD]
#   session-journal.sh index-path [--date YYYY-MM-DD]   # prints the INDEX.md path
#   session-journal.sh dir-path [--date YYYY-MM-DD]     # prints the journal dir
#   session-journal.sh tool-counter increment           # used by PostToolUse hook
#   session-journal.sh tool-counter read                # current count
#   session-journal.sh tool-counter reset
#
# All commands fail-soft: warn to stderr, exit 0 — never block the caller.

set -uo pipefail

HQ_ROOT="${HQ_ROOT:-${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}}"

today() { date -u +%Y-%m-%d; }
now_iso_z() { date -u +%Y-%m-%dT%H:%M:%SZ; }
now_hhmm_z() { date -u +%H:%MZ; }

journal_dir_for() {
  local d="${1:-$(today)}"
  printf '%s/workspace/threads/journal/%s' "$HQ_ROOT" "$d"
}

warn() { echo "session-journal: $*" >&2; }

slugify() {
  # Lowercase, replace non-alnum with hyphen, collapse hyphens, trim.
  printf '%s' "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//' \
    | cut -c1-40
}

next_seq() {
  local dir="$1"
  # Highest NNN in the dir, +1, zero-padded to 3.
  local hi
  hi=$(ls "$dir" 2>/dev/null \
    | grep -E '^[0-9]{3}-' \
    | sed -E 's/^([0-9]+)-.*/\1/' \
    | sort -n \
    | tail -1)
  if [ -z "$hi" ]; then printf '001'; else printf '%03d' $((10#$hi + 1)); fi
}

cmd="${1:-}"; shift || true

case "$cmd" in
  write)
    title="${1:-}"; shift || true
    files_csv=""
    body_file=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --files)     files_csv="${2:-}"; shift 2 || break ;;
        --body-file) body_file="${2:-}"; shift 2 || break ;;
        *) shift ;;
      esac
    done

    [ -z "$title" ] && { warn "write: title required"; exit 0; }

    d="$(today)"
    dir="$(journal_dir_for "$d")"
    mkdir -p "$dir" 2>/dev/null || { warn "write: mkdir failed: $dir"; exit 0; }

    seq="$(next_seq "$dir")"
    slug="$(slugify "$title")"
    [ -z "$slug" ] && slug="entry"
    out="$dir/${seq}-${slug}.md"

    # Build frontmatter
    {
      printf -- '---\n'
      printf 'ts: %s\n' "$(now_iso_z)"
      printf 'title: %s\n' "$title"
      printf 'slug: %s\n' "$slug"
      if [ -n "$files_csv" ]; then
        printf 'files:\n'
        old_ifs="$IFS"
        IFS=','
        set -- $files_csv
        IFS="$old_ifs"
        for f in "$@"; do
          [ -n "$f" ] && printf '  - %s\n' "$f"
        done
      fi
      printf 'status: closed\n'
      printf -- '---\n\n'
      printf '# %s — %s\n\n' "$seq" "$title"
      if [ -n "$body_file" ] && [ -f "$body_file" ]; then
        cat "$body_file"
      else
        printf '## Goal\n\n## Findings\n\n## Decisions\n\n## Next\n'
      fi
    } > "$out" 2>/dev/null || { warn "write: failed to write $out"; exit 0; }

    # Update INDEX.md
    idx="$dir/INDEX.md"
    if [ ! -f "$idx" ]; then
      printf '# Session journal — %s\n\n' "$d" > "$idx"
    fi
    printf -- '- `%s` %s — %s\n' "$seq" "$(now_hhmm_z)" "$title" >> "$idx" \
      || warn "write: INDEX update failed"

    # Reset tool counter — milestone was journaled
    "$0" tool-counter reset >/dev/null 2>&1 || true

    printf '%s\n' "$out"
    ;;

  list)
    date_arg="$(today)"
    while [ $# -gt 0 ]; do
      case "$1" in --date) date_arg="${2:-$(today)}"; shift 2 ;; *) shift ;; esac
    done
    dir="$(journal_dir_for "$date_arg")"
    idx="$dir/INDEX.md"
    if [ -f "$idx" ]; then
      cat "$idx"
    else
      echo "(no journal for $date_arg)"
    fi
    ;;

  read)
    seq="${1:-}"; shift || true
    date_arg="$(today)"
    while [ $# -gt 0 ]; do
      case "$1" in --date) date_arg="${2:-$(today)}"; shift 2 ;; *) shift ;; esac
    done
    [ -z "$seq" ] && { warn "read: NNN required"; exit 0; }
    seq=$(printf '%03d' $((10#$seq)) 2>/dev/null) || seq="$seq"
    dir="$(journal_dir_for "$date_arg")"
    match=$(ls "$dir" 2>/dev/null | grep -E "^${seq}-" | head -1)
    if [ -n "$match" ]; then cat "$dir/$match"; else warn "read: no entry $seq for $date_arg"; fi
    ;;

  index-path)
    date_arg="$(today)"
    while [ $# -gt 0 ]; do
      case "$1" in --date) date_arg="${2:-$(today)}"; shift 2 ;; *) shift ;; esac
    done
    printf '%s/INDEX.md\n' "$(journal_dir_for "$date_arg")"
    ;;

  dir-path)
    date_arg="$(today)"
    while [ $# -gt 0 ]; do
      case "$1" in --date) date_arg="${2:-$(today)}"; shift 2 ;; *) shift ;; esac
    done
    journal_dir_for "$date_arg"
    ;;

  tool-counter)
    sub="${1:-}"; shift || true
    dir="$(journal_dir_for "$(today)")"
    mkdir -p "$dir" 2>/dev/null || true
    counter="$dir/.tool-count"
    case "$sub" in
      increment)
        n=0
        [ -f "$counter" ] && n=$(cat "$counter" 2>/dev/null | tr -d '\n' | tr -dc '0-9')
        [ -z "$n" ] && n=0
        echo $((n + 1)) > "$counter" 2>/dev/null || true
        ;;
      read)
        n=0
        [ -f "$counter" ] && n=$(cat "$counter" 2>/dev/null | tr -d '\n' | tr -dc '0-9')
        printf '%d\n' "${n:-0}"
        ;;
      reset)
        echo 0 > "$counter" 2>/dev/null || true
        ;;
      *) warn "tool-counter: subcommand required (increment|read|reset)" ;;
    esac
    ;;

  *)
    cat >&2 <<'USAGE'
session-journal.sh: usage:
  session-journal.sh write "<title>" [--files f1,f2,...] [--body-file PATH]
  session-journal.sh list [--date YYYY-MM-DD]
  session-journal.sh read <NNN> [--date YYYY-MM-DD]
  session-journal.sh index-path [--date YYYY-MM-DD]
  session-journal.sh dir-path [--date YYYY-MM-DD]
  session-journal.sh tool-counter (increment|read|reset)
USAGE
    exit 1
    ;;
esac
