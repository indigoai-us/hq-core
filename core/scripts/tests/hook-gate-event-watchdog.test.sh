#!/usr/bin/env bash
# hq-core: public
# hook-gate-event-watchdog.test.sh: gates launched by one hook dispatcher share
# one timeout watchdog instead of starting one each, with identical decisions,
# and a hung gate is still killed within its bound.
#
# An adapter that sources hook-adapter-core.sh exports HQAD_DISPATCHER_PID and
# runs one hook-gate.sh per registry hook. Each gate used to start its own
# hook-timeout-watchdog.sh, so one tool call through an adapter started a
# watchdog per gate. The gate now arms one watchdog per dispatcher, tracked by
# a claim file, and that watchdog ends once the dispatcher has exited.
#
# Sections:
#   [1] N gates under one dispatcher start one watchdog; without a dispatcher
#       each gate starts and reaps its own (unchanged)
#   [2] exit code, stdout and stderr are identical with and without a dispatcher
#   [3] the shared watchdog exits after the dispatcher and removes its claim
#   [4] a stale claim re-arms; an unwritable claim falls back to per-gate
#   [5] a hung gate is killed within its bound: the adapter's hard cap, and an
#       outer timeout whose caller reads the gate's output to EOF
#   [6] the shared watchdog warns about the gate that runs long, by name, and
#       not about time spent between gates
#   [7] POSIX mode with an unwritable claim, an unreadable claim, a gate whose
#       parent is not the dispatcher, and a stdout capture that must not wait
#       for the shared watchdog
#
# Runs under every Bash found: the PATH bash and /bin/bash (3.2 on macOS).
# Set HOOK_GATE_TEST_BASHES to override the list.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"

