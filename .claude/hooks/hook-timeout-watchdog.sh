#!/usr/bin/env bash
# Best-effort early warning for hooks that are close to their harness timeout.
#
# This process is always launched in the background by the dispatchers. It is
# intentionally self-contained: neither its stdout nor stderr can affect hook
# semantics, and every reporting failure is ignored by the caller.

set -u

DEFAULT_TIMEOUT_SECONDS=30
DEFAULT_GATE_LEAD_SECONDS=10
DEFAULT_MASTER_LEAD_SECONDS=20
DEFAULT_MASTER_ABSOLUTE_SECONDS=120
DEFAULT_THROTTLE_SECONDS=900

root=""
source_kind=""
hook_path=""
hook_id=""
event_name=""
started_at=""
parent_pid=""
invocation_id=""
sleep_pid=""
lock_dir=""
report_done_file=""
threshold_kind="relative"
test_trigger_file="${HQ_HOOK_TIMEOUT_SENTRY_TEST_TRIGGER_FILE:-}"
test_lock_ready_file="${HQ_HOOK_TIMEOUT_SENTRY_TEST_LOCK_READY_FILE:-}"

usage() {
  exit 0
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --root) root="${2:-}"; shift 2 ;;
    --source) source_kind="${2:-}"; shift 2 ;;
    --hook-path) hook_path="${2:-}"; shift 2 ;;
    --hook-id) hook_id="${2:-}"; shift 2 ;;
    --event) event_name="${2:-}"; shift 2 ;;
    --started-at) started_at="${2:-}"; shift 2 ;;
    --parent-pid) parent_pid="${2:-}"; shift 2 ;;
    --invocation-id) invocation_id="${2:-}"; shift 2 ;;
    --threshold) threshold_kind="${2:-}"; shift 2 ;;
    *) usage ;;
  esac
done

is_nonnegative_integer() {
  [[ "${1:-}" =~ ^[0-9]+$ ]]
}

timing_precision_value() {
  local candidate=""
  [ -n "${EPOCHREALTIME:-}" ] && { printf 'ms'; return; }
  candidate="$(date +%s%3N 2>/dev/null || true)"
  if [[ "$candidate" =~ ^[0-9]+$ ]] && [ "${#candidate}" -gt 10 ]; then
    printf 'ms'
    return
  fi
  if command -v perl >/dev/null 2>&1; then
    candidate="$(perl -MTime::HiRes=time -e 'printf "%.0f", time() * 1000' 2>/dev/null || true)"
    if [[ "$candidate" =~ ^[0-9]+$ ]]; then
      printf 'ms'
      return
    fi
  fi
  printf 's'
}

now_ms() {
  local realtime seconds fraction now
  realtime="${EPOCHREALTIME:-}"
  if [ -n "$realtime" ]; then
    seconds="${realtime%%.*}"
    fraction="${realtime#*.}"
    fraction="${fraction}000"
    fraction="${fraction:0:3}"
    if [[ "$seconds" =~ ^[0-9]+$ ]] && [[ "$fraction" =~ ^[0-9]{3}$ ]]; then
      printf '%s%s' "$seconds" "$fraction"
      return 0
    fi
  fi
  now="$(date +%s%3N 2>/dev/null || true)"
  if [[ "$now" =~ ^[0-9]+$ ]] && [ "${#now}" -gt 10 ]; then
    printf '%s' "$now"
    return 0
  fi
  if command -v perl >/dev/null 2>&1; then
    now="$(perl -MTime::HiRes=time -e 'printf "%.0f", time() * 1000' 2>/dev/null || true)"
    if [[ "$now" =~ ^[0-9]+$ ]]; then
      printf '%s' "$now"
      return 0
    fi
  fi
  now="$(date +%s 2>/dev/null || printf '0')"
  [[ "$now" =~ ^[0-9]+$ ]] || now=0
  printf '%s000' "$now"
}

is_timeout_watchdog_disabled() {
  local entry remaining
  remaining="${HQ_DISABLED_HOOKS:-}"
  while [ -n "$remaining" ]; do
    case "$remaining" in
      *,*) entry="${remaining%%,*}"; remaining="${remaining#*,}" ;;
      *) entry="$remaining"; remaining="" ;;
    esac
    entry="${entry#"${entry%%[![:space:]]*}"}"
    entry="${entry%"${entry##*[![:space:]]}"}"
    [ "$entry" = "hook-timeout-sentry" ] && return 0
  done
  return 1
}

