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
# Policy: .claude/policies/repo-run-coordination.md
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

HQ_ROOT="${HQ_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
REG_DIR="$HQ_ROOT/workspace/orchestrator"
REG_FILE="$REG_DIR/active-runs.json"
LOCK_DIR="$REG_FILE.lock"
ORCH_YAML="$HQ_ROOT/settings/orchestrator.yaml"

# ---------- helpers ----------

_log() { echo "[repo-run-registry] $*" >&2; }
_die() { echo "ERROR: $*" >&2; exit 1; }

_iso_now() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

# BSD-compatible ISO8601 → epoch seconds
_iso_to_epoch() {
  local iso="$1"
  # strip trailing Z, split on T
  date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$iso" +%s 2>/dev/null || echo 0
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
_lock() {
  local tries=0
  local max=50
  while ! mkdir "$LOCK_DIR" 2>/dev/null; do
    tries=$((tries + 1))
    if [[ $tries -ge $max ]]; then
      # stale lock fallback: remove if older than 60s
      if [[ -d "$LOCK_DIR" ]]; then
        local age
        age=$(( $(date +%s) - $(stat -f %m "$LOCK_DIR" 2>/dev/null || echo 0) ))
        if [[ $age -gt 60 ]]; then
          rm -rf "$LOCK_DIR" 2>/dev/null || true
          continue
        fi
      fi
      _die "registry lock timeout"
    fi
    sleep 0.1
  done
}
_unlock() { rm -rf "$LOCK_DIR" 2>/dev/null || true; }

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
  _prune_stale >/dev/null 2>&1 || true
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
  _prune_stale >/dev/null 2>&1 || true
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
  _prune_stale >/dev/null 2>&1 || true

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
