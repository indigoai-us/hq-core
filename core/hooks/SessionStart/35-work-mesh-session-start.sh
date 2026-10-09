#!/usr/bin/env bash
# hq-core: public
# SessionStart: enqueue session_start + detached hq mesh context reconcile (US-010).
set -uo pipefail

case "${HQ_WORK_MESH_DISABLED:-}" in 1|true|TRUE|yes|YES|on|ON) exit 0 ;; esac
case ",${HQ_DISABLED_HOOKS:-}," in *,work-mesh,*|*,work-mesh-live,*|*,\*,*) exit 0 ;; esac

HOOK_FILE="${BASH_SOURCE[0]}"
if [ -z "${HQ_ROOT:-}" ]; then
  HQ_ROOT="$(cd "${HOOK_FILE%/*}/../../.." 2>/dev/null && pwd)" || exit 0
fi
# shellcheck source=core/scripts/lib/work-mesh-enqueue.sh
. "$HQ_ROOT/core/scripts/lib/work-mesh-enqueue.sh" 2>/dev/null || exit 0

INPUT=""
IFS= read -r -d '' INPUT || true
[ -n "$INPUT" ] || INPUT='{}'

CWD="${PWD:-}"
_wm_json_str() {
  local json=$1 key=$2 rest
  REPLY=
  local needle="\"$key\""
  case "$json" in
    *"$needle"*)
      rest="${json#*"$needle"}"
      rest="${rest#*:}"
      while [ "${rest#"${rest%%[![:space:]]*}"}" != "$rest" ]; do rest="${rest#?}"; done
      case "$rest" in
        \"*) rest="${rest#\"}"; REPLY="${rest%%\"*}" ;;
      esac
      ;;
  esac
}
_wm_json_str "$INPUT" session_id; ENGINE_SID=$REPLY
[ -n "$ENGINE_SID" ] || { _wm_json_str "$INPUT" sessionId; ENGINE_SID=$REPLY; }
ENGINE_SID="${ENGINE_SID//[[:space:]]/}"
PARENT_SID="${HQ_PARENT_SESSION_ID:-${HQ_SESSION_ID:-}}"
PARENT_SID="${PARENT_SID//[[:space:]]/}"

# Conduct lanes retain HQ_SESSION_ID for parent pool accounting. Their engine
# supplies a new session id in SessionStart stdin; use that child id for mesh
# binding and reconciliation instead of relabeling the already-bound parent.
if [ -n "${HQ_SPAWN_COMPANY:-}" ] && [ -n "$ENGINE_SID" ]; then
  SID="$ENGINE_SID"
else
  SID="${HQ_SESSION_ID:-${CLAUDE_CODE_SESSION_ID:-${CLAUDE_SESSION_ID:-${CODEX_SESSION_ID:-${CODEX_THREAD_ID:-}}}}}"
  SID="${SID//[[:space:]]/}"
  [ -n "$SID" ] || SID="$ENGINE_SID"
fi
_wm_json_str "$INPUT" cwd; [ -n "$REPLY" ] && CWD=$REPLY
[ -n "$SID" ] || exit 0

BOUND_COMPANY=""
WORK_CONTEXT_ROOT="${HQ_WORK_CONTEXT_ROOT:-${HOME:-}/.hq/work-context}"
if [ -f "$HQ_ROOT/core/scripts/lib/session-auto-bind.sh" ]; then
  # shellcheck source=core/scripts/lib/session-scope-capability.sh
  . "$HQ_ROOT/core/scripts/lib/session-scope-capability.sh" 2>/dev/null || true
  # shellcheck source=core/scripts/lib/session-auto-bind.sh
  . "$HQ_ROOT/core/scripts/lib/session-auto-bind.sh" 2>/dev/null || true
  if command -v session_auto_bind_apply >/dev/null 2>&1; then
    # Device defaults are intentionally left to hq mesh context reconcile. It
    # sees cwd + repository evidence and can return company_conflict; promoting
    # a preference into meta/scope here would make it trusted too early.
    HQ_SESSION_AUTO_BIND_SKIP_DEVICE_DEFAULT=1 session_auto_bind_apply "$HQ_ROOT" "$SID" "$PARENT_SID" || true
    BOUND_COMPANY="$(session_auto_bind_meta_slug "$HQ_ROOT" "$SID" 2>/dev/null || true)"
  fi
fi

HARNESS="${HQ_HARNESS:-${HQ_WORK_MESH_HARNESS:-${HQ_CHECKPOINT_RUNTIME:-claude-code}}}"
case "$HARNESS" in
  claude|Claude|ClaudeCode) HARNESS=claude-code ;;
  Codex) HARNESS=codex ;;
  Grok) HARNESS=grok ;;
esac
ADAPTER="${HQ_ADAPTER_CONTRACT_VERSION:-1.0.0}"
RUNTIME="${HQ_RUNTIME_VERSION:-${CLAUDE_CODE_VERSION:-${CODEX_VERSION:-${GROK_VERSION:-}}}}"

COMPANY="${BOUND_COMPANY:-${HQ_SPAWN_COMPANY:-}}"
PROJECT="${HQ_SPAWN_PROJECT:-}"
TASK="${HQ_SPAWN_TASK:-}"
# Skip meta.yaml forks unless spawn context is incomplete and a session meta exists.
if [ -z "$COMPANY" ] || [ -z "$PROJECT" ] || [ -z "$TASK" ]; then
  meta="$HQ_ROOT/workspace/sessions/$SID/meta.yaml"
  if [ -f "$meta" ]; then
    meta_get() {
      awk -v k="$1" '$1==k":"{ sub(/^[^:]+:[[:space:]]*/,""); gsub(/^"|"$/,""); print; exit }' "$meta" 2>/dev/null
    }
    [ -n "$COMPANY" ] || COMPANY="$(meta_get company_slug)"
    [ -n "$PROJECT" ] || PROJECT="$(meta_get project)"
    [ -n "$TASK" ] || TASK="$(meta_get task)"
  fi
