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
# check and owner-of prune stale entries too. Without the registry lock a
# reader's prune can write its older snapshot over a register that landed in
# between, and the new owner disappears from the registry.
for i in 1 2 3 4 5 6; do
  HQ_ROOT="$HQ" "$REG" register --run-id "race-$i" --pid "$OWNER_PID" --session-id other-session \
    --command /run-project --project demo --repo "$HQ/repos/private/app" --scope repo >/dev/null 2>&1 &
  for _ in 1 2 3; do
    HQ_ROOT="$HQ" "$REG" check --target "$HQ/repos/private/app/src/file.txt" --session-id mine >/dev/null 2>&1 &
    HQ_ROOT="$HQ" "$REG" owner-of --path "$HQ/repos/private/app/src/file.txt" >/dev/null 2>&1 &
  done
done
while [ -n "$(jobs -pr | grep -vx "$OWNER_PID")" ]; do sleep 0.1; done
n="$(HQ_ROOT="$HQ" "$REG" list 2>/dev/null | jq 'length')"
[ "$n" = "7" ] && ok "concurrent readers do not drop a new registration" \
  || fail "concurrent readers do not drop a new registration" "runs=$n, want 7"

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
chmod -x "$REG"
got="$(edit "$HQ/repos/private/app/src/file.txt" mine)"
if [ "$got" = "0" ] && grep -q 'repo-run-registry.sh is missing or not executable' "$ERR"; then
  ok "a missing helper is reported on stderr"
else
  fail "a missing helper is reported on stderr" "rc=$got stderr=$(cat "$ERR")"
fi

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
