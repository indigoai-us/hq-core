#!/usr/bin/env bash
# Small, side-effect-free probes shared by the master dispatcher and watchdog.

hook_timeout_os_name() {
  case "${1:-}" in
    Linux|linux|linux-*) printf 'linux' ;;
    Darwin|darwin|darwin-*) printf 'macos' ;;
    MINGW*|MSYS*|CYGWIN*|Windows_NT*|mingw*|msys*|cygwin*|windows*) printf 'windows' ;;
    *) printf 'other' ;;
  esac
}

hook_timeout_load_average() {
  local platform="${1:-}" proc_file="${2:-/proc/loadavg}" sysctl_bin="${3:-sysctl}"
  local value="" token
  case "$(hook_timeout_os_name "$platform")" in
    linux)
      if [ -r "$proc_file" ]; then
        IFS=' ' read -r value _ < "$proc_file" || true
      fi
      ;;
    macos)
      if [ -x "$sysctl_bin" ] || command -v "$sysctl_bin" >/dev/null 2>&1; then
        value="$("$sysctl_bin" -n vm.loadavg 2>/dev/null || true)"
        for token in $value; do
          case "$token" in '{'|'}') continue ;; esac
          value="$token"
          break
        done
      fi
      ;;
    *) printf 'unavailable'; return 0 ;;
  esac
  if [[ "$value" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    printf '%s' "$value"
  else
    printf 'unavailable'
  fi
}

hook_timeout_now_ms() {
  local realtime seconds fraction now
  realtime="${EPOCHREALTIME:-}"
  if [ -n "$realtime" ]; then
    seconds="${realtime%%.*}"
    fraction="${realtime#*.}000"
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

# Milliseconds from a monotonic clock for phase and active-child durations.
# Linux and Git Bash expose uptime through procfs; macOS uses Perl's monotonic
# clock. A missing monotonic source produces no sample rather than a wall-clock
# duration that could move backwards.
hook_timeout_monotonic_ms() {
  local uptime seconds fraction now
  if [ -r /proc/uptime ]; then
    IFS=' ' read -r uptime _ < /proc/uptime || true
    seconds="${uptime%%.*}"
    fraction="${uptime#*.}000"
    fraction="${fraction:0:3}"
    if [[ "$seconds" =~ ^[0-9]+$ ]] && [[ "$fraction" =~ ^[0-9]{3}$ ]]; then
      printf '%s%s' "$seconds" "$fraction"
      return 0
    fi
  fi
  if command -v perl >/dev/null 2>&1; then
    now="$(perl -MTime::HiRes=clock_gettime,CLOCK_MONOTONIC -e 'printf "%.0f", clock_gettime(CLOCK_MONOTONIC) * 1000' 2>/dev/null || true)"
    if [[ "$now" =~ ^[0-9]+$ ]]; then
      printf '%s' "$now"
      return 0
    fi
  fi
  return 1
}

hook_timeout_normalize_phase() {
  case "${1:-}" in
    startup|source|config_load|policy_load|external_command|output_write|wait|child_wait|probe|parse)
      printf '%s' "$1"
      ;;
    *) printf 'other' ;;
  esac
}

