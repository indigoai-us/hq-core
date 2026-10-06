#!/usr/bin/env bash
# block-on-active-run.test.sh — the cross-session repo guard blocks for real.
#
# Uses the shipped core/scripts/repo-run-registry.sh (not a stub) in a temp HQ
# root, registers a run owned by another live process and session, and checks
# that an Edit inside that repo is blocked. Before this test the guard read
# $HQ_ROOT/scripts/repo-run-registry.sh, which does not exist, and exited 0 on
# every install; on Linux the registry also pruned every live run as stale
# because its timestamp parse was BSD-only. Both regressions fail case [1].
#
# Also covers: own-session allow, allow outside the repo, allow with no runs,
# the check-repo-active-runs.sh SessionStart banner, and the check-hq-hooks.sh
# report for a missing guard helper.
#
# Explicitly wired into .github/workflows/pr-checks.yml (tests here are not
# auto-discovered).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "ok   [$1]"; }
fail() { FAIL=$((FAIL+1)); echo "FAIL [$1]: $2"; }

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq required for this suite"; exit 0; }

TMP="$(mktemp -d)"
OWNER_PID=""
cleanup() {
  [ -n "$OWNER_PID" ] && kill "$OWNER_PID" 2>/dev/null
  rm -rf "$TMP"
}
trap cleanup EXIT

HQ="$TMP/hq"
mkdir -p "$HQ/.claude/hooks" "$HQ/core/scripts/lib" "$HQ/workspace" "$HQ/repos/private/app/src"
cp "$ROOT/.claude/hooks/block-on-active-run.sh" "$ROOT/.claude/hooks/check-repo-active-runs.sh" "$HQ/.claude/hooks/"
cp "$ROOT/core/scripts/repo-run-registry.sh" "$ROOT/core/scripts/hook-lib.sh" "$HQ/core/scripts/"
cp "$ROOT/core/scripts/lib/portable.sh" "$HQ/core/scripts/lib/"
git -C "$HQ/repos/private/app" init -q
printf 'x\n' > "$HQ/repos/private/app/src/file.txt"
mkdir -p "$HQ/notes"

REG="$HQ/core/scripts/repo-run-registry.sh"
ERR="$TMP/err"

# A live process that is not an ancestor of the hook stands in for the other
# session's Claude Code parent.
sleep 600 &
OWNER_PID=$!

edit() { # <file_path> <session_id> -> prints exit code
  local rc=0 payload
  payload="$(jq -nc --arg fp "$1" --arg sid "$2" '{tool_name:"Edit", session_id:$sid, tool_input:{file_path:$fp}}')"
  ( cd "$HQ" && printf '%s' "$payload" | env -u BASH_ENV -u HQ_IGNORE_ACTIVE_RUNS \
      HQ_ROOT="$HQ" CLAUDE_PROJECT_DIR="$HQ" bash "$HQ/.claude/hooks/block-on-active-run.sh" ) \
      >/dev/null 2>"$ERR" || rc=$?
  printf '%s' "$rc"
}

# --- [0] no registry file yet: allow --------------------------------------
got="$(edit "$HQ/repos/private/app/src/file.txt" mine)"
[ "$got" = "0" ] && ok "no active-runs file allows the edit" || fail "no active-runs file allows the edit" "rc=$got"

# SessionStart must not create the registry file: its presence switches on the
# guard's prefilter for every later tool call.
( cd "$HQ/repos/private/app" && printf '{}' | env -u BASH_ENV HQ_ROOT="$HQ" CLAUDE_PROJECT_DIR="$HQ" \
  bash "$HQ/.claude/hooks/check-repo-active-runs.sh" >/dev/null 2>&1 )
[ ! -e "$HQ/workspace/orchestrator/active-runs.json" ] \
  && ok "SessionStart does not create active-runs.json" \
  || fail "SessionStart does not create active-runs.json" "file was created"