is_enabled() {
  case "${HQ_HOOK_TIMEOUT_SENTRY:-1}" in
    0|false|FALSE|no|NO|off|OFF) return 1 ;;
  esac
  is_timeout_watchdog_disabled && return 1
  return 0
}

# Produce a collision-resistant opaque filename component. These records cross
# hook fires and must never associate one session's breadcrumb with another.
sha256_fields() {
  if command -v shasum >/dev/null 2>&1; then
    printf '%s\0' "$@" | shasum -a 256 2>/dev/null | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    printf '%s\0' "$@" | sha256sum 2>/dev/null | awk '{print $1}'
  elif command -v openssl >/dev/null 2>&1; then
    printf '%s\0' "$@" | openssl dgst -sha256 2>/dev/null | awk '{print $NF}'
  fi
}

# The fingerprint is a grouping key, so it must not contain an installation-
# specific absolute path. Normalize only the spellings that can change the
# lexical root boundary; diagnostics retain the original hook_path unchanged.
normalize_fingerprint_path() {
  local path="$1" original="$1" normalized
  while [ "${path#./}" != "$path" ]; do
    path="${path#./}"
  done
  while :; do
    normalized="${path//\/\.\//\/}"
    [ "$normalized" = "$path" ] && break
    path="$normalized"
  done
  while [ "$path" != "/" ] && [ "${path%/}" != "$path" ]; do
    path="${path%/}"
  done
  [ -n "$path" ] || [ -z "$original" ] || path="."
  printf '%s' "$path"
}

