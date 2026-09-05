#!/usr/bin/env bash
# hq-core: public
# work-mesh-enqueue.sh — append one Work Mesh Live spool line with printf only.
#
# Sourced by hooks. Never execute directly.
# No jq. No node. One write under PIPE_BUF via printf >> spool (O_APPEND).
#
# Line format is byte-identical to hq-cli formatSpoolLine() for the same inputs
# (fixed key order, compact JSON). See src/lib/mesh/live/format-spool-line.ts.
#
# Usage:
#   source "$HQ_ROOT/core/scripts/lib/work-mesh-enqueue.sh"
#   work_mesh_enqueue \
#     --kind session_start \
#     --session-id "$sid" \
#     --harness claude-code \
#     --adapter-version 1.0.0 \
#     --seq 1 \
#     [--event-id ULID] [--at ISO8601] [--runtime-version V] \
#     [--task-id T] [--status S] [--reason R] [--summary S] \
#     [--cwd P] [--hq-root P] [--company-slug S] [--project P] [--task T] \
#     [--tool-writes N] [--spool PATH]

# Crockford base32 alphabet (ULID) — no I L O U
_WORK_MESH_CROCKFORD='0123456789ABCDEFGHJKMNPQRSTVWXYZ'

# work_mesh_json_quote <string>
#   Set REPLY to a JSON string value (with surrounding quotes). No subshell.
#   Fast path for values without \ " or controls (typical session metadata).
work_mesh_json_quote() {
  local s=$1
  case "$s" in
    *'\\'*|*'\"'*|*$'\n'*|*$'\r'*|*$'\t'*)
      s=${s//'\'/'\\'}
      s=${s//'"'/'\"'}
      s=${s//$'\n'/'\n'}
      s=${s//$'\r'/'\r'}
      s=${s//$'\t'/'\t'}
      REPLY="\"${s}\""
      ;;
    *)
      REPLY="\"${s}\""
      ;;
  esac
}

# work_mesh_json_escape <string>
#   Print a JSON string value (compat wrapper for tests / callers).
work_mesh_json_escape() {
  work_mesh_json_quote "$1"
  printf '%s' "$REPLY"
}

# Cached: bash 5.1+ has $SRANDOM (re-read yields new entropy).
_WORK_MESH_HAS_SRANDOM=0
if [[ ${BASH_VERSINFO[0]} -gt 5 || ( ${BASH_VERSINFO[0]} -eq 5 && ${BASH_VERSINFO[1]} -ge 1 ) ]]; then
  _WORK_MESH_HAS_SRANDOM=1
fi

# work_mesh_ulid
#   Print a 26-char Crockford ULID (48-bit ms time + 80-bit entropy).
#   Prefer bash 5+ builtins ($EPOCHREALTIME, $SRANDOM) to stay under the
#   20ms hook budget; fall back to date/dd/od on older bash.
#   Also sets REPLY (avoids command-substitution fork when callers use it).
work_mesh_ulid() {
  local alphabet=$_WORK_MESH_CROCKFORD
  local now_ms time_part="" rand_part=""
  local -i i rem val

  if [[ -n "${EPOCHREALTIME-}" ]]; then
    local sec=${EPOCHREALTIME%.*}
    local frac=${EPOCHREALTIME#*.}000
    frac=${frac:0:3}
    now_ms=$((10#$sec * 1000 + 10#$frac))
  else
    now_ms=$(date +%s%3N 2>/dev/null || true)
    case "$now_ms" in
      ""|*[!0-9]*)
        now_ms=$(date +%s)
        now_ms=$((now_ms * 1000))
        ;;
    esac
  fi

  # 48-bit timestamp → 10 Crockford chars (fits in signed 64-bit).
  val=$((now_ms & 0xFFFFFFFFFFFF))
  for ((i = 0; i < 10; i++)); do
    rem=$((val & 31))
    time_part="${alphabet:rem:1}${time_part}"
    val=$((val >> 5))
  done

  local -a b=()
  if [ "$_WORK_MESH_HAS_SRANDOM" -eq 1 ]; then
    for ((i = 0; i < 10; i++)); do
      b+=($((SRANDOM & 255)))
    done
  else
    local bytes
    bytes=$(dd if=/dev/urandom bs=10 count=1 2>/dev/null | od -An -tu1 | tr -s ' ' '\n' | grep -E '^[0-9]+$' | head -n 10 | tr '\n' ' ')
    # shellcheck disable=SC2206
    local -a bb=($bytes)
    b=("${bb[@]}")
    while [ "${#b[@]}" -lt 10 ]; do
      b+=($((RANDOM % 256)))
    done
  fi

  # Encode 80 bits MSB-first as 16×5-bit Crockford chars without a 80-bit int:
  # maintain a bit buffer that never exceeds ~16 bits of pending state.
  local -i bitbuf=0 bits=0 bi=0 byte
  rand_part=
  for ((i = 0; i < 16; i++)); do
    while [ "$bits" -lt 5 ]; do
      if [ "$bi" -lt 10 ]; then
        byte=${b[bi]}
        bi=$((bi + 1))
        bitbuf=$(((bitbuf << 8) | (byte & 255)))
        bits=$((bits + 8))
      else
        bitbuf=$((bitbuf << 5))
        bits=$((bits + 5))
      fi
    done
    rem=$(((bitbuf >> (bits - 5)) & 31))
    bits=$((bits - 5))
    rand_part+="${alphabet:rem:1}"
  done

  REPLY="${time_part}${rand_part}"
  printf '%s' "$REPLY"
}

# work_mesh_ensure_spool <path>
#   Create parent dir 0700 and spool file 0600 when missing.
#   Hot path: existing spool returns immediately (no chmod/stat storms).
work_mesh_ensure_spool() {
  local spool=$1 dir
  if [ -f "$spool" ]; then
    return 0
  fi
  dir=$(dirname -- "$spool")
  mkdir -p -- "$dir" 2>/dev/null || true
  chmod 700 -- "$dir" 2>/dev/null || true
  (umask 077; printf '' >"$spool") || return 1
  chmod 600 -- "$spool" 2>/dev/null || true
}

# work_mesh_enqueue [options]
#   Build one compact JSON line and append with a single printf write.
work_mesh_enqueue() {
  local kind="" session_id="" harness="" adapter_version="" runtime_version=""
  local at="" seq="" event_id="" task_id="" status="" reason="" summary=""
  local cwd="" hq_root="" company_slug="" project="" task="" tool_writes=""
  local spool=${WORK_MESH_SPOOL:-"${HOME}/.hq/work-mesh/spool.jsonl"}

  while [ $# -gt 0 ]; do
    case "$1" in
      --kind) kind=$2; shift 2 ;;
      --session-id) session_id=$2; shift 2 ;;
      --harness) harness=$2; shift 2 ;;
      --adapter-version) adapter_version=$2; shift 2 ;;
      --runtime-version) runtime_version=$2; shift 2 ;;
      --at) at=$2; shift 2 ;;
      --seq) seq=$2; shift 2 ;;
      --event-id) event_id=$2; shift 2 ;;
      --task-id) task_id=$2; shift 2 ;;
      --status) status=$2; shift 2 ;;
      --reason) reason=$2; shift 2 ;;
      --summary) summary=$2; shift 2 ;;
      --cwd) cwd=$2; shift 2 ;;
      --hq-root) hq_root=$2; shift 2 ;;
      --company-slug) company_slug=$2; shift 2 ;;
      --project) project=$2; shift 2 ;;
      --task) task=$2; shift 2 ;;
      --tool-writes) tool_writes=$2; shift 2 ;;
      --spool) spool=$2; shift 2 ;;
      *) printf 'work_mesh_enqueue: unknown arg %s\n' "$1" >&2; return 2 ;;
    esac
  done

  if [ -z "$session_id" ]; then
    printf 'work_mesh_enqueue: sessionId required\n' >&2
    return 1
  fi
  if [ -z "$kind" ] || [ -z "$harness" ] || [ -z "$adapter_version" ] || [ -z "$seq" ]; then
    printf 'work_mesh_enqueue: kind, harness, adapter-version, seq required\n' >&2
    return 1
  fi

  if [ -z "$event_id" ]; then
    work_mesh_ulid >/dev/null
    event_id=$REPLY
  fi
  if [ -z "$at" ]; then
    # Builtin UTC clock (bash 4.2+ printf %( )T) — no date(1) fork.
    if TZ=UTC printf -v at '%(%Y-%m-%dT%H:%M:%S)T.000Z' -1 2>/dev/null && [ -n "$at" ]; then
      :
    else
      at=$(date -u +"%Y-%m-%dT%H:%M:%S.000Z" 2>/dev/null || date -u +"%Y-%m-%dT%H:%M:%SZ")
    fi
  fi

  # Build compact JSON without command-substitution forks (keeps hook p95 low).
  local line q
  work_mesh_json_quote "$event_id"; q=$REPLY
  line='{"v":1,"eventId":'"$q"
  work_mesh_json_quote "$kind"; q=$REPLY
  line+=',"kind":'"$q"
  work_mesh_json_quote "$session_id"; q=$REPLY
  line+=',"sessionId":'"$q"
  work_mesh_json_quote "$harness"; q=$REPLY
  line+=',"harness":'"$q"
  work_mesh_json_quote "$adapter_version"; q=$REPLY
  line+=',"adapterVersion":'"$q"
  if [ -n "$runtime_version" ]; then
    work_mesh_json_quote "$runtime_version"; q=$REPLY
    line+=',"runtimeVersion":'"$q"
  fi
  work_mesh_json_quote "$at"; q=$REPLY
  line+=',"at":'"$q"',"seq":'"$seq"
  if [ -n "$task_id" ]; then
    work_mesh_json_quote "$task_id"; q=$REPLY
    line+=',"taskId":'"$q"
  fi
  if [ -n "$status" ]; then
    work_mesh_json_quote "$status"; q=$REPLY
    line+=',"status":'"$q"
  fi
  if [ -n "$reason" ]; then
    work_mesh_json_quote "$reason"; q=$REPLY
    line+=',"reason":'"$q"
  fi
  if [ -n "$summary" ]; then
    work_mesh_json_quote "$summary"; q=$REPLY
    line+=',"summary":'"$q"
  fi
  if [ -n "$cwd" ]; then
    work_mesh_json_quote "$cwd"; q=$REPLY
    line+=',"cwd":'"$q"
  fi
  if [ -n "$hq_root" ]; then
    work_mesh_json_quote "$hq_root"; q=$REPLY
    line+=',"hqRoot":'"$q"
  fi
  if [ -n "$company_slug" ]; then
    work_mesh_json_quote "$company_slug"; q=$REPLY
    line+=',"companySlug":'"$q"
  fi
  if [ -n "$project" ]; then
    work_mesh_json_quote "$project"; q=$REPLY
    line+=',"project":'"$q"
  fi
  if [ -n "$task" ]; then
    work_mesh_json_quote "$task"; q=$REPLY
    line+=',"task":'"$q"
  fi
  if [ -n "$tool_writes" ]; then
    line+=',"toolWrites":'"$tool_writes"
  fi
  line+='}'

  work_mesh_ensure_spool "$spool" || return 1
  # Single write under O_APPEND (printf → one write syscall for the line).
  printf '%s\n' "$line" >>"$spool" || return 1
  return 0
}