HQ_ROOT="$HQ" "$REG" register --run-id foreign-run --pid "$OWNER_PID" --session-id other-session \
  --command /run-project --project demo --repo "$HQ/repos/private/app" --scope repo >/dev/null 2>&1 \
  || fail "register a foreign run" "registry register failed"

# --- [1] foreign run owns the repo: block ---------------------------------
got="$(edit "$HQ/repos/private/app/src/file.txt" mine)"
if [ "$got" = "2" ] && grep -q 'owned by another Claude session' "$ERR"; then
  ok "edit in a repo owned by another session is blocked"
else
  fail "edit in a repo owned by another session is blocked" "rc=$got stderr=$(cat "$ERR")"
fi

# The check must not prune a live, fresh run (Linux timestamp parse).
n="$(HQ_ROOT="$HQ" "$REG" list 2>/dev/null | jq 'length')"
[ "$n" = "1" ] && ok "a live run survives the stale-entry prune" || fail "a live run survives the stale-entry prune" "runs=$n"

# --- [2] same session: allow ----------------------------------------------
got="$(edit "$HQ/repos/private/app/src/file.txt" other-session)"
[ "$got" = "0" ] && ok "the owning session may edit its own repo" || fail "the owning session may edit its own repo" "rc=$got"

# --- [3] outside the owned repo: allow ------------------------------------
got="$(edit "$HQ/notes/n.md" mine)"
[ "$got" = "0" ] && ok "edit outside the owned repo is allowed" || fail "edit outside the owned repo is allowed" "rc=$got"

# --- [4] SessionStart banner names the owner ------------------------------
out="$( cd "$HQ/repos/private/app" && printf '{}' | env -u BASH_ENV HQ_ROOT="$HQ" CLAUDE_PROJECT_DIR="$HQ" \
  bash "$HQ/.claude/hooks/check-repo-active-runs.sh" 2>/dev/null )"
case "$out" in
  *"<active-runs-warning>"*"foreign-run"*) ok "SessionStart warns inside an owned repo" ;;
  *) fail "SessionStart warns inside an owned repo" "$out" ;;
esac

# --- [4b] a reader's prune must not drop a concurrent register ------------
# check and owner-of prune stale entries too. Keep every register result so a
# wrong count tells us whether a writer timed out on the shared lock.
REGISTER_PIDS=()
for i in 1 2 3 4 5 6; do
  HQ_ROOT="$HQ" "$REG" register --run-id "race-$i" --pid "$OWNER_PID" --session-id other-session \
    --command /run-project --project demo --repo "$HQ/repos/private/app" --scope repo \
    >/dev/null 2>"$TMP/register-$i.stderr" &
  REGISTER_PIDS+=("$!")
  for _ in 1 2 3; do
    HQ_ROOT="$HQ" "$REG" check --target "$HQ/repos/private/app/src/file.txt" --session-id mine >/dev/null 2>&1 &
    HQ_ROOT="$HQ" "$REG" owner-of --path "$HQ/repos/private/app/src/file.txt" >/dev/null 2>&1 &
  done
done
for i in 1 2 3 4 5 6; do
  register_pid="${REGISTER_PIDS[$((i - 1))]}"
  if wait "$register_pid"; then register_rc=0; else register_rc=$?; fi
  printf '%s\n' "$register_rc" > "$TMP/register-$i.rc"
done
while [ -n "$(jobs -pr | grep -vx "$OWNER_PID")" ]; do sleep 0.1; done
n="$(HQ_ROOT="$HQ" "$REG" list 2>/dev/null | jq 'length')"
register_errors=""
for i in 1 2 3 4 5 6; do
  register_rc="$(cat "$TMP/register-$i.rc")"
  if [ "$register_rc" -ne 0 ]; then
    register_stderr="$(cat "$TMP/register-$i.stderr")"
    register_errors="$register_errors race-$i rc=$register_rc stderr=$register_stderr;"
  fi