hook_fingerprint_identity() {
  local normalized_root normalized_hook relative_path=""
  normalized_root="$(normalize_fingerprint_path "$root")"
  normalized_hook="$(normalize_fingerprint_path "$hook_path")"

  case "$normalized_root" in
    "") ;;
    "/")
      case "$normalized_hook" in
        /*) relative_path="${normalized_hook#/}" ;;
      esac
      ;;
    ".")
      case "$normalized_hook" in
        /*) ;;
        *) relative_path="$normalized_hook" ;;
      esac
      ;;
    *)
      case "$normalized_hook" in
        "$normalized_root"/*) relative_path="${normalized_hook#"$normalized_root"/}" ;;
      esac
      ;;
  esac

  if [ -n "$relative_path" ]; then
    normalize_fingerprint_path "$relative_path"
  else
    basename "$normalized_hook"
  fi
}

# shellcheck disable=SC2329 # Invoked by TERM/INT/HUP traps below.
cleanup() {
  # Dispatchers may send a direct signal and a process-group signal in quick
  # succession. Ignore the second one while releasing the throttle lock;
  # restoring the default disposition here could kill this cleanup mid-rmdir.
  trap '' TERM INT HUP
  [ -z "$sleep_pid" ] || kill "$sleep_pid" >/dev/null 2>&1 || true
  [ -z "$sleep_pid" ] || wait "$sleep_pid" >/dev/null 2>&1 || true
  [ -z "$lock_dir" ] || rmdir "$lock_dir" >/dev/null 2>&1 || true
  lock_dir=""
  exit 0
}

trap cleanup TERM INT HUP

is_enabled || exit 0
[ -n "$root" ] && [ -n "$source_kind" ] && [ -n "$hook_path" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0

# The behavioral suite supplies a targeted trigger rather than racing this
# worker against wall-clock sleeps on a loaded CI host. It is deliberately
# inert unless that test-only environment variable is present. Match the three
# fields separately so a dispatcher trigger cannot accidentally release one of
# its child watchdogs (or vice versa).
test_triggered() {
  [ -n "$test_trigger_file" ] && [ -f "$test_trigger_file" ] || return 1
  awk -F '\t' -v source="$source_kind" -v hook="$hook_path" -v threshold="$threshold_kind" '
    $1 == source && $2 == hook && $3 == threshold { found = 1; exit }
    END { exit(found ? 0 : 1) }
  ' "$test_trigger_file" >/dev/null 2>&1
}

wait_for_test_trigger() {
  while ! test_triggered; do
    # Fast gated hooks should let their dispatcher cancel this worker rather
    # than leaving it to poll until a test harness removes its temporary tree.
    if [ "$source_kind" = "hook-gate" ] \
      && is_nonnegative_integer "$parent_pid" \
      && ! kill -0 "$parent_pid" >/dev/null 2>&1; then
      return 1
    fi
    sleep 0.02 >/dev/null 2>&1 &
    sleep_pid=$!
    wait "$sleep_pid" >/dev/null 2>&1 || return 1
    sleep_pid=""
  done
  return 0
}

# A test-only rendezvous holds the throttle lock until the dispatcher cancels
# this worker. It makes lock cleanup observable without relying on scheduler
# timing. Production never sets this variable.
hold_test_lock() {
  [ -n "$test_lock_ready_file" ] || return 0
  : > "$test_lock_ready_file" 2>/dev/null || true
  while :; do
    sleep 0.02 >/dev/null 2>&1 &
    sleep_pid=$!
    wait "$sleep_pid" >/dev/null 2>&1 || return 0
    sleep_pid=""
  done
}

# Make cancellation cheap: almost every hook completes before this one-second
# grace sleep. Configuration parsing and payload metadata extraction happen
# only after it, so the foreground dispatcher need only signal and reap a
# sleeping process. The eventual warning still uses the original start time.
if [ -n "$test_trigger_file" ]; then
  wait_for_test_trigger || exit 0
else
  sleep 1 >/dev/null 2>&1 &
  sleep_pid=$!
  wait "$sleep_pid" >/dev/null 2>&1 || exit 0
  sleep_pid=""
fi

# Read only to derive the explicitly allowed event/session/tool metadata. The
# payload is never written, forwarded, logged, or included in the report.
input="$(cat 2>/dev/null || true)"
metadata="$(jq -c '
  {
    event: (.hook_event_name // .hookEventName // ""),
    tool: (.tool_name // .toolName // ""),
    session: (.session_id // .sessionId // ""),
    cwd: (.cwd // "")
  }
  | with_entries(if (.value | type) == "string" then . else .value = "" end)
' <<<"$input" 2>/dev/null || true)"
input=""

if [ -n "$metadata" ]; then
  payload_event="$(jq -r '.event' <<<"$metadata" 2>/dev/null || true)"
  tool_name="$(jq -r '.tool' <<<"$metadata" 2>/dev/null || true)"
  session_id="$(jq -r '.session' <<<"$metadata" 2>/dev/null || true)"
else
  payload_event=""
  tool_name=""
  session_id=""
  cwd=""
fi
[ -n "$event_name" ] || event_name="$payload_event"
[ -n "$event_name" ] || event_name="unknown"
[ -n "$tool_name" ] || tool_name="unknown"
[ -n "$session_id" ] || session_id="unknown"
if [ -n "$metadata" ]; then
  cwd="$(jq -r '.cwd' <<<"$metadata" 2>/dev/null || true)"
fi

# Bound caller-derived scalar strings before passing them to the CLI's strict
# metadata allowlist. These values are metadata only; no hook payload values are
# ever retained after the parse above.
bounded() {
  printf '%s' "$1" | cut -c1-256
}
event_name="$(bounded "$event_name")"
tool_name="$(bounded "$tool_name")"
session_id="$(bounded "$session_id")"
cwd="$(bounded "$cwd")"
timing_precision="$(timing_precision_value)"

bash_env_state() {
  if [ -n "${BASH_ENV:-}" ]; then
    printf 'set'
  else
    printf 'unset'
  fi
}

shell_descriptor() {
  local shell_name="${BASH:-bash}" shell_version="${BASH_VERSION:-unknown}"
  # Git Bash on Windows can expose SHELL with backslash separators. Normalize
  # those separators before taking the basename so the descriptor remains a
  # bounded shell label on every supported host.
  shell_name="${shell_name//\\//}"
  shell_name="${shell_name##*/}"
  case "$shell_name" in
    *[!A-Za-z0-9._+-]*|'') shell_name="unknown" ;;
  esac
  printf '%s %s' "$shell_name" "$shell_version"
}

