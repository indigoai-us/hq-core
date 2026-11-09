#!/usr/bin/env bash
# Deferred Stop work returns before a slow body, then the body still runs.
# A crashed or never-started worker cannot wedge the queue. The checkpoint
# hook always runs the gate (its block decision survives) and only turns off
# the sibling backend. The hidden launcher builds a correct Windows command,
# and on Git Bash (the windows shell-smoke job) it is run for real: wait
# status, stdout, stderr, stdin, paths with spaces, .cmd programs, detach.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); echo "ok   [$1]"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL [$1]: $2"; }

IS_WINDOWS=0
case "$(uname -s 2>/dev/null || echo unknown)" in
  MINGW*|MSYS*|CYGWIN*) IS_WINDOWS=1 ;;
esac
BASH_BIN="$(command -v bash)"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
HIDDEN="$ROOT/core/scripts/hq-hidden-run.sh"

wait_for_file() { # <path> <expected-content> <seconds>
  local i=0
  while [ "$i" -lt "$3" ]; do
    if [ -f "$1" ] && [ "$(cat "$1" 2>/dev/null)" = "$2" ]; then return 0; fi
    sleep 1
    i=$((i + 1))
  done
  return 1
}

# A Stop hook that defers a 10 s body and then records its stdin.
make_slow_hook() { # <path> <mark> [seconds]
  cat >"$1" <<SH
#!/usr/bin/env bash
set -uo pipefail
. "$ROOT/core/scripts/lib/hook-stop-async.sh"
hook_stop_async_enter "\$0" || true
INPUT="\$(cat || true)"
sleep ${3:-10}
printf '%s\n' "\$INPUT" > "$2"
SH
  chmod +x "$1"
}

run_deferred() { # <hook> <queue> <payload>
  printf '%s' "$3" | env \
    HOME="$TMP/home" \
    HQ_HOOK_EVENT=Stop \
    HQ_HOOK_ASYNC_DIR="$2" \
    HQ_ROOT="$ROOT" \
    CLAUDE_PROJECT_DIR="$ROOT" \
    "$BASH_BIN" "$1"
}

# --- 1. slow body is queued, not inline --------------------------------------
QUEUE="$TMP/queue"
MARK="$TMP/ran"
make_slow_hook "$TMP/slow.sh" "$MARK"
budget=3
[ "$IS_WINDOWS" = "1" ] && budget=6
start="$(date +%s)"
run_deferred "$TMP/slow.sh" "$QUEUE" payload-1
rc=$?
elapsed=$(( $(date +%s) - start ))
echo "  defer wall=${elapsed}s (the 10 s body must not be included)"
[ "$rc" -eq 0 ] && ok "defer exits 0" || fail "defer exit" "rc=$rc"
[ "$elapsed" -lt "$budget" ] && ok "defer returns in ${elapsed}s, not the 10 s body" || fail "defer time" "${elapsed}s"
if wait_for_file "$MARK" payload-1 40; then
  ok "queued body ran with its payload"
else
  fail "queued body" "mark missing; log=$(tail -20 "$QUEUE/drain.log" 2>/dev/null)"
fi
wait_for_file "$QUEUE/gone" never 3 >/dev/null 2>&1 || true
[ ! -e "$QUEUE/drain.lock" ] && ok "worker released the lock" || fail "lock release" "$(cat "$QUEUE/drain.lock" 2>/dev/null)"

# --- 2. a worker that never started or crashed does not wedge the queue ------
FAST="$TMP/fast.sh"
make_slow_hook "$FAST" "$TMP/ran-crash" 0
old=$(( $(date +%s) - 60 ))
for lock_case in "0 $old" "999999 $old"; do
  q="$TMP/q-crash-${lock_case%% *}"
  mkdir -p "$q/items"
  printf '%s\n' "$lock_case" >"$q/drain.lock"
  rm -f "$TMP/ran-crash"
  run_deferred "$FAST" "$q" "after-crash"
  if wait_for_file "$TMP/ran-crash" after-crash 40; then
    ok "stale lock '$lock_case' is taken over and the item runs"
  else
    fail "stale lock '$lock_case'" "item never ran; lock=$(cat "$q/drain.lock" 2>/dev/null) log=$(tail -5 "$q/drain.log" 2>/dev/null)"
  fi
done

# The pre-release directory lock is replaced too.
q="$TMP/q-legacy"
mkdir -p "$q/items" "$q/drain.lock"
rm -f "$TMP/ran-crash"
run_deferred "$FAST" "$q" "after-legacy"
wait_for_file "$TMP/ran-crash" after-legacy 40 \
  && ok "legacy directory lock is replaced" || fail "legacy lock" "item never ran"