done
if [ "$n" = "7" ]; then
  ok "concurrent readers do not drop a new registration"
else
  fail "concurrent readers do not drop a new registration" \
    "runs=$n, want 7; non-zero register results:${register_errors:- none}"
fi
if [ -z "$register_errors" ]; then
  ok "every concurrent register exits successfully"
else
  fail "every concurrent register exits successfully" "$register_errors"
fi

# --- [4c] busy lock makes reader prune optional and non-blocking -----------
# _prune_stale_locked may skip pruning when a writer owns the lock, but it
# must still answer check and owner-of from the current registry contents.
REG_FILE="$HQ/workspace/orchestrator/active-runs.json"
LOCK_DIR="$REG_FILE.lock"
if mkdir "$LOCK_DIR" 2>/dev/null; then
  started="$(date +%s)"
  if HQ_ROOT="$HQ" "$REG" check --target "$HQ/repos/private/app/src/file.txt" --session-id mine \
    >"$TMP/busy-check.out" 2>"$TMP/busy-check.err"; then check_rc=0; else check_rc=$?; fi
  check_elapsed=$(( $(date +%s) - started ))
  if [ "$check_rc" = "2" ] && [ "$check_elapsed" -lt 4 ] && grep -q 'run_id=' "$TMP/busy-check.err"; then
    ok "check returns its foreign-owner result quickly while the lock is busy"
  else
    fail "check returns its foreign-owner result quickly while the lock is busy" \
      "rc=$check_rc elapsed=${check_elapsed}s stderr=$(cat "$TMP/busy-check.err")"
  fi

  started="$(date +%s)"
  if HQ_ROOT="$HQ" "$REG" owner-of --path "$HQ/repos/private/app/src/file.txt" \
    >"$TMP/busy-owner.out" 2>"$TMP/busy-owner.err"; then owner_rc=0; else owner_rc=$?; fi
  owner_elapsed=$(( $(date +%s) - started ))
  if [ "$owner_rc" = "0" ] && [ "$owner_elapsed" -lt 4 ] \
    && jq -e 'length == 7' "$TMP/busy-owner.out" >/dev/null; then
    ok "owner-of returns its current owner list quickly while the lock is busy"
  else
    fail "owner-of returns its current owner list quickly while the lock is busy" \
      "rc=$owner_rc elapsed=${owner_elapsed}s out=$(cat "$TMP/busy-owner.out") err=$(cat "$TMP/busy-owner.err")"
  fi
  rmdir "$LOCK_DIR"
else
  fail "create the registry lock for the busy-reader case" "could not mkdir $LOCK_DIR"
fi

# --- [4d] stale lock recovery lets check prune a dead owner ------------------
DEAD_REPO="$HQ/repos/private/dead-lock-app"
DEAD_RUN_ID="dead-lock-owner"
mkdir -p "$DEAD_REPO/src"
git -C "$DEAD_REPO" init -q
printf 'x\n' > "$DEAD_REPO/src/file.txt"
sleep 600 &
DEAD_OWNER_PID=$!
HQ_ROOT="$HQ" "$REG" register --run-id "$DEAD_RUN_ID" --pid "$DEAD_OWNER_PID" --session-id dead-session \
  --command /run-project --project demo --repo "$DEAD_REPO" --scope repo >/dev/null 2>"$TMP/dead-register.stderr"
kill "$DEAD_OWNER_PID" 2>/dev/null
wait "$DEAD_OWNER_PID" 2>/dev/null
[ "$(jq --arg id "$DEAD_RUN_ID" '[.runs[] | select(.run_id == $id)] | length' "$REG_FILE")" = "1" ] \
  && ok "the dead run is present before stale-lock recovery" \
  || fail "the dead run is present before stale-lock recovery" "runs=$(cat "$REG_FILE") stderr=$(cat "$TMP/dead-register.stderr")"