normalize_cwd_path() {
  local value="$1" os drive converted
  value="${value//\\//}"
  os="$(uname -s 2>/dev/null || printf 'unknown')"
  case "$os" in
    MINGW*|MSYS*|CYGWIN*)
      if command -v cygpath >/dev/null 2>&1; then
        converted="$(cygpath -u "$value" 2>/dev/null || true)"
        [ -n "$converted" ] && value="$converted"
      fi
      case "$value" in
        /[A-Za-z]/*)
          drive="${value:1:1}"
          value="$drive:${value:2}"
          ;;
      esac
      value="$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]')"
      ;;
  esac
  while [ "$value" != "/" ] && [ "${value%/}" != "$value" ]; do
    value="${value%/}"
  done
  printf '%s' "$value"
}

cwd_kind() {
  local cwd_root cwd_value
  cwd_root="$(normalize_cwd_path "$root")"
  cwd_value="$(normalize_cwd_path "$cwd")"
  case "$cwd_value" in
    "$cwd_root") printf 'hq-root' ;;
    "$cwd_root/repos/public/"*|"$cwd_root/repos/private/"*) printf 'repo' ;;
    "$cwd_root/workspace/worktrees/"*) printf 'worktree' ;;
    *) printf 'other' ;;
  esac
}

nproc_value() {
  local result=""
  if command -v getconf >/dev/null 2>&1; then
    result="$(getconf _NPROCESSORS_ONLN 2>/dev/null || true)"
  fi
  if ! is_nonnegative_integer "$result" || [ "$result" -lt 1 ]; then
    if command -v sysctl >/dev/null 2>&1; then
      result="$(sysctl -n hw.ncpu 2>/dev/null || true)"
    fi
  fi
  if ! is_nonnegative_integer "$result" || [ "$result" -lt 1 ]; then
    result=1
  fi
  printf '%s' "$result"
}

hook_name="$(basename "$hook_path")"

safe_hook_script() {
  local value="$hook_name"
  case "$value" in
    ''|*[!A-Za-z0-9._-]*) printf 'unknown' ;;
    *) value="${value:0:128}"; printf '%s' "$value" ;;
  esac
}

hook_sequence_json() {
  local session_hash journal_file sequence
  session_hash="$(sha256_fields "$session_id")"
  [ -n "$session_hash" ] || { printf '[]'; return; }
  journal_file="$root/workspace/.hook-timeout-journal/$session_hash.tsv"
  [ -f "$journal_file" ] || { printf '[]'; return; }
  sequence="$(tail -n 20 "$journal_file" 2>/dev/null | jq -Rsc '
    split("\n")
    | map(select(length > 0) | split("\t")
      | select(length == 3)
      | {script: .[0], event: .[1], ms: (.[2] | tonumber)})
  ' 2>/dev/null || true)"
  if [ -n "$sequence" ]; then
    printf '%s' "$sequence"
  else
    printf '[]'
  fi
}

policy_trigger_metadata_json() {
  local session_hash journal_file metadata_file key value
  local trigger_script="" trigger_event="" ledger_bucket="" facts_bucket=""
  journal_file="${HQ_HOOK_TIMEOUT_JOURNAL_FILE:-}"
  if [ -z "$journal_file" ]; then
    [ -d "$root/workspace/.hook-timeout-journal" ] || { printf '{}'; return; }
    session_hash="$(sha256_fields "$session_id")"
    [ -n "$session_hash" ] || { printf '{}'; return; }
    journal_file="$root/workspace/.hook-timeout-journal/$session_hash.tsv"
  fi
  metadata_file="$journal_file.meta"
  [ -f "$metadata_file" ] || { printf '{}'; return; }
  while IFS='=' read -r key value; do
    case "$key" in
      policy_trigger_script) trigger_script="$value" ;;
      policy_trigger_event) trigger_event="$value" ;;
      ledger_bytes_bucket) ledger_bucket="$value" ;;
      facts_bytes_bucket) facts_bucket="$value" ;;
    esac
  done < "$metadata_file"
  [ "$trigger_script" = "inject-policy-on-trigger.sh" ] || { printf '{}'; return; }
  case "$ledger_bucket" in '<16K'|'16-64K'|'64-128K'|'>128K') ;; *) printf '{}'; return ;; esac
  case "$facts_bucket" in '<16K'|'16-64K'|'64-128K'|'>128K') ;; *) printf '{}'; return ;; esac
  jq -cn \
    --arg script "$trigger_script" \
    --arg event "$trigger_event" \
    --arg ledger "$ledger_bucket" \
    --arg facts "$facts_bucket" \
    '{policy_trigger_script: $script, policy_trigger_event: $event, ledger_bytes_bucket: $ledger, facts_bytes_bucket: $facts}'
}

resolve_claude_timeout() {
  local result=""
  case "$source_kind" in
    hook-gate)
      result="$(jq -r --arg event "$event_name" --arg hook_id "$hook_id" --arg hook_name "$hook_name" '
        [
          .hooks[$event][]?.hooks[]?
          | select(.type == "command")
          | (.command // "") as $command
          | select($command | contains("hook-gate.sh"))
          | ($command | try capture("hook-gate\\.sh\\\"[[:space:]]+(?<id>[^[:space:]]+)[[:space:]]+\\\"[^\\\"]*/(?<file>[^/\\\"]+)\\\"") catch null) as $parts
          | select($parts != null and $parts.id == $hook_id and $parts.file == $hook_name)
          | .timeout
        ]
        | map(select(type == "number" and . >= 1))
        | unique
        | if length == 1 then .[0] else empty end
      ' "$root/.claude/settings.json" 2>/dev/null || true)"
      # Gated hooks now live in hook-registry.json (dispatched by master-hook);
      # a directly-invoked gate (adapter fallback, local settings, tests) finds
      # its declared timeout there when settings.json no longer carries it.
      if [ -z "$result" ] && [ -f "$root/.claude/hooks/hook-registry.json" ]; then
        result="$(jq -r --arg event "$event_name" --arg hook_id "$hook_id" --arg hook_name "$hook_name" '
          [
            .hooks[$event][]?.hooks[]?
            | select(.id == $hook_id and ((.script // "") | endswith("/" + $hook_name)))
            | .timeout
          ]
          | map(select(type == "number" and . >= 1))
          | unique
          | if length == 1 then .[0] else empty end
        ' "$root/.claude/hooks/hook-registry.json" 2>/dev/null || true)"
      fi
      ;;
    master-dispatch|master-child)
      result="$(jq -r --arg event "$event_name" '
        [
          .hooks[$event][]?.hooks[]?
          | select(.type == "command" and ((.command // "") | contains("master-hook.sh")))
          | .timeout
        ]
        | map(select(type == "number" and . >= 1))
        | unique
        | if length == 1 then .[0] else empty end
      ' "$root/.claude/settings.json" 2>/dev/null || true)"
      ;;
  esac
  printf '%s' "$result"
}

resolve_codex_timeout() {
  local config="$root/.codex/config.toml"
  [ -f "$config" ] || return 0
  awk -v event="$event_name" '
    $0 == "[[hooks." event ".hooks]]" { in_event = 1; next }
    in_event && /^\[\[hooks\./ { exit }
    in_event && /^[[:space:]]*timeout[[:space:]]*=/ {
      sub(/^[^=]*=[[:space:]]*/, "")
      sub(/[[:space:]]*(#.*)?$/, "")
      if ($0 ~ /^[0-9]+$/) print
      exit
    }
  ' "$config" 2>/dev/null || true
}

resolve_grok_timeout() {
  local config="$root/.grok/hooks/hq-grok-user-bridge.json"
  [ -f "$config" ] || return 0
  jq -r --arg event "$event_name" '
    [
      .hooks[$event][]?.hooks[]?
      | .timeout
    ]
    | map(select(type == "number" and . >= 1))
    | unique
    | if length == 1 then .[0] else empty end
  ' "$config" 2>/dev/null || true
}

resolve_timeout() {
  local harness result=""
  harness="$(printf '%s' "${HQ_HARNESS:-claude}" | tr '[:upper:]' '[:lower:]')"
  case "$harness" in
    ''|claude) result="$(resolve_claude_timeout)" ;;
    codex) result="$(resolve_codex_timeout)" ;;
    grok) result="$(resolve_grok_timeout)" ;;
  esac
  if is_nonnegative_integer "$result" && [ "$result" -ge 1 ]; then
    printf '%s' "$result"
  else
    printf '%s' "$DEFAULT_TIMEOUT_SECONDS"
  fi
}

declared_timeout="$(resolve_timeout)"
case "$source_kind" in
  master-dispatch|master-child)
    case "$threshold_kind" in
      absolute)
        absolute_seconds="${HQ_HOOK_TIMEOUT_MASTER_ABSOLUTE_SECONDS:-$DEFAULT_MASTER_ABSOLUTE_SECONDS}"
        is_nonnegative_integer "$absolute_seconds" || absolute_seconds="$DEFAULT_MASTER_ABSOLUTE_SECONDS"
        lead_seconds="${HQ_HOOK_TIMEOUT_MASTER_WARN_LEAD_SECONDS:-$DEFAULT_MASTER_LEAD_SECONDS}"
        is_nonnegative_integer "$lead_seconds" || lead_seconds="$DEFAULT_MASTER_LEAD_SECONDS"
        latest_safe_warning=$((declared_timeout - lead_seconds))
        [ "$latest_safe_warning" -ge 0 ] || latest_safe_warning=0
        [ "$absolute_seconds" -le "$latest_safe_warning" ] || absolute_seconds="$latest_safe_warning"
        watchdog_timeout_seconds="$absolute_seconds"
        ;;
      relative)
        lead_seconds="${HQ_HOOK_TIMEOUT_MASTER_WARN_LEAD_SECONDS:-$DEFAULT_MASTER_LEAD_SECONDS}"
        is_nonnegative_integer "$lead_seconds" || lead_seconds="$DEFAULT_MASTER_LEAD_SECONDS"
        watchdog_timeout_seconds=$((declared_timeout - lead_seconds))
        [ "$watchdog_timeout_seconds" -ge 0 ] || watchdog_timeout_seconds=0
        ;;
      *) exit 0 ;;
    esac
    ;;
  *)
    lead_seconds="${HQ_HOOK_TIMEOUT_SENTRY_LEAD_SECONDS:-$DEFAULT_GATE_LEAD_SECONDS}"
    is_nonnegative_integer "$lead_seconds" || lead_seconds="$DEFAULT_GATE_LEAD_SECONDS"
    watchdog_timeout_seconds=$((declared_timeout - lead_seconds))
    [ "$watchdog_timeout_seconds" -ge 0 ] || watchdog_timeout_seconds=0
    ;;