# A live worker's lock is respected: the item waits for that worker.
q="$TMP/q-live"
mkdir -p "$q/items"
printf '%s %s\n' "$$" "$(date +%s)" >"$q/drain.lock"
rm -f "$TMP/ran-crash"
run_deferred "$FAST" "$q" "live"
sleep 2
if [ ! -f "$TMP/ran-crash" ] && [ "$(cut -d' ' -f1 "$q/drain.lock")" = "$$" ]; then
  ok "a live worker's lock is left alone"
else
  fail "live lock" "lock was taken over"
fi
# The live worker drains it.
env HQ_HOOK_ASYNC_DIR="$q" "$BASH_BIN" -c ". '$ROOT/core/scripts/lib/hook-stop-async.sh'; printf '%s %s\n' \$\$ \$(date +%s) >'$q/drain.lock'; exec '$BASH_BIN' '$ROOT/core/scripts/hook-stop-async-drain.sh' '$q'"
wait_for_file "$TMP/ran-crash" live 20 && ok "the lock holder drains the waiting item" || fail "live drain" "item never ran"

# --- 3. checkpoint gate keeps its decision; only the sibling is skipped ------
make_gate_home() { # <home>
  mkdir -p "$1/.local/bin"
  cat >"$1/.local/bin/hq" <<'SH'
#!/bin/sh
printf 'args=%s\n' "$*" >"$GATE_LOG"
printf 'backend=%s\n' "${HQ_CHECKPOINT_BACKEND:-}" >>"$GATE_LOG"
printf 'noupdate=%s\n' "${HQ_NO_UPDATE_CHECK:-}" >>"$GATE_LOG"
cat >>"$GATE_LOG"
printf '{"decision":"block","reason":"checkpoint first"}\n'
SH
  chmod +x "$1/.local/bin/hq"
  if [ "$IS_WINDOWS" = "1" ]; then
    # npm on Windows installs hq next to hq.cmd; cmd.exe runs the .cmd.
    printf '@echo off\r\n"%s" "%s" %%*\r\n' "$(cygpath -w "$BASH_BIN")" "$1/.local/bin/hq" >"$1/.local/bin/hq.cmd"
  fi
}
run_gate() { # <home> -> stdout
  env -u HQ_CHECKPOINT_BACKEND -u HQ_NO_UPDATE_CHECK \
    HOME="$1" \
    HQ_TOOLCHAIN_DIR="$1/none" \
    PATH="/usr/bin:/bin" \
    CLAUDE_PROJECT_DIR="$TMP/proj" \
    GATE_LOG="$TMP/gate.log" \
    "$BASH_BIN" "$ROOT/.claude/hooks/checkpoint-stop-gate.sh" <<<'{"session_id":"s-1"}'
}
mkdir -p "$TMP/proj/.claude"
GH="$TMP/gate home"
make_gate_home "$GH"
rm -f "$TMP/gate.log"
out="$(run_gate "$GH")"
case "$out" in
  *'"decision":"block"'*) ok "gate runs and its block decision is emitted when hq is only in ~/.local/bin" ;;
  *) fail "gate decision" "stdout=$out log=$(cat "$TMP/gate.log" 2>/dev/null)" ;;
esac
grep -q '^args=core checkpoint-stop-gate$' "$TMP/gate.log" 2>/dev/null \
  && ok "gate argv intact" || fail "gate argv" "$(cat "$TMP/gate.log" 2>/dev/null)"
grep -q '"session_id":"s-1"' "$TMP/gate.log" 2>/dev/null \
  && ok "gate payload reaches hq on stdin" || fail "gate stdin" "$(cat "$TMP/gate.log" 2>/dev/null)"
grep -q '^noupdate=1' "$TMP/gate.log" 2>/dev/null \
  && ok "HQ_NO_UPDATE_CHECK=1 reaches hq" || fail "no-update" "$(cat "$TMP/gate.log" 2>/dev/null)"
grep -q '^backend=none' "$TMP/gate.log" 2>/dev/null \
  && ok "no claude/grok: the sibling backend is set to none" || fail "backend none" "$(cat "$TMP/gate.log" 2>/dev/null)"

