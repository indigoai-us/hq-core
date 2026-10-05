#!/usr/bin/env bash
# session-journal.sh — minimal helper for session-level journal entries.
# Spec: core/knowledge/public/hq-core/session-journal-spec.md
#
# Usage:
#   session-journal.sh write "<title>" [--files f1,f2,...] [--body-file PATH] [--session KEY]
#   session-journal.sh list [--date YYYY-MM-DD]
#   session-journal.sh read <NNN> [--date YYYY-MM-DD]
#   session-journal.sh index-path [--date YYYY-MM-DD]   # prints the INDEX.md path
#   session-journal.sh dir-path [--date YYYY-MM-DD]     # prints the journal dir
#   session-journal.sh tool-counter increment [--session KEY]   # used by PostToolUse hook
#   session-journal.sh tool-counter read [--session KEY]        # current count
#   session-journal.sh tool-counter reset [--session KEY]
#
# The tool counter is per-session: state lives at
# workspace/threads/journal/<date>/.tool-count-<session-key>. The key comes from
# --session, else $HQ_JOURNAL_SESSION, else $HQ_HOOK_SESSION_ID, else
# "unscoped". A date-global counter let concurrent Claude and Codex tasks
# trigger and reset each other's journal reminders.
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

# Counters are per-session. A date-global counter lets concurrent Claude and
# Codex tasks trip (and reset) each other's journal reminders.
counter_key() {
  local raw="${1:-}"
  raw="$(printf '%s' "$raw" | tr -c 'A-Za-z0-9._-' '_')"
  raw="${raw#_}"; raw="${raw%_}"
  [ -z "$raw" ] && raw="unscoped"
  [ "${#raw}" -gt 96 ] && raw="${raw:0:96}"
  printf '%s' "$raw"
}

resolve_session_key() {
  counter_key "${1:-${HQ_JOURNAL_SESSION:-${HQ_HOOK_SESSION_ID:-}}}"
}

# Read-modify-write on the counter must not interleave across concurrent tasks.
# Waiters retry for about 5 s (250 x 20 ms) by default; under heavy contention a
# 1 s budget was not enough for 30 concurrent writers. After that the update is
# skipped rather than run unlocked. HQ_JOURNAL_COUNTER_LOCK_TRIES overrides the
# attempt count (tests use it to force exhaustion quickly).
# A stale lock is reclaimable only when its recorded owner PID is no longer
# alive. The sibling reclaim directory serializes reclaimers; after rechecking
# the owner under that claim, rename the stale lock before deleting its unique
# tombstone so a new owner can never be removed by cleanup.
reclaim_stale_counter_lock() {
  local lockdir="$1" owner_pid current_owner claim stale_dir suffix=0
  owner_pid="$(cat "$lockdir/pid" 2>/dev/null || true)"
  case "$owner_pid" in ''|*[!0-9]*) return 1 ;; esac
  [ "$owner_pid" -gt 1 ] 2>/dev/null || return 1
  kill -0 "$owner_pid" 2>/dev/null && return 1

  claim="${lockdir}.reclaim"
  mkdir "$claim" 2>/dev/null || return 1
  if ! printf '%s\n' "$$" > "$claim/pid" 2>/dev/null; then
    rmdir "$claim" 2>/dev/null || true
    return 1
  fi

  current_owner="$(cat "$lockdir/pid" 2>/dev/null || true)"
  if [ "$current_owner" = "$owner_pid" ] && ! kill -0 "$owner_pid" 2>/dev/null; then
    stale_dir="${lockdir}.stale.$$.$RANDOM"
    while [ -e "$stale_dir" ]; do
      suffix=$((suffix + 1))
      stale_dir="${lockdir}.stale.$$.$RANDOM.$suffix"
    done
    if mv "$lockdir" "$stale_dir" 2>/dev/null; then
      rm -rf "$stale_dir" 2>/dev/null || true
      rm -rf "$claim" 2>/dev/null || true
      return 0
    fi
  fi

  rm -rf "$claim" 2>/dev/null || true
  return 1
}

with_counter_lock() {
  local lockdir="$1"; shift
  local i=0 acquired=0 rc=0 tries="${HQ_JOURNAL_COUNTER_LOCK_TRIES:-250}"
  case "$tries" in ''|*[!0-9]*) tries=250 ;; esac
  while [ "$i" -lt "$tries" ]; do
    if mkdir "$lockdir" 2>/dev/null; then
      acquired=1
      if ! printf '%s\n' "$$" > "$lockdir/pid" 2>/dev/null; then
        rm -rf "$lockdir" 2>/dev/null || true
        return 0
      fi
      break
    fi
    reclaim_stale_counter_lock "$lockdir" && continue
    i=$((i + 1))
    [ "$i" -ge "$tries" ] || sleep 0.02 2>/dev/null || sleep 1
  done
  if [ "$acquired" -ne 1 ]; then
    warn "tool-counter: lock remained busy; skipped update"
    return 0
  fi

  "$@" || rc=$?
  if [ "$(cat "$lockdir/pid" 2>/dev/null || true)" = "$$" ]; then
    rm -rf "$lockdir" 2>/dev/null || true
  fi
  return "$rc"
}

counter_read_raw() {
  local counter="$1" n=0
  [ -f "$counter" ] && n=$(tr -dc '0-9' < "$counter" 2>/dev/null)
  [ -z "$n" ] && n=0
  printf '%d' "$n"
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
    session_arg=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --files)     files_csv="${2:-}"; shift 2 || break ;;
        --body-file) body_file="${2:-}"; shift 2 || break ;;
        --session)   session_arg="${2:-}"; shift 2 || break ;;
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

    # Reset the tool counter for THIS session only — journaling one task's
    # milestone must not clear a concurrent task's progress toward its own.
    "$0" tool-counter reset --session "$(resolve_session_key "$session_arg")" >/dev/null 2>&1 || true

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
    session_arg=""
    while [ $# -gt 0 ]; do
      case "$1" in --session) session_arg="${2:-}"; shift 2 || break ;; *) shift ;; esac
    done
    session_key="$(resolve_session_key "$session_arg")"
    dir="$(journal_dir_for "$(today)")"
    mkdir -p "$dir" 2>/dev/null || true
    counter="$dir/.tool-count-$session_key"
    lockdir="$counter.lock"
    case "$sub" in
      increment)
        do_increment() {
          local n
          n=$(counter_read_raw "$counter")
          echo $((n + 1)) > "$counter" 2>/dev/null || true
        }
        with_counter_lock "$lockdir" do_increment
        ;;
      read)
        printf '%d\n' "$(counter_read_raw "$counter")"
        ;;
      reset)
        do_reset() { echo 0 > "$counter" 2>/dev/null || true; }
        with_counter_lock "$lockdir" do_reset
        ;;
      *) warn "tool-counter: subcommand required (increment|read|reset)" ;;
    esac
    ;;

  *)
    cat >&2 <<'USAGE'
session-journal.sh: usage:
  session-journal.sh write "<title>" [--files f1,f2,...] [--body-file PATH] [--session KEY]
  session-journal.sh list [--date YYYY-MM-DD]
  session-journal.sh read <NNN> [--date YYYY-MM-DD]
  session-journal.sh index-path [--date YYYY-MM-DD]
  session-journal.sh dir-path [--date YYYY-MM-DD]
  session-journal.sh tool-counter (increment|read|reset) [--session KEY]
USAGE
    exit 1
    ;;
esac
