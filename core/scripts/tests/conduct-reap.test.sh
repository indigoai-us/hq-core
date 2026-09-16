#!/usr/bin/env bash
# hq-core: public
# Regression test for conduct-reap.sh.
#
# Covers the ownership classifier, which is the only part of the reaper that
# can cause harm if it is wrong in either direction: calling a live lane an
# orphan destroys someone's running work, and calling an orphan live lets the
# leak this script exists to stop continue.
#
# The first version of the classifier tested only the recorded pid's immediate
# parent and treated "parent exists" as "owner alive". That is wrong for the
# normal case, because a lane is a small tree — a bash launcher, the node
# runner beneath it, a worker beneath that — so a lane's parent is almost
# always another piece of the same orphaned lane. It misfiled a real orphan
# (a runner whose own parent was a bash launcher reparented to launchd) as
# live. Ownership is a property of the whole ancestor chain: the lane is owned
# only while the chain still reaches an orchestrating `claude` process.
#
# Strategy: build a throwaway HQ root and put real processes in it. A session
# is impersonated by an executable named `claude`, which is what the classifier
# keys on. It cannot be a copy of /bin/sh — macOS kills a relocated system
# binary on exec — so it is an ordinary script, and the classifier has to find
# the name in argv rather than in `ps -o comm=`, which would report the
# interpreter for the fixture and for a real session alike.

set -euo pipefail

SRC_ROOT="$(git rev-parse --show-toplevel)"
TMP="$(mktemp -d)"
PIDS=()
cleanup() {
  # Kill each fixture pid directly. Never `kill -- -$p` here: these pids are
  # not group leaders, so that signals whatever group they happen to belong to
  # — which includes this test and the shell that started it.
  for p in "${PIDS[@]:-}"; do
    [ -n "$p" ] || continue
    for kid in $(pgrep -P "$p" 2>/dev/null || true); do kill -KILL "$kid" 2>/dev/null || true; done
    kill -KILL "$p" 2>/dev/null || true
  done
  rm -rf "$TMP"
}
trap cleanup EXIT

RUNNER_DIR="$TMP/workspace/tmp/workflow-runner"
mkdir -p "$RUNNER_DIR"
REAP=("bash" "$SRC_ROOT/core/scripts/conduct-reap.sh")
export HQ_ROOT="$TMP"

lock() { mkdir -p "$RUNNER_DIR/$1"; printf '{"pid":%s,"startedAt":"2026-09-16T00:00:00Z"}\n' "$2" > "$RUNNER_DIR/$1/runner.json"; }

fail() { echo "conduct-reap.test: FAIL — $1" >&2; exit 1; }

# --- fixture: a lane whose orchestrating session is alive ----------------------
printf '#!/bin/bash\n%s\n' 'sleep 301 & echo $! > "$1"; sleep 301' > "$TMP/claude"
chmod +x "$TMP/claude"
"$TMP/claude" "$TMP/owned.pid" &
owner_pid=$!
disown "$owner_pid" 2>/dev/null || true   # keep job-control's kill notice off stderr
PIDS+=("$owner_pid")
for _ in $(seq 1 40); do [ -s "$TMP/owned.pid" ] && break; sleep 0.1; done
[ -s "$TMP/owned.pid" ] || fail "fixture: owned lane never started"
owned_pid="$(cat "$TMP/owned.pid")"
lock owned "$owned_pid"

# --- fixture: a lane with no session anywhere in its chain ---------------------
# The launcher must exit, not merely detach: while it lives, the lane's ppid
# points at this test, whose own chain reaches a real session, and the
# classifier would correctly call it owned. Let the intermediate shell start
# the lane and die, so launchd adopts what is left.
# (No `setsid` here: macOS does not ship one — which is exactly why
# hq-detach.sh falls back to node's `detached` option on this platform.)
bash -c 'nohup sleep 317 >/dev/null 2>&1 &' >/dev/null 2>&1
for _ in $(seq 1 40); do
  orphan_pid="$(pgrep -n -f '^sleep 317$' || true)"
  [ -n "$orphan_pid" ] && [ "$(ps -o ppid= -p "$orphan_pid" | tr -d ' ')" = "1" ] && break
  sleep 0.1
done
[ -n "${orphan_pid:-}" ] || fail "fixture: orphan lane never started"
[ "$(ps -o ppid= -p "$orphan_pid" | tr -d ' ')" = "1" ] || fail "fixture: orphan lane was never reparented"
PIDS+=("$orphan_pid")
lock orphan "$orphan_pid"

