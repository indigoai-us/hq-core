#!/usr/bin/env bash
# hq-core: public
# Deliver one durable hq-lanes completion event to its owning Codex session.
set -euo pipefail

ROOT="${HQ_ROOT:-${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}}"
SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

die() { echo "lanes-completion-watch: $*" >&2; exit 1; }
quote() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }
valid_lane() { case "$1" in ''|*[!A-Za-z0-9_-]*) return 1 ;; esac; }
valid_since() {
  case "$1" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z)
      jq -en --arg since "$1" '($since|fromdateiso8601) as $epoch | ($epoch|strftime("%Y-%m-%dT%H:%M:%SZ")) == $since' >/dev/null 2>&1 && return 0
      ;;
    *) return 1 ;;
  esac
  return 1
}
since_key() { printf '%s' "$1" | tr -d ':-'; }
valid_round_id() { case "$1" in ''|*[!A-Za-z0-9_-]*) return 1 ;; esac; }
round_key() { printf '%s-%s' "$(since_key "$1")" "$2"; }
run_dir() { valid_lane "$1" || die "invalid lane id"; D="$ROOT/workspace/lanes-runs/$1"; [ -d "$D" ] || die "lane run directory does not exist: $D"; }
round_dir() { printf '%s/codex-completion' "$D"; }
claim_lock() {
  local path="$1" holder=""
  if mkdir "$path" 2>/dev/null; then printf '%s\n' "$$" > "$path/pid"; return 0; fi
  holder="$(cat "$path/pid" 2>/dev/null || true)"
  case "$holder" in ''|*[!0-9]*) ;; *) kill -0 "$holder" 2>/dev/null && return 1 ;; esac
  rm -f "$path/pid"
  rmdir "$path" 2>/dev/null || return 1
  mkdir "$path" 2>/dev/null || return 1
  printf '%s\n' "$$" > "$path/pid"
}
release_lock() { rm -f "$1/pid"; rmdir "$1" 2>/dev/null || true; }

cmd_emit() {
  local lane="${1:-}" since="${2:-}" round_id="${3:-}" timeout="${4:-60}" result show state decision ref log outcome receipt lock dir tmp qualifies envelope_at update_at ended_at
  valid_lane "$lane" || die "emit requires a valid lane id"
  valid_since "$since" || die "emit requires --since YYYY-MM-DDTHH:MM:SSZ"
  valid_round_id "$round_id" || die "emit requires a valid --round-id"
  case "$timeout" in ''|*[!0-9]*|0) die "wait timeout must be a positive number of seconds" ;; esac
  run_dir "$lane"
  dir="$(round_dir "$since")"
  mkdir -p "$dir"
  receipt="$dir/$(round_key "$since" "$round_id").json"
  lock="$dir/$(round_key "$since" "$round_id").lock"
  [ ! -f "$receipt" ] || return 0
  if ! claim_lock "$lock"; then
    [ -f "$receipt" ] && return 0
    die "another completion watcher owns this lane round"
  fi
  [ ! -f "$receipt" ] || return 0
  while :; do
    show="$(HQ_NO_UPDATE_CHECK=1 hq lanes show "$lane" --json)" || die "hq lanes show failed for $lane"
    printf '%s' "$show" | jq -e '.ok == true and (.lane | type == "object")' >/dev/null 2>&1 || die "hq lanes show returned an unreadable result for $lane"
    state="$(printf '%s' "$show" | jq -r '.lane.state // "unknown"')"
    decision="$(printf '%s' "$show" | jq -r '.lane.last_envelope.decision // empty')"
    ref="$(printf '%s' "$show" | jq -r '.lane.last_envelope.ref // empty')"
    envelope_at="$(printf '%s' "$show" | jq -r '.lane.last_envelope.at // empty')"
    update_at="$(printf '%s' "$show" | jq -r '.lane.updated_at // empty')"
    ended_at="$(printf '%s' "$show" | jq -r '.lane.ended_at // empty')"
    qualifies=0
    case "$state" in
      done|blocked)
        [ -n "$envelope_at" ] && jq -en --arg at "$envelope_at" --arg since "$since" '($at|sub("\\.[0-9]+Z$";"Z")|fromdateiso8601) >= ($since|fromdateiso8601)' >/dev/null 2>&1 && qualifies=1
        ;;
      awaiting_input)
        if [ -n "$envelope_at" ]; then
          jq -en --arg at "$envelope_at" --arg since "$since" '($at|sub("\\.[0-9]+Z$";"Z")|fromdateiso8601) >= ($since|fromdateiso8601)' >/dev/null 2>&1 && qualifies=1
        fi
        if [ "$qualifies" -eq 0 ] && [ -n "$update_at" ]; then
          jq -en --arg at "$update_at" --arg since "$since" '($at|sub("\\.[0-9]+Z$";"Z")|fromdateiso8601) >= ($since|fromdateiso8601)' >/dev/null 2>&1 && qualifies=1
        fi
        ;;
      failed|interrupted|cancelled|killed)
        [ -n "$ended_at" ] || ended_at="$update_at"
        [ -n "$ended_at" ] && jq -en --arg at "$ended_at" --arg since "$since" '($at|sub("\\.[0-9]+Z$";"Z")|fromdateiso8601) >= ($since|fromdateiso8601)' >/dev/null 2>&1 && qualifies=1
        ;;
    esac
    if [ "$qualifies" -eq 1 ]; then
      case "$state" in done|blocked|awaiting_input)
        if [ -n "$envelope_at" ] && jq -en --arg at "$envelope_at" --arg since "$since" '($at|sub("\\.[0-9]+Z$";"Z")|fromdateiso8601) >= ($since|fromdateiso8601)' >/dev/null 2>&1; then
          outcome="${decision:-$state}"
        else
          outcome="$state"; ref=""; decision=""
        fi
        ;;
        *) outcome="$state"; ref=""; decision="" ;;
      esac
      log="$D/logs/worker.out"
      tmp="$receipt.$$"
      jq -cn --arg lane_id "$lane" --arg since "$since" --arg outcome "$outcome" --arg state "$state" \
        --arg envelope_path "$ref" --arg log_path "$log" \
        '{kind:"conduct-lane-complete",lane_id:$lane_id,since:$since,outcome:$outcome,lane_state:$state,envelope_path:$envelope_path,log_path:$log_path}' > "$tmp"
      mv "$tmp" "$receipt"
      printf 'CONDUCT_LANE_COMPLETE %s\n' "$(jq -c . "$receipt")"
      release_lock "$lock"
      return 0
    fi
    result="$(HQ_NO_UPDATE_CHECK=1 hq lanes wait --any "$lane" --for envelope --for state --for question --timeout "$timeout" --json 2>/dev/null || true)"
    if printf '%s' "$result" | jq -e '.ok == true' >/dev/null 2>&1; then
      continue
    fi
    if printf '%s' "$result" | jq -e '.error == "wait_timeout"' >/dev/null 2>&1; then
      continue
    fi
    die "hq lanes wait returned an unreadable result for $lane"
  done
}

