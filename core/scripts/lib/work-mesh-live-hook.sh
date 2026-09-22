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
#   Sets REPLY to the new count. Uses temp+mv and chmod 600.
#   Merge-safe: only toolWrites and updatedAt change; every other field the
#   hq-cli reconcile/ack path wrote (companyUid, companySlug, projectId, taskId,
#   startedAt, bindingEpisodeId, decision, contextStatus, ...) is preserved
#   byte-for-byte. Prefers jq; the no-jq fallback edits the two values in place
#   in pure bash (compact or pretty-printed JSON, any key order) and only
#   appends a missing key. contextStatus is set to "unresolved" only on a fresh
#   stub. Bash 3.2 compatible; no sed/awk/GNU flags.
#   Concurrency: hq-cli writes the same path with same-dir tmp + rename and has
#   no lock convention (hq-cli src/lib/work-context/atomic.ts). Two lines of
#   defense against a reconcile write landing between our read and mv:
#     1. mkdir lock at <path>.lock (Bash 3.2 safe), bounded wait ~200ms, stale
#        lock reclaimed by age (>5s). If the lock cannot be taken, the bump is
#        skipped (return 1) rather than risk a clobber.
#     2. Re-read immediately before mv; if the file changed since the first
#        read, rebuild from the new body.
#   Test seam: WORK_MESH_BUMP_TEST_SLEEP_AFTER_READ=<secs> sleeps between the
#   first read and the re-read so a test can inject a concurrent writer.
work_mesh_live_bump_tool_writes() {
  local sid="$1" path dir lock rc
  path="$(work_mesh_live_state_path "$sid")"
  dir="${path%/*}"
  if [ ! -d "$dir" ]; then
    mkdir -p -- "$dir" 2>/dev/null || true
    chmod 700 -- "$dir" 2>/dev/null || true
  fi
  lock="$path.lock"
  _work_mesh_live_lock_acquire "$lock" || return 1
  _work_mesh_live_bump_locked "$sid" "$path"
  rc=$?
  rm -rf -- "$lock" 2>/dev/null || true
  return $rc
}

# _work_mesh_live_lock_acquire <lockdir>
#   mkdir lock; ~20 x 10ms bounded wait; reclaim when the holder's stamp is
#   older than 5s (or missing after the full wait). 0 = held, 1 = give up.
_work_mesh_live_lock_acquire() {
  local lock="$1" i=0 now stamp
  while :; do
    if mkdir -- "$lock" 2>/dev/null; then
      date +%s >"$lock/ts" 2>/dev/null || true
      return 0
    fi
    i=$((i + 1))
    if [ "$i" -ge 20 ]; then
      now="$(date +%s 2>/dev/null || printf '0')"
      stamp="$(cat "$lock/ts" 2>/dev/null || printf '')"
      case "$stamp" in ""|*[!0-9]*) stamp=0 ;; esac
      if [ "$stamp" -eq 0 ] || [ $((now - stamp)) -gt 5 ]; then
        rm -rf -- "$lock" 2>/dev/null || true
        if mkdir -- "$lock" 2>/dev/null; then
          date +%s >"$lock/ts" 2>/dev/null || true
          return 0
        fi
      fi
      return 1
    fi
    sleep 0.01 2>/dev/null || sleep 1
  done
}