fi

SEQ_DIR="${WORK_MESH_SEQ_DIR:-$HOME/.hq/work-mesh/seq}"
if [ ! -d "$SEQ_DIR" ]; then
  mkdir -p -- "$SEQ_DIR" 2>/dev/null || true
  chmod 700 -- "$SEQ_DIR" 2>/dev/null || true
fi
COMPANIES=()
META_LOCK_SET=""
LOCK_META="$HQ_ROOT/workspace/sessions/$SID/meta.yaml"
if [ -n "$COMPANY" ] && [ -r "$LOCK_META" ]; then
  META_LOCK_SET="$(awk '$1 == "company_slugs:" { sub(/^[^:]+:[[:space:]]*/, ""); gsub(/[[:space:]\"]/, ""); print; exit }' "$LOCK_META" 2>/dev/null || true)"
fi
# Legacy and singleton sessions keep the original one-company fast path. Only
# consult the capability reader and flag client when metadata indicates a set
# could contain more than one company; the capability remains authoritative.
case "$META_LOCK_SET" in *,*) NEED_LOCK_SET=1 ;; *) NEED_LOCK_SET=0 ;; esac
if [ "$NEED_LOCK_SET" = 1 ] && [ -f "$HQ_ROOT/workspace/sessions/$SID/scope-capability.json" ] && \
   [ -f "$HQ_ROOT/core/scripts/lib/session-scope-capability.sh" ]; then
  . "$HQ_ROOT/core/scripts/lib/session-scope-capability.sh" 2>/dev/null || true
  while IFS= read -r locked_company; do
    [ -n "$locked_company" ] && [ "$locked_company" != personal ] && COMPANIES+=("$locked_company")
  done < <(session_scope_read_companies "$HQ_ROOT" "$SID" 2>/dev/null || true)
fi
[ "${#COMPANIES[@]}" -gt 0 ] && COMPANY="${COMPANIES[0]}"
[ "${#COMPANIES[@]}" -gt 0 ] || { [ -n "$COMPANY" ] && COMPANIES=("$COMPANY"); }
if [ "${#COMPANIES[@]}" -eq 0 ]; then COMPANIES=(""); fi
for company in "${COMPANIES[@]}"; do
  SEQ_FILE="$SEQ_DIR/$SID"
  SEQ=0
  if [ -f "$SEQ_FILE" ]; then SEQ="$(<"$SEQ_FILE")"; SEQ="${SEQ//[[:space:]]/}"; fi
  case "$SEQ" in ""|*[!0-9]*) SEQ=0 ;; esac
  SEQ=$((SEQ + 1))
  printf '%s\n' "$SEQ" >"$SEQ_FILE"
  ENQ=(--kind session_start --session-id "$SID" --harness "$HARNESS" --adapter-version "$ADAPTER" --seq "$SEQ" --cwd "$CWD" --hq-root "$HQ_ROOT")
  [ -n "$RUNTIME" ] && ENQ+=(--runtime-version "$RUNTIME")
  [ -n "$company" ] && ENQ+=(--company-slug "$company")
  [ -n "$PROJECT" ] && ENQ+=(--project "$PROJECT")
  [ -n "$TASK" ] && ENQ+=(--task "$TASK")
  work_mesh_enqueue "${ENQ[@]}" || true
done

# US-011: record live binding so mid-session organize can detect rebind.
if [ -n "$PROJECT" ] && [ -f "$HQ_ROOT/core/scripts/lib/work-mesh-live-rebind.sh" ]; then
  # shellcheck source=core/scripts/lib/work-mesh-live-rebind.sh
  . "$HQ_ROOT/core/scripts/lib/work-mesh-live-rebind.sh" 2>/dev/null || true
  if command -v work_mesh_live_write_binding_marker >/dev/null 2>&1; then
    work_mesh_live_write_binding_marker "$SID" "$COMPANY" "$PROJECT" "$TASK" || true
  fi
fi