esac
throttle_seconds="${HQ_HOOK_TIMEOUT_SENTRY_THROTTLE_SECONDS:-$DEFAULT_THROTTLE_SECONDS}"
is_nonnegative_integer "$throttle_seconds" || throttle_seconds="$DEFAULT_THROTTLE_SECONDS"

now_seconds="$(date +%s 2>/dev/null || printf '0')"
is_nonnegative_integer "$now_seconds" || now_seconds=0
# Gate launches intentionally omit this timestamp to avoid a foreground process
# on every fast hook. Sampling after the one-second grace can make its warning
# at most one second late, while keeping the configured lead approximate.
is_nonnegative_integer "$started_at" || started_at="$now_seconds"
# Recompute the threshold after normalizing a missing start timestamp.
case "$source_kind:$threshold_kind" in
  master-dispatch:absolute|master-child:absolute)
    warning_at=$((started_at + watchdog_timeout_seconds))
    ;;
  master-dispatch:relative|master-child:relative)
    warning_at=$((started_at + declared_timeout - lead_seconds))
    ;;
  *) warning_at=$((started_at + declared_timeout - lead_seconds)) ;;
esac
wait_seconds=$((warning_at - now_seconds))
[ "$wait_seconds" -ge 0 ] || wait_seconds=0

if [ -z "$test_trigger_file" ]; then
  sleep "$wait_seconds" >/dev/null 2>&1 &
  sleep_pid=$!
  wait "$sleep_pid" >/dev/null 2>&1 || exit 0
  sleep_pid=""
