#!/bin/bash
# Shared helpers for the gated hq-monitor hooks.

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
  local root="$1" payload="$2"
  if ! command -v hq >/dev/null 2>&1; then
    hq_monitor_log_once "$root" "$payload" cli-unavailable "hq is unavailable; monitor guard remains disabled"
    return 1
  fi
  if HQ_NO_UPDATE_CHECK=1 hq monitor enabled >/dev/null 2>&1; then return 0; fi
  hq_monitor_cli_ready "$root" "$payload" >/dev/null 2>&1 || true
  return 1
}

hq_monitor_cli_ready() {
  local root="$1" payload="$2" help
  if ! command -v hq >/dev/null 2>&1; then
    hq_monitor_log_once "$root" "$payload" cli-unavailable "hq is unavailable; monitor delivery is disabled"
    return 1
  fi
  help="$(HQ_NO_UPDATE_CHECK=1 hq --help 2>/dev/null || true)"
  if ! printf '%s\n' "$help" | grep -Eq '^[[:space:]]+monitor([[:space:]]|$)'; then
    hq_monitor_log_once "$root" "$payload" monitor-command-unavailable "installed hq CLI has no monitor command; monitor delivery is disabled"
    return 1
  fi
  return 0
}
