#!/bin/bash
# repo-run-registry.sh — CLI for cross-session repo-level run coordination
#
# Manages workspace/orchestrator/active-runs.json: a global registry of
# long-running Claude sessions that currently hold a repo (scope=repo) or
# a specific worktree (scope=worktree:<path>). Other sessions consult this
# registry at SessionStart and before Edit/Write/dangerous Bash to avoid
# concurrent edit conflicts.
#
# See plan: ~/.claude/plans/structured-stargazing-candy.md
# Policy: core/policies/repo-run-coordination.md
#
# Subcommands:
#   register  --run-id X --pid N --session-id S --command C --project P --repo R --scope SC [--host H]
#   deregister --run-id X
#   heartbeat --run-id X
#   list
#   check --target PATH [--pid N] [--session-id S]
#   clean-stale
#   owner-of --path PATH
#
# Exit codes:
#   0 = ok / not blocked
#   2 = blocked by foreign owner (check only)
#   1 = usage / internal error

set -euo pipefail

HQ_ROOT="${HQ_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
# shellcheck source=core/scripts/lib/portable.sh
. "$HQ_ROOT/core/scripts/lib/portable.sh"
REG_DIR="$HQ_ROOT/workspace/orchestrator"
REG_FILE="$REG_DIR/active-runs.json"
LOCK_DIR="$REG_FILE.lock"
RECOVER_DIR="$LOCK_DIR.recover"
WRITER_WAIT_MARKER=""
WRITER_WAIT_PREVIOUS_EXIT_TRAP=""
# Resolve the orchestrator settings file. personal/settings is read DIRECTLY now
# (the reindex symlink mirror into core/settings is retired). orchestrator.yaml
# ships as a core default; unlike the list-shaped overlays (policies/workers/
# knowledge, where core + personal BOTH surface), this is a singleton config
# file — so a personal copy, when present, overrides the shipped default.
ORCH_YAML="$HQ_ROOT/core/settings/orchestrator.yaml"
if [[ -f "$HQ_ROOT/personal/settings/orchestrator.yaml" ]]; then
  ORCH_YAML="$HQ_ROOT/personal/settings/orchestrator.yaml"
fi

# ---------- helpers ----------

_log() { echo "[repo-run-registry] $*" >&2; }
_die() { echo "ERROR: $*" >&2; exit 1; }

_iso_now() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

# ISO8601 (UTC, trailing Z) → epoch seconds. BSD date first, then GNU date.
# A BSD-only parse returned 0 on Linux, so _prune_stale treated every live
# run as stale and deleted it before any check could block on it.
_iso_to_epoch() {
  local iso="$1"
  date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$iso" +%s 2>/dev/null \
    || date -u -d "$iso" +%s 2>/dev/null \
    || echo 0
}

_hostname() { hostname -s 2>/dev/null || echo "unknown"; }