# Read Bash's high-resolution clock without a command substitution or external
# process. Bash 3.2 does not expose EPOCHREALTIME, so those shells retain phase
# names but omit duration samples.
hook_timeout_realtime_ms() {
  local realtime seconds fraction
  HOOK_TIMEOUT_REALTIME_MS=""
  realtime="${EPOCHREALTIME:-}"
  case "$realtime" in *.*) ;; *) return 1 ;; esac
  seconds="${realtime%%.*}"
  fraction="${realtime#*.}000"
  fraction="${fraction:0:3}"
  [[ "$seconds" =~ ^[0-9]{1,12}$ ]] || return 1
  [[ "$fraction" =~ ^[0-9]{3}$ ]] || return 1
  HOOK_TIMEOUT_REALTIME_MS=$((10#$seconds * 1000 + 10#$fraction))
}

master_debug_phase_buffer_record() {
  local phase="$1" elapsed_ms="$2" i entry entry_phase entry_elapsed total
  case "$phase" in
    external_command)
      if [ "${#MASTER_DEBUG_PHASE_BUFFER[@]}" -ge 19 ]; then
        local -a recent=()
        for ((i = 1; i < ${#MASTER_DEBUG_PHASE_BUFFER[@]}; i++)); do
          recent+=("${MASTER_DEBUG_PHASE_BUFFER[$i]}")
        done
        MASTER_DEBUG_PHASE_BUFFER=("${recent[@]}")
      fi
      MASTER_DEBUG_PHASE_BUFFER+=("$phase"$'\t'"$elapsed_ms")
      ;;
    startup|source|config_load|policy_load|output_write)
      for i in "${!MASTER_DEBUG_PHASE_BUFFER[@]}"; do
        entry="${MASTER_DEBUG_PHASE_BUFFER[$i]}"
        entry_phase="${entry%%$'\t'*}"
        [ "$entry_phase" = "$phase" ] || continue
        entry_elapsed="${entry#*$'\t'}"
        total=$((entry_elapsed + elapsed_ms))
        MASTER_DEBUG_PHASE_BUFFER[$i]="$phase"$'\t'"$total"
        return 0
      done
      MASTER_DEBUG_PHASE_BUFFER+=("$phase"$'\t'"$elapsed_ms")
      ;;
  esac
}

master_debug_phase_write_state() {
  local phase="$1" started_ms="$2" completed="" entry entry_phase entry_elapsed
  [ -n "${MASTER_DEBUG_ACTIVE_PHASE_FILE:-}" ] || return 0
  for entry in ${MASTER_DEBUG_PHASE_BUFFER[@]+"${MASTER_DEBUG_PHASE_BUFFER[@]}"}; do
    entry_phase="${entry%%$'\t'*}"
    entry_elapsed="${entry#*$'\t'}"
    [[ "$entry_elapsed" =~ ^[0-9]{1,9}$ ]] || continue
    completed+="${completed:+,}$entry_phase:$entry_elapsed"
  done
  printf '%s\t%s\t%s\n' "$phase" "$started_ms" "$completed" \
    > "$MASTER_DEBUG_ACTIVE_PHASE_FILE" 2>/dev/null || true
}

master_debug_phase_start() {
  local phase="${1:-other}" started_ms
  case "$phase" in
    startup|source|config_load|policy_load|external_command|output_write|wait|child_wait|probe|parse) ;;
    *) phase=other ;;
  esac
  hook_timeout_realtime_ms || true
  started_ms="${HOOK_TIMEOUT_REALTIME_MS:-}"
  MASTER_DEBUG_ACTIVE_PHASE="$phase"
  MASTER_DEBUG_ACTIVE_STARTED="$started_ms"
  [[ "$started_ms" =~ ^[0-9]{1,16}$ ]] || started_ms=0
  master_debug_phase_write_state "$phase" "$started_ms"
}

master_debug_phase_finish() {
  local phase="${1:-other}" ended_ms elapsed_ms
  case "$phase" in
    startup|source|config_load|policy_load|external_command|output_write|wait|child_wait|probe|parse) ;;
    *) phase=other ;;
  esac
  hook_timeout_realtime_ms || true
  ended_ms="${HOOK_TIMEOUT_REALTIME_MS:-}"
  if [ "${MASTER_DEBUG_ACTIVE_PHASE:-}" = "$phase" ] \
    && [[ "${MASTER_DEBUG_ACTIVE_STARTED:-}" =~ ^[0-9]{1,16}$ ]] \
    && [[ "$ended_ms" =~ ^[0-9]{1,16}$ ]] \
    && [ "$ended_ms" -ge "$MASTER_DEBUG_ACTIVE_STARTED" ]; then
    elapsed_ms=$((ended_ms - MASTER_DEBUG_ACTIVE_STARTED))
    [ "$elapsed_ms" -le 86400000 ] || elapsed_ms=86400000
    master_debug_phase_buffer_record "$phase" "$elapsed_ms"
  fi
  MASTER_DEBUG_ACTIVE_PHASE=""
  MASTER_DEBUG_ACTIVE_STARTED=""
}