if mkdir "$LOCK_DIR" 2>/dev/null; then
  if touch -t 200001010000 "$LOCK_DIR"; then
    started="$(date +%s)"
    if HQ_ROOT="$HQ" "$REG" check --target "$DEAD_REPO/src/file.txt" --session-id mine \
      >"$TMP/stale-check.out" 2>"$TMP/stale-check.err"; then stale_check_rc=0; else stale_check_rc=$?; fi
    check_elapsed=$(( $(date +%s) - started ))
    dead_count="$(jq --arg id "$DEAD_RUN_ID" '[.runs[] | select(.run_id == $id)] | length' "$REG_FILE")"
    if [ "$stale_check_rc" = "0" ] && [ "$check_elapsed" -lt 4 ] && [ "$dead_count" = "0" ] && [ ! -d "$LOCK_DIR" ]; then
      ok "check removes a stale lock and prunes its dead owner quickly"
    else
      fail "check removes a stale lock and prunes its dead owner quickly" \
        "rc=$stale_check_rc elapsed=${check_elapsed}s dead_entries=$dead_count lock_exists=$([ -d "$LOCK_DIR" ] && echo yes || echo no) stderr=$(cat "$TMP/stale-check.err")"
    fi
  else
    fail "age the dead-owner lock past 60 seconds" "touch -t failed for $LOCK_DIR"
    rmdir "$LOCK_DIR" 2>/dev/null
  fi
else
  fail "create stale lock for dead-owner check" "could not mkdir $LOCK_DIR"
fi
rmdir "$LOCK_DIR" 2>/dev/null

# --- [4e] readers yield while a live writer has published intent -----------
WAIT_RUN_ID="wait-marker-dead-owner"
WAIT_PID=99999999
jq --arg id "$WAIT_RUN_ID" --arg repo "$DEAD_REPO" --argjson pid "$WAIT_PID" \
  --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '.runs += [{run_id:$id,pid:$pid,session_id:"wait-marker-test",command:"/run-project",project:"demo",repo_path:$repo,scope:"repo",started_at:$now,heartbeat_at:$now}]' \
  "$REG_FILE" > "$TMP/wait-marker-registry.json" \
  && mv "$TMP/wait-marker-registry.json" "$REG_FILE"
WAIT_MARKER="$LOCK_DIR.wait.$$"
touch "$WAIT_MARKER"
if HQ_ROOT="$HQ" "$REG" check --target "$DEAD_REPO/src/file.txt" --session-id mine \
  >"$TMP/wait-marker-check.out" 2>"$TMP/wait-marker-check.err"; then wait_check_rc=0; else wait_check_rc=$?; fi
dead_count="$(jq --arg id "$WAIT_RUN_ID" '[.runs[] | select(.run_id == $id)] | length' "$REG_FILE")"
if [ "$wait_check_rc" = "2" ] && [ "$dead_count" = "1" ] && [ ! -d "$LOCK_DIR" ]; then
  ok "a reader yields to a live writer marker without creating a lock"
else
  fail "a reader yields to a live writer marker without creating a lock" \
    "rc=$wait_check_rc dead_entries=$dead_count lock_exists=$([ -d "$LOCK_DIR" ] && echo yes || echo no)"
fi
rm -f "$WAIT_MARKER"
if HQ_ROOT="$HQ" "$REG" check --target "$DEAD_REPO/src/file.txt" --session-id mine \
  >"$TMP/wait-marker-prune.out" 2>"$TMP/wait-marker-prune.err"; then prune_check_rc=0; else prune_check_rc=$?; fi
dead_count="$(jq --arg id "$WAIT_RUN_ID" '[.runs[] | select(.run_id == $id)] | length' "$REG_FILE")"
if [ "$prune_check_rc" = "0" ] && [ "$dead_count" = "0" ] && [ ! -d "$LOCK_DIR" ]; then
  ok "a reader prunes the dead run after writer intent is gone"
