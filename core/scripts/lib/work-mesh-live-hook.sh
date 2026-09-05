#!/usr/bin/env bash
# hq-core: public
# work-mesh-live-hook.sh — shared helpers for Work Mesh Live enqueue-only hooks.
# Sourced by core/hooks/*/3*-work-mesh-*.sh. Never execute directly.

# work_mesh_live_disabled
#   Exit 0 (true) when kill switches say these hooks must no-op.
work_mesh_live_disabled() {
  case "${HQ_WORK_MESH_DISABLED:-}" in
    1|true|TRUE|yes|YES|on|ON) return 0 ;;
  esac
  case ",${HQ_DISABLED_HOOKS:-}," in
    *,work-mesh,*|*,work-mesh-live,*|*,\*,*) return 0 ;;
  esac
  return 1
}

# work_mesh_live_bootstrap
#   Resolve HQ_ROOT from the calling hook path; source enqueue + session-id.
#   Caller must set _WM_HOOK_DIR to dirname of BASH_SOURCE[0] before calling,
#   OR pass the hook file path as $1.
work_mesh_live_bootstrap() {
  local hook_file="${1:-${BASH_SOURCE[1]:-}}"
  local hook_dir hq
  hook_dir="$(cd "$(dirname "$hook_file")" 2>/dev/null && pwd)" || return 1
  # core/hooks/<Event>/<file> -> HQ root is ../../..
  hq="${HQ_ROOT:-$(cd "$hook_dir/../../.." 2>/dev/null && pwd)}"
  [ -n "$hq" ] || return 1
  export HQ_ROOT="$hq"
  # shellcheck source=core/scripts/lib/work-mesh-enqueue.sh
  . "$HQ_ROOT/core/scripts/lib/work-mesh-enqueue.sh" 2>/dev/null || return 1
  # shellcheck source=core/scripts/lib/session-id.sh
  . "$HQ_ROOT/core/scripts/lib/session-id.sh" 2>/dev/null || true
  return 0
}

# work_mesh_live_session_id <stdin-json>
#   Prefer env (session_id_from_env); else payload session_id / sessionId.
work_mesh_live_session_id() {
  local input="${1:-}" id=""
  if command -v session_id_from_env >/dev/null 2>&1; then
    id="$(session_id_from_env)"
  fi
  if [ -z "$id" ]; then
    for var in HQ_SESSION_ID CLAUDE_CODE_SESSION_ID CLAUDE_SESSION_ID CODEX_SESSION_ID CODEX_THREAD_ID; do
      id="${!var:-}"
      id="$(printf '%s' "$id" | tr -d '[:space:]')"
      [ -n "$id" ] && break
    done
  fi
  if [ -z "$id" ] && [ -n "$input" ]; then
    # Prefer jq when present; pure-bash fallback for the common keys.
    if command -v jq >/dev/null 2>&1; then
      id="$(printf '%s' "$input" | jq -r '.session_id // .sessionId // .conversation_id // .conversationId // .thread_id // .threadId // empty' 2>/dev/null || true)"
    else
      id="$(printf '%s' "$input" | sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p; t; s/.*"sessionId"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)"
    fi
    id="$(printf '%s' "$id" | tr -d '[:space:]')"
  fi
  if command -v session_id_is_valid >/dev/null 2>&1; then
    session_id_is_valid "$id" || id=""
  else
    case "$id" in
      ""|.|..|*[!A-Za-z0-9._-]*) id="" ;;
    esac
  fi
  printf '%s' "$id"
}

# work_mesh_live_harness
#   HQ_HARNESS / HQ_WORK_MESH_HARNESS / HQ_CHECKPOINT_RUNTIME -> contract harness.
work_mesh_live_harness() {
  local h="${HQ_HARNESS:-${HQ_WORK_MESH_HARNESS:-${HQ_CHECKPOINT_RUNTIME:-claude-code}}}"
  case "$h" in
    claude|claude-code|Claude|ClaudeCode) printf 'claude-code' ;;
    codex|Codex) printf 'codex' ;;
    grok|Grok) printf 'grok' ;;
    hq-sessions|hq_sessions|sessions) printf 'hq-sessions' ;;
    agent-box|agent_box|box) printf 'agent-box' ;;
    *) printf '%s' "$h" ;;
  esac
}