fi

# Do not create a late report or breadcrumb after any dispatcher died before
# the warning threshold. A breadcrumb already written before a genuine harness
# kill remains durable for the next delivering event; this guard runs before
# every write, so it cannot consume or erase that evidence.
if is_nonnegative_integer "$parent_pid" \
  && ! kill -0 "$parent_pid" >/dev/null 2>&1; then
  exit 0
fi

warning_seconds="$(date +%s 2>/dev/null || printf '%s' "$now_seconds")"
is_nonnegative_integer "$warning_seconds" || warning_seconds="$now_seconds"
warning_now_ms="$(now_ms)"
started_at_ms=$((started_at * 1000))
elapsed_ms=$((warning_now_ms - started_at_ms))
[ "$elapsed_ms" -ge 0 ] || elapsed_ms=0
remaining_ms=$((started_at_ms + declared_timeout * 1000 - warning_now_ms))
[ "$remaining_ms" -ge 0 ] || remaining_ms=0
[ "$watchdog_timeout_seconds" -ge 0 ] || watchdog_timeout_seconds=0
watchdog_timeout_ms=$((watchdog_timeout_seconds * 1000))
declared_timeout_ms=$((declared_timeout * 1000))

allow_warning() {
  local state_dir marker previous now hash
  state_dir="$root/workspace/.hook-timeout-sentry"
  mkdir -p "$state_dir" >/dev/null 2>&1 || return 1
  hash="$(sha256_fields "$session_id" "$hook_path" "$threshold_kind")"
  [ -n "$hash" ] || return 1
  marker="$state_dir/$hash"
  now="$warning_seconds"
  previous=""
  [ ! -f "$marker" ] || previous="$(cat "$marker" 2>/dev/null || true)"
  if is_nonnegative_integer "$previous" && [ $((now - previous)) -lt "$throttle_seconds" ]; then
    return 1
  fi
  lock_dir="$marker.lock"
  mkdir "$lock_dir" >/dev/null 2>&1 || { lock_dir=""; return 1; }
  hold_test_lock
  previous=""
  [ ! -f "$marker" ] || previous="$(cat "$marker" 2>/dev/null || true)"
  if is_nonnegative_integer "$previous" && [ $((now - previous)) -lt "$throttle_seconds" ]; then
    rmdir "$lock_dir" >/dev/null 2>&1 || true
    lock_dir=""
    return 1
  fi
  printf '%s\n' "$now" > "$marker" 2>/dev/null || {
    rmdir "$lock_dir" >/dev/null 2>&1 || true
    lock_dir=""
    return 1
  }
  rmdir "$lock_dir" >/dev/null 2>&1 || true
  lock_dir=""
  return 0
}