printf '#!/bin/sh\nexit 0\n' >"$GH/.local/bin/claude"
chmod +x "$GH/.local/bin/claude"
rm -f "$TMP/gate.log"
out="$(run_gate "$GH")"
grep -q '^backend=$' "$TMP/gate.log" 2>/dev/null \
  && ok "claude in ~/.local/bin: backend left to the CLI" || fail "backend auto" "$(cat "$TMP/gate.log" 2>/dev/null)"
case "$out" in *'"decision":"block"'*) ok "gate decision kept with a backend present" ;; *) fail "gate decision 2" "$out" ;; esac

# --- 4. Windows command construction (any host, dry run) ---------------------
DRY_BIN="$TMP/dir with space"
mkdir -p "$DRY_BIN"
printf '#!/bin/sh\n' >"$DRY_BIN/tool"
printf '@echo off\r\n' >"$DRY_BIN/tool.cmd"
chmod +x "$DRY_BIN/tool"
dry="$(PATH="$DRY_BIN:$PATH" HQ_HIDDEN_WINDOWS_DRY_RUN=1 bash "$HIDDEN" --wait -- tool core "a b" 2>&1 </dev/null)"
first="$(printf '%s\n' "$dry" | head -1)"
case "$first" in
  *'"'*) fail "wscript argv" "embedded quotes: $first" ;;
  *' wait') ok "wscript gets plain arguments ending in wait" ;;
  *) fail "wscript argv" "$first" ;;
esac
printf '%s\n' "$dry" | grep -F >/dev/null "call \"$DRY_BIN/tool.cmd\" \"core\" \"a b\" < " \
  && ok ".cmd companion is preferred and each argument is quoted once" || fail "cmd line" "$dry"
printf '%s\n' "$dry" | grep >/dev/null 'echo %ERRORLEVEL%' \
  && ok "exit status is recorded" || fail "errorlevel" "$dry"
PATH="$DRY_BIN:$PATH" HQ_HIDDEN_WINDOWS_DRY_RUN=1 bash "$HIDDEN" --wait -- tool 'say "hi"' >/dev/null 2>&1 </dev/null
[ "$?" -eq 2 ] && ok "an argument with a double quote is refused" || fail "quote refusal" "accepted"
PATH="$DRY_BIN:$PATH" HQ_HIDDEN_WINDOWS_DRY_RUN=1 bash "$HIDDEN" --wait -- tool '100%' >/dev/null 2>&1 </dev/null
[ "$?" -eq 2 ] && ok "an argument with % is refused" || fail "percent refusal" "accepted"

# --- 4b. launcher failures fall back to a direct run (any host) --------------
FB="$TMP/fallback bin"
mkdir -p "$FB"
printf '#!/bin/sh\nprintf "%%s" "$3"\n' >"$FB/cygpath"
printf '#!/bin/sh\nexit 0\n' >"$FB/fake-wscript"
cat >"$FB/echo-stdin" <<'SH'
#!/usr/bin/env bash
printf 'direct:%s\n' "$(cat)"
exit 5
SH
chmod +x "$FB/cygpath" "$FB/fake-wscript" "$FB/echo-stdin"

# A wscript that never runs the command: no status, so the command runs directly.
out="$(printf 'in-1' | PATH="$FB:$PATH" HQ_HIDDEN_FORCE_WINDOWS=1 HQ_HIDDEN_WSCRIPT="$FB/fake-wscript" \
  bash "$HIDDEN" --wait --direct-on-error -- echo-stdin 2>/dev/null)"
rc=$?
[ "$rc" -eq 5 ] && [ "$out" = "direct:in-1" ] \
  && ok "no status from the hidden run: direct run with the same stdin and status" || fail "fallback no-status" "rc=$rc out=$out"

# A temp path cmd.exe cannot quote: refused, then run directly.
PCT="$TMP/pct%dir"
mkdir -p "$PCT"
out="$(printf 'in-2' | PATH="$FB:$PATH" TMPDIR="$PCT" HQ_HIDDEN_FORCE_WINDOWS=1 HQ_HIDDEN_WSCRIPT="$FB/fake-wscript" \
  bash "$HIDDEN" --wait --direct-on-error -- echo-stdin 2>/dev/null)"
rc=$?
[ "$rc" -eq 5 ] && [ "$out" = "direct:in-2" ] \
  && ok "a % in the temp path falls back to a direct run" || fail "fallback percent" "rc=$rc out=$out"

# Without --direct-on-error the refusal stays a launcher error (status 2).
PATH="$FB:$PATH" TMPDIR="$PCT" HQ_HIDDEN_FORCE_WINDOWS=1 HQ_HIDDEN_WSCRIPT="$FB/fake-wscript" \
  bash "$HIDDEN" --wait -- echo-stdin </dev/null >/dev/null 2>&1