else
  fail "a reader prunes the dead run after writer intent is gone" \
    "rc=$prune_check_rc dead_entries=$dead_count lock_exists=$([ -d "$LOCK_DIR" ] && echo yes || echo no)"
fi

# --- [4f] stale-lock removal is serialized by the recovery mutex -----------
RECOVER_DIR="$LOCK_DIR.recover"
RECOVER_RUN_ID="recovery-mutex-dead-owner"
add_recovery_run() {
  jq --arg id "$RECOVER_RUN_ID" --arg repo "$DEAD_REPO" --argjson pid "$WAIT_PID" \
    --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '.runs += [{run_id:$id,pid:$pid,session_id:"recovery-mutex-test",command:"/run-project",project:"demo",repo_path:$repo,scope:"repo",started_at:$now,heartbeat_at:$now}]' \
    "$REG_FILE" > "$TMP/recovery-registry.json" \
    && mv "$TMP/recovery-registry.json" "$REG_FILE"
}
add_recovery_run
if mkdir "$LOCK_DIR" 2>/dev/null; then
  if touch -t 200001010000 "$LOCK_DIR" && mkdir "$RECOVER_DIR" 2>/dev/null; then
    started="$(date +%s)"
    if HQ_ROOT="$HQ" "$REG" check --target "$HQ/notes/n.md" --session-id mine \
      >"$TMP/recovery-busy-check.out" 2>"$TMP/recovery-busy-check.err"; then recover_busy_rc=0; else recover_busy_rc=$?; fi
    recover_busy_elapsed=$(( $(date +%s) - started ))
    dead_count="$(jq --arg id "$RECOVER_RUN_ID" '[.runs[] | select(.run_id == $id)] | length' "$REG_FILE")"
    if [ "$recover_busy_rc" = "0" ] && [ "$recover_busy_elapsed" -lt 4 ] \
      && [ -d "$LOCK_DIR" ] && [ "$dead_count" = "1" ]; then
      ok "a fresh recovery mutex prevents stale-lock removal"
    else
      fail "a fresh recovery mutex prevents stale-lock removal" \
        "rc=$recover_busy_rc elapsed=${recover_busy_elapsed}s dead_entries=$dead_count lock_exists=$([ -d "$LOCK_DIR" ] && echo yes || echo no)"
    fi

    rmdir "$RECOVER_DIR" 2>/dev/null
    # Re-establish the stale-lock case if the baseline incorrectly recovered
    # it in the preceding assertion, so this second phase independently proves
    # recovery succeeds once the mutex is free.
    if [ ! -d "$LOCK_DIR" ]; then
      mkdir "$LOCK_DIR" 2>/dev/null
      touch -t 200001010000 "$LOCK_DIR"
    fi
    dead_count="$(jq --arg id "$RECOVER_RUN_ID" '[.runs[] | select(.run_id == $id)] | length' "$REG_FILE")"
    [ "$dead_count" = "1" ] || add_recovery_run
    if HQ_ROOT="$HQ" "$REG" check --target "$HQ/notes/n.md" --session-id mine \
      >"$TMP/recovery-free-check.out" 2>"$TMP/recovery-free-check.err"; then recover_free_rc=0; else recover_free_rc=$?; fi
    dead_count="$(jq --arg id "$RECOVER_RUN_ID" '[.runs[] | select(.run_id == $id)] | length' "$REG_FILE")"
    if [ "$recover_free_rc" = "0" ] && [ ! -d "$LOCK_DIR" ] && [ "$dead_count" = "0" ]; then
      ok "stale-lock recovery prunes after the recovery mutex is released"
    else
      fail "stale-lock recovery prunes after the recovery mutex is released" \
        "rc=$recover_free_rc dead_entries=$dead_count lock_exists=$([ -d "$LOCK_DIR" ] && echo yes || echo no)"
    fi
  else
    fail "prepare a stale lock and fresh recovery mutex" "could not age lock or create $RECOVER_DIR"
    rm -rf "$LOCK_DIR" "$RECOVER_DIR"
  fi
