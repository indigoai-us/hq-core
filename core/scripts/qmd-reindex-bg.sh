#!/usr/bin/env bash
# qmd-reindex-bg.sh — single-flight background search reindex for handoff/sync.
#
# Ownership (PR #149 / hq-pro #1790 / US-001):
#   - Hosted agent boxes: NEVER mutate qmd from handoff. Managed timer/indexer
#     owns all update/embed. Print "skipped-agent" so callers can record it.
#   - Laptop / non-agent HQ: one nonblocking single-flight lock around
#     cleanup → update → embed. Never start a second writer when the lock is busy.
#
# Architecture (nonblocking for handoff callers that use command substitution):
#   Launcher (default): hard-skip agents, skip missing qmd, then detach-spawn
#     this same script with --worker and print the real child PID immediately.
#     Detach uses a background subshell that resets HUP/INT dispositions then
#     exec's the worker (no nohup/async inherited ignore — traps must catch).
#   Worker (--worker): owns portable lock / dedupe / qmd pipeline; never respawns.
#
# Handoff does NOT invoke managed wrappers (no agent-side freshness ownership).
#
# Usage:
#   core/scripts/qmd-reindex-bg.sh
#   core/scripts/qmd-reindex-bg.sh --log /tmp/qmd-handoff.log
#   core/scripts/qmd-reindex-bg.sh --worker --log /tmp/qmd-handoff.log   # internal
#
# Stdout tokens (launcher only):
#   skipped-agent  — agent box (or forced skip); no qmd invoked
#   skipped        — qmd CLI missing; no work started
#   <pid>          — real detached --worker child PID
#
# Exit 0 always for callers that must not fail handoff.

set -u