[ "$?" -eq 2 ] && ok "without --direct-on-error a refusal is status 2" || fail "no fallback" "unexpected status"

if [ "$IS_WINDOWS" != "1" ]; then
  # No cygpath at all (a non-Windows host forced onto the Windows path).
  NOCYG="$TMP/nocyg"
  mkdir -p "$NOCYG"
  cp "$FB/echo-stdin" "$NOCYG/echo-stdin"
  out="$(printf 'in-3' | PATH="$NOCYG:/usr/bin:/bin" HQ_HIDDEN_FORCE_WINDOWS=1 \
    "$BASH_BIN" "$HIDDEN" --wait --direct-on-error -- echo-stdin 2>/dev/null)"
  rc=$?
  [ "$rc" -eq 5 ] && [ "$out" = "direct:in-3" ] \
    && ok "missing cygpath falls back to a direct run" || fail "fallback cygpath" "rc=$rc out=$out"
fi

# The gate end to end: a launcher error never blocks the turn, the CLI's
# decision still comes through.
rm -f "$TMP/gate.log"
out="$(env -u HQ_CHECKPOINT_BACKEND -u HQ_NO_UPDATE_CHECK \
  HOME="$GH" HQ_TOOLCHAIN_DIR="$GH/none" PATH="$FB:/usr/bin:/bin" TMPDIR="$PCT" \
  HQ_HIDDEN_FORCE_WINDOWS=1 HQ_HIDDEN_WSCRIPT="$FB/fake-wscript" \
  CLAUDE_PROJECT_DIR="$TMP/proj" GATE_LOG="$TMP/gate.log" \
  "$BASH_BIN" "$ROOT/.claude/hooks/checkpoint-stop-gate.sh" <<<'{"session_id":"s-2"}' 2>/dev/null)"
rc=$?
case "$rc:$out" in
  0:*'"decision":"block"'*) ok "gate falls back to a direct hq run on a launcher error and keeps the decision" ;;
  *) fail "gate fallback" "rc=$rc out=$out log=$(cat "$TMP/gate.log" 2>/dev/null)" ;;
esac
grep -F '"session_id":"s-2"' "$TMP/gate.log" >/dev/null 2>&1 \
  && ok "gate fallback still passes the payload" || fail "gate fallback stdin" "$(cat "$TMP/gate.log" 2>/dev/null)"

# "!" is carried literally (cmd.exe expands it only with delayed expansion).
dry="$(PATH="$DRY_BIN:$PATH" HQ_HIDDEN_WINDOWS_DRY_RUN=1 bash "$HIDDEN" --wait -- tool 'a!b' 2>&1 </dev/null)"
rc=$?
[ "$rc" -eq 0 ] && printf '%s\n' "$dry" | grep -F '"a!b"' >/dev/null \
  && ok "an argument with ! is accepted" || fail "bang" "rc=$rc $dry"

# --- 2b. worker crash recovery, lock ownership, log rotation ----------------
DRAIN="$ROOT/core/scripts/hook-stop-async-drain.sh"
make_item() { # <queue> <name> <mark> <payload>
  mkdir -p "$1/items/$2"
  printf '#!/usr/bin/env bash\ncat > "%s"\n' "$3" >"$1/item-$2.sh"
  printf '%s\n' "$1/item-$2.sh" >"$1/items/$2/script"
  printf '%s' "$4" >"$1/items/$2/stdin"
  printf '%s\n' "$TMP" >"$1/items/$2/cwd"
}
q="$TMP/q-orphan"
mkdir -p "$q/items"
make_item "$q" "100.running.999999" "$TMP/orphan-1" orphan-1
make_item "$q" "101.running.999998" "$TMP/orphan-2" orphan-2
printf '2\n' >"$q/items/101.running.999998/attempts"
printf '0 %s\n' "$(date +%s)" >"$q/drain.lock"
"$BASH_BIN" "$DRAIN" "$q" >/dev/null 2>&1
[ "$(cat "$TMP/orphan-1" 2>/dev/null)" = "orphan-1" ] \
  && ok "an item left claimed by a dead worker is requeued and runs" || fail "orphan requeue" "$(ls "$q/items")"
[ ! -e "$TMP/orphan-2" ] && grep -F 'dropped 101.running.999998 after 3 attempts' "$q/drain.log" >/dev/null 2>&1 \
  && ok "an item past its attempt limit is dropped with a log line" || fail "orphan drop" "$(cat "$q/drain.log" 2>/dev/null)"
