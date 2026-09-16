#!/usr/bin/env bash
# hq-core: public
# conduct-reap.sh — find and clean up detached conduct lanes whose orchestrator
# is gone.
#
# Usage:
#   bash core/scripts/conduct-reap.sh                 # report only (default)
#   bash core/scripts/conduct-reap.sh --apply         # remove stale lock dirs
#   bash core/scripts/conduct-reap.sh --apply --kill  # also stop orphaned lanes
#   bash core/scripts/conduct-reap.sh --min-age 60    # orphan age gate, minutes
#
# WHY THIS EXISTS
#
# `hq-detach.sh` starts a lane in its own POSIX session precisely so "a parent
# turn sweep cannot reap it" — a lane has to outlive the turn that launched it.
# That is correct, and it is a one-way door: nothing was tied to the
# orchestrating session on the other side, so a lane whose owner exits is
# reparented to launchd and keeps working, unsupervised, forever.
#
# The cost is cumulative rather than dramatic. Each surviving lane runs a real
# worker, and a worker runs test suites that fan out to roughly one process per
# core. Several days of these accumulate quietly until the machine is
# oversubscribed and every app on it — not just HQ — becomes unusable. Observed
# 2026-09-16: load average 246 on 18 cores, 99 node processes, a runner orphaned
# mid-task, a pool lane asleep for 15h51m, and node processes orphaned for three
# days. The desktop app was blamed first; it was using 55 MB and 0.2% CPU.
#
# WHAT IT WILL NOT DO
#
# A lane whose orchestrator is still alive is someone's running work and is
# never touched, at any age. Killing a live lane loses whatever it had not yet
# committed, and "it looks idle" is not evidence: a lane waiting on a build is
# indistinguishable from a wedged one at the process level.
#
# Reporting is the default. Both mutating modes are opt-in, and `--kill` is
# separate from `--apply` because removing a tombstone file and stopping a
# running process are not the same risk.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${HQ_ROOT:-${CLAUDE_PROJECT_DIR:-$(cd "$SCRIPT_DIR/../.." && pwd)}}"

# Read JSON through hook-lib's jq-first / node-fallback primitive. Windows
# boxes routinely have no working interpreter of the obvious alternative — or
# the Microsoft Store alias stub, which resolves on PATH and then fails every
# call — so depending on one here would silently disable the sweep on exactly
# the machines least able to absorb a process leak.
# shellcheck source=core/scripts/hook-lib.sh
. "$SCRIPT_DIR/hook-lib.sh" 2>/dev/null || true
if ! declare -F hq_json_get >/dev/null 2>&1; then
  # Without the library the runner.json extras are simply unavailable; lane.pid
  # still drives the sweep, so degrade rather than refuse to run.
  hq_json_get() { cat >/dev/null 2>&1; printf ''; }
fi
RUNNER_DIR="$REPO_ROOT/workspace/tmp/workflow-runner"

APPLY=0
KILL=0
MIN_AGE_MIN=30

while [ $# -gt 0 ]; do
  case "$1" in
    --apply) APPLY=1 ;;
    --kill) KILL=1 ;;
    --min-age) MIN_AGE_MIN="${2:-30}"; shift ;;
    -h|--help) sed -n '3,12p' "${BASH_SOURCE[0]}" | sed -e 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "conduct-reap: unknown argument '$1'" >&2; exit 2 ;;
  esac
  shift
done

case "$MIN_AGE_MIN" in
  ''|*[!0-9]*) echo "conduct-reap: --min-age takes minutes as a positive integer" >&2; exit 2 ;;
esac

[ -d "$RUNNER_DIR" ] || { echo "conduct-reap: no runner state at $RUNNER_DIR — nothing to do"; exit 0; }

# Ownership is a property of the whole ancestor chain, not the immediate parent.
# A lane is typically a small tree — a bash launcher, the node runner under it,
# a worker under that — so "my parent is alive" proves nothing: the parent is
# usually another piece of the same orphaned lane. The question is whether the
# chain still reaches an orchestrating `claude` session. If it terminates at
# launchd without one, nobody is supervising this work.
#
# Match on argv rather than `ps -o comm=`: comm reports the interpreter, so a
# real session shows up as `node` and would never be recognized. Compare the
# basename of each argument against `claude` exactly — a loose substring test
# matches every `.claude/hooks/...` path on the machine and would mark the
# whole world live.
has_live_owner() {
  local pid="$1" hops=0 cmd tok
  while [ -n "$pid" ] && [ "$pid" != "0" ] && [ "$pid" != "1" ] && [ "$hops" -lt 24 ]; do
    cmd="$(ps -o command= -p "$pid" 2>/dev/null || true)"
    for tok in $cmd; do
      # Strip the directory with parameter expansion, not `basename`: argv is
      # full of tokens like `-c`, which basename reads as a flag.
      [ "${tok##*/}" = "claude" ] && return 0
    done
    pid="$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ' || true)"
    hops=$((hops + 1))
  done
  return 1
}

# Retire a lane's liveness markers without touching the rest of its directory.
# The lane dir also holds lane.log and args.json — the only record of what that
# lane was asked to do and what it did. A finished lane is worth a few KB of
# transcript, and an operator asking "what was that thing doing before it went
# wrong" has nowhere else to look. Clear the markers; leave the evidence.
clear_markers() {
  rm -f "$1/lane.pid" "$1/runner.pid" "$1/runner.json"
}