pass=0
fail=0
ok() { pass=$((pass + 1)); printf '  ok: %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL: %s\n' "$1"; }

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq unavailable"; exit 0; }
command -v perl >/dev/null 2>&1 || { echo "SKIP: perl unavailable"; exit 0; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/hook-gate-event-wd.XXXXXX")"
TMP="$(cd "$TMP" && pwd -P)"
cleanup() {
  local f pid
  for f in "$TMP"/pids/*; do
    [ -f "$f" ] || continue
    pid="$(cat "$f" 2>/dev/null || true)"
    case "$pid" in ''|*[!0-9]*) ;; *) kill -KILL "$pid" 2>/dev/null || true ;; esac
  done
  rm -rf "$TMP"
}
trap cleanup EXIT
mkdir -p "$TMP/pids"

FIX="$TMP/hq"
mkdir -p "$FIX/.claude/hooks/real" "$FIX/core/scripts/lib" "$FIX/workspace" "$FIX/hooks"
cp "$ROOT/.claude/hooks/hook-gate.sh" "$FIX/.claude/hooks/"
cp "$ROOT/.claude/hooks/hook-timeout-watchdog.sh" "$ROOT/.claude/hooks/hook-timeout-probe.sh" \
  "$FIX/.claude/hooks/real/"
cp "$ROOT/core/scripts/hook-lib.sh" "$ROOT/core/scripts/resolve-hq-root.sh" "$FIX/core/scripts/"
cp "$ROOT"/core/scripts/lib/*.sh "$FIX/core/scripts/lib/"
cp "$ROOT/core/scripts/lib/trigger-fact-text.awk" "$FIX/core/scripts/lib/" 2>/dev/null || true
chmod +x "$FIX/.claude/hooks/hook-gate.sh"

# The gate starts .claude/hooks/hook-timeout-watchdog.sh. This wrapper logs each
# start, then execs the real watchdog in the same process so its pid, claim
# handling and parent tracking are the shipped behavior.
WD_LOG="$TMP/watchdog-starts.log"
export ARMED_DIR="$TMP/armed"
WD_ALL="$TMP/watchdog-all.log"
: > "$WD_ALL"
cat > "$FIX/.claude/hooks/hook-timeout-watchdog.sh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$\$" >> "$WD_LOG"
printf '%s\n' "\$\$" >> "$WD_ALL"
exec "\${BASH:-bash}" "$FIX/.claude/hooks/real/hook-timeout-watchdog.sh" "\$@"
EOF

# Hook bodies, one per decision shape.
cat > "$FIX/hooks/allow-context.sh" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
printf '%s\n' '{"hookSpecificOutput":{"additionalContext":"ctx"}}'
EOF
cat > "$FIX/hooks/allow-silent.sh" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
EOF
cat > "$FIX/hooks/block.sh" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
echo "BLOCKED: synthetic guard" >&2
exit 2
EOF
cat > "$FIX/hooks/crash.sh" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
echo "synthetic crash" >&2
exit 1
EOF
cat > "$FIX/hooks/no-stdin.sh" <<'EOF'
#!/usr/bin/env bash
echo "left early" >&2
exit 2
EOF
# Writes its pid, then hangs. exec keeps the pid, so the test can prove the
# process is gone afterwards.
cat > "$FIX/hooks/hang.sh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$\$" > "$TMP/pids/hang.\$PPID.\$\$"
exec sleep 600
EOF
cat > "$FIX/hooks/ctx-slowish.sh" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
printf '%s\n' '{"hookSpecificOutput":{"additionalContext":"ctx"}}'
sleep 3
EOF
cat > "$FIX/hooks/slow.sh" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
sleep 16
EOF
cp "$FIX/hooks/slow.sh" "$FIX/hooks/slow2.sh"
cat > "$FIX/hooks/short.sh" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
sleep 3.5
EOF
chmod +x "$FIX"/hooks/*.sh "$FIX/.claude/hooks/hook-timeout-watchdog.sh"

# dispatcher.sh <bash> <mode> <count> <hook-id> <hook-script>
#   mode=event: sources hook-adapter-core.sh like an adapter (exports
#   HQAD_DISPATCHER_PID). mode=legacy: same, then unsets it.
#   Prints one "rc=<n>" line per gate on fd 3 and the gates' stdout on stdout.
cat > "$FIX/dispatcher.sh" <<'EOF'
tb="$1"; mode="$2"; count="$3"; hook_id="$4"; hook="$5"
export HQ_ROOT="$FIX_ROOT" CLAUDE_PROJECT_DIR="$FIX_ROOT"
. "$FIX_ROOT/core/scripts/lib/hook-adapter-core.sh"
[ "$mode" = event ] || unset HQAD_DISPATCHER_PID
[ -z "${DISPATCHER_PID_FILE:-}" ] || printf '%s\n' "$$" > "$DISPATCHER_PID_FILE"
payload='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"true"},"session_id":"s-event-wd","cwd":"/"}'
i=0
while [ "$i" -lt "$count" ]; do
  # One arming receipt per gate. The gate writes it in the foreground before it
  # starts a watchdog, so the count does not race a per-gate watchdog that its
  # gate reaps before the watchdog has run a line.
  export HQ_HOOK_TIMEOUT_SENTRY_TEST_ARMED_FILE="$ARMED_DIR/armed.$i"
  if [ "${DISPATCH_VIA_SUBSHELL:-0}" = 1 ]; then
    # The gate's parent is a subshell, not the dispatcher.
    ( printf '%s' "$payload" | "$tb" "$FIX_ROOT/.claude/hooks/hook-gate.sh" "$hook_id" "$hook"
      printf 'rc=%s\n' "${PIPESTATUS[1]}" >&3 )
  else
    printf '%s' "$payload" | env ${GATE_POSIX:+POSIXLY_CORRECT=1} "$tb" "$FIX_ROOT/.claude/hooks/hook-gate.sh" "$hook_id" "$hook"
    printf 'rc=%s\n' "${PIPESTATUS[1]}" >&3
  fi
  i=$((i + 1))
  [ "$i" -ge "$count" ] || [ -z "${DISPATCH_GAP:-}" ] || sleep "$DISPATCH_GAP"
done
EOF

BASHES=()
if [ -n "${HOOK_GATE_TEST_BASHES:-}" ]; then
  # shellcheck disable=SC2206
  BASHES=(${HOOK_GATE_TEST_BASHES})
else
  path_bash="$(command -v bash)"
  BASHES=("$path_bash")
  if [ -x /bin/bash ] && [ "$(cd /bin && pwd -P)/bash" != "$(cd "$(dirname "$path_bash")" && pwd -P)/bash" ]; then
    BASHES+=(/bin/bash)
  fi
fi

export FIX_ROOT="$FIX"
export HQ_HOOK_TIMEOUT_SENTRY=1
export HQ_HOOK_PROFILE=standard
export HQ_FLAG_HQ_ANYWHERE_RUNTIME=false
export HQ_HARNESS=codex
export HQ_NO_UPDATE_CHECK=1
unset HQ_DISABLED_HOOKS HQAD_DISPATCHER_PID HQ_HOOK_TIMEOUT_SENTRY_TEST_TRIGGER_FILE || true
# The default warning point is ~20 s after start. A shared watchdog must still
# exit within a few seconds of its dispatcher, so the waits below stay short.
unset HQ_HOOK_TIMEOUT_SENTRY_LEAD_SECONDS || true
LINGER_MAX=8
# Keep the reporter's network call out of the test. With HQ_TEST_REPORT_LOG set,
# the stub keeps each report the watchdog sends.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/hq" <<'EOF'
#!/bin/sh
if [ -n "${HQ_TEST_REPORT_LOG:-}" ]; then
  cat >> "$HQ_TEST_REPORT_LOG"
  printf '\n' >> "$HQ_TEST_REPORT_LOG"
else
  cat >/dev/null 2>&1
fi
exit 0
EOF
chmod +x "$TMP/bin/hq"
export PATH="$TMP/bin:$PATH"

claim_dir="$FIX/workspace/.hook-timeout-sentry"

run_dispatch() { # <bash> <mode> <count> <hook-id> <hook> -> sets OUT ERR RCS
  : > "$WD_LOG"
  rm -rf "$ARMED_DIR"; mkdir -p "$ARMED_DIR"
  "$1" "$FIX/dispatcher.sh" "$@" >"$TMP/out" 2>"$TMP/err" 3>"$TMP/rcs"
  OUT="$(cat "$TMP/out")"
  ERR="$(cat "$TMP/err")"
  RCS="$(tr '\n' ' ' < "$TMP/rcs")"
}

# Watchdogs armed in the last run (arming receipts, one file per arming gate).
starts() { find "$ARMED_DIR" -name 'armed.*' -type f 2>/dev/null | wc -l | tr -d ' '; }

# Wait until every watchdog started in this fixture has exited. A shared
# watchdog hands its claim back before it reports, so claim files alone do not
# show that it is done.
wait_for_watchdogs_exit() { # <seconds>
  local deadline=$((SECONDS + $1)) p live
  while :; do
    live=0
    while IFS= read -r p; do
      [ -n "$p" ] && kill -0 "$p" 2>/dev/null && live=1
    done < "$WD_ALL"
    [ "$live" -eq 0 ] && return 0
    [ "$SECONDS" -lt "$deadline" ] || return 1
    sleep 0.2
  done
}

wait_for_no_live_claims() { # <seconds>
  local deadline=$((SECONDS + $1)) claim pid live
  while :; do
    live=0
    for claim in "$claim_dir"/gate-event-*.pid; do
      [ -f "$claim" ] || continue
      pid="$(cat "$claim" 2>/dev/null || true)"
      case "$pid" in ''|*[!0-9]*) continue ;; esac
      kill -0 "$pid" 2>/dev/null && live=1
    done
    [ "$live" -eq 0 ] && return 0
    [ "$SECONDS" -lt "$deadline" ] || return 1
    sleep 0.2
  done
}

N=6
for TB in "${BASHES[@]}"; do
  ver="$("$TB" -c 'echo "${BASH_VERSINFO[0]}.${BASH_VERSINFO[1]}"')"
  echo "== bash $ver ($TB)"

  echo "[1] one watchdog per dispatcher event"
  rm -rf "$claim_dir"
  run_dispatch "$TB" event "$N" block-hq-glob "$FIX/hooks/allow-silent.sh"
  n="$(starts)"
  [ "$n" = 1 ] && ok "$N gates under a dispatcher started 1 watchdog" \
    || bad "$N gates under a dispatcher started $n watchdogs (want 1)"
  wait_for_no_live_claims "$LINGER_MAX" || bad "shared watchdog still alive ${LINGER_MAX} s after its dispatcher exited"
  run_dispatch "$TB" legacy "$N" block-hq-glob "$FIX/hooks/allow-silent.sh"
  n="$(starts)"
  [ "$n" = "$N" ] && ok "without a dispatcher each of $N gates started its own watchdog" \
    || bad "without a dispatcher $N gates started $n watchdogs (want $N)"

  echo "[2] decisions identical with and without a dispatcher"
  for hook in allow-context allow-silent block crash no-stdin; do
    run_dispatch "$TB" legacy 2 block-hq-glob "$FIX/hooks/$hook.sh"
    l_out="$OUT"; l_err="$ERR"; l_rcs="$RCS"
    run_dispatch "$TB" event 2 block-hq-glob "$FIX/hooks/$hook.sh"
    if [ "$OUT" = "$l_out" ] && [ "$ERR" = "$l_err" ] && [ "$RCS" = "$l_rcs" ]; then
      ok "$hook: rc [$RCS] and output match"
    else
      bad "$hook: event rc [$RCS] vs legacy [$l_rcs]; stdout or stderr differs"
    fi
  done
  run_dispatch "$TB" event 1 block-hq-glob "$FIX/hooks/block.sh"
  case "$RCS:$ERR" in
    "rc=2 :"*"BLOCKED: synthetic guard"*"Blocked by hook block-hq-glob."*) ok "block keeps exit 2 and the gate's reason line" ;;
    *) bad "block lost exit 2 or its reason (rc [$RCS])" ;;
  esac
  # A hook outside the profile is skipped and starts no watchdog either way.
  run_dispatch "$TB" event 2 not-a-registered-hook "$FIX/hooks/block.sh"
  [ "$RCS" = "rc=0 rc=0 " ] && [ "$(starts)" = 0 ] && ok "out-of-profile hook skipped with no watchdog" \
    || bad "out-of-profile hook: rc [$RCS], watchdogs $(starts)"
  # The kill switch still turns the watchdog off under a dispatcher.
  HQ_HOOK_TIMEOUT_SENTRY=0 run_dispatch "$TB" event 2 block-hq-glob "$FIX/hooks/allow-silent.sh"
  [ "$(starts)" = 0 ] && ok "HQ_HOOK_TIMEOUT_SENTRY=0 starts no watchdog" \
    || bad "HQ_HOOK_TIMEOUT_SENTRY=0 started $(starts) watchdogs"
  HQ_DISABLED_HOOKS=hook-timeout-sentry run_dispatch "$TB" event 2 block-hq-glob "$FIX/hooks/allow-silent.sh"
  [ "$(starts)" = 0 ] && ok "HQ_DISABLED_HOOKS=hook-timeout-sentry starts no watchdog" \
    || bad "HQ_DISABLED_HOOKS=hook-timeout-sentry started $(starts) watchdogs"
  wait_for_no_live_claims "$LINGER_MAX" || true

  echo "[3] shared watchdog ends after its dispatcher and removes its claim"
  rm -rf "$claim_dir"
  DISPATCHER_PID_FILE="$TMP/dispatcher.pid" run_dispatch "$TB" event 3 block-hq-glob "$FIX/hooks/allow-silent.sh"
  dpid="$(cat "$TMP/dispatcher.pid")"
  wpid="$(awk 'NF{print; exit}' "$WD_LOG")"
  if wait_for_no_live_claims "$LINGER_MAX"; then ok "watchdog exited after dispatcher $dpid ended"
  else bad "watchdog $wpid outlived dispatcher $dpid by ${LINGER_MAX} s"; fi
  deadline=$((SECONDS + 5))
  while [ -e "$claim_dir/gate-event-$dpid.pid" ] && [ "$SECONDS" -lt "$deadline" ]; do sleep 0.2; done
  [ ! -e "$claim_dir/gate-event-$dpid.pid" ] && ok "claim file removed" \
    || bad "claim file for dispatcher $dpid left behind"
  # The claim is released from the watchdog's EXIT trap, just before the
  # process ends, so give the exit itself a moment.
  deadline=$((SECONDS + 5))
  while [ -n "$wpid" ] && kill -0 "$wpid" 2>/dev/null && [ "$SECONDS" -lt "$deadline" ]; do sleep 0.2; done
  if [ -n "$wpid" ] && kill -0 "$wpid" 2>/dev/null; then bad "watchdog pid $wpid still running"
  else ok "no watchdog process left"; fi

  echo "[4] stale and unwritable claims"
  # A claim naming a dead pid must not suppress the next event's watchdog.
  # The dispatcher pid is only known once it runs, so it seeds its own stale
  # claim before launching the gates.
  rm -rf "$claim_dir"; mkdir -p "$claim_dir"
  cat > "$FIX/seed-dispatcher.sh" <<'EOF'
mkdir -p "$FIX_ROOT/workspace/.hook-timeout-sentry"
dead=999999
while kill -0 "$dead" 2>/dev/null; do dead=$((dead - 1)); done
printf '%s\n' "$dead" > "$FIX_ROOT/workspace/.hook-timeout-sentry/gate-event-$$.pid"
. "$FIX_ROOT/dispatcher.sh"
EOF
  : > "$WD_LOG"
  rm -rf "$ARMED_DIR"; mkdir -p "$ARMED_DIR"
  "$TB" "$FIX/seed-dispatcher.sh" "$TB" event 3 block-hq-glob "$FIX/hooks/allow-silent.sh" \
    >/dev/null 2>&1 3>/dev/null
  [ "$(starts)" = 1 ] && ok "stale claim re-armed exactly one watchdog" \
    || bad "stale claim: $(starts) watchdogs started (want 1)"
  wait_for_no_live_claims "$LINGER_MAX" || true
  if [ "$(id -u)" != 0 ]; then
    rm -rf "$claim_dir"; mkdir -p "$claim_dir"; chmod 0555 "$claim_dir"
    run_dispatch "$TB" event 3 block-hq-glob "$FIX/hooks/allow-silent.sh"
    chmod 0755 "$claim_dir"
    [ "$(starts)" = 3 ] && [ "$RCS" = "rc=0 rc=0 rc=0 " ] \
      && ok "unwritable claim falls back to one reaped watchdog per gate" \
      || bad "unwritable claim: $(starts) watchdogs, rc [$RCS]"
    leftover=0
    while IFS= read -r p; do
      [ -n "$p" ] && kill -0 "$p" 2>/dev/null && leftover=1
    done < "$WD_LOG"
    [ "$leftover" -eq 0 ] && ok "per-gate fallback watchdogs were reaped" \
      || bad "per-gate fallback left a watchdog running"
  fi

  echo "[5] a hung gate is killed within its bound"
  # (a) The adapter's hard cap (hq_run_capped, used for advisory hooks).
  cat > "$FIX/capped-dispatcher.sh" <<'EOF'
export HQ_ROOT="$FIX_ROOT" CLAUDE_PROJECT_DIR="$FIX_ROOT"
. "$FIX_ROOT/core/scripts/lib/hook-adapter-core.sh"
. "$FIX_ROOT/core/scripts/lib/advisory-cap.sh"
payload='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"true"},"session_id":"s-hang","cwd":"/"}'
hq_run_capped 2 "$1" "$FIX_ROOT/.claude/hooks/hook-gate.sh" block-hq-glob "$FIX_ROOT/hooks/hang.sh" \
  < <(printf '%s' "$payload")
printf 'rc=%s timed_out=%s\n' "$HQ_RUN_CAPPED_RC" "$HQ_RUN_CAPPED_TIMED_OUT"
EOF
  rm -f "$TMP"/pids/hang.*
  t0=$SECONDS
  # Bounded from outside as well, so a cap that never fires fails this case
  # instead of hanging the suite.
  "$TB" "$FIX/capped-dispatcher.sh" "$TB" >"$TMP/capped.out" 2>/dev/null &
  capped_pid=$!
  while kill -0 "$capped_pid" 2>/dev/null && [ $((SECONDS - t0)) -lt 60 ]; do sleep 0.2; done
  if kill -0 "$capped_pid" 2>/dev/null; then
    pkill -KILL -f "$FIX/" 2>/dev/null || true
    wait "$capped_pid" 2>/dev/null || true
    printf 'still running after 60 s\n' > "$TMP/capped.out"
  else
    wait "$capped_pid" 2>/dev/null || true
  fi
  res="$(cat "$TMP/capped.out")"
  dt=$((SECONDS - t0))
  case "$res" in
    *"timed_out=1"*) [ "$dt" -le 20 ] && ok "cap killed the hung gate in ${dt}s (cap 2 s): $res" \
      || bad "cap took ${dt}s for a 2 s cap" ;;
    *) bad "hung gate was not capped: $res (${dt}s)" ;;
  esac
  hang_left=0
  for f in "$TMP"/pids/hang.*; do
    [ -f "$f" ] || continue
    kill -0 "$(cat "$f")" 2>/dev/null && hang_left=1
  done
  [ "$hang_left" -eq 0 ] && ok "hung hook process is gone after the cap" \
    || bad "hung hook process survived the cap"

  # (b) An outer deadline around a blocking gate whose caller reads stdout to
  # EOF, as a runtime that kills a slow hook does. The shared watchdog has its
  # stdio detached, so the caller returns at the bound with a non-zero status
  # (a blocking adapter turns that into a block).
  rm -f "$TMP"/pids/hang.*
  t0=$SECONDS
  perl -e 'setpgrp(0,0); $SIG{ALRM}=sub{kill "TERM", -$$; sleep 1; kill "KILL", -$$; exit 124}; alarm 2; $pid=fork; if(!$pid){exec @ARGV} waitpid($pid,0); alarm 0; exit($?>>8)' \
    "$TB" "$FIX/dispatcher.sh" "$TB" event 1 block-hq-glob "$FIX/hooks/hang.sh" 3>/dev/null 2>/dev/null \
    | cat >/dev/null
  rc="${PIPESTATUS[0]}"
  dt=$((SECONDS - t0))
  [ "$rc" -ne 0 ] && [ "$dt" -le 8 ] && ok "outer deadline ended the hung gate in ${dt}s with rc $rc" \
    || bad "outer deadline: rc $rc after ${dt}s (want non-zero within 8 s)"
  hang_left=0
  for f in "$TMP"/pids/hang.*; do
    [ -f "$f" ] || continue
    kill -0 "$(cat "$f")" 2>/dev/null && hang_left=1
  done
  [ "$hang_left" -eq 0 ] && ok "hung hook process is gone after the deadline" \
    || bad "hung hook process survived the deadline"
  wait_for_no_live_claims "$LINGER_MAX" || bad "shared watchdog outlived the killed dispatcher by ${LINGER_MAX} s"

  echo "[6] the shared watchdog warns about the gate that runs long"
  # Warning point 30 s - 26 s lead = 4 s after a gate starts. Two fast gates,
  # then two slow gates of 16 s each. Both slow gates must be named: the second
  # starts after the first one's report, so it needs a fresh shared watchdog. The waits for the
  # watchdog to exit are long so a loaded host cannot leak a late report into
  # the next case.
  # A watchdog left from an earlier case would be counted against this case's
  # 90 s check below, so fail here, naming the earlier cases, instead.
  wait_for_watchdogs_exit 90 || bad "a watchdog from an earlier case was still running 90 s before the slow event"
  rm -rf "$claim_dir" "$FIX/workspace/.hook-timeout-journal"
  : > "$TMP/reports.log"
  cat > "$FIX/mixed-dispatcher.sh" <<'EOF'
export HQ_ROOT="$FIX_ROOT" CLAUDE_PROJECT_DIR="$FIX_ROOT"
. "$FIX_ROOT/core/scripts/lib/hook-adapter-core.sh"
payload='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"true"},"session_id":"s-attr","cwd":"/"}'
for hook in allow-silent allow-context slow slow2; do
  printf '%s' "$payload" | "$1" "$FIX_ROOT/.claude/hooks/hook-gate.sh" block-hq-glob "$FIX_ROOT/hooks/$hook.sh" >/dev/null 2>&1
done
EOF
  HQ_TEST_REPORT_LOG="$TMP/reports.log" HQ_HOOK_TIMEOUT_SENTRY_LEAD_SECONDS=26 \
    "$TB" "$FIX/mixed-dispatcher.sh" "$TB"
  wait_for_watchdogs_exit 90 || bad "a watchdog was still running 90 s after the slow event"
  if grep -q '"hook_name":"slow.sh"' "$TMP/reports.log" \
    && grep -q '"hook_name":"slow2.sh"' "$TMP/reports.log" \
    && ! grep -q 'allow-silent.sh\|allow-context.sh' "$TMP/reports.log"; then
    ok "warnings name both slow gates (slow.sh, slow2.sh) and no fast gate"
  else
    bad "warning attribution wrong: $(tr -d '\n' < "$TMP/reports.log" | cut -c1-300)"
  fi
  # Time spent in the dispatcher between gates is not a gate's: no warning.
  : > "$TMP/reports.log"
  HQ_TEST_REPORT_LOG="$TMP/reports.log" HQ_HOOK_TIMEOUT_SENTRY_LEAD_SECONDS=26 DISPATCH_GAP=10 \
    run_dispatch "$TB" event 2 block-hq-glob "$FIX/hooks/allow-silent.sh"
  wait_for_watchdogs_exit 90 || true
  [ ! -s "$TMP/reports.log" ] && ok "a 10 s gap between fast gates sends no warning" \
    || bad "gap between gates produced a warning: $(tr -d '\n' < "$TMP/reports.log" | cut -c1-200)"

  # Warning point 0 (lead = timeout): a per-gate watchdog still only warns
  # about a gate alive after its grace, so a run of fast gates sends nothing.
  : > "$TMP/reports.log"
  HQ_TEST_REPORT_LOG="$TMP/reports.log" HQ_HOOK_TIMEOUT_SENTRY_LEAD_SECONDS=30 \
    run_dispatch "$TB" event 20 block-hq-glob "$FIX/hooks/allow-silent.sh"
  wait_for_watchdogs_exit 90 || true
  [ ! -s "$TMP/reports.log" ] && ok "warning point 0: 20 fast gates send no warning" \
    || bad "warning point 0 reported a fast gate: $(tr -d '\n' < "$TMP/reports.log" | cut -c1-200)"

  # Warning point 0 with one 3.5 s gate: a per-gate watchdog warns about it once
  # its grace has passed, so the shared watchdog must too (short budgets such
  # as a 3 s SessionEnd timeout).
  : > "$TMP/reports.log"
  HQ_TEST_REPORT_LOG="$TMP/reports.log" HQ_HOOK_TIMEOUT_SENTRY_LEAD_SECONDS=30 \
    run_dispatch "$TB" event 1 block-hq-glob "$FIX/hooks/short.sh"
  wait_for_watchdogs_exit 90 || true
  grep -q '"hook_name":"short.sh"' "$TMP/reports.log" \
    && ok "warning point 0: a 3.5 s gate is reported" \
    || bad "warning point 0: the 3.5 s gate was not reported"

  echo "[7] edge cases keep decisions and stderr unchanged"
  # POSIX mode (gate only): a failed redirection on a special builtin would
  # end the gate. The result must match the same gate without a dispatcher.
  if [ "$(id -u)" != 0 ]; then
    rm -rf "$claim_dir"; mkdir -p "$claim_dir"; chmod 0555 "$claim_dir"
    GATE_POSIX=1 run_dispatch "$TB" legacy 1 block-hq-glob "$FIX/hooks/block.sh"
    l_rcs="$RCS"; l_err="$ERR"
    GATE_POSIX=1 run_dispatch "$TB" event 1 block-hq-glob "$FIX/hooks/block.sh"
    chmod 0755 "$claim_dir"
    if [ "$RCS" = "$l_rcs" ] && [ "$ERR" = "$l_err" ] && [ "$RCS" = "rc=2 " ]; then
      ok "POSIX mode with an unwritable claim blocks exactly as without a dispatcher"
    else
      bad "POSIX mode with an unwritable claim: rc [$RCS] vs [$l_rcs], stderr [$ERR] vs [$l_err]"
    fi
  fi
  # A claim that cannot be read as a file must not print to the gate's stderr.
  rm -rf "$claim_dir"; mkdir -p "$claim_dir"
  cat > "$FIX/dir-claim-dispatcher.sh" <<'EOF'
mkdir -p "$FIX_ROOT/workspace/.hook-timeout-sentry/gate-event-$$.pid"
. "$FIX_ROOT/dispatcher.sh"
EOF
  "$TB" "$FIX/dir-claim-dispatcher.sh" "$TB" event 1 block-hq-glob "$FIX/hooks/block.sh" \
    >/dev/null 2>"$TMP/err" 3>"$TMP/rcs"
  case "$(tr '\n' ' ' < "$TMP/rcs"):$(cat "$TMP/err")" in
    "rc=2 :BLOCKED: synthetic guard"*"Blocked by hook block-hq-glob.") ok "unreadable claim leaves stderr and rc unchanged" ;;
    *) bad "unreadable claim changed stderr or rc: $(cat "$TMP/err")" ;;
  esac
  rm -rf "$claim_dir"
  # A gate whose parent is not the dispatcher keeps its own watchdog.
  DISPATCH_VIA_SUBSHELL=1 run_dispatch "$TB" event 3 block-hq-glob "$FIX/hooks/allow-silent.sh"
  [ "$(starts)" = 3 ] && [ "$RCS" = "rc=0 rc=0 rc=0 " ] \
    && ok "gates launched from a subshell keep one watchdog each" \
    || bad "subshell gates: $(starts) watchdogs, rc [$RCS]"
  # The caller's capture of stdout returns while the shared watchdog still runs,
  # so the watchdog does not hold the pipe. The hook takes 3 s, so the watchdog
  # finds the dispatcher alive after its 1 s grace and is in a 2-4 s wait step
  # when the capture ends.
  rm -rf "$claim_dir"
  : > "$WD_LOG"
  t0=$SECONDS
  out="$("$TB" "$FIX/dispatcher.sh" "$TB" event 1 block-hq-glob "$FIX/hooks/ctx-slowish.sh" 3>/dev/null 2>/dev/null)"
  dt=$((SECONDS - t0))
  wpid="$(awk 'NF{print; exit}' "$WD_LOG")"
  if [ "$out" = '{"hookSpecificOutput":{"additionalContext":"ctx"}}' ] \
    && [ -n "$wpid" ] && kill -0 "$wpid" 2>/dev/null; then
    ok "stdout capture returned in ${dt}s while the shared watchdog was still running"
  else
    bad "stdout capture: ${dt}s, watchdog [$wpid] alive=$(kill -0 "$wpid" 2>/dev/null && echo yes || echo no), out [$out]"
  fi
  wait_for_no_live_claims "$LINGER_MAX" || bad "shared watchdog outlived its dispatcher by ${LINGER_MAX} s"
done

echo "hook-gate-event-watchdog: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
