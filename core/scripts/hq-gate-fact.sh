#!/usr/bin/env bash
# Session-scoped fact ledger used by policy gate hooks.
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="${HQ_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
. "$SCRIPT_DIR/hook-lib.sh"
. "$SCRIPT_DIR/lib/session-id.sh"

usage() {
  printf '%s\n' 'usage: hq-gate-fact.sh confirm <fact> [--note <text>] | check <fact> [--within <minutes>] | list | revoke <fact>' >&2
  exit 2
}

is_known_fact() {
  case "$1" in
    sending_account_confirmed|recipients_confirmed|draft_approved|humanize_passed|enforcement_observed) return 0 ;;
    *) return 1 ;;
  esac
}

[ "$#" -gt 0 ] || usage
command_name="$1"
shift
session_id="$(session_id_resolve "$ROOT")"
[ -n "$session_id" ] || { printf '%s\n' 'gate fact error: no current session id' >&2; exit 2; }
state_dir="$(hq_hook_state_dir "$ROOT")/gate-facts/$session_id"

case "$command_name" in
  confirm)
    [ "$#" -ge 1 ] || usage
    fact="$1"
    shift
    is_known_fact "$fact" || { printf 'gate fact error: unknown fact: %s\n' "$fact" >&2; exit 2; }
    note=""
    source="helper"
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --note)
          [ "$#" -ge 2 ] || usage
          [ -z "$note" ] || usage
          note="$2"
          shift 2
          ;;
        *) usage ;;
      esac
    done
    case "$fact" in
      sending_account_confirmed|recipients_confirmed|draft_approved)
        proof="$state_dir/proofs/$fact.json"
        [ -s "$proof" ] || { printf 'gate fact error: AskUserQuestion proof required for %s\n' "$fact" >&2; exit 2; }
        if ! jq -e --arg fact "$fact" --arg sid "$session_id" '
          .fact == $fact and .session_id == $sid and .source == "askuserquestion" and
          (.answer | type == "string" and test("^(confirmed|yes|approved)$";"i")) and
          (.confirmed_at | type == "string")
        ' "$proof" >/dev/null 2>&1; then
          printf 'gate fact error: invalid AskUserQuestion proof for %s\n' "$fact" >&2
          exit 2
        fi
        source="askuserquestion"
        note="$(jq -r '.answer' "$proof")"
        ;;
      *) source="helper" ;;
    esac
    command -v jq >/dev/null 2>&1 || { printf '%s\n' 'gate fact error: jq is required' >&2; exit 2; }
    umask 077
    mkdir -p "$state_dir" || { printf '%s\n' 'gate fact error: cannot create session state directory' >&2; exit 2; }
    timestamp="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    tmp="$(mktemp "$state_dir/.fact.XXXXXX")" || { printf '%s\n' 'gate fact error: cannot create temporary record' >&2; exit 2; }
    if ! jq -n --arg fact "$fact" --arg confirmed_at "$timestamp" --arg note "$note" --arg source "$source" '{fact:$fact, confirmed_at:$confirmed_at, note:$note, source:$source}' > "$tmp"; then
      rm -f "$tmp"
      printf '%s\n' 'gate fact error: could not encode record' >&2
      exit 2
    fi
    chmod 600 "$tmp"
    mv -f "$tmp" "$state_dir/$fact.json"
    [ "$source" != askuserquestion ] || rm -f "$state_dir/proofs/$fact.json"
    ;;
  check)
    [ "$#" -ge 1 ] || usage
    fact="$1"
    shift
    is_known_fact "$fact" || { printf 'gate fact error: unknown fact: %s\n' "$fact" >&2; exit 2; }
    within=""
    if [ "$#" -gt 0 ]; then
      [ "$#" -eq 2 ] && [ "$1" = --within ] || usage
      within="$2"
      case "$within" in ''|*[!0-9]*|????????*) usage ;; esac
    fi
    if hq_gate_fact_present "$fact" "$within"; then
      exit 0
    fi
    exit 1
    ;;
  list)
    [ "$#" -eq 0 ] || usage
    if [ -d "$state_dir" ]; then
      for file in "$state_dir"/*.json; do
        [ -f "$file" ] || continue
        cat "$file"
      done | jq -s 'sort_by(.fact)'
    else
      printf '%s\n' '[]'
    fi
    ;;
  revoke)
    [ "$#" -eq 1 ] || usage
    fact="$1"
    is_known_fact "$fact" || { printf 'gate fact error: unknown fact: %s\n' "$fact" >&2; exit 2; }
    rm -f "$state_dir/$fact.json"
    ;;
  *) usage ;;
esac
