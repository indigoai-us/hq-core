#!/usr/bin/env bash
# hq-core: public
# handoff-open-steps.sh — list and close next steps across handoff threads
# (2026-09-07).
#
# Handoff threads record next_steps; since 2026-09-07 each carries an `id`
# (`<thread_id>#<n>`) and a `status` (open|done|dropped). This script is the
# closure side: /startwork and /resumework list what is still open instead of
# re-copying it forward, and a session closes a step when it is actually done.
#
# Usage:
#   handoff-open-steps.sh list [--limit N] [--company <slug>] [--json]
#   handoff-open-steps.sh close <step-id> [--as done|dropped] [--note "<why>"]
#   handoff-open-steps.sh reopen <step-id>
#
# Threads live in workspace/threads/T-*.json (and archive/**). Closing edits
# the step in place inside its thread file (only `status`, `closed_at`,
# `closed_by`, `note`) and bumps `updated_at`; nothing else in the thread is
# touched. Legacy steps without an id are listed with a synthetic id and can be
# closed the same way (the id is written on first close).
set -uo pipefail
HQ_ROOT="${HQ_ROOT:-${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}}"
THREADS="$HQ_ROOT/workspace/threads"
command -v jq >/dev/null 2>&1 || { echo "handoff-open-steps: jq required" >&2; exit 2; }
CMD="${1:-list}"; shift || true

thread_files() { # newest first, handoffs and checkpoints only
  find "$THREADS" -name 'T-*.json' ! -name '*.changeset.json' ! -path '*/resume-locks/*' 2>/dev/null \
    | while IFS= read -r f; do printf '%s\t%s\n' "$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f")" "$f"; done \
    | sort -rn | cut -f2
}
normalize_thread() { # <file> -> ensure every step has id/status (in memory)
  jq -c '.next_steps = ((.next_steps // []) | to_entries | map(.key as $k |
      (if (.value|type)=="string" then {step:.value} else .value end)
      | .id = (.id // (input_filename|split("/")|last|sub("\\.json$";"")) + "#" + (($k+1)|tostring))
      | .status = (.status // "open")) | map(del(.key)))' "$1"
}

case "$CMD" in
  list)
    LIMIT=20; CO=""; JSON=0
    while [ $# -gt 0 ]; do case "$1" in --limit) LIMIT="$2"; shift 2;; --company) CO="$2"; shift 2;; --json) JSON=1; shift;; *) shift;; esac; done
    n=0; rows=""
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      [ "$n" -ge "$LIMIT" ] && break
      n=$((n+1))
      t="$(normalize_thread "$f" 2>/dev/null)" || continue
      if [ -n "$CO" ]; then
        printf '%s' "$t" | jq -e --arg co "$CO" '(.metadata.company // []) | index($co) != null' >/dev/null 2>&1 || continue
      fi
      rows="$rows$(printf '%s' "$t" | jq -c '{thread: .thread_id, title: (.metadata.title // ""), created: .created_at} as $h | .next_steps[] | select(.status == "open") | $h + {id, step}')
"
    done < <(thread_files)
    if [ "$JSON" = 1 ]; then printf '%s' "$rows" | jq -s 'map(select(. != null))'; exit 0; fi
    if [ -z "$(printf '%s' "$rows" | tr -d '[:space:]')" ]; then echo "No open handoff steps in the last $n thread(s)."; exit 0; fi
    printf '%s' "$rows" | jq -r '"\(.id)  \(.step)  [\(.title)]"'
    ;;
  close|reopen)
    ID="${1:-}"; shift || true
    [ -n "$ID" ] || { echo "usage: $CMD <step-id>" >&2; exit 2; }
    AS="done"; NOTE=""
    while [ $# -gt 0 ]; do case "$1" in --as) AS="$2"; shift 2;; --note) NOTE="$2"; shift 2;; *) shift;; esac; done
    [ "$CMD" = reopen ] && AS="open"
    case "$AS" in done|dropped|open) ;; *) echo "--as must be done|dropped" >&2; exit 2;; esac
    tid="${ID%%#*}"
    f="$(find "$THREADS" -name "$tid.json" ! -path '*/resume-locks/*' 2>/dev/null | head -1)"
    [ -n "$f" ] || { echo "handoff-open-steps: thread $tid not found under $THREADS" >&2; exit 3; }
    now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"; by="${HQ_SESSION_ID:-${CLAUDE_SESSION_ID:-unknown-session}}"
    normalize_thread "$f" | jq --arg id "$ID" --arg as "$AS" --arg now "$now" --arg by "$by" --arg note "$NOTE" '
      if ([.next_steps[] | select(.id == $id)] | length) == 0 then error("step \($id) not in thread") else . end
      | .next_steps = (.next_steps | map(if .id == $id then
          (if $as == "open" then del(.closed_at, .closed_by) | .status = "open"
           else .status = $as | .closed_at = $now | .closed_by = $by | (if $note != "" then .note = $note else . end) end)
        else . end))
      | .updated_at = $now' > "$f.tmp" 2>"$f.err" || { cat "$f.err" >&2; rm -f "$f.tmp" "$f.err"; exit 3; }
    rm -f "$f.err"; mv "$f.tmp" "$f"
    echo "handoff-open-steps: $ID -> $AS"
    ;;
  *) sed -n 2,22p "$0"; exit 2 ;;
esac