[ -z "$(ls -A "$q/items" 2>/dev/null)" ] && [ ! -e "$q/drain.lock" ] \
  && ok "queue and lock are empty after recovery" || fail "orphan cleanup" "$(ls -A "$q/items") lock=$(cat "$q/drain.lock" 2>/dev/null)"

q="$TMP/q-owned"
mkdir -p "$q/items"
make_item "$q" "200" "$TMP/owned" owned
printf '%s %s\n' "$$" "$(date +%s)" >"$q/drain.lock"
"$BASH_BIN" "$DRAIN" "$q" >/dev/null 2>&1
[ ! -e "$TMP/owned" ] && [ "$(cut -d' ' -f1 "$q/drain.lock")" = "$$" ] \
  && ok "a worker that does not own the lock exits without running or rewriting it" || fail "ownership" "ran or rewrote the lock"

q="$TMP/q-rotate"
mkdir -p "$q/items"
head -c 1100000 /dev/zero | tr '\0' 'x' >"$q/drain.log"
printf '0 %s\n' "$(date +%s)" >"$q/drain.lock"
"$BASH_BIN" "$DRAIN" "$q" >/dev/null 2>&1
[ -f "$q/drain.log.1" ] && [ ! -s "$q/drain.log" ] \
  && ok "drain.log rotates past 1 MB" || fail "rotate" "$(ls -la "$q")"

# --- 2b2. an unclaimable item cannot wedge the worker; payload privacy --------
if [ "$IS_WINDOWS" != "1" ] && [ "$(id -u)" != "0" ]; then
  q="$TMP/q-stuck"
  mkdir -p "$q/items"
  make_item "$q" "300" "$TMP/stuck" stuck
  chmod 500 "$q/items"
  printf '0 %s\n' "$(date +%s)" >"$q/drain.lock"
  "$BASH_BIN" "$DRAIN" "$q" >/dev/null 2>&1 &
  stuck_pid=$!
  i=0
  while [ "$i" -lt 10 ] && kill -0 "$stuck_pid" 2>/dev/null; do sleep 1; i=$((i + 1)); done
  if kill -0 "$stuck_pid" 2>/dev/null; then
    kill -9 "$stuck_pid" 2>/dev/null
    fail "unclaimable item" "the worker was still spinning after 10 s"
  else
    ok "an unclaimable item ends the worker instead of spinning"
  fi
  wait "$stuck_pid" 2>/dev/null
  [ ! -e "$q/drain.lock" ] && ok "the worker releases the lock after a failed claim" || fail "stuck lock" "$(cat "$q/drain.lock" 2>/dev/null)"
  chmod 700 "$q/items"

  # Publishing fails: the body runs inline with the payload it was given.
  q="$TMP/q-nopublish"
  NOMV="$TMP/nomv"
  mkdir -p "$NOMV"
  printf '#!/bin/sh\nexit 1\n' >"$NOMV/mv"
  chmod +x "$NOMV/mv"
  make_slow_hook "$TMP/nopub.sh" "$TMP/ran-nopub" 0
  printf 'kept-payload' | env PATH="$NOMV:$PATH" HOME="$TMP/home" HQ_HOOK_EVENT=Stop HQ_HOOK_ASYNC_DIR="$q" HQ_ROOT="$ROOT" CLAUDE_PROJECT_DIR="$ROOT" "$BASH_BIN" "$TMP/nopub.sh" 2>/dev/null
  [ "$(cat "$TMP/ran-nopub" 2>/dev/null)" = "kept-payload" ] \
    && ok "a failed publish runs the body with its payload" || fail "publish fallback" "got '$(cat "$TMP/ran-nopub" 2>/dev/null)'"

  mode="$(ls -ld "$QUEUE/items" | cut -c1-10)$(ls -ld "$QUEUE" | cut -c1-10)"
  [ "$mode" = "drwx------drwx------" ] && ok "the queue is private to the user" || fail "queue mode" "$mode"
fi