# Absolute self path for reliable re-exec (caller may have relative $0).
_SELF="${BASH_SOURCE[0]}"
case "$_SELF" in
  /*) ;;
  *) _SELF="$(cd "$(dirname "$_SELF")" && pwd)/$(basename "$_SELF")" ;;
esac

LOG="${QMD_REINDEX_LOG:-${QMD_HANDOFF_LOG:-${HANDOFF_LOG_DIR:-/tmp}/qmd-handoff.log}}"
WORKER=0

while [ $# -gt 0 ]; do
  case "$1" in
    --worker)
      WORKER=1
      shift
      ;;
    --log)
      if [ $# -ge 2 ]; then
        LOG="$2"
        shift 2
      else
        shift
      fi
      ;;
    --log=*)
      LOG="${1#--log=}"
      shift
      ;;
    -h|--help)
      sed -n '2,32p' "$0"
      exit 0
      ;;
    *) shift ;;
  esac
done

# -------- agent hard-skip (MUST run before any command -v qmd) --------
# Established markers (ANY → skipped-agent). Never invoke qmd or managed wrappers.
is_agent_box() {
  case "${HQ_QMD_REINDEX_MODE:-}" in
    skip-agent|skip) return 0 ;;
  esac
  if [ -n "${HQ_AGENT_BOX:-}" ] && [ "${HQ_AGENT_BOX}" != "0" ]; then
    return 0
  fi
  # File markers only (no systemctl is-enabled on the hot path).
  if [ -x /usr/local/bin/hq-agent-qmd-index ] \
    || [ -x /usr/local/lib/hq-agent/qmd-index-user ] \
    || [ -f /etc/systemd/system/hq-agent-qmd-index.timer ] \
    || [ -f /etc/systemd/system/hq-agent-qmd-index.service ]; then
    return 0
  fi
  # Sole agent state dir is sufficient (do not require companion workdir).
  if [ -d /var/lib/hq-agent ]; then
    return 0
  fi
  return 1
}

if [ "$WORKER" -eq 0 ]; then
  # ---- Launcher: agent first, then empty-HOME / missing-qmd, then detach ----
  # HQ_AGENT_BOX=1 with qmd absent must print skipped-agent (not skipped).
  if is_agent_box; then
    echo "skipped-agent" >>"$LOG" 2>/dev/null || true
    echo "skipped-agent"
    exit 0
  fi

  # Empty HOME: no laptop mutation (no locks, no qmd). Quiet exit 0.
  if [ -z "${HOME:-}" ]; then
    exit 0
  fi

  if ! command -v qmd >/dev/null 2>&1; then
    echo "skipped"
    exit 0
  fi

  # Spawn worker detached with catchable HUP/INT. nohup and bare async children
  # enter with HUP (and often INT) ignored; Bash cannot trap signals ignored on
  # entry. Reset dispositions in a subshell, then exec so $! is the real worker.
  (
    trap - HUP INT
    exec bash "$_SELF" --worker --log "$LOG"
  ) </dev/null >/dev/null 2>&1 &
  _worker_pid=$!
  disown "$_worker_pid" 2>/dev/null || true
  echo "$_worker_pid"
  exit 0
fi

# =====================================================================
# Worker mode: portable single-flight lock + pipeline. Never respawns.
# =====================================================================

# Agent re-check before qmd lookup (env may have changed; never mutate agents).
if is_agent_box; then
  exit 0
fi

# Empty HOME: no locks under /tmp or shared roots; no qmd. Quiet exit 0.
if [ -z "${HOME:-}" ]; then
  exit 0
fi

if ! command -v qmd >/dev/null 2>&1; then
  exit 0
fi

# Lock root: only ${HOME}/.hq/locks (never ~/.hq-agent managed lock domain).
LOCK_ROOT="${HOME}/.hq/locks"
mkdir -p "$LOCK_ROOT" 2>/dev/null || true

LOCK_DIR="${LOCK_ROOT}/qmd-reindex-bg.lock"
OWNER_FILE="${LOCK_DIR}/owner"
# Generation-fenced reclaim: claim.<G>/ holds exclusive reclaim rights for the
# main-lock generation G (owner nonce). Never a fixed-path reclaim mutex mv.
COMPLETE_STAMP="${LOCK_ROOT}/qmd-reindex-bg.completed"
DEDUPE_SEC="${QMD_HANDOFF_DEDUPE_SEC:-90}"
LOG_MAX_BYTES="${QMD_HANDOFF_LOG_MAX_BYTES:-65536}"
LOCK_GRACE_SEC="${QMD_HANDOFF_LOCK_GRACE_SEC:-5}"
# Held claim (set by try_claim_generation; cleared by release_claim).
CLAIM_DIR_HELD=""
CLAIM_PATH_HELD=""
# Unique acquisition marker under a main lock this process exclusively mkdir'd
# (set before owner publish; cleared on success or identity-safe abandon).
ACQ_MARKER_HELD=""

now_epoch() {
  date +%s 2>/dev/null || echo 0
}

log_ts() {
  date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date
}

run_qmd() {
  # ionice is Linux-only; never let its absence skip qmd (macOS).
  if command -v ionice >/dev/null 2>&1; then
    nice -n 19 ionice -c 3 "$@"
  else
    nice -n 19 "$@"
  fi
}

lock_mtime() {
  if stat -c %Y "$LOCK_DIR" 2>/dev/null; then
    return 0
  fi
  if stat -f %m "$LOCK_DIR" 2>/dev/null; then
    return 0
  fi
  echo 0
}

# Quiet skip when a recent *successful* flight already finished. Collapses
# sequential finalize → post without sleeping. Failed updates leave no stamp
# so post still gets a second chance.
recently_completed() {
  local last now
  case "${DEDUPE_SEC}" in
    ''|*[!0-9]*) return 1 ;;
    0) return 1 ;;
  esac
  [ -f "$COMPLETE_STAMP" ] || return 1
  last="$(awk -F= '/^ts=/{print $2; exit}' "$COMPLETE_STAMP" 2>/dev/null || true)"
  case "${last}" in
    ''|*[!0-9]*) return 1 ;;
  esac
  now="$(now_epoch)"
  [ "$now" -ge "$last" ] 2>/dev/null || return 1
  [ $((now - last)) -lt "$DEDUPE_SEC" ] 2>/dev/null
}

write_completion_stamp() {
  {
    echo "ts=$(now_epoch)"
    echo "pid=$$"
    echo "mode=raw"
  } >"$COMPLETE_STAMP" 2>/dev/null || true
}

# Publish a complete main-lock owner record (temp + atomic mv) and verify
# readback. Returns 0 only when the durable record belongs to this process.
# Callers must treat failure as failed acquisition (no pipeline entry).
write_owner_record() {
  local tmp nonce ts rpid rnonce
  # Test-only deterministic failure inject (unset in production).
  if [ -n "${QMD_FORCE_OWNER_WRITE_FAIL:-}" ]; then
    return 1
  fi
  [ -d "$LOCK_DIR" ] || return 1
  ts="$(now_epoch)"
  nonce="$$.$RANDOM"
  tmp="${LOCK_DIR}/.owner.tmp.$$.$RANDOM"
  {
    echo "pid=$$"
    echo "ts=$ts"
    echo "nonce=$nonce"
  } >"$tmp" 2>/dev/null || {
    rm -f "$tmp" 2>/dev/null || true
    return 1
  }
  if ! mv -f "$tmp" "$OWNER_FILE" 2>/dev/null; then
    rm -f "$tmp" 2>/dev/null || true
    return 1
  fi
  rpid="$(awk -F= '/^pid=/{print $2; exit}' "$OWNER_FILE" 2>/dev/null || true)"
  rnonce="$(awk -F= '/^nonce=/{print $2; exit}' "$OWNER_FILE" 2>/dev/null || true)"
  if [ "$rpid" != "$$" ] || [ -z "$rnonce" ] || [ "$rnonce" != "$nonce" ]; then
    return 1
  fi
  return 0
}

# Install a unique acquisition marker under LOCK_DIR (exclusive mkdir) so this
# process can later abandon by exact identity rather than fixed-path rm -rf.
# Must run immediately after exclusive mkdir of the main lock, before owner publish.
_install_acq_marker() {
  local name path
  [ -d "$LOCK_DIR" ] || return 1
  name="acq.$$.$RANDOM"
  path="${LOCK_DIR}/${name}"
  if ! mkdir "$path" 2>/dev/null; then
    name="acq.$$.$RANDOM.$RANDOM"
    path="${LOCK_DIR}/${name}"
    mkdir "$path" 2>/dev/null || return 1
  fi
  ACQ_MARKER_HELD="$path"
  return 0
}

# Remove our acquisition marker after verified owner publish (success path).
_clear_acq_marker() {
  if [ -n "${ACQ_MARKER_HELD:-}" ]; then
    rm -rf "$ACQ_MARKER_HELD" 2>/dev/null || true
  fi
  ACQ_MARKER_HELD=""
}

# Abandon a main lock this process uniquely created (exclusive mkdir) after a
# failed owner publish. Identity-safe: remove only the exact acquisition marker
# we installed, then rmdir the parent if empty. Never recursively delete the
# fixed LOCK_DIR path — a peer may have moved our dir and recreated a live lock
# there; the marker is then absent and rmdir of a non-empty replacement fails.
_abandon_created_lock() {
  if [ -n "${ACQ_MARKER_HELD:-}" ]; then
    rm -rf "$ACQ_MARKER_HELD" 2>/dev/null || true
  fi
  ACQ_MARKER_HELD=""
  rmdir "$LOCK_DIR" 2>/dev/null || true
}

owner_is_live() {
  local opid mt now age grace
  [ -d "$LOCK_DIR" ] || return 1

  if [ -f "$OWNER_FILE" ]; then
    opid="$(awk -F= '/^pid=/{print $2; exit}' "$OWNER_FILE" 2>/dev/null || true)"
    case "${opid}" in
      ''|*[!0-9]*) ;;
      *)
        if kill -0 "$opid" 2>/dev/null; then
          return 0
        fi
        return 1
        ;;
    esac
  fi

  grace="${LOCK_GRACE_SEC}"
  case "${grace}" in
    ''|*[!0-9]*) grace=5 ;;
  esac
  mt="$(lock_mtime)"
  case "${mt}" in
    ''|*[!0-9]*) return 0 ;;
  esac
  now="$(now_epoch)"
  age=$((now - mt))
  [ "$age" -lt 0 ] && age=0
  [ "$age" -lt "$grace" ]
}

release_lock() {
  local opid
  if [ -f "$OWNER_FILE" ]; then
    opid="$(awk -F= '/^pid=/{print $2; exit}' "$OWNER_FILE" 2>/dev/null || true)"
    if [ "$opid" = "$$" ]; then
      rm -rf "$LOCK_DIR" 2>/dev/null || true
    fi
  fi
}

# Generation token from the current main owner record. Contenders that observed
# stale generation G may only claim/move G; after replacement G' they abort.
# Prints token on stdout; returns 0 if LOCK_DIR exists, 1 otherwise.
read_owner_generation() {
  local nonce pid ts
  [ -d "$LOCK_DIR" ] || return 1
  if [ -f "$OWNER_FILE" ]; then
    nonce="$(awk -F= '/^nonce=/{print $2; exit}' "$OWNER_FILE" 2>/dev/null || true)"
    case "$nonce" in
      ''|*[!A-Za-z0-9._-]*|*..*) ;;
      *)
        printf '%s\n' "$nonce"
        return 0
        ;;
    esac
    pid="$(awk -F= '/^pid=/{print $2; exit}' "$OWNER_FILE" 2>/dev/null || true)"
    ts="$(awk -F= '/^ts=/{print $2; exit}' "$OWNER_FILE" 2>/dev/null || true)"
    case "$pid" in ''|*[!0-9]*) pid=x ;; esac
    case "$ts" in ''|*[!0-9]*) ts=0 ;; esac
    printf 'p%s.t%s\n' "$pid" "$ts"
    return 0
  fi
  printf 'empty\n'
  return 0
}

# True while claim dir is in the mkdir→write-claimant window (no c.* yet).
# Grace floor ≥5s so LOCK_GRACE_SEC=0 tests cannot steal mid-acquire.
claim_dir_in_grace() {
  local claim_dir="$1" mt now age grace
  grace="${LOCK_GRACE_SEC}"
  case "${grace}" in
    ''|*[!0-9]*) grace=5 ;;
  esac
  if [ "$grace" -lt 5 ]; then
    grace=5
  fi
  mt=0
  if mt="$(stat -c %Y "$claim_dir" 2>/dev/null)"; then
    :
  elif mt="$(stat -f %m "$claim_dir" 2>/dev/null)"; then
    :
  else
    return 0
  fi
  case "${mt}" in
    ''|*[!0-9]*) return 0 ;;
  esac
  now="$(now_epoch)"
  age=$((now - mt))
  [ "$age" -lt 0 ] && age=0
  [ "$age" -lt "$grace" ]
}

# Read pid from a unique claimant marker (file or directory with owner).
_claimant_pid() {
  local path="$1" owner_file
  if [ -d "$path" ]; then
    owner_file="${path}/owner"
  elif [ -f "$path" ]; then
    owner_file="$path"
  else
    return 1
  fi
  [ -f "$owner_file" ] || return 1
  awk -F= '/^pid=/{print $2; exit}' "$owner_file" 2>/dev/null
}

# Install uniquely named claimant under claim_dir via exclusive mkdir so the
# parent is non-empty before any peer can rmdir-if-empty. Owner/claimant record
# is mandatory: temp+atomic publish + readback. On failure, remove only the
# unique c.* this process created (leave claim_dir for peers / reclaim).
_claim_install_marker() {
  local claim_dir="$1" claim_name claim_path tmp ts rpid
  [ -d "$claim_dir" ] || return 1
  claim_name="c.$$.$RANDOM"
  claim_path="${claim_dir}/${claim_name}"
  if ! mkdir "$claim_path" 2>/dev/null; then
    claim_name="c.$$.$RANDOM.$RANDOM"
    claim_path="${claim_dir}/${claim_name}"
    mkdir "$claim_path" 2>/dev/null || return 1
  fi
  # Test-only deterministic failure inject (unset in production).
  if [ -n "${QMD_FORCE_CLAIMANT_WRITE_FAIL:-}" ]; then
    rm -rf "$claim_path" 2>/dev/null || true
    return 1
  fi
  ts="$(now_epoch)"
  tmp="${claim_path}/.owner.tmp.$$.$RANDOM"
  {
    echo "pid=$$"
    echo "ts=$ts"
  } >"$tmp" 2>/dev/null || {
    rm -f "$tmp" 2>/dev/null || true
    rm -rf "$claim_path" 2>/dev/null || true
    return 1
  }
  if ! mv -f "$tmp" "${claim_path}/owner" 2>/dev/null; then
    rm -f "$tmp" 2>/dev/null || true
    rm -rf "$claim_path" 2>/dev/null || true
    return 1
  fi
  rpid="$(awk -F= '/^pid=/{print $2; exit}' "${claim_path}/owner" 2>/dev/null || true)"
  if [ "$rpid" != "$$" ]; then
    # Incomplete publish: remove only our unique marker if still ours/empty.
    rm -rf "$claim_path" 2>/dev/null || true
    return 1
  fi
  CLAIM_DIR_HELD="$claim_dir"
  CLAIM_PATH_HELD="$claim_path"
  return 0
}

# Try exclusive create of claim.G + unique claimant. Returns 0 on hold.
_claim_mkdir_install() {
  local claim_dir="$1"
  if mkdir "$claim_dir" 2>/dev/null; then
    if _claim_install_marker "$claim_dir"; then
      return 0
    fi
    rmdir "$claim_dir" 2>/dev/null || true
    return 1
  fi
  return 1
}

# Nonblocking exclusive claim for main-lock generation G.
# Abandoned recovery: only a contender that successfully mv'd an exact observed
# dead claimant filename may rmdir-if-empty; never fixed-path mv of claim.G.
try_claim_generation() {
  local gen="$1"
  local claim_dir f opid steal any_live moved

  case "$gen" in
    ''|*[!A-Za-z0-9._-]*|*..*) return 1 ;;
  esac

  claim_dir="${LOCK_ROOT}/qmd-reindex-bg.claim.${gen}"

  if _claim_mkdir_install "$claim_dir"; then
    return 0
  fi

  if [ ! -d "$claim_dir" ]; then
    # Peer removed it — one more exclusive create attempt.
    _claim_mkdir_install "$claim_dir"
    return $?
  fi

  any_live=0
  moved=0
  for f in "$claim_dir"/c.*; do
    # Unmatched glob stays literal when nullglob is off.
    [ -e "$f" ] || continue
    [ -f "$f" ] || [ -d "$f" ] || continue
    opid="$(_claimant_pid "$f" 2>/dev/null || true)"
    case "${opid}" in
      ''|*[!0-9]*)
        # Unparseable marker: protect mid-write if claim dir is young.
        if claim_dir_in_grace "$claim_dir"; then
          return 1
        fi
        steal="${claim_dir}.stale-claim.$$.$RANDOM"
        rm -rf "$steal" 2>/dev/null || true
        if mv "$f" "$steal" 2>/dev/null; then
          moved=1
          rm -rf "$steal" 2>/dev/null || true
        fi
        ;;
      *)
        if kill -0 "$opid" 2>/dev/null; then
          any_live=1
        else
          # Move the exact observed claimant name only (not claim.G).
          steal="${claim_dir}.stale-claim.$$.$RANDOM"
          rm -rf "$steal" 2>/dev/null || true
          if mv "$f" "$steal" 2>/dev/null; then
            moved=1
            rm -rf "$steal" 2>/dev/null || true
          fi
        fi
        ;;
    esac
  done

  if [ "$any_live" -eq 1 ]; then
    return 1
  fi

  if [ "$moved" -eq 0 ]; then
    # Empty mid-acquire window, or we lost every dead-claimant mv to a peer.
    # Only rmdir empty dirs past grace; never rmdir after a failed steal (peer
    # may be between mkdir and marker install).
    if claim_dir_in_grace "$claim_dir"; then
      return 1
    fi
    if rmdir "$claim_dir" 2>/dev/null; then
      _claim_mkdir_install "$claim_dir"
      return $?
    fi
    _claim_mkdir_install "$claim_dir"
    return $?
  fi

  # We successfully moved ≥1 exact dead claimant. rmdir only if empty — fails
  # if a new unique claimant (directory) already appeared.
  if rmdir "$claim_dir" 2>/dev/null; then
    _claim_mkdir_install "$claim_dir"
    return $?
  fi

  # Not empty or already gone: try exclusive create if path free.
  _claim_mkdir_install "$claim_dir"
  return $?
}

release_claim() {
  if [ -n "${CLAIM_PATH_HELD:-}" ]; then
    rm -rf "$CLAIM_PATH_HELD" 2>/dev/null || true
  fi
  if [ -n "${CLAIM_DIR_HELD:-}" ]; then
    rmdir "$CLAIM_DIR_HELD" 2>/dev/null || true
  fi
  CLAIM_DIR_HELD=""
  CLAIM_PATH_HELD=""
}

cap_log() {
  local size max tmp keep
  max="${LOG_MAX_BYTES}"
  case "${max}" in
    ''|*[!0-9]*) return 0 ;;
    0) return 0 ;;
  esac
  [ -f "$LOG" ] || return 0
  size="$(wc -c <"$LOG" 2>/dev/null | tr -d '[:space:]' || echo 0)"
  case "${size}" in
    ''|*[!0-9]*) return 0 ;;
  esac
  [ "$size" -gt "$max" ] 2>/dev/null || return 0
  keep="$max"
  tmp="${LOG}.cap.$$"
  if tail -c "$keep" "$LOG" >"$tmp" 2>/dev/null; then
    mv "$tmp" "$LOG" 2>/dev/null || rm -f "$tmp" 2>/dev/null || true
  else
    rm -f "$tmp" 2>/dev/null || true
  fi
}

# After exclusive mkdir of the main lock: install acquisition marker, publish
# owner, clear marker on success or identity-safe abandon on failure.
# Returns 0 on verified ownership, 1 if acquisition must be abandoned.
_finalize_created_lock() {
  if ! _install_acq_marker; then
    # Empty exclusive mkdir with no marker — rmdir only (never rm -rf LOCK_DIR).
    rmdir "$LOCK_DIR" 2>/dev/null || true
    return 1
  fi
  if write_owner_record; then
    _clear_acq_marker
    return 0
  fi
  # Exclusive mkdir succeeded but owner record is not durable — abandon.
  _abandon_created_lock
  return 1
}

# Portable mkdir single-flight only (one lock contract). Nonblocking:
# mkdir wins, live owner → busy, dead/stale owner → generation-fenced claim
# for observed G, re-read owner (must still be G), then mv (never touch G+1).
try_acquire_lock() {
  local steal gen gen2

  if mkdir "$LOCK_DIR" 2>/dev/null; then
    _finalize_created_lock
    return $?
  fi

  if owner_is_live; then
    return 1
  fi

  # Stale main lock: claim exclusive reclaim rights for observed generation G.
  gen="$(read_owner_generation)" || return 1
  case "$gen" in
    ''|*[!A-Za-z0-9._-]*|*..*) return 1 ;;
  esac

  if ! try_claim_generation "$gen"; then
    return 1
  fi

  # Holding claim.G — revalidate generation before any mv of LOCK_DIR.
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    if _finalize_created_lock; then
      release_claim
      return 0
    fi
    release_claim
    return 1
  fi

  if owner_is_live; then
    release_claim
    return 1
  fi

  gen2="$(read_owner_generation)" || {
    release_claim
    return 1
  }
  if [ "$gen2" != "$gen" ]; then
    # Observed G; replacement is a different generation — cannot touch it.
    release_claim
    return 1
  fi

  steal="${LOCK_DIR}.stale.$$.$RANDOM"
  rm -rf "$steal" 2>/dev/null || true
  if mv "$LOCK_DIR" "$steal" 2>/dev/null; then
    rm -rf "$steal" 2>/dev/null || true
    if mkdir "$LOCK_DIR" 2>/dev/null; then
      if _finalize_created_lock; then
        release_claim
        return 0
      fi
      release_claim
      return 1
    fi
  fi

  release_claim
  return 1
}

if recently_completed; then
  exit 0
fi

if ! try_acquire_lock; then
  # Live owner still flying, or lost reclaim race. Quiet success; no second writer.
  exit 0
fi

# Common EXIT cleanup: best-effort log cap (including interrupted noisy
# commands), then release owned lock. INT/TERM/HUP must exit so the pipeline
# does not continue (update/embed/stamp) after ownership is released.
_worker_exit_cleanup() {
  cap_log 2>/dev/null || true
  release_lock
}
trap _worker_exit_cleanup EXIT
trap 'exit 0' INT TERM HUP

if recently_completed; then
  exit 0
fi

# Winner only: write log and run pipeline under lock.
# cleanup: best-effort; embed only if update succeeds; all failures → exit 0.
mkdir -p "$(dirname "$LOG")" 2>/dev/null || true
{
  echo "[qmd-reindex-bg] start worker ts=$(log_ts) pid=$$"
} >"$LOG" 2>/dev/null || true

run_qmd qmd cleanup >>"$LOG" 2>&1 || true

# Stamp only after successful update *and* embed attempt finishes so sequential
# finalize→post within DEDUPE_SEC does not suppress a legitimate embed retry.
# No stamp on update failure — post still gets a second chance.
if run_qmd qmd update >>"$LOG" 2>&1; then
  run_qmd qmd embed >>"$LOG" 2>&1 || true
  write_completion_stamp
  echo "[qmd-reindex-bg] done ts=$(log_ts)" >>"$LOG" 2>&1 || true
else
  echo "[qmd-reindex-bg] update-failed ts=$(log_ts)" >>"$LOG" 2>&1 || true
fi
# Cap also on the normal path (EXIT trap re-runs cap_log best-effort — idempotent).
cap_log

exit 0