# --- fixture: a lane whose parent is alive but is itself orphaned --------------
# This is the shape the naive classifier got wrong, and the reason the
# single-level check is not merely incomplete but backwards: the recorded pid
# is the node runner, its parent is the bash launcher that started it, and the
# launcher is the one launchd adopted. Checking only the immediate parent sees
# a living process and concludes someone is in charge.
bash -c 'nohup bash -c "sleep 331 & wait" >/dev/null 2>&1 &' >/dev/null 2>&1
for _ in $(seq 1 40); do
  nested_parent="$(pgrep -f 'sleep 331 & wait' | head -1 || true)"
  [ -n "$nested_parent" ] && [ "$(ps -o ppid= -p "$nested_parent" | tr -d ' ')" = "1" ] && break
  sleep 0.1
done
[ -n "${nested_parent:-}" ] || fail "fixture: nested orphan launcher never started"
# Find the lane as a child of its launcher, not by a global pattern match: a
# stray `sleep` left by an earlier aborted run would otherwise be picked up.
nested_pid="$(pgrep -P "$nested_parent" | head -1 || true)"
[ -n "$nested_pid" ] || fail "fixture: nested orphan lane never started"
PIDS+=("$nested_parent" "$nested_pid")
lock nested "$nested_pid"

# --- fixture: a lane recording both its launcher and its runner ----------------
# A lane writes lane.pid for the launcher that owns the whole tree and
# runner.json for the node process beneath it. Signalling the runner would
# leave the launcher alive, so the launcher is the one that must be picked.
bash -c 'nohup bash -c "sleep 347 & wait" >/dev/null 2>&1 &' >/dev/null 2>&1
for _ in $(seq 1 40); do
  rooted_launcher="$(pgrep -f 'sleep 347 & wait' | head -1 || true)"
  [ -n "$rooted_launcher" ] && [ "$(ps -o ppid= -p "$rooted_launcher" | tr -d ' ')" = "1" ] && break
  sleep 0.1
done
[ -n "${rooted_launcher:-}" ] || fail "fixture: rooted launcher never started"
rooted_runner="$(pgrep -P "$rooted_launcher" | head -1 || true)"
[ -n "$rooted_runner" ] || fail "fixture: rooted runner never started"
PIDS+=("$rooted_launcher" "$rooted_runner")
lock rooted "$rooted_runner"
echo "$rooted_launcher" > "$RUNNER_DIR/rooted/lane.pid"

# --- fixture: a finished lane that left its lock behind ------------------------
lock stale 999999

# --- report mode must classify all three and change nothing --------------------
out="$("${REAP[@]}" --min-age 0)"
echo "$out" | grep -q "keep     live .*owned" || fail "a lane with a live owning session was not kept: $out"
echo "$out" | grep -q "would stop    orphan .*orphan" || fail "an orphan with no owning session was not flagged: $out"
echo "$out" | grep -q "would stop    orphan .*nested" \
  || fail "a lane whose living parent is itself orphaned was not flagged: $out"
echo "$out" | grep -q "would stop    orphan .*rooted.*(pid $rooted_launcher," \
  || fail "the lane's launcher was not preferred over its runner: $out"
echo "$out" | grep -q "would clear   stale .*stale" || fail "a dead lane's lock was not flagged stale: $out"
kill -0 "$orphan_pid" 2>/dev/null || fail "report mode killed the orphan — the default must never mutate"
[ -f "$RUNNER_DIR/stale/runner.json" ] || fail "report mode cleared a marker — the default must never mutate"

# --- the age gate must protect a freshly orphaned lane -------------------------
out="$("${REAP[@]}" --min-age 600)"
echo "$out" | grep -q "keep     orphan .*under the 600m gate" || fail "the age gate did not hold a young orphan: $out"

# --- --apply alone clears locks but must not touch a running lane --------------
out="$("${REAP[@]}" --apply --min-age 0)"
[ -f "$RUNNER_DIR/stale/runner.json" ] && fail "--apply did not clear the finished lane's marker"
kill -0 "$orphan_pid" 2>/dev/null || fail "--apply stopped an orphan without --kill"
kill -0 "$owned_pid" 2>/dev/null || fail "--apply stopped an owned lane"

# --- --apply --kill stops the orphan and only the orphan ----------------------
"${REAP[@]}" --apply --kill --min-age 0 >/dev/null
sleep 0.5
kill -0 "$orphan_pid" 2>/dev/null && fail "--apply --kill left the orphan running"
kill -0 "$owned_pid" 2>/dev/null || fail "--apply --kill stopped a lane whose owning session was alive"
kill -0 "$rooted_launcher" 2>/dev/null && fail "--apply --kill left the lane's launcher running"
kill -0 "$rooted_runner" 2>/dev/null && fail "--apply --kill left the runner beneath the launcher running"
[ -f "$RUNNER_DIR/owned/runner.json" ] || fail "--apply --kill cleared a live lane's marker"

echo "conduct-reap.test: PASS"