# --- 2c. a failed launch still runs the Stop work ----------------------------
# Both launchers fail, as on macOS with neither setsid nor node on PATH.
FX="$TMP/fx root"
mkdir -p "$FX/core/scripts/lib"
cp "$ROOT/core/scripts/lib/hook-stop-async.sh" "$FX/core/scripts/lib/"
cp "$ROOT/core/scripts/hook-stop-async-drain.sh" "$FX/core/scripts/"
printf '#!/usr/bin/env bash\necho launcher-down >&2\nexit 1\n' >"$FX/core/scripts/hq-hidden-run.sh"
cp "$FX/core/scripts/hq-hidden-run.sh" "$FX/core/scripts/hq-detach.sh"
make_slow_hook "$TMP/fail-launch.sh" "$TMP/ran-fail-launch" 0
q="$TMP/q-fail-launch"
printf 'launch-failed' | env HOME="$TMP/home" HQ_HOOK_EVENT=Stop HQ_HOOK_ASYNC_DIR="$q" \
  HQ_ROOT="$FX" CLAUDE_PROJECT_DIR="$FX" "$BASH_BIN" "$TMP/fail-launch.sh"
rc=$?
[ "$rc" -eq 0 ] && ok "failed launch: the hook exits 0" || fail "failed launch rc" "rc=$rc"
[ "$(cat "$TMP/ran-fail-launch" 2>/dev/null)" = "launch-failed" ] \
  && ok "failed launch: the Stop work ran before the hook returned" \
  || fail "failed launch work" "never ran; items=$(ls "$q/items" 2>/dev/null) log=$(tail -3 "$q/drain.log" 2>/dev/null)"
[ -z "$(ls -A "$q/items" 2>/dev/null)" ] && [ ! -e "$q/drain.lock" ] \
  && ok "failed launch: queue and lock are clear" || fail "failed launch cleanup" "items=$(ls -A "$q/items") lock=$(cat "$q/drain.lock" 2>/dev/null)"
grep -F 'launch failed' "$q/drain.log" >/dev/null 2>&1 \
  && ok "failed launch: the fallback is logged" || fail "failed launch log" "$(cat "$q/drain.log" 2>/dev/null)"

# --- 2d. one drain runs each item with that item's own session and repo ------
ENV_HOOK="$TMP/env-hook.sh"
cat >"$ENV_HOOK" <<SH
#!/usr/bin/env bash
set -uo pipefail
. "$ROOT/core/scripts/lib/hook-stop-async.sh"
hook_stop_async_enter "\$0" || true
cat >/dev/null
{
  printf 'sid=%s\n' "\${HQ_SESSION_ID:-}"
  printf 'claude_sid=%s\n' "\${CLAUDE_SESSION_ID:-}"
  printf 'project=%s\n' "\${CLAUDE_PROJECT_DIR:-}"
  printf 'gitdir=%s\n' "\${GIT_DIR:-}"
  printf 'pwd=%s\n' "\$PWD"
  printf 'child_sid=%s\n' "\$("$BASH_BIN" -c 'printf %s "\${HQ_SESSION_ID:-}"')"
} >"\$PWD/.ran"
SH
chmod +x "$ENV_HOOK"
q="$TMP/q-env"
mkdir -p "$q/items"
RA="$(cd "$TMP" && pwd -P)/repo-a"; RB="$(cd "$TMP" && pwd -P)/repo-b"; RS="$(cd "$TMP" && pwd -P)/repo-starter"; RG="$(cd "$TMP" && pwd -P)/repo-gone"
mkdir -p "$RA" "$RB" "$RS" "$RG"
# A live lock holds the worker back while both sessions enqueue.
printf '%s %s\n' "$$" "$(date +%s)" >"$q/drain.lock"
( cd "$RA" && printf '{}' | env -u HQ_SESSION_ID -u CLAUDE_SESSION_ID HOME="$TMP/home" HQ_HOOK_EVENT=Stop HQ_HOOK_ASYNC_DIR="$q" \
    HQ_ROOT="$ROOT" CLAUDE_PROJECT_DIR="$RA" HQ_SESSION_ID=sess-a "$BASH_BIN" "$ENV_HOOK" )
( cd "$RB" && printf '{}' | env -u HQ_SESSION_ID -u CLAUDE_SESSION_ID HOME="$TMP/home" HQ_HOOK_EVENT=Stop HQ_HOOK_ASYNC_DIR="$q" \
    HQ_ROOT="$ROOT" CLAUDE_PROJECT_DIR="$RB" "$BASH_BIN" "$ENV_HOOK" )
( cd "$RG" && printf '{}' | env -u HQ_SESSION_ID -u CLAUDE_SESSION_ID HOME="$TMP/home" HQ_HOOK_EVENT=Stop HQ_HOOK_ASYNC_DIR="$q" \
    HQ_ROOT="$ROOT" CLAUDE_PROJECT_DIR="$RG" HQ_SESSION_ID=sess-gone "$BASH_BIN" "$ENV_HOOK" )