else
  fail "create stale lock for recovery-mutex case" "could not mkdir $LOCK_DIR"
fi
rmdir "$LOCK_DIR" 2>/dev/null
rmdir "$RECOVER_DIR" 2>/dev/null

# --- [5] owner process gone: the stale run is pruned and edits are allowed -
kill "$OWNER_PID" 2>/dev/null; wait "$OWNER_PID" 2>/dev/null; OWNER_PID=""
got="$(edit "$HQ/repos/private/app/src/file.txt" mine)"
[ "$got" = "0" ] && ok "a dead owner's run no longer blocks" || fail "a dead owner's run no longer blocks" "rc=$got"
n="$(jq '.runs | length' "$HQ/workspace/orchestrator/active-runs.json")"
[ "$n" = "0" ] && ok "the dead owner's run is pruned" || fail "the dead owner's run is pruned" "runs=$n"

# --- [6] empty registry: allow without consulting the helper --------------
got="$(edit "$HQ/repos/private/app/src/file.txt" mine)"
[ "$got" = "0" ] && ok "an empty registry allows the edit" || fail "an empty registry allows the edit" "rc=$got"

# --- [7] missing helper: fail open, but say so ----------------------------
printf '%s\n' '{"version":1,"runs":[{"run_id":"r","pid":1,"session_id":"x","scope":"repo","repo_path":"/"}]}' \
  > "$HQ/workspace/orchestrator/active-runs.json"
mv "$REG" "$TMP/repo-run-registry.real"
cat > "$REG" <<EOF
#!/usr/bin/env bash
printf '%s\\n' 'repo-run-registry.sh: this script needs hq-cli >= 5.78.0 (found 5.77.0); upgrade with: npm install -g @indigoai-us/hq-cli@latest' >&2
printf 'called\\n' >> '$TMP/repo-run-registry.calls'
exit 127
EOF
chmod +x "$REG"
got="$(edit "$HQ/repos/private/app/src/file.txt" mine)"
if [ "$got" = "0" ] && [ ! -s "$ERR" ] && [ "$(cat "$TMP/repo-run-registry.calls")" = "called" ]; then
  ok "a 127 forwarder is called, its stderr is suppressed, and the edit fails open"
else
  fail "a 127 forwarder is called, its stderr is suppressed, and the edit fails open" "rc=$got stderr=$(cat "$ERR") calls=$(cat "$TMP/repo-run-registry.calls" 2>/dev/null)"
fi
rm -f "$REG"
mv "$TMP/repo-run-registry.real" "$REG"
chmod -x "$REG"
got="$(edit "$HQ/repos/private/app/src/file.txt" mine)"
if [ "$got" = "0" ] && grep -q 'repo-run-registry.sh is missing or not executable' "$ERR"; then
  ok "a missing helper is reported on stderr"
else
  fail "a missing helper is reported on stderr" "rc=$got stderr=$(cat "$ERR")"
fi

# The SessionStart sibling uses the same helper, but captures a 127 failure as
# data and emits no banner. With the helper absent it exits silently first.
CHECK_OUT="$TMP/check-repo.out"; CHECK_ERR="$TMP/check-repo.err"
cat > "$REG" <<EOF
#!/usr/bin/env bash
printf '%s\\n' 'repo-run-registry.sh: this script needs hq-cli >= 5.78.0 (found 5.77.0); upgrade with: npm install -g @indigoai-us/hq-cli@latest' >&2
printf 'called\\n' >> '$TMP/check-repo-registry.calls'
exit 127
EOF
chmod +x "$REG"
if ( cd "$HQ" && printf '{}' | HQ_ROOT="$HQ" CLAUDE_PROJECT_DIR="$HQ" bash "$HQ/.claude/hooks/check-repo-active-runs.sh" ) >"$CHECK_OUT" 2>"$CHECK_ERR"; then
  check_rc=0