allow_warning || exit 0

write_master_breadcrumb() {
  local session_hash record_hash breadcrumb_dir temporary record
  session_hash="$(sha256_fields "$session_id")"
  record_hash="$(sha256_fields "$hook_path" "$threshold_kind" "$warning_seconds" "$$" "$invocation_id")"
  [ -n "$session_hash" ] && [ -n "$record_hash" ] || return 1
  breadcrumb_dir="$root/workspace/.hook-timeout-breadcrumbs/$session_hash"
  mkdir -p "$breadcrumb_dir" >/dev/null 2>&1 || return 1
  temporary="$breadcrumb_dir/.${record_hash}.$$.tmp"
  record="$breadcrumb_dir/${threshold_kind}-${record_hash}.json"
  report_done_file="$record.reported"
  rm -f "$report_done_file" >/dev/null 2>&1 || true
  jq -cn \
    --arg hook_path "$hook_path" \
    --arg hook_event "$event_name" \
    --arg threshold "$threshold_kind" \
    --arg invocation_id "$invocation_id" \
    --argjson elapsed_ms "$elapsed_ms" \
    --argjson declared_timeout_ms "$declared_timeout_ms" \
    '{hook_path: $hook_path, hook_event: $hook_event, threshold: $threshold, invocation_id: $invocation_id, elapsed_ms: $elapsed_ms, declared_timeout_ms: $declared_timeout_ms}' \
    > "$temporary" 2>/dev/null || { rm -f "$temporary"; return 1; }
  mv "$temporary" "$record" 2>/dev/null || { rm -f "$temporary"; return 1; }
  return 0
}

mark_report_done() {
  [ -n "$report_done_file" ] || return 0
  : > "$report_done_file" 2>/dev/null || true
}

case "$source_kind" in
  master-dispatch|master-child) write_master_breadcrumb || true ;;
esac

if ! command -v hq >/dev/null 2>&1; then
  mark_report_done
  exit 0
fi

load_average=""
if [ -r /proc/loadavg ]; then
  read -r load_one load_five load_fifteen _ < /proc/loadavg || true
  load_average="${load_one:-},${load_five:-},${load_fifteen:-}"
elif command -v sysctl >/dev/null 2>&1; then
  load_average="$(sysctl -n vm.loadavg 2>/dev/null || true)"
fi