cmd_start() {
  local lane="" session_id="" provider="" since="" round_id="" wait_timeout=60 out="" command="" dir="" record="" lock=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --lane) lane="${2:-}"; shift 2 ;;
      --provider) provider="${2:-}"; shift 2 ;;
      --session-id) session_id="${2:-}"; shift 2 ;;
      --since) since="${2:-}"; shift 2 ;;
      --round-id) round_id="${2:-}"; shift 2 ;;
      --wait-timeout) wait_timeout="${2:-}"; shift 2 ;;
      *) die "unknown start option: $1" ;;
    esac
  done
  [ "$provider" = codex ] || die "start supports only Codex parents"
  valid_lane "$lane" || die "start requires a valid lane id"
  valid_since "$since" || die "start requires --since YYYY-MM-DDTHH:MM:SSZ"
  valid_round_id "$round_id" || die "start requires a valid --round-id"
  case "$session_id" in ''|*[!A-Za-z0-9_-]*) die "start requires a valid Codex session id" ;; esac
  [ "${CODEX_SESSION_ID:-${CODEX_THREAD_ID:-}}" = "$session_id" ] || die "mismatched owner rejected: target is not this Codex session"
  case "$wait_timeout" in ''|*[!0-9]*|0) die "wait timeout must be a positive number of seconds" ;; esac
  run_dir "$lane"
  dir="$(round_dir "$since")"
  mkdir -p "$dir"
  record="$dir/$(round_key "$since" "$round_id").monitor.json"
  lock="$dir/$(round_key "$since" "$round_id").monitor.lock"
  if [ -s "$record" ]; then cat "$record"; return 0; fi
  claim_lock "$lock" || { [ -s "$record" ] && { cat "$record"; return 0; }; die "a Codex completion monitor is already being scheduled for this lane round"; }
  command="HQ_ROOT=$(quote "$ROOT") exec /bin/bash $(quote "$SCRIPT") emit $(quote "$lane") $(quote "$since") $(quote "$round_id") $(quote "$wait_timeout")"
  out="$(HQ_NO_UPDATE_CHECK=1 hq monitor start --persistent --target "session:codex:$session_id" \
    --description "conduct lane $lane completion" --command "$command" --json)" \
    || { release_lock "$lock"; die "hq monitor start failed; completion was not scheduled"; }
  if ! printf '%s' "$out" | jq -e '.ok == true and ((.monitor_id // .id // "") | length > 0)' >/dev/null; then
    release_lock "$lock"
    die "hq monitor did not confirm scheduling; no completion was scheduled"
  fi
  printf '%s\n' "$out" > "$record"
  release_lock "$lock"
  printf '%s\n' "$out"
}

case "${1:-}" in
  start) shift; cmd_start "$@" ;;
  emit) shift; cmd_emit "$@" ;;
  *) die "usage: lanes-completion-watch.sh start --lane <id> --provider codex --session-id <id> --since <UTC timestamp> --round-id <id> | emit <lane-id> <since> <round-id> [wait-timeout]" ;;
esac
