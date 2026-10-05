#!/bin/bash
# Shared helpers for the gated hq-monitor hooks.

HQ_MONITOR_CLI_TIMEOUT_SECONDS=1

# Session-start monitor checks are advisory. Do not let an hq cold start hold
# the hook: stop the command after one second and let the caller skip delivery.
hq_monitor_bounded_command() {
  local seconds="$1" output_file="" timeout_file cmd_pid watchdog_pid rc=0 attempt=0 candidate output
  shift
  # Do not require an external mktemp binary: hooks may run with a deliberately
  # minimal PATH. Create a private, collision-checked file using shell builtins.
  while [ "$attempt" -lt 10 ]; do
    candidate="${TMPDIR:-/tmp}/hq-monitor-cli.$$.$RANDOM"
    if (umask 077; set -o noclobber; : > "$candidate") 2>/dev/null; then
      output_file="$candidate"
      break
    fi
    attempt=$((attempt + 1))
  done
  [ -n "$output_file" ] || return 1
  timeout_file="${output_file}.timeout"
  HQ_NO_UPDATE_CHECK=1 "$@" >"$output_file" 2>/dev/null &
  cmd_pid=$!
  (
    if sleep "$seconds" 2>/dev/null; then
      : > "$timeout_file" 2>/dev/null
      descendants="$(hq_monitor_capture_descendants "$cmd_pid")"
      if [ -n "$descendants" ]; then
        for descendant in $descendants; do kill -TERM "$descendant" 2>/dev/null || true; done
        sleep 0.1 2>/dev/null || true
        # Kill recorded PIDs while the wrapper is still alive; after reaping,
        # the OS reparents them and a parent-based lookup can no longer find them.
        for descendant in $descendants; do kill -KILL "$descendant" 2>/dev/null || true; done
      elif command -v pkill >/dev/null 2>&1; then
        pkill -TERM -P "$cmd_pid" 2>/dev/null || true
        sleep 0.1 2>/dev/null || true
        pkill -KILL -P "$cmd_pid" 2>/dev/null || true
      fi
      kill -TERM "$cmd_pid" 2>/dev/null || true
      sleep 0.1 2>/dev/null || true
      kill -KILL "$cmd_pid" 2>/dev/null || true
    fi
  ) >/dev/null 2>&1 &
  watchdog_pid=$!
  wait "$cmd_pid" 2>/dev/null || rc=$?
  if command -v pkill >/dev/null 2>&1; then pkill -TERM -P "$watchdog_pid" 2>/dev/null || true; fi
  kill "$watchdog_pid" 2>/dev/null || true
  wait "$watchdog_pid" 2>/dev/null || true
  if [ -f "$timeout_file" ]; then
    rm -f "$output_file" "$timeout_file" 2>/dev/null || true
    return 124
  fi
  if [ -r "$output_file" ]; then
    output="$(< "$output_file")" || rc=1
    printf '%s' "$output"
  else
    rc=1
  fi
  rm -f "$output_file" "$timeout_file" 2>/dev/null || true
  return "$rc"
}

hq_monitor_capture_descendants() {
  local root_pid="$1" process_table queue descendants parent pid ppid
  process_table="$(ps -A -o pid= -o ppid= 2>/dev/null)" || return 0
  queue="$root_pid"
  descendants=""
  while [ -n "$queue" ]; do
    parent="${queue%% *}"
    if [ "$queue" = "$parent" ]; then queue=""; else queue="${queue#* }"; fi
    while read -r pid ppid; do
      if [ "$ppid" = "$parent" ] && [ "$pid" != "$root_pid" ]; then
        queue="${queue:+$queue }$pid"
        descendants="${descendants:+$descendants }$pid"
      fi
    done <<EOF
$process_table
EOF
  done
  for pid in $descendants; do printf '%s\n' "$pid"; done
}

hq_monitor_root() {
  local self_src="${BASH_SOURCE[1]:-$0}" self_dir
  if [ -n "${HQ_ROOT:-}" ] && [ -f "$HQ_ROOT/.claude/hooks/hook-gate.sh" ]; then
    printf '%s' "$HQ_ROOT"
    return 0
  fi
  if [ -n "${CLAUDE_PROJECT_DIR:-}" ] && [ -f "$CLAUDE_PROJECT_DIR/.claude/hooks/hook-gate.sh" ]; then
    printf '%s' "$CLAUDE_PROJECT_DIR"
    return 0
  fi
  self_dir="$(cd "$(dirname "$self_src")/../.." 2>/dev/null && pwd -P || true)"
  [ -f "$self_dir/.claude/hooks/hook-gate.sh" ] && printf '%s' "$self_dir"
}

