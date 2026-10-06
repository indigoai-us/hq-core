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
  # Win32 rejects newline file-name bytes; otherwise keep the POSIX slug pipeline.
  local slug_input="$1"; if [[ "${OSTYPE:-}" == msys* ]] || [[ "${MSYSTEM:-}" == MINGW* ]]; then slug_input="${slug_input//$'\n'/-}"; fi; printf '%s' "$slug_input" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//' \
    | cut -c1-40
}

yaml_double_quoted() {
  local value="$1" output='"' character next pair hex
  local LC_ALL=C index
  for ((index = 0; index < ${#value}; index++)); do
    character="${value:index:1}"
    if [[ "$character" == $'\xc2' ]] && (( index + 1 < ${#value} )); then
      next="${value:index+1:1}"
      pair="$character$next"
      case "$pair" in
        $'\xc2\x80') hex=0080 ;;
        $'\xc2\x81') hex=0081 ;;
        $'\xc2\x82') hex=0082 ;;
        $'\xc2\x83') hex=0083 ;;
        $'\xc2\x84') hex=0084 ;;
        $'\xc2\x85') hex=0085 ;;
        $'\xc2\x86') hex=0086 ;;
        $'\xc2\x87') hex=0087 ;;
        $'\xc2\x88') hex=0088 ;;
        $'\xc2\x89') hex=0089 ;;
        $'\xc2\x8a') hex=008a ;;
        $'\xc2\x8b') hex=008b ;;
        $'\xc2\x8c') hex=008c ;;
        $'\xc2\x8d') hex=008d ;;
        $'\xc2\x8e') hex=008e ;;
        $'\xc2\x8f') hex=008f ;;
        $'\xc2\x90') hex=0090 ;;
        $'\xc2\x91') hex=0091 ;;
        $'\xc2\x92') hex=0092 ;;
        $'\xc2\x93') hex=0093 ;;
        $'\xc2\x94') hex=0094 ;;
        $'\xc2\x95') hex=0095 ;;
        $'\xc2\x96') hex=0096 ;;
        $'\xc2\x97') hex=0097 ;;
        $'\xc2\x98') hex=0098 ;;
        $'\xc2\x99') hex=0099 ;;
        $'\xc2\x9a') hex=009a ;;
        $'\xc2\x9b') hex=009b ;;
        $'\xc2\x9c') hex=009c ;;
        $'\xc2\x9d') hex=009d ;;
        $'\xc2\x9e') hex=009e ;;
        $'\xc2\x9f') hex=009f ;;
        *) hex= ;;
      esac
      if [[ -n "$hex" ]]; then
        output+="\\u$hex"
        index=$((index + 1))
        continue
      fi
    fi
    case "$character" in
      \\) output+='\\' ;;
      '"') output+='\"' ;;
      $'\n') output+='\n' ;;
      $'\r') output+='\r' ;;
      $'\t') output+='\t' ;;
      *)
        if [[ "$character" == [[:cntrl:]] ]]; then
          printf -v codepoint '%d' "'${character}"
          printf -v hex '%02x' "$codepoint"
          output+="\\x$hex"
        else
          output+="$character"
        fi
        ;;
    esac
  done
  printf '%s"' "$output"
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

acquire_journal_write_lock() {
  local lock="$1/.session-journal-write.lock" owner=0 i=0
  while [[ "$i" -lt 250 || ( "${OSTYPE:-}" == msys* && "$i" -lt 1500 ) ]]; do
    if mkdir "$lock" 2>/dev/null; then
      printf '%s\n' "$$" > "$lock/pid" || { rm -rf "$lock"; return 1; }
      JOURNAL_WRITE_LOCK="$lock"
      return 0
    fi
    owner="$(cat "$lock/pid" 2>/dev/null || true)"
    if [[ "$owner" =~ ^[0-9]+$ ]] && [ "$owner" -gt 0 ] && ! kill -0 "$owner" 2>/dev/null; then
      if [ "$(cat "$lock/pid" 2>/dev/null || true)" = "$owner" ]; then rm -rf "$lock" 2>/dev/null || true; fi
    fi
    i=$((i + 1))
    sleep 0.02 2>/dev/null || sleep 1
  done
  return 1
}

release_journal_write_lock() {
  [ -n "${JOURNAL_WRITE_LOCK:-}" ] || return 0
  if [ "$(cat "$JOURNAL_WRITE_LOCK/pid" 2>/dev/null || true)" = "$$" ]; then
    rm -rf "$JOURNAL_WRITE_LOCK" 2>/dev/null || true
  fi
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

    slug="$(slugify "$title")"
    [ -z "$slug" ] && slug="entry"
    yaml_title="$(yaml_double_quoted "$title")"
    yaml_slug="$slug"
    [[ "$slug" != *$'\n'* ]] || yaml_slug="$(yaml_double_quoted "$slug")"
    JOURNAL_WRITE_LOCK=""
    acquire_journal_write_lock "$dir" || { warn "write: failed to acquire journal lock"; exit 0; }
    trap release_journal_write_lock EXIT
    seq=""
    out=""
    created=false
    attempt=0
    while [ "$attempt" -lt 10000 ]; do
      attempt=$((attempt + 1))
      seq="$(next_seq "$dir")"
      out="$dir/${seq}-${slug}.md"
      write_status=0
      (
        set -o noclobber
        if ! exec 3>"$out" 2>/dev/null; then
          if [ -e "$out" ] || [ -L "$out" ]; then exit 17; fi
          exit 16
        fi
        {
          printf -- '---\n'
          printf 'ts: %s\n' "$(now_iso_z)"
          printf 'title: %s\n' "$yaml_title"
          printf 'slug: %s\n' "$yaml_slug"
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
        } >&3 || exit 18
      )
      write_status=$?
      if [ "$write_status" -eq 0 ]; then
        created=true
        break
      elif [ "$write_status" -eq 17 ]; then
        continue
      else
        warn "write: failed to write $out"
        exit 0
      fi
    done
    [ "$created" = true ] || { warn "write: failed to write $out"; exit 0; }

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
    [[ "$seq" =~ ^[0-9]{1,18}$ ]] || { warn "read: NNN required"; exit 0; }
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