# US-039: a CLI older than 5.139.0 leaves pending_registration on board.json.
# The retry runs up to three `hq mesh project ensure` calls. That work is
# detached (nohup, log file) and single-flight (mkdir lock per company).
# The session-start path only takes or skips the lock; it never waits.
_wm_lock_age_seconds() {
  local path=$1 stamp now
  stamp="$(stat -c '%Y' "$path" 2>/dev/null || true)"
  case "$stamp" in ''|*[!0-9]*) stamp="$(stat -f '%m' "$path" 2>/dev/null || true)" ;; esac
  case "$stamp" in ''|*[!0-9]*) return 1 ;; esac
  now="$(date +%s 2>/dev/null || true)"
  case "$now" in ''|*[!0-9]*) return 1 ;; esac
  REPLY=$((now - stamp))
}

_wm_reclaim_abandoned_reaper() {
  local reaper=$1 stale_after=$2 retired age
  [ -d "$reaper" ] || return 0
  _wm_lock_age_seconds "$reaper" || return 1
  age=$REPLY
  [ "$age" -gt "$stale_after" ] || return 1
  retired="$reaper.stale.$$.$RANDOM"
  [ ! -e "$retired" ] || return 1
  if ! mv -- "$reaper" "$retired" 2>/dev/null; then
    return 1
  fi
  if _wm_lock_age_seconds "$retired" && [ "$REPLY" -gt "$stale_after" ]; then
    rm -rf -- "$retired" 2>/dev/null || true
    return 0
  fi
  [ -e "$reaper" ] || mv -- "$retired" "$reaper" 2>/dev/null || true
  return 1
}

_wm_lock_acquire() {
  local lock=$1 stale_after=${2:-30} reaper="$1.reclaim" retired age
  if [ -d "$reaper" ]; then
    _wm_reclaim_abandoned_reaper "$reaper" "$stale_after" || return 1
  fi
  if mkdir -- "$lock" 2>/dev/null; then
    printf '%s\n' "$$" >"$lock/pid" 2>/dev/null || true
    if [ -d "$reaper" ]; then
      rm -rf -- "$lock" 2>/dev/null || true
      return 1
    fi
    return 0
  fi

  # Reclaim only by age. The detached stages have deadlines up to ten seconds,
  # so a thirty-second-old lock cannot belong to live work. The reclaim mutex
  # keeps stale classification from being applied to a replacement lock. A
  # crashed reclaimer is itself reclaimed after the same quiescent interval.
  mkdir -- "$reaper" 2>/dev/null || return 1
  if [ -d "$lock" ] && _wm_lock_age_seconds "$lock"; then
    age=$REPLY
    if [ "$age" -gt "$stale_after" ]; then
      retired="$lock.stale.$$.$RANDOM"
      if [ ! -e "$retired" ] && mv -- "$lock" "$retired" 2>/dev/null; then
        if _wm_lock_age_seconds "$retired" && [ "$REPLY" -gt "$stale_after" ]; then
          rm -rf -- "$retired" 2>/dev/null || true
        elif [ ! -e "$lock" ]; then
          mv -- "$retired" "$lock" 2>/dev/null || true
        fi
      fi
    fi
  fi
  rmdir -- "$reaper" 2>/dev/null || true
  return 1
}

_wm_retry_pending_child() {
  local script=$2 company=$3
  _WM_CHILD_LOCK=$1
  printf '%s\n' "$$" >"$_WM_CHILD_LOCK/pid" 2>/dev/null || true
  trap 'rm -rf -- "$_WM_CHILD_LOCK"' EXIT INT TERM
  command -v session_auto_bind_run_with_timeout >/dev/null 2>&1 || return 0
  HQ_NO_UPDATE_CHECK=1 session_auto_bind_run_with_timeout --timeout-ms 5000 \
    bash "$script" --retry-pending "$company" || true
}

_wm_retry_pending_detached() {
  local company=$1 script safe dir lock log
  [ -n "$company" ] || return 0
  script="${HQ_REGISTER_PENDING_SCRIPT:-$HQ_ROOT/core/scripts/register-project.sh}"
  [ -f "$script" ] || return 0
  safe="${company//[^A-Za-z0-9._-]/_}"
  [ -n "$safe" ] || return 0
  dir="${HQ_REGISTER_PENDING_DIR:-${TMPDIR:-/tmp}/hq-register-pending}"
  mkdir -p -- "$dir" 2>/dev/null || return 0
  chmod 700 -- "$dir" 2>/dev/null || true
  lock="$dir/${safe}.lock"
  log="$dir/${safe}.log"
  _wm_lock_acquire "$lock" 30 || return 0
  export -f session_auto_bind_run_with_timeout _wm_retry_pending_child
  nohup bash -c '_wm_retry_pending_child "$@"' _ "$lock" "$script" "$company" >>"$log" 2>&1 </dev/null &
  printf '%s\n' "$!" >"$lock/pid" 2>/dev/null || true
  disown 2>/dev/null || true
}

_wm_retry_pending_detached "$COMPANY" || true

