#!/usr/bin/env bash
# hq-core: public
# resume-thread-lock.sh — durable, session-attributed lock markers for
# /resumework. Locks live outside individual thread JSON files so archival can
# move a thread without orphaning or mutating its immutable handoff record.
#
# Usage:
#   resume-thread-lock.sh inspect <thread-id>
#   resume-thread-lock.sh acquire <thread-id> --session-id <session-id>
#   resume-thread-lock.sh acquire <thread-id> --replace --expected-generation <generation> --session-id <session-id>
#
# inspect always exits zero and returns one JSON object with status unlocked,
# locked, or stale. acquire exits 3 with that same locked/stale JSON when an
# existing marker needs an explicit user confirmation; --replace is reserved
# for the confirmed re-resume path.

set -euo pipefail

HQ_ROOT="${HQ_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
THREADS_DIR="$HQ_ROOT/workspace/threads"
LOCKS_DIR="$THREADS_DIR/resume-locks"
STALE_SECONDS="${HQ_RESUME_LOCK_STALE_SECONDS:-86400}"
REPLACE_CLAIM_STALE_SECONDS="${HQ_RESUME_REPLACE_CLAIM_STALE_SECONDS:-60}"

usage() {
  cat <<'USAGE'
usage:
  resume-thread-lock.sh inspect <thread-id>
  resume-thread-lock.sh acquire <thread-id> --session-id <session-id>
  resume-thread-lock.sh acquire <thread-id> --replace --expected-generation <generation> --session-id <session-id>
USAGE
}

fail_usage() {
  echo "resume-thread-lock: $*" >&2
  usage >&2
  exit 2
}

command -v jq >/dev/null 2>&1 || {
  echo "resume-thread-lock: jq is required" >&2
  exit 1
}

[[ "$STALE_SECONDS" =~ ^[0-9]+$ ]] || fail_usage "HQ_RESUME_LOCK_STALE_SECONDS must be a non-negative integer"
[[ "$REPLACE_CLAIM_STALE_SECONDS" =~ ^[0-9]+$ ]] || fail_usage "HQ_RESUME_REPLACE_CLAIM_STALE_SECONDS must be a non-negative integer"

subcommand="${1:-}"
shift || true

thread_id="${1:-}"
shift || true
[[ "$thread_id" =~ ^T-[A-Za-z0-9][A-Za-z0-9_-]*$ ]] || fail_usage "thread id must be a canonical T-* id"

replace="false"
session_id=""
expected_generation=""
expected_generation_set="false"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --replace)
      replace="true"
      shift
      ;;
    --session-id)
      [[ $# -ge 2 ]] || fail_usage "--session-id requires a value"
      session_id="$2"
      shift 2
      ;;
    --expected-generation)
      [[ $# -ge 2 ]] || fail_usage "--expected-generation requires a value"
      expected_generation="$2"
      expected_generation_set="true"
      shift 2
      ;;
    *)
      fail_usage "unknown argument: $1"
      ;;
  esac
done

case "$subcommand" in
  inspect)
    [[ "$replace" = "false" && -z "$session_id" ]] \
      || fail_usage "inspect takes only a thread id"
    ;;
  acquire)
    [[ -n "$session_id" ]] || fail_usage "acquire requires --session-id"
    if [[ "$replace" = "true" ]]; then
      [[ "$expected_generation_set" = "true" ]] || fail_usage "--replace requires --expected-generation from the inspected lock"
    else
      [[ "$expected_generation_set" = "false" ]] || fail_usage "--expected-generation is only valid with --replace"
    fi
    ;;
  *)
    fail_usage "expected inspect or acquire"
    ;;
esac

lock_dir="$LOCKS_DIR/$thread_id.lock"
record_path="$lock_dir/current.json"
replace_claim_dir="$lock_dir/.replace-claim"
relative_lock_path="workspace/threads/resume-locks/$thread_id.lock"

now_epoch() {
  date -u +%s
}

now_iso() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

claim_is_stale() {
  local claim_mtime current_epoch
  claim_mtime="$(stat -f %m "$replace_claim_dir" 2>/dev/null || stat -c %Y "$replace_claim_dir" 2>/dev/null || echo 0)"
  [[ "$claim_mtime" =~ ^[0-9]+$ ]] || return 1
  current_epoch="$(now_epoch)"
  (( current_epoch - claim_mtime > REPLACE_CLAIM_STALE_SECONDS ))
}

acquire_replace_claim() {
  if mkdir "$replace_claim_dir" 2>/dev/null; then
    return 0
  fi

  # A killed process can leave an empty claim directory behind. Recover only a
  # demonstrably stale claim, and only with rmdir so an unexpected payload is
  # never removed.
  if [[ -d "$replace_claim_dir" ]] && claim_is_stale; then
    rmdir "$replace_claim_dir" 2>/dev/null || true
    mkdir "$replace_claim_dir" 2>/dev/null && return 0
  fi

  return 1
}

emit_unlocked() {
  jq -cn \
    --arg thread_id "$thread_id" \
    --arg lock_path "$relative_lock_path" \
    '{status:"unlocked", thread_id:$thread_id, lock_path:$lock_path}'
}