else
  check_rc=$?
fi
[ "$check_rc" = 0 ] && [ ! -s "$CHECK_OUT" ] && [ ! -s "$CHECK_ERR" ] \
  && [ "$(cat "$TMP/check-repo-registry.calls")" = "called" ] \
  && ok "check-repo-active-runs suppresses a 127 result and emits no banner" \
  || fail "check-repo-active-runs suppresses a 127 result and emits no banner" "rc=$check_rc out=$(cat "$CHECK_OUT") err=$(cat "$CHECK_ERR")"
rm -f "$REG"
if ( cd "$HQ" && printf '{}' | HQ_ROOT="$HQ" CLAUDE_PROJECT_DIR="$HQ" bash "$HQ/.claude/hooks/check-repo-active-runs.sh" ) >"$CHECK_OUT" 2>"$CHECK_ERR"; then
  check_rc=0
else
  check_rc=$?
fi
[ "$check_rc" = 0 ] && [ ! -s "$CHECK_OUT" ] && [ ! -s "$CHECK_ERR" ] \
  && ok "check-repo-active-runs is silent when the helper is absent" \
  || fail "check-repo-active-runs is silent when the helper is absent" "rc=$check_rc out=$(cat "$CHECK_OUT") err=$(cat "$CHECK_ERR")"

# --- [8] check-hq-hooks.sh reports a missing guard helper -----------------
# Inline checker only: a failing `hq` shim first on PATH makes try_doctor fall
# back. Minimal root with the shipped settings and dispatcher present.
CHK="$TMP/chk"
mkdir -p "$CHK/.claude/hooks" "$CHK/core/scripts/lib"
cp "$ROOT/.claude/settings.json" "$CHK/.claude/settings.json"
cp "$ROOT/.claude/hooks/master-hook.sh" "$CHK/.claude/hooks/master-hook.sh"
mkdir -p "$TMP/bin"
printf '#!/bin/sh\nexit 127\n' > "$TMP/bin/hq"
chmod +x "$TMP/bin/hq"
NOHQ_PATH="$TMP/bin:$PATH"
# A tree without the guard hook does not need its helper (minimal fixtures).
check_out="$(PATH="$NOHQ_PATH" bash "$ROOT/core/scripts/check-hq-hooks.sh" --root "$CHK" 2>&1)"
case "$check_out" in
  *"guard helper"*) fail "check-hq-hooks ignores the helper when the guard is absent" "$check_out" ;;
  *) ok "check-hq-hooks ignores the helper when the guard is absent" ;;
esac
cp "$ROOT/.claude/hooks/block-on-active-run.sh" "$CHK/.claude/hooks/block-on-active-run.sh"
check_out="$(PATH="$NOHQ_PATH" bash "$ROOT/core/scripts/check-hq-hooks.sh" --root "$CHK" 2>&1)"
case "$check_out" in
  *"guard helper core/scripts/repo-run-registry.sh is missing"*) ok "check-hq-hooks reports the missing guard helper" ;;
  *) fail "check-hq-hooks reports the missing guard helper" "$check_out" ;;
esac
cp "$ROOT/core/scripts/repo-run-registry.sh" "$CHK/core/scripts/repo-run-registry.sh"
chmod +x "$CHK/core/scripts/repo-run-registry.sh"
check_out="$(PATH="$NOHQ_PATH" bash "$ROOT/core/scripts/check-hq-hooks.sh" --root "$CHK" 2>&1)"
case "$check_out" in
  *"guard helper"*) fail "check-hq-hooks is quiet when the helper exists" "$check_out" ;;
  *) ok "check-hq-hooks is quiet when the helper exists" ;;
esac

echo "block-on-active-run: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