rm -rf "$RG"
# The worker belongs to a third session, in a third repo, with git overrides.
printf '0 %s\n' "$(date +%s)" >"$q/drain.lock"
( cd "$RS" && env HQ_SESSION_ID=sess-starter CLAUDE_SESSION_ID=claude-starter CLAUDE_PROJECT_DIR="$RS" \
    GIT_DIR="$RS/.git" "$BASH_BIN" "$ROOT/core/scripts/hook-stop-async-drain.sh" "$q" ) >/dev/null 2>&1
check_env() { # <file> <line> <label>
  grep -Fx -- "$2" "$1" >/dev/null 2>&1 && ok "$3" || fail "$3" "$(cat "$1" 2>/dev/null | tr '\n' ' ')"
}
check_env "$RA/.ran" 'sid=sess-a' "drain: item A keeps its own session id"
check_env "$RA/.ran" 'child_sid=sess-a' "drain: item A's session id is exported to child processes"
check_env "$RA/.ran" "project=$RA" "drain: item A keeps its own project dir"
check_env "$RA/.ran" "pwd=$RA" "drain: item A runs in its own repo"
check_env "$RB/.ran" 'sid=' "drain: an item with no session id does not inherit the worker's"
check_env "$RB/.ran" 'claude_sid=' "drain: a second session id variable does not leak either"
check_env "$RB/.ran" "project=$RB" "drain: item B keeps its own project dir"
check_env "$RB/.ran" "pwd=$RB" "drain: item B runs in its own repo"
check_env "$RB/.ran" 'gitdir=' "drain: the worker's GIT_DIR does not reach an item"
[ ! -e "$RS/.ran" ] && ok "drain: an item whose repo is gone does not run in the worker's repo" \
  || fail "drain gone cwd" "ran in the worker's directory: $(cat "$RS/.ran")"
grep -F 'cwd is gone' "$q/drain.log" >/dev/null 2>&1 \
  && ok "drain: the skipped item is logged" || fail "drain gone log" "$(cat "$q/drain.log" 2>/dev/null)"
[ -z "$(ls -A "$q/items" 2>/dev/null)" ] && ok "drain: no item is left behind" || fail "drain leftovers" "$(ls -A "$q/items")"

# --- 4c. non-ASCII paths on Windows: UTF-8 batch, and failure is visible ------
UB="$TMP/bin-caf"$'\xc3\xa9'
mkdir -p "$UB"
printf '@echo off\r\n' >"$UB/tool.cmd"
printf '#!/bin/sh\n' >"$UB/tool"
chmod +x "$UB/tool"
dry="$(PATH="$UB:$PATH" HQ_HIDDEN_WINDOWS_DRY_RUN=1 bash "$HIDDEN" -- tool a 2>&1 </dev/null)"
printf '%s\n' "$dry" | grep -F >/dev/null 'chcp.com" 65001' \
  && ok "a non-ASCII path switches the batch file to UTF-8" || fail "chcp" "$dry"
# The switch comes before the first line that holds the path.
first_chcp="$(printf '%s\n' "$dry" | grep -n 'chcp.com' | head -1 | cut -d: -f1)"
first_path="$(printf '%s\n' "$dry" | grep -n 'bin-caf' | sed -n 2p | cut -d: -f1)"
[ -n "$first_chcp" ] && [ -n "$first_path" ] && [ "$first_chcp" -lt "$first_path" ] \
  && ok "the UTF-8 switch precedes every path in the batch file" || fail "chcp order" "$dry"
dry="$(PATH="$DRY_BIN:$PATH" HQ_HIDDEN_WINDOWS_DRY_RUN=1 TMPDIR=/tmp bash "$HIDDEN" -- tool a 2>&1 </dev/null)"
printf '%s\n' "$dry" | grep -F >/dev/null 'chcp.com' \
  && fail "chcp ascii" "ASCII paths must not start chcp: $dry" || ok "ASCII paths start no chcp process"
printf '%s\n' "$dry" | grep -F >/dev/null 'if not exist' \
  && ok "the batch file checks the program path before running" || fail "preflight" "$dry"

# A launcher that reports success while the batch file never ran: visible failure.
err="$(PATH="$FB:$PATH" HQ_HIDDEN_FORCE_WINDOWS=1 HQ_HIDDEN_WSCRIPT="$FB/fake-wscript" HQ_HIDDEN_START_TIMEOUT=1 \
  bash "$HIDDEN" -- echo-stdin 2>&1 </dev/null)"
