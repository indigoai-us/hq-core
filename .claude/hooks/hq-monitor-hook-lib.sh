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
  local root="$1" payload="$2" cache_key="${3:-}"
  if ! command -v hq >/dev/null 2>&1; then
    hq_monitor_log_once "$root" "$payload" cli-unavailable "hq is unavailable; monitor guard remains disabled"
    return 1
  fi
  if HQ_NO_UPDATE_CHECK=1 hq monitor enabled >/dev/null 2>&1; then return 0; fi
  hq_monitor_cli_ready "$root" "$payload" "$cache_key" >/dev/null 2>&1 || true
  return 1
}

hq_monitor_cli_ready() {
  local root="$1" payload="$2" cache_key="${3:-}" help cli_path cache_file cached_cli="" cached_ready="" tmp
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
  help="$(HQ_NO_UPDATE_CHECK=1 hq --help 2>/dev/null || true)"
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