# Reuse the session journal directory and keep completed timings in shell
# variables. Only the current phase snapshot is written for the watchdog.
master_debug_initialize() {
  local root="${1:-}" invocation_id="${2:-}" debug_dir started_ms phase
  [ -n "$root" ] && [[ "$invocation_id" =~ ^[A-Za-z0-9._-]{1,128}$ ]] || return 0
  debug_dir="$root/workspace/.hook-timeout-journal"
  [ -d "$debug_dir" ] || return 0
  MASTER_DEBUG_PHASE_FILE="$debug_dir/$invocation_id.debug.tsv"
  MASTER_DEBUG_ACTIVE_PHASE_FILE="$MASTER_DEBUG_PHASE_FILE.active"
  # shellcheck disable=SC2034 # Master-hook and watchdog read this shared path.
  MASTER_DEBUG_CLI_VERSION_FILE="$MASTER_DEBUG_PHASE_FILE.cli-version"
  phase="${MASTER_DEBUG_ACTIVE_PHASE:-other}"
  started_ms="${MASTER_DEBUG_ACTIVE_STARTED:-0}"
  [[ "$started_ms" =~ ^[0-9]{1,16}$ ]] || started_ms=0
  master_debug_phase_write_state "$phase" "$started_ms"
}

hook_timeout_normalize_event() {
  case "${1:-}" in
    PreToolUse|PostToolUse|UserPromptSubmit|SessionStart|SessionEnd|Stop|PreCompact|Notification|PermissionRequest|SubagentStart|SubagentStop|TaskCompleted|TeammateIdle)
      printf '%s' "$1"
      ;;
    *) printf 'other' ;;
  esac
}

# Match only allowlisted basenames at the end of the first command token. This
# accepts a path with arguments while never returning its directory or args.
hook_timeout_normalize_basename() {
  local value="${1:-}" candidate
  for candidate in \
    master-hook.sh hook-gate.sh hook-timeout-watchdog.sh check-hq-update.sh \
    block-core-writes-bash.sh block-core-writes.sh block-hq-worktree-session.sh \
    inject-policy-on-trigger.sh inject-local-context.sh session-title.sh \
    45-lanes-senior-monitor.sh lanes-senior-monitor-stop-gate.sh reindex.sh \
    bash bash.exe sh cmd cmd.exe powershell powershell.exe wmic.exe jq jq.exe \
    node node.exe git git.exe python python.exe py"thon3" py"thon3.exe" true sleep \
    cat grep sed awk find timeout curl gh hq npm pnpm npx; do
    case "$value" in
      "$candidate"|"$candidate "*|*/"$candidate"|*/"$candidate "*|*\\"$candidate"|*\\"$candidate "*)
        printf '%s' "$candidate"
        return 0
        ;;
    esac
  done
  printf 'other'
}

hook_timeout_normalize_hook_name() {
  local name
  name="$(hook_timeout_normalize_basename "${1:-}")"
  case "$name" in
    master-hook.sh|hook-gate.sh|hook-timeout-watchdog.sh|check-hq-update.sh|\
    block-core-writes-bash.sh|block-core-writes.sh|block-hq-worktree-session.sh|\
    inject-policy-on-trigger.sh|inject-local-context.sh|session-title.sh|\
    45-lanes-senior-monitor.sh|lanes-senior-monitor-stop-gate.sh|reindex.sh)
      printf '%s' "$name"
      ;;
    *) printf 'other' ;;
  esac
}

hook_timeout_bounded_ms() {
  local value="${1:-}" allow_negative="${2:-no}" number
  if [ "$allow_negative" = yes ]; then
    [[ "$value" =~ ^-?[0-9]{1,9}$ ]] || { printf '0'; return; }
    number=$((value))
    [ "$number" -ge -86400000 ] && [ "$number" -le 86400000 ] || number=0
  else
    [[ "$value" =~ ^[0-9]{1,9}$ ]] || { printf '0'; return; }
    number=$((value))
    [ "$number" -le 86400000 ] || number=0
  fi
  printf '%s' "$number"
}

