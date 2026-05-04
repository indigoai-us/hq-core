#!/usr/bin/env bash
# hq-status-summary.sh — classify noisy HQ git status output.
#
# This is deliberately read-only. It turns `git status --porcelain --ignored`
# into a compact summary that separates current-session touched paths from the
# local HQ baseline noise that may remain untracked on installer-created roots.

set -euo pipefail

ROOT="${HQ_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
PORCELAIN_FILE=""
SESSION_FILES_JSON="[]"
FORMAT="json"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --porcelain-file) PORCELAIN_FILE="$2"; shift 2 ;;
    --session-files-json) SESSION_FILES_JSON="$2"; shift 2 ;;
    --json) FORMAT="json"; shift ;;
    --text) FORMAT="text"; shift ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

cd "$ROOT"

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

tracked="$tmpdir/tracked"
session_untracked="$tmpdir/session_untracked"
baseline_untracked="$tmpdir/baseline_untracked"
unrelated_untracked="$tmpdir/unrelated_untracked"
ignored="$tmpdir/ignored"
unsafe_session="$tmpdir/unsafe_session"
: >"$tracked"; : >"$session_untracked"; : >"$baseline_untracked"; : >"$unrelated_untracked"; : >"$ignored"; : >"$unsafe_session"

session_paths_file="$tmpdir/session_paths"
printf '%s' "$SESSION_FILES_JSON" | jq -r '
  if type != "array" then empty else
    .[] | if type == "string" then . else (.path // empty) end
  end
' 2>/dev/null | sed '/^$/d' > "$session_paths_file" || : > "$session_paths_file"

baseline_patterns_file="$tmpdir/baseline_patterns"
if [[ -f workspace/baseline/hq-local-baseline.json ]]; then
  jq -r '.categories[]?.patterns[]?' workspace/baseline/hq-local-baseline.json 2>/dev/null > "$baseline_patterns_file" || : > "$baseline_patterns_file"
else
  cat > "$baseline_patterns_file" <<'PATTERNS'
companies/*
workspace/*
repos/*
settings/*
.hq/*
PATTERNS
fi

is_session_path() {
  local path="$1"
  local p
  while IFS= read -r p; do
    [[ -z "$p" ]] && continue
    if [[ "$path" == "$p" || "$path" == "$p/"* || "$p" == "$path/"* ]]; then
      return 0
    fi
  done < "$session_paths_file"
  return 1
}

is_baseline_path() {
  local path="$1"
  local pat
  while IFS= read -r pat; do
    [[ -z "$pat" ]] && continue
    case "$path" in
      $pat) return 0 ;;
    esac
  done < "$baseline_patterns_file"
  return 1
}

status_source="$tmpdir/porcelain"
if [[ -n "$PORCELAIN_FILE" ]]; then
  cp "$PORCELAIN_FILE" "$status_source"
else
  git status --porcelain --ignored > "$status_source"
fi

while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  code="${line:0:2}"
  path="${line:3}"
  if [[ "$path" == *" -> "* ]]; then
    path="${path##* -> }"
  fi

  case "$code" in
    '!!')
      printf '%s\n' "$path" >> "$ignored"
      ;;
    '??')
      if is_session_path "$path"; then
        printf '%s\n' "$path" >> "$session_untracked"
      elif is_baseline_path "$path"; then
        printf '%s\n' "$path" >> "$baseline_untracked"
      else
        printf '%s\n' "$path" >> "$unrelated_untracked"
      fi
      ;;
    *)
      printf '%s\n' "$path" >> "$tracked"
      ;;
  esac
done < "$status_source"

json_array() {
  jq -R -s 'split("\n") | map(select(length > 0))' "$1"
}

tracked_json=$(json_array "$tracked")
session_untracked_json=$(json_array "$session_untracked")
baseline_untracked_json=$(json_array "$baseline_untracked")
unrelated_untracked_json=$(json_array "$unrelated_untracked")
ignored_json=$(json_array "$ignored")

if [[ "$FORMAT" == "text" ]]; then
  printf 'tracked_changes=%s\n' "$(jq 'length' <<<"$tracked_json")"
  printf 'session_untracked=%s\n' "$(jq 'length' <<<"$session_untracked_json")"
  printf 'baseline_untracked=%s\n' "$(jq 'length' <<<"$baseline_untracked_json")"
  printf 'unrelated_untracked=%s\n' "$(jq 'length' <<<"$unrelated_untracked_json")"
  printf 'ignored=%s\n' "$(jq 'length' <<<"$ignored_json")"
else
  jq -n \
    --argjson tracked "$tracked_json" \
    --argjson session_untracked "$session_untracked_json" \
    --argjson baseline_untracked "$baseline_untracked_json" \
    --argjson unrelated_untracked "$unrelated_untracked_json" \
    --argjson ignored "$ignored_json" \
    '{
      counts: {
        tracked_changes: ($tracked | length),
        session_touched_untracked: ($session_untracked | length),
        baseline_untracked: ($baseline_untracked | length),
        unrelated_untracked: ($unrelated_untracked | length),
        ignored: ($ignored | length),
        baseline_noise: (($baseline_untracked | length) + ($unrelated_untracked | length))
      },
      files: {
        tracked_changes: $tracked,
        session_touched_untracked: $session_untracked,
        baseline_untracked: $baseline_untracked,
        unrelated_untracked: $unrelated_untracked,
        ignored: $ignored
      }
    }'
fi