hq_monitor_log_once() {
  local root="$1" payload="$2" key="$3" message="$4" session_key log
  [ -n "$root" ] || return 0
  local HQ_LIB_WINSEP=0
  . "$root/core/scripts/hook-lib.sh" 2>/dev/null || return 0
  session_key="$(hq_hook_session_key_from_payload "$payload")"
  if hq_hook_warning_once "$root" "$session_key" "hq-monitor:$key"; then
    log="$root/workspace/logs/hq-monitor-hook.log"
    mkdir -p "${log%/*}" 2>/dev/null || return 0
    printf '%s hq-monitor: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date)" "$message" >>"$log" 2>/dev/null || true
  fi
}

hq_monitor_enabled() {
  local root="$1" payload="$2" cache_key="${3:-}" probe_rc=0 timeout_seconds="${4:-$HQ_MONITOR_CLI_TIMEOUT_SECONDS}"
  if ! command -v hq >/dev/null 2>&1; then
    hq_monitor_log_once "$root" "$payload" cli-unavailable "hq is unavailable; monitor guard remains disabled"
    return 1
  fi
  hq_monitor_bounded_command "$timeout_seconds" hq monitor enabled >/dev/null \
    || probe_rc=$?
  if [ "$probe_rc" -eq 0 ]; then return 0; fi
  # A timeout is not a negative setting; skip this advisory hook without
  # starting the second cold CLI probe in the same SessionStart.
  [ "$probe_rc" -eq 124 ] && return 1
  hq_monitor_cli_ready "$root" "$payload" "$cache_key" >/dev/null 2>&1 || true
  return 1
}

hq_monitor_cli_ready() {
  local root="$1" payload="$2" cache_key="${3:-}" help cli_path cache_file cached_cli="" cached_ready="" tmp help_rc=0
  if ! command -v hq >/dev/null 2>&1; then
    hq_monitor_log_once "$root" "$payload" cli-unavailable "hq is unavailable; monitor delivery is disabled"
    return 1
  fi
  cli_path="$(type -P hq 2>/dev/null || command -v hq)"
  case "$cache_key" in ''|*[!A-Za-z0-9._-]*) cache_key="" ;; esac
  if [ -n "$cache_key" ]; then
    cache_file="$root/workspace/orchestrator/hook-state/hq-monitor-cli-ready/$cache_key"
    if [ -f "$cache_file" ] && [ "$cache_file" -nt "$cli_path" ]; then
      {
        IFS= read -r cached_cli || true
        IFS= read -r cached_ready || true
      } < "$cache_file"
      if [ "$cached_cli" = "$cli_path" ]; then
        case "$cached_ready" in
          1) return 0 ;;
          0)
            hq_monitor_log_once "$root" "$payload" monitor-command-unavailable "installed hq CLI has no monitor command; monitor delivery is disabled"
            return 1
            ;;
        esac
      fi
    fi
  fi
  help="$(hq_monitor_bounded_command "$HQ_MONITOR_CLI_TIMEOUT_SECONDS" hq --help 2>/dev/null)" || help_rc=$?
  # A timed-out probe says nothing about command support; leave the cache
  # untouched so a later SessionStart can retry it.
  [ "$help_rc" -eq 124 ] && return 1
  if printf '%s\n' "$help" | grep -Eq '^[[:space:]]+monitor([[:space:]]|$)'; then
    cached_ready=1
  else
    cached_ready=0
    hq_monitor_log_once "$root" "$payload" monitor-command-unavailable "installed hq CLI has no monitor command; monitor delivery is disabled"
  fi
  if [ -n "$cache_key" ]; then
    tmp="$cache_file.tmp.$$"
    (umask 077; mkdir -p "${cache_file%/*}" 2>/dev/null) || true
    if [ -d "${cache_file%/*}" ] \
       && printf '%s\n%s\n' "$cli_path" "$cached_ready" > "$tmp" 2>/dev/null \
       && mv -f "$tmp" "$cache_file" 2>/dev/null; then
      :
    else
      rm -f "$tmp" 2>/dev/null || true
    fi
  fi
  if [ "$cached_ready" = "0" ]; then
    return 1
  fi
  return 0
}