# _work_mesh_live_bump_render <sid> <path> <tmp>
#   Read <path> (if any), build the bumped document into <tmp>.
#   Sets _WM_SEEN to the body that was read ("" when absent) and REPLY to the
#   new count. Returns 1 when the file must not be touched.
_work_mesh_live_bump_render() {
  local sid="$1" path="$2" tmp="$3" cur="" next ts body="" rest have_jq=0 written=0
  _WM_SEEN=""
  command -v jq >/dev/null 2>&1 && have_jq=1
  if [ -f "$path" ]; then
    body="$(<"$path")"
    _WM_SEEN="$body"
    case "$body" in
      *"\"toolWrites\""*)
        rest="${body#*\"toolWrites\"}"; rest="${rest#*:}"
        while [ "${rest#"${rest%%[![:space:]]*}"}" != "$rest" ]; do rest="${rest#?}"; done
        cur="${rest%%[!0-9]*}"
        ;;
    esac
  fi
  case "$cur" in ""|*[!0-9]*) cur=0 ;; esac
  next=$((cur + 1))
  ts=""
  # %(...)T needs Bash 4.2+; macOS Bash 3.2 falls back to date -u (BSD + GNU).
  TZ=UTC printf -v ts '%(%Y-%m-%dT%H:%M:%S)T.000Z' -1 2>/dev/null || ts=""
  case "$ts" in
    ""|*%*) ts="$(TZ=UTC date -u '+%Y-%m-%dT%H:%M:%S.000Z' 2>/dev/null || true)" ;;
  esac
  [ -n "$ts" ] || ts="1970-01-01T00:00:00.000Z"
  if [ ! -f "$path" ]; then
    printf '{"contractVersion":1,"sessionId":"%s","contextStatus":"unresolved","toolWrites":%s,"updatedAt":"%s"}\n' \
      "$sid" "$next" "$ts" >"$tmp" || return 1
    REPLY="$next"
    return 0
  fi
  if [ "$have_jq" -eq 1 ]; then
    if printf '%s' "$body" | jq --argjson n "$next" --arg ts "$ts" \
        '.toolWrites = $n | .updatedAt = $ts' >"$tmp" 2>/dev/null \
       && [ -s "$tmp" ]; then
      written=1
    elif jq -n empty >/dev/null 2>&1; then
      # jq works but could not parse the file (malformed/partial JSON).
      # Never replace the CLI's file with a stub: leave it untouched and skip.
      rm -f -- "$tmp" 2>/dev/null
      return 1
    fi
    # else: jq on PATH is unusable; take the pure-bash path below.
  fi
  if [ "$written" -eq 0 ]; then
    # No-jq fallback: pure-bash in-place edit of the two values (no extra
    # spawns, Bash 3.2 safe). Works for compact and pretty JSON in any key
    # order; every other byte of the CLI's file is left as is.
    local pre digits add
    case "$body" in
      *"\"toolWrites\""*)
        pre="${body%%\"toolWrites\"*}"
        rest="${body#*\"toolWrites\"}"
        while [ "${rest#"${rest%%[![:space:]:]*}"}" != "$rest" ]; do rest="${rest#?}"; done
        digits="${rest%%[!0-9]*}"
        rest="${rest#"$digits"}"
        body="$pre\"toolWrites\": $next$rest"
        ;;
    esac
    case "$body" in
      *"\"updatedAt\""*)
        pre="${body%%\"updatedAt\"*}"
        rest="${body#*\"updatedAt\"}"
        while [ "${rest#"${rest%%[![:space:]:]*}"}" != "$rest" ]; do rest="${rest#?}"; done
        case "$rest" in
          \"*) rest="${rest#\"}"; rest="${rest#*\"}" ;;
        esac
        body="$pre\"updatedAt\": \"$ts\"$rest"
        ;;
    esac
    add=""
    case "$body" in *"\"toolWrites\""*) ;; *) add="\"toolWrites\": $next" ;; esac
    case "$body" in *"\"updatedAt\""*) ;; *) add="${add:+$add, }\"updatedAt\": \"$ts\"" ;; esac
    if [ -n "$add" ]; then
      # Insert right after the opening brace so the closing brace stays put.
      case "$body" in
        *\{*)
          pre="${body%%\{*}"
          rest="${body#*\{}"
          local peek="$rest"
          while [ "${peek#"${peek%%[![:space:]]*}"}" != "$peek" ]; do peek="${peek#?}"; done
          case "$peek" in
            \}*) body="$pre{$add$peek" ;;
            *)   body="$pre{$add, $rest" ;;
          esac
          ;;
        *) body="{$add}" ;;
      esac
    fi
    if printf '%s\n' "$body" >"$tmp" 2>/dev/null && [ -s "$tmp" ]; then
      written=1
    fi
  fi
  if [ "$written" -eq 0 ]; then
    rm -f -- "$tmp" 2>/dev/null
    return 1
  fi
  REPLY="$next"
  return 0
}

# _work_mesh_live_bump_locked <sid> <path>  (caller holds the lock)
_work_mesh_live_bump_locked() {
  local sid="$1" path="$2" tmp seen again
  tmp="$path.tmp.$$"
  _work_mesh_live_bump_render "$sid" "$path" "$tmp" || return 1
  seen="$_WM_SEEN"
  if [ -n "${WORK_MESH_BUMP_TEST_SLEEP_AFTER_READ:-}" ]; then
    sleep "$WORK_MESH_BUMP_TEST_SLEEP_AFTER_READ" 2>/dev/null || true
  fi
  # Second line of defense: re-read right before mv; if a concurrent writer
  # (hq-cli reconcile/ack) changed the file since our read, rebuild from it.
  again=""
  [ -f "$path" ] && again="$(<"$path")"
  if [ "$again" != "$seen" ]; then
    rm -f -- "$tmp" 2>/dev/null
    _work_mesh_live_bump_render "$sid" "$path" "$tmp" || return 1
  fi
  mv -f -- "$tmp" "$path" 2>/dev/null || { rm -f -- "$tmp"; return 1; }
  chmod 600 -- "$path" 2>/dev/null || true
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