rc=$?
[ "$rc" -ne 0 ] && ok "a detached run that never started is not a success (status $rc)" || fail "nowait silent success" "rc=0 err=$err"
printf '%s' "$err" | grep -F >/dev/null 'did not start' \
  && ok "the launcher says so on stderr" || fail "nowait message" "$err"

# --- 5. Windows behaviour (Git Bash only) ------------------------------------
if [ "$IS_WINDOWS" = "1" ]; then
  WB="$TMP/win bin"
  mkdir -p "$WB"
  cat >"$WB/echo-args.sh" <<'SH'
#!/usr/bin/env bash
printf 'argc=%s\n' "$#"
for a in "$@"; do printf 'arg=[%s]\n' "$a"; done
printf 'stdin=[%s]\n' "$(cat)"
echo "to-stderr" >&2
exit 3
SH
  out="$(printf 'hello stdin' | bash "$HIDDEN" --wait -- bash "$WB/echo-args.sh" "two words" "x&y" 2>"$TMP/w.err")"
  rc=$?
  [ "$rc" -eq 3 ] && ok "windows --wait returns the child status" || fail "windows status" "rc=$rc out=$out err=$(cat "$TMP/w.err")"
  printf '%s\n' "$out" | grep -F >/dev/null 'arg=[two words]' && printf '%s\n' "$out" | grep -F >/dev/null 'arg=[x&y]' \
    && ok "windows --wait keeps arguments with spaces and &" || fail "windows args" "$out"
  printf '%s\n' "$out" | grep -F >/dev/null 'stdin=[hello stdin]' && ok "windows --wait passes stdin" || fail "windows stdin" "$out"
  grep -q 'to-stderr' "$TMP/w.err" && ok "windows --wait returns stderr" || fail "windows stderr" "$(cat "$TMP/w.err")"

  printf '@echo off\r\necho cmd-ran %%1\r\nexit /b 4\r\n' >"$WB/wtool.cmd"
  out="$(PATH="$WB:$PATH" bash "$HIDDEN" --wait -- wtool "p q" </dev/null 2>&1)"
  rc=$?
  [ "$rc" -eq 4 ] && printf '%s' "$out" | grep >/dev/null 'cmd-ran "p q"' \
    && ok "windows --wait runs a .cmd program from a path with spaces" || fail "windows cmd" "rc=$rc out=$out"

  LOG="$WB/detached log.txt"
  bash "$HIDDEN" --logfile "$LOG" -- bash -c 'echo detached-ok' </dev/null
  i=0
  while [ "$i" -lt 30 ] && ! grep -q detached-ok "$LOG" 2>/dev/null; do sleep 1; i=$((i + 1)); done
  grep -q detached-ok "$LOG" 2>/dev/null && ok "windows detached run writes its log" || fail "windows detach" "log=$(cat "$LOG" 2>/dev/null)"

  # Real wscript and cmd.exe with a non-ASCII program path and temp directory.
  UW="$TMP/win caf"$'\xc3\xa9'" dir"
  mkdir -p "$UW/tmp"
  printf '@echo off\r\necho unicode-ran %%1\r\nexit /b 6\r\n' >"$UW/utool.cmd"
  out="$(PATH="$UW:$PATH" TMPDIR="$UW/tmp" bash "$HIDDEN" --wait -- utool "p q" </dev/null 2>"$TMP/u.err")"
  rc=$?
  [ "$rc" -eq 6 ] && printf '%s' "$out" | grep >/dev/null 'unicode-ran "p q"' \
    && ok "windows --wait runs a program under a non-ASCII path" || fail "windows unicode wait" "rc=$rc out=$out err=$(cat "$TMP/u.err")"
  ULOG="$UW/detached log.txt"
  TMPDIR="$UW/tmp" bash "$HIDDEN" --logfile "$ULOG" -- bash -c 'echo unicode-detached-ok' </dev/null 2>"$TMP/u2.err"
  rc=$?
  i=0
  while [ "$i" -lt 30 ] && ! grep -q unicode-detached-ok "$ULOG" 2>/dev/null; do sleep 1; i=$((i + 1)); done
  [ "$rc" -eq 0 ] && grep -q unicode-detached-ok "$ULOG" 2>/dev/null \
    && ok "windows detached run works under a non-ASCII temp and log path" || fail "windows unicode detach" "rc=$rc err=$(cat "$TMP/u2.err") log=$(cat "$ULOG" 2>/dev/null)"
else
  echo "skip [windows behaviour] not a Git Bash host"
fi

echo "hook-stop-async: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