# Stopping a lane means stopping its whole tree: the launcher, the runner
# beneath it, and the worker beneath that. Signalling the process group looks
# like the tidy way to do it, but it is wrong and dangerous here — a lane
# launched with `nohup ... &` is not a group leader, so its pgid names the
# group of whatever shell started it, and `kill -- -$pid` would signal an
# unrelated set of processes. Walk the actual children instead.
descendants() {
  local pid="$1" kid
  for kid in $(pgrep -P "$pid" 2>/dev/null || true); do
    descendants "$kid"
    printf '%s\n' "$kid"
  done
}

stop_tree() {
  local root="$1" targets p
  # Children first, so a supervisor cannot respawn a worker while we work.
  targets="$(descendants "$root")"
  targets="$targets
$root"

  for p in $targets; do
    [ -n "$p" ] && kill -TERM "$p" 2>/dev/null || true
  done
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    kill -0 "$root" 2>/dev/null || break
    sleep 0.5
  done
  for p in $targets; do
    [ -n "$p" ] && kill -KILL "$p" 2>/dev/null || true
  done
  ! kill -0 "$root" 2>/dev/null
}

live=0 orphan=0 stale=0 reaped=0 killed=0 young=0

while IFS= read -r dir; do
  label="${dir#"$RUNNER_DIR"/}"
  # The lane directory is nested under the id of the session that launched it,
  # which is the registration that lets a stray process be traced back to an
  # owner. Lanes from before that nesting sit directly under the runner dir and
  # simply have no owner to name.
  owner_session="$(dirname "$label")"
  [ "$owner_session" = "." ] && owner_session="unregistered"

  # Prefer lane.pid: it holds the lane's root launcher, and every other
  # process in the lane descends from it. runner.json names the node runner
  # alone, so stopping that would leave the launcher — and whatever it waits
  # on or restarts — behind. lane.pid is also much the better registry: only
  # about a fifth of lanes ever write a runner.json at all.
  pid=""
  started=""
  if [ -s "$dir/lane.pid" ]; then
    pid="$(tr -dc '0-9' < "$dir/lane.pid")"
  fi
  if [ -f "$dir/runner.json" ]; then
    started="$(hq_json_get 'startedAt' < "$dir/runner.json" 2>/dev/null || true)"
    started="${started:0:16}"
    [ -n "$pid" ] || pid="$(hq_json_get 'pid' < "$dir/runner.json" 2>/dev/null || true)"
  fi
  # Lanes that never wrote a runner.json still have a date worth showing, so
  # fall back to when the lane directory was created.
  [ -n "$started" ] || started="$(date -r "$dir" '+%Y-%m-%dT%H:%M' 2>/dev/null || true)"

  if [ -z "$pid" ] || ! kill -0 "$pid" 2>/dev/null; then
    # The process is gone, so the marker is just litter. This is housekeeping,
    # not a correctness fix — workflow-runner.mjs already handles a dead pid.
    stale=$((stale + 1))
    if [ "$APPLY" -eq 1 ]; then
      clear_markers "$dir" && reaped=$((reaped + 1))
      echo "cleared  stale    ${started:-?}  $label  [session $owner_session]"
    else
      echo "would clear   stale    ${started:-?}  $label  [session $owner_session]"
    fi
    continue
  fi

  if has_live_owner "$pid"; then
    live=$((live + 1))
    echo "keep     live     ${started:-?}  $label  [session $owner_session] (pid $pid)"
    continue
  fi

  # The chain reached launchd without an owning session: an orphan by
  # inspection, not by inference from idleness.
  age_min=$(( ( $(date +%s) - $(ps -o lstart= -p "$pid" | xargs -I{} date -j -f "%a %b %d %T %Y" "{}" +%s 2>/dev/null || echo "$(date +%s)") ) / 60 ))
  if [ "$age_min" -lt "$MIN_AGE_MIN" ]; then
    young=$((young + 1))
    echo "keep     orphan   ${started:-?}  $label  [session $owner_session] (pid $pid, ${age_min}m old — under the ${MIN_AGE_MIN}m gate)"
    continue
  fi

  orphan=$((orphan + 1))
  if [ "$APPLY" -eq 1 ] && [ "$KILL" -eq 1 ]; then
    if stop_tree "$pid"; then
      killed=$((killed + 1))
      clear_markers "$dir"
      echo "stopped  orphan   ${started:-?}  $label  [session $owner_session] (pid $pid, ${age_min}m old)"
    else
      echo "FAILED   orphan   ${started:-?}  $label  [session $owner_session] (pid $pid — could not signal)"
    fi
  else
    echo "would stop    orphan   ${started:-?}  $label  [session $owner_session] (pid $pid, ${age_min}m old)"
  fi
done < <(find "$RUNNER_DIR" \( -name lane.pid -o -name runner.json \) 2>/dev/null \
           | while IFS= read -r f; do dirname "$f"; done | sort -u)

echo
echo "conduct-reap: $live live, $orphan orphaned, $stale stale, $young under the age gate"
if [ "$APPLY" -eq 0 ]; then
  echo "conduct-reap: report only. --apply clears markers on finished lanes; --apply --kill also stops orphaned lanes."
elif [ "$KILL" -eq 0 ] && [ "$orphan" -gt 0 ]; then
  echo "conduct-reap: cleared $reaped finished lane(s). $orphan orphaned lane(s) left running — add --kill to stop them."
else
  echo "conduct-reap: cleared $reaped finished lane(s), stopped $killed orphaned lane(s)."
fi