hook_timeout_phase_timings_json() {
  local completed_file="${1:-}" active_file="${2:-${1:-}}" active_record="" phase started completed now elapsed raw=""
  if [ -r "$completed_file" ]; then
    raw="$(awk -F '\t' '
      NF == 2 && $1 ~ /^(startup|source|config_load|policy_load|external_command|output_write|wait|child_wait|probe|parse|other)$/ && $2 ~ /^[0-9]+$/ && length($2) <= 9 && $2 <= 86400000 { print $1 "\t" $2 }
    ' "$completed_file" 2>/dev/null)"
  fi
  if [ -r "$active_file" ]; then
    active_record="$(awk -F '\t' 'NF >= 2 { print $1 "\t" $2 "\t" $3; exit }' "$active_file" 2>/dev/null || true)"
    IFS=$'\t' read -r phase started completed <<< "$active_record" || true
    completed="${completed//,/$'\n'}"
    completed="${completed//:/$'\t'}"
    raw="${raw:+$raw$'\n'}$completed"
    hook_timeout_realtime_ms || true
    now="${HOOK_TIMEOUT_REALTIME_MS:-}"
    if [ -n "$phase" ] && [[ "$started" =~ ^[0-9]{1,16}$ ]] && [ "$started" -gt 0 ] \
      && [[ "$now" =~ ^[0-9]{1,16}$ ]] && [ "$now" -ge "$started" ]; then
      elapsed=$((now - started))
      [ "$elapsed" -le 86400000 ] || elapsed=86400000
      raw="${raw:+$raw$'\n'}$phase$'\t'$elapsed"
    fi
  fi
  if [ -z "$raw" ]; then
    printf '[]\n'
    return 0
  fi
  printf '%s\n' "$raw" | jq -Rsc '
    split("\n")
    | map(select(length > 0) | split("\t")
      | select(length == 2 and (.[1] | test("^[0-9]{1,9}$")) and (.[1] | tonumber) <= 86400000)
      | {phase: (.[0] | if . == "startup" or . == "source" or . == "config_load" or . == "policy_load" or . == "external_command" or . == "output_write" or . == "wait" or . == "child_wait" or . == "probe" or . == "parse" then . else "other" end), elapsed_ms: (.[1] | tonumber)})
    | reduce .[] as $entry ({totals: {}, external: []};
        if $entry.phase == "external_command" then
          .external += [$entry.elapsed_ms]
        else
          .totals[$entry.phase] = ((.totals[$entry.phase] // 0) + $entry.elapsed_ms)
        end)
    | . as $records
    | (["startup", "source", "config_load", "policy_load", "output_write"]
      | map(. as $phase | {phase: $phase, elapsed_ms: ($records.totals[$phase] // 0)})) as $required
    | if $records.totals.other != null then
        $required + [{phase: "other", elapsed_ms: $records.totals.other}]
        + ($records.external[-18:] | map({phase: "external_command", elapsed_ms: .}))
      else
        $required + ($records.external[-19:] | map({phase: "external_command", elapsed_ms: .}))
      end
  ' 2>/dev/null || printf '[]'
}

hook_timeout_debug_context_json() {
  local hook_name hook_event budget elapsed remaining phases wait_point child child_elapsed
  local load_average spawn_ms process_count
  hook_name="$(hook_timeout_normalize_hook_name "${1:-}")"
  hook_event="$(hook_timeout_normalize_event "${2:-}")"
  budget="$(hook_timeout_bounded_ms "${3:-}")"
  elapsed="$(hook_timeout_bounded_ms "${4:-}")"
  remaining="$(hook_timeout_bounded_ms "${5:-}" yes)"
  phases="${6:-[]}"
  wait_point="$(hook_timeout_normalize_phase "${7:-wait}")"
  child="$(hook_timeout_normalize_basename "${8:-other}")"
  child_elapsed="$(hook_timeout_bounded_ms "${9:-0}")"
  load_average="${10:-unavailable}"
  spawn_ms="${11:-unavailable}"
  process_count="${12:-unavailable}"
  jq -cn \
    --arg hook_name "$hook_name" \
    --arg hook_event "$hook_event" \
    --arg budget "$budget" \
    --arg elapsed "$elapsed" \
    --arg remaining "$remaining" \
    --argjson phase_timings "$phases" \
    --arg wait_point "$wait_point" \
    --arg waiting_child_basename "$child" \
    --arg waiting_child_elapsed_ms "$child_elapsed" \
    --arg load_average "$load_average" \
    --arg spawn_ms "$spawn_ms" \
    --arg process_count "$process_count" '
      def bounded_metric($value):
        if ($value | test("^[0-9]+([.][0-9]+)?$")) and (($value | tonumber) <= 1000000)
        then ($value | tonumber) else "unavailable" end;
      def bounded_count($value):
        if ($value | test("^[0-9]{1,7}$")) and (($value | tonumber) <= 1000000)
        then ($value | tonumber) else "unavailable" end;
      {
        hook_name: $hook_name,
        hook_event: $hook_event,
        budget_ms: ($budget | tonumber),
        elapsed_ms: ($elapsed | tonumber),
        remaining_ms: ($remaining | tonumber),
        phase_timings: ($phase_timings | if type == "array" then .[-24:] else [] end),
        wait_point: $wait_point,
        waiting_child_basename: $waiting_child_basename,
        waiting_child_elapsed_ms: ($waiting_child_elapsed_ms | tonumber),
        load_average: bounded_metric($load_average),
        spawn_ms: bounded_metric($spawn_ms),
        process_count: bounded_count($process_count)
      }
    ' 2>/dev/null || printf '{}'
}

hook_timeout_attach_debug_context() {
  local report="${1:-}" context="${2:-}"
  [ -n "$report" ] && [ -n "$context" ] || { printf '%s' "$report"; return 0; }
  jq -cn --argjson report "$report" --argjson context "$context" '
    ($context.phase_timings // []) as $timings
    | [range(0; (($timings | length) + 1)) as $drop
      | ($report
        | .metadata.hook_timeout_debug_context = $context
        | .metadata.hook_timeout_debug_context.phase_timings = $timings[$drop:])
      | select((tojson | utf8bytelength) <= 2048)]
    | if length > 0 then .[0] else $report end
  ' 2>/dev/null || printf '%s' "$report"
}

hook_timeout_version_at_least() {
  local version="${1#v}" major minor patch
  [[ "$version" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,4})$ ]] || return 1
  major="${BASH_REMATCH[1]}"
  minor="${BASH_REMATCH[2]}"
  patch="${BASH_REMATCH[3]}"
  [ "$major" -gt 5 ] && return 0
  [ "$major" -lt 5 ] && return 1
  [ "$minor" -gt 183 ] && return 0
  [ "$minor" -lt 183 ] && return 1
  [ "$patch" -ge 0 ]
}

hook_timeout_extract_version_token() {
  local output="${1:-}"
  if [[ "$output" =~ (^|[^[:alnum:].])v?([0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,4})([^[:alnum:].-]|$) ]]; then
    printf '%s' "${BASH_REMATCH[2]}"
    return 0
  fi
  return 1
}

hook_timeout_cli_supports_debug_context() {
  local hq_bin="${1:-hq}" cache_file="${2:-}" platform="${3:-}" version="" temporary=""
  [ -n "$platform" ] || platform="$(uname -s 2>/dev/null || true)"
  if [ -n "$cache_file" ] && [ -r "$cache_file" ]; then
    IFS= read -r version < "$cache_file" || true
    version="$(hook_timeout_extract_version_token "$version" 2>/dev/null || true)"
    hook_timeout_version_at_least "$version"
    return $?
  fi
  if [ "$(hook_timeout_os_name "$platform")" = windows ]; then
    hook_timeout_has_gnu_timeout || return 1
  fi
  version="$(HQ_NO_UPDATE_CHECK=1 hook_timeout_run_bounded 2 "$hq_bin" --version 2>/dev/null || true)"
  version="${version//$'\r'/}"
  version="${version//$'\n'/}"
  [ "${#version}" -le 64 ] || version=""
  version="$(hook_timeout_extract_version_token "$version" 2>/dev/null || true)"
  if [ -n "$cache_file" ] && [ -n "$version" ]; then
    mkdir -p "${cache_file%/*}" >/dev/null 2>&1 || true
    temporary="$cache_file.tmp.$$"
    if printf '%s\n' "$version" > "$temporary" 2>/dev/null; then
      mv -f "$temporary" "$cache_file" >/dev/null 2>&1 || rm -f "$temporary" >/dev/null 2>&1 || true
    fi
  fi
  hook_timeout_version_at_least "$version"
}

hook_timeout_has_gnu_timeout() {
  local version=""
  command -v timeout >/dev/null 2>&1 || return 1
  version="$(timeout --version 2>/dev/null || true)"
  case "$version" in
    *"GNU coreutils"*) return 0 ;;
    *) return 1 ;;
  esac
}

hook_timeout_run_bounded() {
  local seconds="${1:-}"
  shift || true
  case "$seconds" in ''|*[!0-9]*|0) return 2 ;; esac
  if hook_timeout_has_gnu_timeout; then
    timeout -k 1s "${seconds}s" "$@"
  elif command -v perl >/dev/null 2>&1; then
    perl -e 'alarm shift; exec @ARGV or exit 127' "$seconds" "$@"
  else
    return 127
  fi
}

hook_timeout_windows_spawn_ms() {
  local shell_bin="${1:-bash}" started ended elapsed rc=0
  [ -x "$shell_bin" ] || shell_bin="$(command -v "$shell_bin" 2>/dev/null || true)"
  [ -n "$shell_bin" ] && [ -x "$shell_bin" ] || return 127
  # Git Bash's GNU timeout is the only accepted Windows bound. Perl alarm does
  # not reliably stop a spawned Win32 process, and starting PowerShell on this
  # path would add another expensive process to the timeout being measured.
  hook_timeout_has_gnu_timeout || return 127
  started="$(hook_timeout_monotonic_ms 2>/dev/null || true)"
  [[ "$started" =~ ^[0-9]+$ ]] || return 127
  hook_timeout_run_bounded 2 "$shell_bin" -c : >/dev/null 2>&1 || rc=$?
  ended="$(hook_timeout_monotonic_ms 2>/dev/null || true)"
  [[ "$ended" =~ ^[0-9]+$ ]] && [ "$ended" -ge "$started" ] || return 127
  [ "$rc" -eq 0 ] || return 127
  elapsed=$((ended - started))
  [ "$elapsed" -le 2000 ] || return 127
  printf '%s' "$elapsed"
}

hook_timeout_windows_process_count() {
  local ps_bin="${1:-ps}" listing rc=0 count
  [ -x "$ps_bin" ] || ps_bin="$(command -v "$ps_bin" 2>/dev/null || true)"
  [ -n "$ps_bin" ] && [ -x "$ps_bin" ] || { printf 'unavailable'; return 0; }
  hook_timeout_has_gnu_timeout || { printf 'unavailable'; return 0; }
  listing="$(hook_timeout_run_bounded 1 "$ps_bin" -W -o comm= 2>/dev/null)" || rc=$?
  [ "$rc" -eq 0 ] || { printf 'unavailable'; return 0; }
  count="$(printf '%s\n' "$listing" | awk '
    tolower($1) == "bash" || tolower($1) == "bash.exe" ||
    tolower($1) == "node" || tolower($1) == "node.exe" { n++ }
    END { print n + 0 }
  ' 2>/dev/null || true)"
  [[ "$count" =~ ^[0-9]{1,7}$ ]] && [ "$count" -le 1000000 ] || { printf 'unavailable'; return 0; }
  printf '%s' "$count"
}

hook_timeout_windows_probe_json() {
  local shell_bin="${1:-bash}" ps_bin="${2:-ps}" spawn_ms="unavailable" process_count="unavailable"
  spawn_ms="$(hook_timeout_windows_spawn_ms "$shell_bin" 2>/dev/null || printf 'unavailable')"
  process_count="$(hook_timeout_windows_process_count "$ps_bin")"
  jq -cn --arg spawn_ms "$spawn_ms" --arg process_count "$process_count" '
    def number_or_unavailable($value):
      if ($value | test("^[0-9]{1,9}$")) and (($value | tonumber) <= 86400000)
      then ($value | tonumber) else "unavailable" end;
    def count_or_unavailable($value):
      if ($value | test("^[0-9]{1,7}$")) and (($value | tonumber) <= 1000000)
      then ($value | tonumber) else "unavailable" end;
    {spawn_ms: number_or_unavailable($spawn_ms), process_count: count_or_unavailable($process_count)}
  '
}

hook_timeout_spawn_ms() {
  local cache_file="${1:-}" shell_bin="${2:-bash}" platform="${3:-}"
  local cached lock_file started ended elapsed rc=0 temporary=""
  local probe_ok=yes cache_hit=no saved_hup_trap saved_int_trap saved_term_trap
  [ -n "$cache_file" ] || return 0
  [ -n "$platform" ] || platform="$(uname -s 2>/dev/null || true)"
  if [ -f "$cache_file" ]; then
    cached="$(<"$cache_file")"
    [[ "$cached" =~ ^[0-9]+$ ]] && { printf '%s' "$cached"; return 0; }
  fi
  if [ "$(hook_timeout_os_name "$platform")" = windows ]; then
    hook_timeout_has_gnu_timeout || return 0
  else
    hook_timeout_has_gnu_timeout || command -v perl >/dev/null 2>&1 || return 0
  fi
  [ -x "$shell_bin" ] || shell_bin="$(command -v "$shell_bin" 2>/dev/null || true)"
  [ -n "$shell_bin" ] && [ -x "$shell_bin" ] || return 0

  # noclobber makes claiming the per-session cache atomic. A concurrent event
  # uses an already-published value or leaves this event's spawn measurement
  # unavailable; it never waits on the probe or starts a duplicate shell.
  lock_file="$cache_file.lock"
  if ! (set -o noclobber; printf '%s\n' "$$" > "$lock_file") 2>/dev/null; then
    if [ -f "$cache_file" ]; then
      cached="$(<"$cache_file")"
      [[ "$cached" =~ ^[0-9]+$ ]] && printf '%s' "$cached"
    fi
    return 0
  fi

  saved_hup_trap="$(trap -p HUP)"
  saved_int_trap="$(trap -p INT)"
  saved_term_trap="$(trap -p TERM)"
  trap 'rm -f "$lock_file" "${temporary:-}" >/dev/null 2>&1 || true; exit 129' HUP
  trap 'rm -f "$lock_file" "${temporary:-}" >/dev/null 2>&1 || true; exit 130' INT
  trap 'rm -f "$lock_file" "${temporary:-}" >/dev/null 2>&1 || true; exit 143' TERM

  if [ -f "$cache_file" ]; then
    cached="$(<"$cache_file")"
    if [[ "$cached" =~ ^[0-9]+$ ]]; then
      elapsed="$cached"
      cache_hit=yes
    fi
  fi

  if [ "$cache_hit" = no ]; then
    if [ "$(hook_timeout_os_name "$platform")" = windows ]; then
      elapsed="$(hook_timeout_windows_spawn_ms "$shell_bin")" || rc=$?
      [[ "$elapsed" =~ ^[0-9]+$ ]] || probe_ok=no
    else
      started="$(hook_timeout_now_ms)"
      hook_timeout_run_bounded 5 "$shell_bin" -c : >/dev/null 2>&1 || rc=$?
      ended="$(hook_timeout_now_ms)"
      elapsed=0
      if [[ "$started" =~ ^[0-9]+$ ]] && [[ "$ended" =~ ^[0-9]+$ ]] && [ "$ended" -ge "$started" ]; then
        elapsed=$((ended - started))
      fi
      case "$rc" in
        0) ;;
        124|137|142) elapsed=5000 ;;
        *) probe_ok=no ;;
      esac
    fi
  fi
  if [ "$probe_ok" = yes ] && [ "$cache_hit" = no ]; then
    temporary="$cache_file.tmp.$$"
    if printf '%s\n' "$elapsed" > "$temporary" 2>/dev/null; then
      mv -f "$temporary" "$cache_file" >/dev/null 2>&1 || rm -f "$temporary" >/dev/null 2>&1 || true
    else
      rm -f "$temporary" >/dev/null 2>&1 || true
    fi
  fi
  rm -f "$lock_file" >/dev/null 2>&1 || true
  trap - HUP INT TERM
  [ -z "$saved_hup_trap" ] || eval "$saved_hup_trap"
  [ -z "$saved_int_trap" ] || eval "$saved_int_trap"
  [ -z "$saved_term_trap" ] || eval "$saved_term_trap"
  [ "$probe_ok" = no ] || printf '%s' "$elapsed"
  return 0
}