_wm_reconcile_drain() {
  local lock=$1 hq_bin=$2 pending_dir=$3 attempt selected observation last
  local -a pending_files=()
  export LC_ALL=C
  # A crashed lock holder is reclaimable after thirty seconds; keep this
  # detached drainer alive long enough to take over that abandoned lock.
  for ((attempt = 0; attempt < 700; attempt++)); do
    if _wm_lock_acquire "$lock" 30; then
      _WM_CHILD_LOCK=$lock
      printf '%s\n' "$$" >"$_WM_CHILD_LOCK/pid" 2>/dev/null || true
      trap 'rm -rf -- "$_WM_CHILD_LOCK"' EXIT INT TERM

      shopt -s nullglob
      pending_files=("$pending_dir"/*.json)
      [ "${#pending_files[@]}" -gt 0 ] || return 0
      last=$((${#pending_files[@]} - 1))
      selected=${pending_files[$last]}
      observation="$(<"$selected")"
      # Consume one latest snapshot. If a newer one arrives while the current
      # reconcile runs, its own drainer is already waiting on this lock.
      rm -f -- "${pending_files[@]}" 2>/dev/null || true
      [ -f "$observation" ] || return 0
      command -v session_auto_bind_run_with_timeout >/dev/null 2>&1 || return 0
      HQ_NO_UPDATE_CHECK=1 session_auto_bind_run_with_timeout --timeout-ms 10000 \
        "$hq_bin" mesh context reconcile --observation-file "$observation" --machine \
        >/dev/null 2>&1 || true
      return 0
    fi
    sleep 0.05
  done
}

_wm_reconcile_detached() {
  local hq_bin=$1 observation=$2 safe dir lock pending_dir order pending_file pending_tmp worker_pid
  [ -f "$observation" ] || return 0
  [ -n "$hq_bin" ] || return 0
  command -v session_auto_bind_run_with_timeout >/dev/null 2>&1 || return 0
  safe="${SID//[^A-Za-z0-9._-]/_}"
  [ -n "$safe" ] || return 0
  dir="${HQ_WORK_MESH_RECONCILE_DIR:-${TMPDIR:-/tmp}/hq-work-mesh-reconcile}"
  mkdir -p -- "$dir" 2>/dev/null || return 0
  chmod 700 -- "$dir" 2>/dev/null || true
  lock="$dir/$safe.lock"
  pending_dir="$dir/$safe.pending"
  mkdir -p -- "$pending_dir" 2>/dev/null || return 0
  chmod 700 -- "$pending_dir" 2>/dev/null || true
  printf -v order '%020d' "$SEQ"
  pending_file="$pending_dir/$order.$CLIENT_OP.json"
  pending_tmp="$pending_file.tmp.$$"
  printf '%s\n' "$observation" >"$pending_tmp" 2>/dev/null || return 0
  mv -- "$pending_tmp" "$pending_file" 2>/dev/null || {
    rm -f -- "$pending_tmp" 2>/dev/null || true
    return 0
  }
  export -f session_auto_bind_run_with_timeout _wm_lock_age_seconds \
    _wm_reclaim_abandoned_reaper _wm_lock_acquire _wm_reconcile_drain
  nohup bash -c '_wm_reconcile_drain "$@"' _ "$lock" "$hq_bin" "$pending_dir" \
    >/dev/null 2>&1 </dev/null &
  worker_pid=$!
  if [ -n "${HQ_WORK_MESH_RECONCILE_WORKER_PID_FILE:-}" ]; then
    printf '%s\n' "$worker_pid" >>"$HQ_WORK_MESH_RECONCILE_WORKER_PID_FILE" 2>/dev/null || true
  fi
  disown 2>/dev/null || true
}

# Timing / test stub: still record reconcile intent without building a large obs.
if [ "${HQ_WORK_MESH_RECONCILE_STUB:-}" = "1" ]; then
  if [ -n "${HQ_WORK_MESH_RECONCILE_LOG:-}" ]; then
    printf 'reconcile stub %s\n' "$SID" >>"$HQ_WORK_MESH_RECONCILE_LOG" 2>/dev/null || true
  fi
  exit 0
fi

work_mesh_ulid >/dev/null; CLIENT_OP=$REPLY
work_mesh_json_quote "$SID"; _q_sid=$REPLY
work_mesh_json_quote "$HARNESS"; _q_har=$REPLY
work_mesh_json_quote "$ADAPTER"; _q_ad=$REPLY
work_mesh_json_quote "$CLIENT_OP"; _q_op=$REPLY
work_mesh_json_quote "$CWD"; _q_cwd=$REPLY
work_mesh_json_quote "$HQ_ROOT"; _q_root=$REPLY
OBS='{"contractVersion":1,"clientOperationId":'"$_q_op"',"identity":{"sessionId":'"$_q_sid"',"harness":'"$_q_har"',"adapterVersion":'"$_q_ad"
if [ -n "$RUNTIME" ]; then
  work_mesh_json_quote "$RUNTIME"; _q_rt=$REPLY
  OBS+=',"runtimeVersion":'"$_q_rt"
fi
OBS+='},"cwd":'"$_q_cwd"',"hqRoot":'"$_q_root"
if [ -n "$COMPANY" ] || [ -n "$PROJECT" ] || [ -n "$TASK" ]; then
  OBS+=',"trustedContext":{'; _first=1
  if [ -n "$COMPANY" ]; then work_mesh_json_quote "$COMPANY"; OBS+='"companySlug":'"$REPLY"; _first=0; fi
  if [ -n "$PROJECT" ]; then work_mesh_json_quote "$PROJECT"; [ "$_first" -eq 1 ] || OBS+=','; OBS+='"project":'"$REPLY"; _first=0; fi
  if [ -n "$TASK" ]; then work_mesh_json_quote "$TASK"; [ "$_first" -eq 1 ] || OBS+=','; OBS+='"task":'"$REPLY"; fi
  OBS+='}'
fi
OBS+='}'

OBS_DIR="${TMPDIR:-/tmp}/hq-work-mesh-obs"
mkdir -p -- "$OBS_DIR" 2>/dev/null || true
chmod 700 -- "$OBS_DIR" 2>/dev/null || true
OBS_FILE="$OBS_DIR/$SID.$SEQ.json"
printf '%s\n' "$OBS" >"$OBS_FILE" 2>/dev/null || true
if [ -n "${HQ_WORK_MESH_RECONCILE_LOG:-}" ]; then
  printf 'reconcile %s\n' "$OBS_FILE" >>"$HQ_WORK_MESH_RECONCILE_LOG" 2>/dev/null || true
fi
HQ_BIN="$(command -v hq 2>/dev/null || true)"
if [ -n "$HQ_BIN" ] && [ -f "$OBS_FILE" ]; then
  # Resolve an otherwise-unbound session before writing a device-default scope.
  # The observation deliberately carries cwd/repo evidence without a trusted
  # company, so the CLI can classify a default conflict instead of accepting a
  # shell-level preference as a dispatch fact.
  if [ -z "$BOUND_COMPANY" ] && command -v session_auto_bind_run_with_timeout >/dev/null 2>&1; then
    PREFLIGHT_STATE_EXISTED=0
    PREFLIGHT_REPAIR=false
    [ -f "$WORK_CONTEXT_ROOT/sessions/$SID.json" ] && PREFLIGHT_STATE_EXISTED=1
    PREFLIGHT_STATUS=0
    # Five-minute fallback TTL; the checksummed device config invalidates a
    # changed default on the very next SessionStart instead of waiting for it.
    PREFLIGHT_CACHE_TTL_SECONDS=300
    PREFLIGHT_CACHE_FILE="$WORK_CONTEXT_ROOT/sessionstart-preflight-cache.json"
    PREFLIGHT_CACHEABLE=0
    PREFLIGHT_CACHE_KEY=""
    PREFLIGHT_CACHE_HIT=""
    PREFLIGHT_GIT_INCLUDES=0
    if [ "$PREFLIGHT_STATE_EXISTED" -eq 0 ] && command -v jq >/dev/null 2>&1; then
      PREFLIGHT_CACHEABLE=1
      _wm_preflight_checksum() {
        [ -f "$1" ] || { REPLY=missing; return 0; }
        REPLY="$(cksum < "$1" 2>/dev/null)" || REPLY=unreadable
      }
      _wm_preflight_git_config() {
        # A config include can change effective company/remote scope without
        # changing the including file. Such repositories bypass the cache.
        local dir="$CWD" git_entry git_dir common_dir config_path config_fingerprint worktree_fingerprint
        while [ -n "$dir" ] && [ "$dir" != / ]; do
          git_entry="$dir/.git"
          if [ -d "$git_entry" ]; then
            config_path="$git_entry/config"
            common_dir="$git_entry/commondir"
            if [ -f "$common_dir" ]; then
              IFS= read -r common_dir < "$common_dir" || common_dir=""
              case "$common_dir" in /*) ;; *) common_dir="$git_entry/$common_dir" ;; esac
              [ -f "$common_dir/config" ] && config_path="$common_dir/config"
            fi
            if grep -Eiq '^[[:space:]]*\[include(if)?([[:space:]]|\])' "$config_path" 2>/dev/null; then PREFLIGHT_GIT_INCLUDES=1; fi
            _wm_preflight_checksum "$config_path"; config_fingerprint=$REPLY
            if [ -f "$git_entry/config.worktree" ]; then
              if grep -Eiq '^[[:space:]]*\[include(if)?([[:space:]]|\])' "$git_entry/config.worktree" 2>/dev/null; then PREFLIGHT_GIT_INCLUDES=1; fi
              _wm_preflight_checksum "$git_entry/config.worktree"; worktree_fingerprint=$REPLY
              REPLY="$git_entry:$config_fingerprint:worktree:$worktree_fingerprint"
            else
              REPLY="$git_entry:$config_fingerprint"
            fi
            return 0
          elif [ -f "$git_entry" ]; then
            git_dir="$(sed -n 's/^gitdir: //p' "$git_entry" 2>/dev/null | head -n 1)"
            case "$git_dir" in /*) ;; *) git_dir="$dir/$git_dir" ;; esac
            config_path="$git_dir/config"
            common_dir="$git_dir/commondir"
            if [ -f "$common_dir" ]; then
              IFS= read -r common_dir < "$common_dir" || common_dir=""
              case "$common_dir" in /*) ;; *) common_dir="$git_dir/$common_dir" ;; esac
              [ -f "$common_dir/config" ] && config_path="$common_dir/config"
            fi
            if grep -Eiq '^[[:space:]]*\[include(if)?([[:space:]]|\])' "$config_path" 2>/dev/null; then PREFLIGHT_GIT_INCLUDES=1; fi
            _wm_preflight_checksum "$config_path"; config_fingerprint=$REPLY
            if [ -f "$git_dir/config.worktree" ]; then
              if grep -Eiq '^[[:space:]]*\[include(if)?([[:space:]]|\])' "$git_dir/config.worktree" 2>/dev/null; then PREFLIGHT_GIT_INCLUDES=1; fi
              _wm_preflight_checksum "$git_dir/config.worktree"; worktree_fingerprint=$REPLY
              REPLY="$git_dir:$config_fingerprint:worktree:$worktree_fingerprint"
            else
              REPLY="$git_dir:$config_fingerprint"
            fi
            return 0
          fi
          dir="${dir%/*}"
        done
        REPLY=none
      }
      _wm_preflight_checksum "$WORK_CONTEXT_ROOT/config.json"; PREFLIGHT_CONFIG_FINGERPRINT=$REPLY
      _wm_preflight_checksum "$HQ_ROOT/companies/manifest.yaml"; PREFLIGHT_MANIFEST_FINGERPRINT=$REPLY
      PREFLIGHT_IDENTITY_FILE="${HQ_AGENT_IDENTITY_FILE:-/var/lib/hq-agent/identity.json}"
      _wm_preflight_checksum "$PREFLIGHT_IDENTITY_FILE"; PREFLIGHT_IDENTITY_FINGERPRINT="$PREFLIGHT_IDENTITY_FILE:$REPLY"
      _wm_preflight_git_config; PREFLIGHT_GIT_FINGERPRINT=$REPLY
      [ "$PREFLIGHT_GIT_INCLUDES" -eq 0 ] || PREFLIGHT_CACHEABLE=0
      PREFLIGHT_CACHE_KEY="$(jq -cn \
        --arg cwd "$CWD" --arg root "$HQ_ROOT" --arg project "$PROJECT" --arg task "$TASK" \
        --arg config "$PREFLIGHT_CONFIG_FINGERPRINT" --arg manifest "$PREFLIGHT_MANIFEST_FINGERPRINT" \
        --arg git "$PREFLIGHT_GIT_FINGERPRINT" --arg identity "$PREFLIGHT_IDENTITY_FINGERPRINT" \
        '{cwd:$cwd,hqRoot:$root,project:$project,task:$task,deviceConfig:$config,manifest:$manifest,gitConfig:$git,agentIdentity:$identity}' 2>/dev/null)" || PREFLIGHT_CACHE_KEY=""
      if [ -n "$PREFLIGHT_CACHE_KEY" ] && [ -r "$PREFLIGHT_CACHE_FILE" ]; then
        PREFLIGHT_CACHE_NOW="$(date +%s 2>/dev/null || true)"
        case "$PREFLIGHT_CACHE_NOW" in ''|*[!0-9]*) PREFLIGHT_CACHE_NOW="" ;; esac
        if [ -n "$PREFLIGHT_CACHE_NOW" ]; then
          PREFLIGHT_CACHE_HIT="$(jq -cer --arg key "$PREFLIGHT_CACHE_KEY" --argjson now "$PREFLIGHT_CACHE_NOW" \
            --argjson ttl "$PREFLIGHT_CACHE_TTL_SECONDS" '
              select(.version == 1 and .key == $key and (.createdAt | type == "number")
                and ($now >= .createdAt) and (($now - .createdAt) <= $ttl)
                and (.repair == true or .repair == false) and (.result | type == "object"))
              | {repair:.repair,result:.result,artifacts:(.artifacts // {})}
            ' "$PREFLIGHT_CACHE_FILE" 2>/dev/null)" || PREFLIGHT_CACHE_HIT=""
        fi
      fi
    fi
    if [ -n "$PREFLIGHT_CACHE_HIT" ]; then
      PREFLIGHT_RESULT="$(printf '%s' "$PREFLIGHT_CACHE_HIT" | jq -c --arg sid "$SID" --arg op "$CLIENT_OP" \
        '.result | .sessionId=$sid | .clientOperationId=$op' 2>/dev/null)" || PREFLIGHT_RESULT=""
      PREFLIGHT_REPAIR="$(printf '%s' "$PREFLIGHT_CACHE_HIT" | jq -r 'if .repair then "true" else "false" end' 2>/dev/null)" || PREFLIGHT_REPAIR=false
      PREFLIGHT_CACHED_STATE="$(printf '%s' "$PREFLIGHT_CACHE_HIT" | jq -r '.artifacts.sessionState // empty' 2>/dev/null)" || PREFLIGHT_CACHED_STATE=""
      if [ -n "$PREFLIGHT_CACHED_STATE" ]; then
        mkdir -p -- "$WORK_CONTEXT_ROOT/sessions/$SID" 2>/dev/null || true
        chmod 700 -- "$WORK_CONTEXT_ROOT/sessions/$SID" 2>/dev/null || true
        printf '%s' "$PREFLIGHT_CACHED_STATE" | jq -c --arg sid "$SID" --arg op "$CLIENT_OP" \
          'if type == "object" then .sessionId=$sid | .clientOperationId=$op else . end' \
          > "$WORK_CONTEXT_ROOT/sessions/$SID.json.tmp" 2>/dev/null && \
          chmod 600 -- "$WORK_CONTEXT_ROOT/sessions/$SID.json.tmp" 2>/dev/null && \
          mv -f -- "$WORK_CONTEXT_ROOT/sessions/$SID.json.tmp" "$WORK_CONTEXT_ROOT/sessions/$SID.json" 2>/dev/null || true
      fi
      if [ "$(printf '%s' "$PREFLIGHT_CACHE_HIT" | jq -r '.artifacts.board // empty' 2>/dev/null)" ]; then
        mkdir -p -- "$WORK_CONTEXT_ROOT/sessions/$SID" 2>/dev/null || true
        printf '%s' "$PREFLIGHT_CACHE_HIT" | jq -jr '.artifacts.board // empty' \
          > "$WORK_CONTEXT_ROOT/sessions/$SID/board.md.tmp" 2>/dev/null && \
          chmod 600 -- "$WORK_CONTEXT_ROOT/sessions/$SID/board.md.tmp" 2>/dev/null && \
          mv -f -- "$WORK_CONTEXT_ROOT/sessions/$SID/board.md.tmp" "$WORK_CONTEXT_ROOT/sessions/$SID/board.md" 2>/dev/null || true
      fi
    else
      PREFLIGHT_RESULT="$(HQ_NO_UPDATE_CHECK=1 session_auto_bind_run_with_timeout \
        "$HQ_BIN" mesh context reconcile --observation-file "$OBS_FILE" --machine --offline 2>/dev/null)" || PREFLIGHT_STATUS=$?
    fi
    PREFLIGHT_CLASSIFICATION=""
    PREFLIGHT_SLUG=""
    PREFLIGHT_UID=""
    if [ "$PREFLIGHT_STATUS" -eq 0 ] && command -v jq >/dev/null 2>&1; then
      # Allow-list is the vendored CLI fixture file, not a hand-written enum.
      # contractVersion is whatever that file pins. Bump both repos together:
      # hq-cli WORK_CONTEXT_CONTRACT_VERSION + contracts/preflight/v<N>/,
      # this file, and the == 1 pin in preflight-contract-fixtures.test.sh.
      PREFLIGHT_FIXTURES_FILE="${HOOK_FILE%/*}/preflight-fixtures.json"
      PREFLIGHT_CLASSIFICATION="$(printf '%s' "$PREFLIGHT_RESULT" | jq -er --arg sid "$SID" --arg op "$CLIENT_OP" --slurpfile pf "$PREFLIGHT_FIXTURES_FILE" '
        if type == "object"
          and ($pf[0].contractVersion | type == "number")
          and .contractVersion == $pf[0].contractVersion
          and (.sessionId | type == "string") and .sessionId == $sid
          and (.clientOperationId | type == "string") and .clientOperationId == $op
          and (.kind | type == "string")
          and (.classification | type == "string")
          and (.classification as $c | (($pf[0].classifications // []) | index($c)) != null)
          and (.delivery | type == "string") and (.delivery == "clean" or .delivery == "queued" or .delivery == "acked" or .delivery == "quarantined")
          and (.lifecycle | type == "string") and (.lifecycle == "open" or .lifecycle == "terminal")
        then .classification else empty end
      ' 2>/dev/null)" || PREFLIGHT_CLASSIFICATION=""
      PREFLIGHT_SLUG="$(printf '%s' "$PREFLIGHT_RESULT" | jq -er '.companySlug | select(type == "string" and length > 0)' 2>/dev/null)" || PREFLIGHT_SLUG=""
      PREFLIGHT_UID="$(printf '%s' "$PREFLIGHT_RESULT" | jq -er '.companyUid | select(type == "string" and length > 0)' 2>/dev/null)" || PREFLIGHT_UID=""
      if [ -z "$PREFLIGHT_CACHE_HIT" ]; then
        PREFLIGHT_REPAIR="$(HQ_NO_UPDATE_CHECK=1 session_auto_bind_run_with_timeout \
          "$HQ_BIN" mesh context default get --json 2>/dev/null \
          | jq -er '(.repairHeldWithDefault // (.defaultCompany.repairHeldWithDefault // false)) | if . == true then "true" else "false" end' 2>/dev/null)" || PREFLIGHT_REPAIR=false
      fi
      if [ "$PREFLIGHT_CACHEABLE" -eq 1 ] && [ -n "$PREFLIGHT_CACHE_KEY" ] && [ -z "$PREFLIGHT_CACHE_HIT" ]; then
        case "$PREFLIGHT_CLASSIFICATION" in
          company_conflict|bound|needs_project|needs_task|needs_company|unresolved|untracked)
            case "$PREFLIGHT_REPAIR" in true) PREFLIGHT_REPAIR_JSON=true ;; *) PREFLIGHT_REPAIR_JSON=false ;; esac
            if PREFLIGHT_CACHE_NOW="$(date +%s 2>/dev/null)" && [[ "$PREFLIGHT_CACHE_NOW" =~ ^[0-9]+$ ]]; then
              mkdir -p -- "$WORK_CONTEXT_ROOT" 2>/dev/null || true
              chmod 700 -- "$WORK_CONTEXT_ROOT" 2>/dev/null || true
              PREFLIGHT_CACHE_TMP="$(mktemp "$WORK_CONTEXT_ROOT/.sessionstart-preflight-cache.XXXXXX" 2>/dev/null)" || PREFLIGHT_CACHE_TMP=""
              if [ -n "$PREFLIGHT_CACHE_TMP" ]; then
                PREFLIGHT_CACHE_STATE_FILE="$WORK_CONTEXT_ROOT/sessions/$SID.json"
                PREFLIGHT_CACHE_BOARD_FILE="$WORK_CONTEXT_ROOT/sessions/$SID/board.md"
                [ -r "$PREFLIGHT_CACHE_STATE_FILE" ] || PREFLIGHT_CACHE_STATE_FILE=/dev/null
                [ -r "$PREFLIGHT_CACHE_BOARD_FILE" ] || PREFLIGHT_CACHE_BOARD_FILE=/dev/null
                if printf '%s' "$PREFLIGHT_RESULT" | jq -cer --arg key "$PREFLIGHT_CACHE_KEY" \
                  --argjson now "$PREFLIGHT_CACHE_NOW" --argjson repair "$PREFLIGHT_REPAIR_JSON" \
                  --rawfile state "$PREFLIGHT_CACHE_STATE_FILE" \
                  --rawfile board "$PREFLIGHT_CACHE_BOARD_FILE" \
                  '{version:1,createdAt:$now,key:$key,repair:$repair,result:.,artifacts:{sessionState:($state | select(length > 0) // null),board:($board | select(length > 0) // null)}}' \
                  > "$PREFLIGHT_CACHE_TMP" 2>/dev/null; then
                  chmod 600 -- "$PREFLIGHT_CACHE_TMP" 2>/dev/null || true
                  mv -f -- "$PREFLIGHT_CACHE_TMP" "$PREFLIGHT_CACHE_FILE" 2>/dev/null || rm -f -- "$PREFLIGHT_CACHE_TMP" 2>/dev/null || true
                else
                  rm -f -- "$PREFLIGHT_CACHE_TMP" 2>/dev/null || true
                fi
              fi
            fi
            ;;
        esac
      fi
    fi
    case "$PREFLIGHT_CLASSIFICATION" in
      company_conflict|bound|needs_project|needs_task)
        PREFLIGHT_KIND="$(printf '%s' "$PREFLIGHT_RESULT" | jq -er '.kind' 2>/dev/null)" || PREFLIGHT_KIND=""
        case "$PREFLIGHT_CLASSIFICATION:$PREFLIGHT_KIND" in
          company_conflict:company_conflict)
            printf '%s\n' 'work-mesh: company_conflict; leaving device-default session unbound' >&2
            ;;
          bound:bound|bound:queued|needs_project:needs_project|needs_project:queued|needs_task:needs_task|needs_task:queued)
            # Bind the exact slug/uid validated for this session+operation;
            # never re-read the mutable device default after preflight.
            [ -n "$PREFLIGHT_SLUG" ] && [ -n "$PREFLIGHT_UID" ] && \
              session_auto_bind_apply_validated_default "$HQ_ROOT" "$SID" "$PREFLIGHT_SLUG" "$PREFLIGHT_UID" "$PREFLIGHT_STATE_EXISTED" "$PREFLIGHT_REPAIR" || true
            ;;
          *)
            printf '%s\n' 'work-mesh: preflight unresolved; leaving device-default session unbound' >&2
            ;;
        esac
        ;;
      needs_company)
        # No configured/validated default is an ordinary no-op, not an error.
        ;;
      unresolved|untracked)
        printf '%s\n' 'work-mesh: preflight unresolved; leaving device-default session unbound' >&2
        ;;
      "")
        if printf '%s' "$PREFLIGHT_RESULT" | jq -e 'type == "object"' >/dev/null 2>&1; then
          printf '%s\n' 'work-mesh: preflight rejected; classification not in contract' >&2
        else
          printf '%s\n' 'work-mesh: preflight unresolved; leaving device-default session unbound' >&2
        fi
        ;;
      *)
        printf '%s\n' 'work-mesh: preflight rejected; classification not in contract' >&2
        ;;
    esac
  fi
  _wm_reconcile_detached "$HQ_BIN" "$OBS_FILE"
fi
exit 0