emit_stale() {
  local reason="$1" owner_session="$2" resumed_at="$3" generation="$4"
  local prompt="This thread was already resumed by ${owner_session} at ${resumed_at}. Its lock is stale (${reason}). Re-resume anyway?"
  jq -cn \
    --arg thread_id "$thread_id" \
    --arg lock_path "$relative_lock_path" \
    --arg stale_reason "$reason" \
    --arg session_id "$owner_session" \
    --arg resumed_at "$resumed_at" \
    --arg lock_generation "$generation" \
    --arg prompt "$prompt" \
    '{status:"stale", thread_id:$thread_id, lock_path:$lock_path, stale_reason:$stale_reason, session_id:$session_id, resumed_at:$resumed_at, lock_generation:$lock_generation, prompt:$prompt}'
}

emit_locked() {
  local owner_session="$1" resumed_at="$2" generation="$3"
  local prompt="This thread was already resumed by ${owner_session} at ${resumed_at}. Re-resume anyway?"
  jq -cn \
    --arg thread_id "$thread_id" \
    --arg lock_path "$relative_lock_path" \
    --arg session_id "$owner_session" \
    --arg resumed_at "$resumed_at" \
    --arg lock_generation "$generation" \
    --arg prompt "$prompt" \
    '{status:"locked", thread_id:$thread_id, lock_path:$lock_path, session_id:$session_id, resumed_at:$resumed_at, lock_generation:$lock_generation, prompt:$prompt}'
}

# Print the existing lock's state. A damaged or expired marker is deliberately
# not removed: it is still evidence that this handoff was resumed and must pass
# through the same explicit re-resume confirmation as a fresh marker.
existing_state() {
  if [[ ! -d "$lock_dir" ]]; then
    if [[ -e "$lock_dir" ]]; then
      emit_stale "invalid-lock-path" "unknown session" "unknown time" ""
    else
      emit_unlocked
    fi
    return
  fi

  if [[ ! -f "$record_path" ]]; then
    emit_stale "missing-record" "unknown session" "unknown time" ""
    return
  fi

  if ! jq -e '
    .version == 1
    and (.thread_id | type == "string" and length > 0)
    and (.session_id | type == "string" and length > 0)
    and (.resumed_at | type == "string" and length > 0)
    and (.resumed_epoch | type == "number")
    and (.generation | type == "string" and length > 0)
  ' "$record_path" >/dev/null 2>&1; then
    emit_stale "invalid-record" "unknown session" "unknown time" ""
    return
  fi

  local record_thread record_session record_at record_epoch record_generation current_epoch
  record_thread="$(jq -r '.thread_id' "$record_path")"
  record_session="$(jq -r '.session_id' "$record_path")"
  record_at="$(jq -r '.resumed_at' "$record_path")"
  record_epoch="$(jq -r '.resumed_epoch' "$record_path")"
  record_generation="$(jq -r '.generation' "$record_path")"

  if [[ "$record_thread" != "$thread_id" || ! "$record_epoch" =~ ^[0-9]+$ ]]; then
    emit_stale "invalid-record" "$record_session" "$record_at" "$record_generation"
    return
  fi

  current_epoch="$(now_epoch)"
  if (( current_epoch - record_epoch > STALE_SECONDS )); then
    emit_stale "expired" "$record_session" "$record_at" "$record_generation"
    return
  fi

  emit_locked "$record_session" "$record_at" "$record_generation"
}

write_record() {
  local record_dir="$1" epoch timestamp tmp generation
  epoch="$(now_epoch)"
  timestamp="$(now_iso)"
  tmp="$(mktemp "$record_dir/.current.XXXXXX")"
  generation="$(basename "$tmp")"
  jq -cn \
    --arg thread_id "$thread_id" \
    --arg session_id "$session_id" \
    --arg resumed_at "$timestamp" \
    --arg generation "$generation" \
    --argjson resumed_epoch "$epoch" \
    '{version:1, thread_id:$thread_id, session_id:$session_id, resumed_at:$resumed_at, resumed_epoch:$resumed_epoch, generation:$generation}' \
    > "$tmp"
  mv -f "$tmp" "$record_path"
  WRITTEN_GENERATION="$generation"
}

emit_acquired() {
  local generation="$1"
  jq -cn \
    --arg thread_id "$thread_id" \
    --arg lock_path "$relative_lock_path" \
    --arg session_id "$session_id" \
    --arg lock_generation "$generation" \
    '{status:"acquired", thread_id:$thread_id, lock_path:$lock_path, session_id:$session_id, lock_generation:$lock_generation}'
}

case "$subcommand" in
  inspect)
    existing_state
    ;;
  acquire)
    mkdir -p "$LOCKS_DIR"
    if mkdir "$lock_dir" 2>/dev/null; then
      write_record "$lock_dir"
      emit_acquired "$WRITTEN_GENERATION"
      exit 0
    fi

    if [[ "$replace" != "true" ]]; then
      existing_state
      exit 3
    fi

    [[ -d "$lock_dir" ]] || {
      echo "resume-thread-lock: cannot refresh non-directory lock path: $relative_lock_path" >&2
      exit 1
    }
    if ! acquire_replace_claim; then
      existing_state
      exit 4
    fi
    trap 'rmdir "$replace_claim_dir" 2>/dev/null || true' EXIT
    current_state="$(existing_state)"
    current_generation="$(jq -r '.lock_generation // ""' <<<"$current_state")"
    if [[ "$current_generation" != "$expected_generation" ]]; then
      printf '%s\n' "$current_state"
      exit 4
    fi
    write_record "$lock_dir"
    emit_acquired "$WRITTEN_GENERATION"
    ;;
esac