_abs_path() {
  local p="$1"
  if [[ "$p" = /* ]]; then
    echo "$p"
  else
    (cd "$(dirname "$p")" 2>/dev/null && echo "$(pwd)/$(basename "$p")") || echo "$p"
  fi
}

_ensure_reg() {
  mkdir -p "$REG_DIR"
  if [[ ! -f "$REG_FILE" ]]; then
    echo '{"version":1,"runs":[]}' > "$REG_FILE"
  fi
}

# Atomic mutex via mkdir — single-machine only
_lock() { _try_lock || _die "registry lock timeout"; }

_lock_is_stale() {
  local lock_path="${1:-$LOCK_DIR}"
  [[ -d "$lock_path" ]] || return 1
  local mtime age
  mtime="$(portable_stat_mtime "$lock_path" 2>/dev/null)" || return 1
  case "$mtime" in
    ''|*[!0-9]*) return 1 ;;
  esac
  age=$(( $(date +%s) - mtime ))
  [[ $age -gt 60 ]]
}

_clear_writer_wait_marker() {
  [[ -n "$WRITER_WAIT_MARKER" ]] || return 0
  rm -f "$WRITER_WAIT_MARKER" 2>/dev/null || true
  WRITER_WAIT_MARKER=""
}

_restore_writer_wait_exit_trap() {
  if [[ -n "$WRITER_WAIT_PREVIOUS_EXIT_TRAP" ]]; then
    eval "$WRITER_WAIT_PREVIOUS_EXIT_TRAP"
  else
    trap - EXIT
  fi
  WRITER_WAIT_PREVIOUS_EXIT_TRAP=""
}

_writer_wait_marker_is_live() {
  local marker="$1" pid mtime age
  pid="${marker##*.wait.}"
  case "$pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  _is_pid_alive "$pid" || return 1
  mtime="$(portable_stat_mtime "$marker" 2>/dev/null)" || return 1
  case "$mtime" in
    ''|*[!0-9]*) return 1 ;;
  esac
  age=$(( $(date +%s) - mtime ))
  [[ $age -le 60 ]]
}

_has_live_writer_wait_marker() {
  local marker
  for marker in "$LOCK_DIR.wait."*; do
    [[ -f "$marker" ]] || continue
    _writer_wait_marker_is_live "$marker" && return 0
  done
  return 1
}

_prune_dead_writer_wait_markers() {
  local marker pid mtime age
  for marker in "$LOCK_DIR.wait."*; do
    [[ -f "$marker" ]] || continue
    pid="${marker##*.wait.}"
    case "$pid" in
      ''|*[!0-9]*) rm -f "$marker" 2>/dev/null || true; continue ;;
    esac
    if ! _is_pid_alive "$pid"; then
      rm -f "$marker" 2>/dev/null || true
      continue
    fi
    mtime="$(portable_stat_mtime "$marker" 2>/dev/null)" || continue
    case "$mtime" in
      ''|*[!0-9]*) continue ;;
    esac
    age=$(( $(date +%s) - mtime ))
    [[ $age -gt 60 ]] && rm -f "$marker" 2>/dev/null || true
  done
}

# Reclaim a stale registry lock only while holding a separate, non-waiting
# mutex. An expired recovery directory is also reclaimable; a process paused
# for more than 60 seconds inside this deliberately tiny critical section is
# the residual limit of this directory-mutex protocol.
_recover_stale_lock() {
  local removed=1
  if ! mkdir "$RECOVER_DIR" 2>/dev/null; then
    if _lock_is_stale "$RECOVER_DIR"; then
      rm -rf "$RECOVER_DIR" 2>/dev/null || true
    fi
    return 1
  fi

  if _lock_is_stale "$LOCK_DIR"; then
    rm -rf "$LOCK_DIR" 2>/dev/null || true
    [[ ! -e "$LOCK_DIR" ]] && removed=0
  fi
  rmdir "$RECOVER_DIR" 2>/dev/null || true
  return "$removed"
}

# Returns 1 instead of exiting when the lock stays busy (~5s).
_try_lock() {
  local tries=0 wait_marker_published=0
  local max=50
  # register takes the lock before _ensure_reg; without its parent the mkdir
  # below can never succeed and the first register on a fresh install timed out.
  mkdir -p "$REG_DIR" 2>/dev/null || true
  _prune_dead_writer_wait_markers
  while ! mkdir "$LOCK_DIR" 2>/dev/null; do
    if [[ $wait_marker_published -eq 0 ]]; then
      WRITER_WAIT_MARKER="$LOCK_DIR.wait.$$"
      if touch "$WRITER_WAIT_MARKER" 2>/dev/null; then
        WRITER_WAIT_PREVIOUS_EXIT_TRAP="$(trap -p EXIT)"
        trap '_clear_writer_wait_marker' EXIT
        wait_marker_published=1
      else
        WRITER_WAIT_MARKER=""
        _log "could not publish writer wait marker"
      fi
    fi
    tries=$((tries + 1))
    if [[ $tries -ge $max ]]; then
      # Use the same finite retry budget; if recovery or the final mkdir loses
      # to another writer, give up rather than restarting the loop.
      if _recover_stale_lock && mkdir "$LOCK_DIR" 2>/dev/null; then
        if [[ $wait_marker_published -eq 1 ]]; then
          _clear_writer_wait_marker
          _restore_writer_wait_exit_trap
        fi
        return 0
      fi
      if [[ $wait_marker_published -eq 1 ]]; then
        _clear_writer_wait_marker
        _restore_writer_wait_exit_trap
      fi
      return 1
    fi
    sleep 0.1
  done
  if [[ $wait_marker_published -eq 1 ]]; then
    _clear_writer_wait_marker
    _restore_writer_wait_exit_trap
  fi
  return 0
}
_unlock() { rm -rf "$LOCK_DIR" 2>/dev/null || true; }

# list, owner-of and check prune too. Hold the lock so a reader cannot write an
# older snapshot over a concurrent register or heartbeat. If the lock stays
# busy, skip the prune and answer from the file as it is.
_prune_stale_locked() {
  mkdir -p "$REG_DIR" 2>/dev/null || return 0
  # Readers answer from the current file while a live writer is waiting; they
  # never queue for the optional prune and do not remove expired markers.
  _has_live_writer_wait_marker && return 0
  if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    _recover_stale_lock || return 0
    mkdir "$LOCK_DIR" 2>/dev/null || return 0
  fi
  trap '_unlock' EXIT
  _prune_stale >/dev/null 2>&1 || true
  _unlock
  trap - EXIT
}

_is_pid_alive() {
  local pid="$1"
  [[ -z "$pid" || "$pid" == "null" ]] && return 1
  kill -0 "$pid" 2>/dev/null
}

_stale_minutes() {
  if [[ -f "$ORCH_YAML" ]] && command -v yq >/dev/null 2>&1; then
    local v
    v=$(yq eval '.repo_coordination.stale_heartbeat_minutes // 15' "$ORCH_YAML" 2>/dev/null)
    [[ -n "$v" && "$v" != "null" ]] && { echo "$v"; return; }
  fi
  echo 15
}

# Given a target filesystem path, walk up to find the nearest ancestor that
# is either a git repo root OR a HQ orchestrator-known repo path. Emits the
# absolute path of the owning repo (or empty string if none).
_find_owning_repo() {
  local target
  target=$(_abs_path "$1")
  [[ -z "$target" ]] && return
  # If target doesn't exist, walk up to an existing ancestor first
  while [[ -n "$target" && ! -e "$target" ]]; do
    local parent
    parent=$(dirname "$target")
    [[ "$parent" == "$target" ]] && return
    target="$parent"
  done
  # Now walk up looking for .git
  local dir="$target"
  [[ -f "$dir" ]] && dir=$(dirname "$dir")
  while [[ "$dir" != "/" && -n "$dir" ]]; do
    if [[ -e "$dir/.git" ]]; then
      echo "$dir"
      return
    fi
    dir=$(dirname "$dir")
  done
  echo ""
}

# Prune stale entries: dead PID OR heartbeat older than stale_minutes.
# Emits the number of pruned entries on stderr.
_prune_stale() {
  _ensure_reg
  local stale_min
  stale_min=$(_stale_minutes)
  local now_epoch
  now_epoch=$(date +%s)
  local cutoff=$((now_epoch - stale_min * 60))

  # Build a jq filter that keeps only entries with fresh heartbeat; then
  # separately filter dead PIDs in bash.
  local tmp="$REG_FILE.tmp.$$"
  local kept='[]'
  local runs
  runs=$(jq -c '.runs[]' "$REG_FILE" 2>/dev/null || true)
  local pruned=0
  if [[ -n "$runs" ]]; then
    while IFS= read -r entry; do
      [[ -z "$entry" ]] && continue
      local pid hb_iso hb_epoch
      pid=$(echo "$entry" | jq -r '.pid // empty')
      hb_iso=$(echo "$entry" | jq -r '.heartbeat_at // .started_at // empty')
      hb_epoch=$(_iso_to_epoch "$hb_iso")
      if ! _is_pid_alive "$pid"; then
        pruned=$((pruned + 1))
        continue
      fi
      if [[ $hb_epoch -lt $cutoff ]]; then
        pruned=$((pruned + 1))
        continue
      fi
      kept=$(echo "$kept" | jq --argjson e "$entry" '. + [$e]')
    done <<< "$runs"
  fi
  jq --argjson runs "$kept" '.runs = $runs' "$REG_FILE" > "$tmp"
  mv "$tmp" "$REG_FILE"
  [[ $pruned -gt 0 ]] && _log "pruned $pruned stale entries"
  return 0
}

# ---------- subcommands ----------

_cmd_register() {
  local run_id="" pid="" session_id="" command="" project="" repo="" scope="" host=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --run-id) run_id="$2"; shift 2 ;;
      --pid) pid="$2"; shift 2 ;;
      --session-id) session_id="$2"; shift 2 ;;
      --command) command="$2"; shift 2 ;;
      --project) project="$2"; shift 2 ;;
      --repo) repo="$2"; shift 2 ;;
      --scope) scope="$2"; shift 2 ;;
      --host) host="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  [[ -z "$pid" || -z "$command" || -z "$repo" || -z "$scope" ]] && \
    _die "register requires --pid --command --repo --scope"
  repo=$(_abs_path "$repo")
  [[ -z "$run_id" ]] && run_id="$(echo "$command" | tr '/' '-')-$(date +%s)-${project:-none}-$pid"
  [[ -z "$host" ]] && host=$(_hostname)

  _lock
  trap '_unlock' EXIT
  _ensure_reg
  _prune_stale

  local now
  now=$(_iso_now)
  local tmp="$REG_FILE.tmp.$$"
  jq --arg run_id "$run_id" \
     --arg pid "$pid" \
     --arg session_id "$session_id" \
     --arg command "$command" \
     --arg project "$project" \
     --arg repo "$repo" \
     --arg scope "$scope" \
     --arg host "$host" \
     --arg now "$now" \
    '.runs |= map(select(.run_id != $run_id)) |
     .runs += [{
       run_id: $run_id,
       pid: ($pid | tonumber),
       session_id: $session_id,
       command: $command,
       project: $project,
       repo_path: $repo,
       scope: $scope,
       host: $host,
       started_at: $now,
       heartbeat_at: $now
     }]' "$REG_FILE" > "$tmp"
  mv "$tmp" "$REG_FILE"
  _unlock
  trap - EXIT
  echo "$run_id"
}

_cmd_deregister() {
  local run_id=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --run-id) run_id="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  [[ -z "$run_id" ]] && _die "deregister requires --run-id"
  _lock
  trap '_unlock' EXIT
  _ensure_reg
  local tmp="$REG_FILE.tmp.$$"
  jq --arg run_id "$run_id" '.runs |= map(select(.run_id != $run_id))' "$REG_FILE" > "$tmp"
  mv "$tmp" "$REG_FILE"
  _unlock
  trap - EXIT
}

_cmd_heartbeat() {
  local run_id=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --run-id) run_id="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  [[ -z "$run_id" ]] && _die "heartbeat requires --run-id"
  _lock
  trap '_unlock' EXIT
  _ensure_reg
  local now
  now=$(_iso_now)
  local tmp="$REG_FILE.tmp.$$"
  jq --arg run_id "$run_id" --arg now "$now" \
    '.runs |= map(if .run_id == $run_id then .heartbeat_at = $now else . end)' \
    "$REG_FILE" > "$tmp"
  mv "$tmp" "$REG_FILE"
  _unlock
  trap - EXIT
}

_cmd_list() {
  _ensure_reg
  _prune_stale_locked
  jq '.runs' "$REG_FILE"
}

_cmd_clean_stale() {
  _lock
  trap '_unlock' EXIT
  _prune_stale
  _unlock
  trap - EXIT
}

_cmd_owner_of() {
  local path=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --path) path="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  [[ -z "$path" ]] && _die "owner-of requires --path"
  local repo
  repo=$(_find_owning_repo "$path")
  [[ -z "$repo" ]] && { echo ""; return; }
  _ensure_reg
  _prune_stale_locked
  jq --arg repo "$repo" --arg target "$(_abs_path "$path")" \
    '[.runs[] | select(
       (.scope == "repo" and .repo_path == $repo)
       or (.scope | startswith("worktree:")) and
          ($target | startswith(.scope | sub("^worktree:"; "")))
     )]' "$REG_FILE"
}

# Check if a target path is owned by a foreign run.
# Exit 0 = clear / self-owned / no owner; exit 2 = blocked by foreign owner.
_cmd_check() {
  local target="" my_pid="" my_session=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --target) target="$2"; shift 2 ;;
      --pid) my_pid="$2"; shift 2 ;;
      --session-id) my_session="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  [[ -z "$target" ]] && _die "check requires --target"

  _ensure_reg
  _prune_stale_locked

  local abs_target
  abs_target=$(_abs_path "$target")
  local repo
  repo=$(_find_owning_repo "$abs_target")
  [[ -z "$repo" ]] && return 0

  # Collect foreign entries covering this target
  local matches
  matches=$(jq -c --arg repo "$repo" \
                  --arg target "$abs_target" \
                  --arg mypid "${my_pid:-0}" \
                  --arg mysid "${my_session:-__none__}" \
    '[.runs[] | select(
       ((.scope == "repo" and .repo_path == $repo)
         or ((.scope | startswith("worktree:")) and
             ($target | startswith(.scope | sub("^worktree:"; "")))))
       and ((.pid | tostring) != $mypid)
       and (.session_id != $mysid)
     )]' "$REG_FILE" 2>/dev/null || echo '[]')

  local n
  n=$(echo "$matches" | jq 'length')
  if [[ "${n:-0}" -eq 0 ]]; then
    return 0
  fi

  # Emit one summary line per owner to stderr for the calling hook
  echo "$matches" | jq -r '.[] |
    "run_id=\(.run_id) pid=\(.pid) command=\(.command) project=\(.project) scope=\(.scope) repo=\(.repo_path) started=\(.started_at) heartbeat=\(.heartbeat_at)"' >&2
  return 2
}

# ---------- dispatch ----------

main() {
  local sub="${1:-}"
  [[ -z "$sub" ]] && _die "usage: repo-run-registry.sh <subcommand> [args...]"
  shift
  case "$sub" in
    register) _cmd_register "$@" ;;
    deregister) _cmd_deregister "$@" ;;
    heartbeat) _cmd_heartbeat "$@" ;;
    list) _cmd_list "$@" ;;
    check) _cmd_check "$@" ;;
    clean-stale) _cmd_clean_stale "$@" ;;
    owner-of) _cmd_owner_of "$@" ;;
    *) _die "unknown subcommand: $sub" ;;
  esac
}

main "$@"