# work_mesh_live_adapter_version
work_mesh_live_adapter_version() {
  if [ -n "${HQ_ADAPTER_CONTRACT_VERSION:-}" ]; then
    printf '%s' "$HQ_ADAPTER_CONTRACT_VERSION"
    return 0
  fi
  if [ -f "${HQ_ROOT:-}/core/scripts/lib/provider-adapter-version.sh" ]; then
    # shellcheck source=core/scripts/lib/provider-adapter-version.sh
    . "$HQ_ROOT/core/scripts/lib/provider-adapter-version.sh" 2>/dev/null || true
  fi
  printf '%s' "${HQ_ADAPTER_CONTRACT_VERSION:-1.0.0}"
}

# work_mesh_live_runtime_version
work_mesh_live_runtime_version() {
  printf '%s' "${HQ_RUNTIME_VERSION:-${CLAUDE_CODE_VERSION:-${CODEX_VERSION:-${GROK_VERSION:-}}}}"
}

# work_mesh_live_next_seq <session-id>
#   Monotonic seq under ~/.hq/work-mesh/seq/<sid> (or WORK_MESH_SEQ_DIR).
#   Hot path: bash file read, no tr/chmod when the dir already exists.
work_mesh_live_next_seq() {
  local sid="$1" dir file n
  dir="${WORK_MESH_SEQ_DIR:-${HOME}/.hq/work-mesh/seq}"
  if [ ! -d "$dir" ]; then
    mkdir -p -- "$dir" 2>/dev/null || true
    chmod 700 -- "$dir" 2>/dev/null || true
  fi
  file="$dir/$sid"
  n=0
  if [ -f "$file" ]; then
    n="$(<"$file")"
    n="${n//[[:space:]]/}"
    case "$n" in
      ""|*[!0-9]*) n=0 ;;
    esac
  fi
  n=$((n + 1))
  printf '%s\n' "$n" >"$file" 2>/dev/null || return 1
  printf '%s' "$n"
}

# work_mesh_live_meta_get <root> <sid> <key>
work_mesh_live_meta_get() {
  local root="$1" sid="$2" key="$3" meta
  meta="$root/workspace/sessions/$sid/meta.yaml"
  [ -f "$meta" ] || return 0
  awk -v k="$key" '$1==k":"{ sub(/^[^:]+:[[:space:]]*/,""); gsub(/^"|"$/,""); print; exit }' "$meta" 2>/dev/null
}

# work_mesh_live_state_path <sid>
work_mesh_live_state_path() {
  printf '%s/.hq/work-context/sessions/%s.json' "${WORK_MESH_HOME:-$HOME}" "$1"
}

# work_mesh_live_board_path <sid>
work_mesh_live_board_path() {
  printf '%s/.hq/work-context/sessions/%s/board.md' "${WORK_MESH_HOME:-$HOME}" "$1"
}

# work_mesh_live_ask_surfaced_path <sid>
work_mesh_live_ask_surfaced_path() {
  printf '%s/.hq/work-context/sessions/%s.ask-surfaced' "${WORK_MESH_HOME:-$HOME}" "$1"
}

# work_mesh_live_pending_decision_path <sid>
work_mesh_live_pending_decision_path() {
  printf '%s/.hq/work-context/sessions/%s.pending-decision' "${WORK_MESH_HOME:-$HOME}" "$1"
}

# work_mesh_live_word_count <text> — count whitespace-separated tokens.
work_mesh_live_word_count() {
  local t="$1"
  # shellcheck disable=SC2086
  set -- $t
  printf '%s' "$#"
}