hq_version="$(grep -E '^hqVersion:' "$root/core/core.yaml" 2>/dev/null | head -n 1 | tr -d ' "' | cut -d: -f2)"
[ -n "$hq_version" ] || hq_version="unknown"
platform="$(uname -s 2>/dev/null || printf 'unknown')"
hook_fingerprint_identity="$(hook_fingerprint_identity)"
hook_fingerprint_hash="$(sha256_fields "$hook_fingerprint_identity")"
[ -n "$hook_fingerprint_hash" ] || exit 0
bash_env_set="$(bash_env_state)"
shell_info="$(shell_descriptor)"
cwd_kind_value="$(cwd_kind)"
nproc_count="$(nproc_value)"
hook_sequence="$(hook_sequence_json)"
hook_script="$(safe_hook_script)"
policy_trigger_metadata='{}'
case "$hook_name" in
  inject-policy-on-trigger.sh)
    if [ -n "${HQ_HOOK_TIMEOUT_JOURNAL_FILE:-}" ] || [ -d "$root/workspace/.hook-timeout-journal" ]; then
      policy_trigger_metadata="$(policy_trigger_metadata_json)"
    fi
    ;;
esac

event_json="$(jq -cn \
  --arg type "hook_timeout_warning" \
  --arg message "HQ hook is approaching configured timeout" \
  --arg fingerprint "hook-timeout:$event_name:$hook_fingerprint_hash" \
  --arg level "warning" \
  --arg hook_name "$hook_name" \
  --arg hook_event "$event_name" \
  --arg tool_name "$tool_name" \
  --arg session_id "$session_id" \
  --arg hook_path "$hook_path" \
  --arg hq_version "$hq_version" \
  --arg platform "$platform" \
  --arg load_average "$load_average" \
  --arg bash_env_set "$bash_env_set" \
  --arg shell "$shell_info" \
  --arg cwd_kind "$cwd_kind_value" \
  --arg timing_precision "$timing_precision" \
  --arg hook_script "$hook_script" \
  --arg exit_code "running" \
  --argjson declared_timeout_ms "$declared_timeout_ms" \
  --argjson elapsed_ms "$elapsed_ms" \
  --argjson remaining_ms "$remaining_ms" \
  --argjson watchdog_timeout_ms "$watchdog_timeout_ms" \
  --argjson nproc "$nproc_count" \
  --argjson hook_sequence "$hook_sequence" '
    {
      type: $type,
      message: $message,
      fingerprint: $fingerprint,
      level: $level,
      metadata: {
        hook_name: $hook_name,
        hook_event: $hook_event,
        tool_name: $tool_name,
        session_id: $session_id,
        hook_path: $hook_path,
        declared_timeout_ms: $declared_timeout_ms,
        elapsed_ms: $elapsed_ms,
        remaining_ms: $remaining_ms,
        watchdog_timeout_ms: $watchdog_timeout_ms,
        hq_version: $hq_version,
        platform: $platform,
        load_average: $load_average,
        bash_env_set: $bash_env_set,
        shell: $shell,
        cwd_kind: $cwd_kind,
        timing_precision: $timing_precision,
        nproc: $nproc,
        hook_script: $hook_script,
        exit_code: $exit_code,
        hook_sequence: $hook_sequence
      }
    }
  ')" || { mark_report_done; exit 0; }

if [ "$policy_trigger_metadata" != '{}' ]; then
  event_json="$(jq -c --argjson policy_trigger "$policy_trigger_metadata" \
    '.metadata += $policy_trigger' <<<"$event_json")" || { mark_report_done; exit 0; }
fi

# `hq` is only invoked after the hook is already slow. Its public
# `--timeout-ms` contract bounds the send; the dispatcher cancels this worker's
# process session when the delegated hook exits, so this can never delay it.
hq core sentry report --timeout-ms 750 <<<"$event_json" >/dev/null 2>&1 || true
mark_report_done

# Keep the session leader alive until its dispatcher exits. This makes the
# dispatcher's unconditional process-group cancellation safe even if reporting
# completed just before the hook returned: the PID cannot be recycled into an
# unrelated process group in that window. A SIGKILLed dispatcher simply makes
# this loop finish on its next inexpensive poll.
if is_nonnegative_integer "$parent_pid"; then
  while kill -0 "$parent_pid" >/dev/null 2>&1; do
    sleep 1 >/dev/null 2>&1 &
    sleep_pid=$!
    wait "$sleep_pid" >/dev/null 2>&1 || exit 0
    sleep_pid=""
  done
fi
exit 0