# work_mesh_live_is_slash_or_short <prompt>
#   True (0) when slash command or fewer than 3 words.
work_mesh_live_is_slash_or_short() {
  local p="$1" n
  case "$p" in
    /*) return 0 ;;
  esac
  n="$(work_mesh_live_word_count "$p")"
  [ "$n" -lt 3 ]
}

# work_mesh_live_bump_tool_writes <sid>
#   Atomically increment toolWrites on the state JSON (create stub if absent).
#   Sets REPLY to the new count. Uses temp+mv; no jq required on hot path when
#   the file is simple, but prefers jq when available for safe JSON edit.
work_mesh_live_bump_tool_writes() {
  local sid="$1" path dir tmp cur=0 next ts
  path="$(work_mesh_live_state_path "$sid")"
  dir="${path%/*}"
  if [ ! -d "$dir" ]; then
    mkdir -p -- "$dir" 2>/dev/null || true
    chmod 700 -- "$dir" 2>/dev/null || true
  fi
  if [ -f "$path" ]; then
    if command -v jq >/dev/null 2>&1; then
      cur="$(jq -r '.toolWrites // 0' "$path" 2>/dev/null || printf '0')"
    else
      local body rest
      body="$(<"$path")"
      case "$body" in
        *"\"toolWrites\""*)
          rest="${body#*\"toolWrites\"}"; rest="${rest#*:}"
          while [ "${rest#"${rest%%[![:space:]]*}"}" != "$rest" ]; do rest="${rest#?}"; done
          cur="${rest%%[!0-9]*}"
          ;;
      esac
    fi
    case "$cur" in
      ""|*[!0-9]*) cur=0 ;;
    esac
  fi
  next=$((cur + 1))
  if ! TZ=UTC printf -v ts '%(%Y-%m-%dT%H:%M:%S)T.000Z' -1 2>/dev/null; then
    ts="1970-01-01T00:00:00.000Z"
  fi
  tmp="$path.tmp.$$"
  if [ -f "$path" ] && command -v jq >/dev/null 2>&1; then
    jq --argjson n "$next" --arg ts "$ts" \
      '.toolWrites = $n | .updatedAt = $ts' "$path" >"$tmp" 2>/dev/null \
      || printf '{"sessionId":"%s","toolWrites":%s,"updatedAt":"%s"}\n' "$sid" "$next" "$ts" >"$tmp"
  elif [ -f "$path" ]; then
    if grep -q '"toolWrites"' "$path" 2>/dev/null; then
      sed "s/\"toolWrites\"[[:space:]]*:[[:space:]]*[0-9][0-9]*/\"toolWrites\":$next/" "$path" >"$tmp"
    else
      sed "s/}$/,\"toolWrites\":$next}/" "$path" >"$tmp"
    fi
  else
    printf '{"contractVersion":1,"sessionId":"%s","contextStatus":"unresolved","toolWrites":%s,"updatedAt":"%s"}\n' \
      "$sid" "$next" "$ts" >"$tmp"
  fi
  mv -f -- "$tmp" "$path" 2>/dev/null || { rm -f -- "$tmp"; return 1; }
  chmod 600 -- "$path" 2>/dev/null || true
  REPLY="$next"
  return 0
}

# work_mesh_live_is_file_write_tool <tool_name> <bash_command?>
work_mesh_live_is_file_write_tool() {
  local tool="$1" cmd="${2:-}"
  case "$tool" in
    Edit|Write|MultiEdit|NotebookEdit|apply_patch|StrReplace|search_replace|write) return 0 ;;
    Bash|Shell|run_terminal_command)
      # Redirect / common file-mutating bash forms (no nested quotes in case arms).
      case "$cmd" in
        *\>*|*tee\ *|*mv\ *|*cp\ *|*truncate\ *) return 0 ;;
        *sed\ -i*|*dd\ if=*) return 0 ;;
        *) return 1 ;;
      esac
      ;;
    *) return 1 ;;
  esac
}
