#!/usr/bin/env bash
# hq-core: public
# The Codex adapter stands aside for an event the native engine answered
# (hq-core-rust US-021 c4).
#
# Inside an HQ root, Codex runs the native engine's entry (user-scope
# hooks.json, written by `hq reindex` with core.next on) and this adapter
# (tracked .codex/config.toml) for the same event, at once, with the same
# payload. The engine now marks each event it answers, just before its answer
# goes out, in ${HQ_HOOK_STATE_DIR:-~/.hq/state/hq-hook}/codex-answered/. The
# adapter stands aside only when the mark with its own key appears within a
# short wait, so an engine that does not answer never leaves the event
# unanswered.
#
# Checked against a throwaway HQ root with the real hooks, settings and
# adapter, an isolated HOME and state folder, and a trace line at the top of
# the fixture's master-hook.sh (the adapter runs it for every
# UserPromptSubmit it answers). The mark key is computed here with Perl's
# Digest::SHA, independently of the adapter's shell:
#   key = sha256("hq-codex-answered-v2\n<root>\n<session>\n<Event>\n" + sha256hex(payload))
# where <root> is the HQ root's real path.
#   1. Stands aside (no output, master-hook never starts, mark consumed): the
#      mark is there before the adapter starts, or appears once the adapter
#      has started its wait (written when its trace line shows up, not after
#      a fixed sleep), or the adapter runs through a symlink to the root the
#      mark names.
#   2. Answers as before:
#      - no engine at all (no hint, no mark): no wait;
#      - the engine answered this event before (hint) but writes no mark this
#        time (absent, crashed, silent, untrusted): after the wait;
#      - a mark for another HQ root: root B's adapter with root A's mark
#        (review R13);
#      - a mark for another session, another payload of the same session,
#        another event, a stale mark, a mark that is a symlink;
#      - a stale hint (no wait);
#      - mark present but: the event argument (engine hand-back), HQ_CORE_NEXT
#        or HQ_HOOK_ENGINE off, ~/.hq/state/core-next.off,
#        ~/.hq/hook-engine.off, HQ_CODEX_NATIVE_STEP_ASIDE=0, a relative
#        HQ_HOOK_STATE_DIR. The mark is left in place.
#   3. Latency: the elapsed time of each path is printed (LATENCY lines); the
#      no-mark path waits at least HQ_CODEX_NATIVE_WAIT_MS. The pull-request
#      run uses a 100 ms wait, so no case waits long on a real timer. The
#      per-event wait caps are checked here from the adapter's trace:
#      SessionEnd caps a 99999 ms ask at 300 ms, 1 s inside its config.toml
#      timeout, and UserPromptSubmit caps it at 10000 ms.
#   4. Timeouts (only with CNSA_TIMEOUT_FIT=1, run nightly by
#      codex-adapter-native-timeout-fit.test.sh because it waits out real
#      Codex timeouts): for every event in .codex/config.toml, an engine that
#      answered before but writes no mark now, with the longest wait asked
#      for, still leaves the adapter answering at least 1 s inside the event's
#      Codex timeout (run under the real timeout for events under 15 s, such
#      as SessionEnd at 3 s, and for UserPromptSubmit).
#   5. With HQ_TEST_HQ_HOOK=<engine binary> (hq-cli with host::answered), the
#      real engine and the adapter run at once on the same payload: the engine
#      answers and the adapter stands aside.
# HQ_TEST_SOURCE_ROOT takes the hooks and adapter from another checkout (for
# example origin/main, where case 1 answers in full and the test fails).

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
SRC="${HQ_TEST_SOURCE_ROOT:-$ROOT}"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "  ok: $*"; }

for dep in jq tar perl; do
  command -v "$dep" >/dev/null 2>&1 || fail "$dep required"
done
perl -MDigest::SHA -e 1 2>/dev/null || fail "perl Digest::SHA required"
case "${OSTYPE:-}" in
  # Reindex keeps shell registrations on Windows; the adapter never stands aside there.
  msys*|cygwin*|win32*) echo "SKIP: no native Codex registration on Windows"; exit 0 ;;
esac

TMP="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/cnsa.XXXXXX")" && pwd -P)"
BG_PIDS=""
cleanup() {
  local pid
  for pid in $BG_PIDS; do kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; done
  rm -rf "$TMP"
}
trap cleanup EXIT INT TERM

FIX="$TMP/hq"
HOME_DIR="$TMP/home"
STATE="$TMP/state"
MARKS="$STATE/codex-answered"
mkdir -p "$FIX" "$HOME_DIR"
chmod 700 "$HOME_DIR"
(cd "$SRC" && tar -cf - --exclude 'core/scripts/tests' \
  .claude .codex core/scripts core/hooks core/core.yaml core/settings) | tar -xf - -C "$FIX"
mkdir -p "$FIX/companies" "$FIX/core/policies" "$FIX/personal/policies" "$FIX/workspace"
printf 'companies: {}\n' > "$FIX/companies/manifest.yaml"

# One line per master-hook.sh start, written before anything else in it runs.
TRACE="$TMP/master-runs.log"
TRACE_LINE='[ -z "${CNSA_TRACE:-}" ] || printf "%s\n" "$$" >> "$CNSA_TRACE"'
TRACE_LINE="$TRACE_LINE" perl -0pi -e 's{\A(#![^\n]*\n)}{$1$ENV{TRACE_LINE}\n} or die "no shebang\n";' \
  "$FIX/.claude/hooks/master-hook.sh"

ADAPTER="$FIX/.codex/hooks/hq-codex-hook-adapter.sh"
[ -f "$ADAPTER" ] || fail "adapter not found at $ADAPTER"
WAIT_MS=100
TIMEOUT_FIT="${CNSA_TIMEOUT_FIT:-0}"

payload() { # <session> <turn>
  jq -nc --arg s "$1" --arg t "$2" --arg cwd "$FIX" \
    '{session_id:$s,turn_id:$t,transcript_path:null,cwd:$cwd,hook_event_name:"UserPromptSubmit",model:"gpt-test",permission_mode:"bypassPermissions",prompt:"Please summarize the open work."}'
}
mark_key() { # <session> <event> <payload> [root, default the fixture root]
  KEY_ROOT="${4:-$FIX}" KEY_SID="$1" KEY_EVENT="$2" KEY_PAYLOAD="$3" perl -MDigest::SHA=sha256_hex -e '
    my $p = $ENV{KEY_PAYLOAD}; $p =~ s/\n+\z//;
    print sha256_hex("hq-codex-answered-v2\n$ENV{KEY_ROOT}\n$ENV{KEY_SID}\n$ENV{KEY_EVENT}\n" . sha256_hex($p));'
}
now_s() { date +%s; }
now_ms() { perl -MTime::HiRes=time -e 'printf "%d", time * 1000'; }
write_hint() { mkdir -p "$MARKS"; printf '%s\n' "${2:-$(now_s)}" > "$MARKS/event-$1"; }
write_mark() { mkdir -p "$MARKS"; printf '%s\n' "${2:-$(now_s)}" > "$MARKS/$1"; }
reset_state() {
  # The policy injector keeps a per-session ledger in the root; every case
  # reuses one session id, so clear it or a later answer has nothing to add.
  rm -rf "$STATE" "$HOME_DIR/.hq" "$FIX/workspace/orchestrator"
  : > "$TRACE"
}

OUT="" ERR="" CODE=0 ELAPSED=0
run_adapter() { # <payload> [adapter args...] ; EXTRA_ENV for env assignments
  local p="$1" start
  shift
  : > "$TRACE"
  start="$(now_ms)"
  set +e
  OUT="$(cd "${RUN_ROOT:-$FIX}" && printf '%s' "$p" | ${KILL_AFTER:+perl -e 'alarm shift @ARGV; exec @ARGV or die' "$KILL_AFTER"} env -i PATH="$PATH" HOME="$HOME_DIR" TMPDIR="$TMP" \
    HQ_NO_UPDATE_CHECK=1 HQ_TELEMETRY=0 CNSA_TRACE="$TRACE" HQ_HOOK_STATE_DIR="$STATE" \
    HQ_CODEX_NATIVE_WAIT_MS="$WAIT_MS" ${EXTRA_ENV:-} /bin/bash "${RUN_ROOT:-$FIX}/.codex/hooks/hq-codex-hook-adapter.sh" "$@" 2>"$TMP/stderr")"
  CODE=$?
  set -e
  ELAPSED=$(( $(now_ms) - start ))
  ERR="$(cat "$TMP/stderr")"
}
context() { printf '%s' "$OUT" | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null || true; }
master_ran() { [ -s "$TRACE" ]; }
expect_answers() { # <label>
  [ "$CODE" -eq 0 ] || fail "$1: exit $CODE (stderr: ${ERR:0:400})"
  master_ran || fail "$1: master-hook.sh never started (stdout: ${OUT:0:400}; stderr: ${ERR:0:400})"
  [ -n "$(context)" ] || fail "$1: no hookSpecificOutput.additionalContext in the answer (stdout: ${OUT:0:400})"
  pass "$1: answers (${ELAPSED} ms)"
}
expect_aside() { # <label>
  [ "$CODE" -eq 0 ] || fail "$1: exit $CODE (stderr: ${ERR:0:400})"
  [ -z "$OUT" ] || fail "$1: expected no output, got: ${OUT:0:400}"
  ! master_ran || fail "$1: master-hook.sh started"
  pass "$1: stands aside (${ELAPSED} ms)"
}

SID="cnsa-session"
P1="$(payload "$SID" turn-1)"
K1="$(mark_key "$SID" UserPromptSubmit "$P1")"
event_payload() { # <event> <turn>
  jq -nc --arg e "$1" --arg s "$SID" --arg t "$2" --arg cwd "$FIX" \
    '{session_id:$s,turn_id:$t,transcript_path:null,cwd:$cwd,hook_event_name:$e,model:"gpt-test",permission_mode:"bypassPermissions",prompt:"Please summarize the open work.",source:"startup",reason:"other",tool_name:"Bash",tool_use_id:"tu-1",tool_input:{command:"ls"},tool_response:{stdout:"x",exit_code:0},stop_hook_active:false,last_assistant_message:"done"}'
}

if [ "$TIMEOUT_FIT" != 1 ]; then

echo "1. the engine answered: the adapter stands aside"
reset_state; EXTRA_ENV=""
write_hint UserPromptSubmit; write_mark "$K1"
run_adapter "$P1"; expect_aside "mark present before the adapter starts"
[ ! -e "$MARKS/$K1" ] || fail "the adapter did not consume the mark"
pass "the mark was consumed"
LAT_PRESENT=$ELAPSED
# The mark is written as soon as the adapter's trace shows it has started to
# wait, so this case covers a mark that arrives during the wait without a
# fixed sleep. The wait is long enough that the watcher always wins; the
# adapter stops waiting the moment the mark appears.
reset_state; write_hint UserPromptSubmit
: > "$TMP/stderr"
( n=0
  until grep -q 'waiting up to [0-9]* ms for the native mark' "$TMP/stderr" 2>/dev/null; do
    n=$((n + 1)); [ "$n" -lt 400 ] || exit 0
    perl -MTime::HiRes=sleep -e 'sleep 0.005'
  done
  write_mark "$K1" ) &
BG_PIDS="$BG_PIDS $!"
saved_wait=$WAIT_MS; WAIT_MS=1500
EXTRA_ENV="HQ_HOOK_TRACE=1"; run_adapter "$P1"; EXTRA_ENV=""
WAIT_MS=$saved_wait
expect_aside "mark written while the adapter waits"
LAT_LATE=$ELAPSED
# The engine keys the mark by its --hq-root with every link resolved; an
# adapter reached through a symlink to that root resolves to the same path.
ln -s "$FIX" "$TMP/hq-link"
reset_state; write_hint UserPromptSubmit; write_mark "$K1"
RUN_ROOT="$TMP/hq-link"; run_adapter "$P1"; RUN_ROOT=""
expect_aside "adapter run through a symlink to the root the mark names"

echo "2. no mark, or not this one: the adapter answers"
reset_state
run_adapter "$P1"; expect_answers "no engine (no hint, no mark)"
LAT_NONE=$ELAPSED
reset_state; write_hint UserPromptSubmit
EXTRA_ENV="HQ_HOOK_TRACE=1"; run_adapter "$P1"; EXTRA_ENV=""
expect_answers "hint but no mark (engine absent, crashed, silent or untrusted)"
LAT_NOMARK=$ELAPSED
[ "$LAT_NOMARK" -ge "$WAIT_MS" ] || fail "the no-mark path waited ${LAT_NOMARK} ms, less than ${WAIT_MS} ms"
# The adapter traces the start of its wait. This case is the positive
# control for the stale-hint check below, which asserts the trace is absent.
grep -q 'waiting up to [0-9]* ms for the native mark' <<<"$ERR" || fail "a fresh hint with no mark did not trace its wait (stderr: ${ERR:0:400})"
pass "a fresh hint with no mark traces its wait"
# The per-event wait caps, on every pull request. A wait over the cap would
# outlast the event's Codex timeout and leave the event unanswered. The cap in
# force is read from the adapter's trace, so no case waits out a long cap.
# SessionEnd (3 s timeout) asks for 99999 ms and must wait 300 ms at most.
SE_TIMEOUT_S="$(awk '
  /^\[\[hooks\.[A-Za-z]+\]\]$/ { ev = $0; gsub(/^\[\[hooks\.|\]\]$/, "", ev); next }
  /^timeout *= *[0-9]+ *$/ && ev == "SessionEnd" { t = $0; sub(/^timeout *= */, "", t); sub(/ *$/, "", t); print t; exit }
' "$FIX/.codex/config.toml")"
[ -n "$SE_TIMEOUT_S" ] || fail "no SessionEnd timeout in .codex/config.toml"
reset_state; write_hint SessionEnd
saved_wait=$WAIT_MS; WAIT_MS=99999
EXTRA_ENV="HQ_HOOK_TRACE=1"; run_adapter "$(event_payload SessionEnd turn-cap)"; EXTRA_ENV=""
WAIT_MS=$saved_wait
[ "$CODE" -eq 0 ] || fail "SessionEnd with a long wait asked: exit $CODE (stderr: ${ERR:0:400})"
master_ran || fail "SessionEnd with a long wait asked: master-hook.sh never started"
se_wait="$(sed -n 's/.*SessionEnd waiting up to \([0-9]*\) ms for the native mark.*/\1/p' <<<"$ERR" | head -1)"
[ "$se_wait" = 300 ] || fail "SessionEnd waited up to '${se_wait}' ms for a 99999 ms ask, not its 300 ms cap (stderr: ${ERR:0:400})"
[ $(( se_wait + 1000 )) -lt $(( SE_TIMEOUT_S * 1000 )) ] || fail "SessionEnd's ${se_wait} ms cap leaves under 1 s of its ${SE_TIMEOUT_S} s timeout"
pass "SessionEnd caps a 99999 ms wait at 300 ms (${ELAPSED} ms, timeout ${SE_TIMEOUT_S} s)"
# UserPromptSubmit asks for 99999 ms and must cap it at 10000 ms. The mark is
# written as soon as the wait starts, so the case costs about one poll.
reset_state; write_hint UserPromptSubmit
: > "$TMP/stderr"
( n=0
  until grep -q 'waiting up to [0-9]* ms for the native mark' "$TMP/stderr" 2>/dev/null; do
    n=$((n + 1)); [ "$n" -lt 400 ] || exit 0
    perl -MTime::HiRes=sleep -e 'sleep 0.005'
  done
  write_mark "$K1" ) &
BG_PIDS="$BG_PIDS $!"
saved_wait=$WAIT_MS; WAIT_MS=99999
EXTRA_ENV="HQ_HOOK_TRACE=1"; run_adapter "$P1"; EXTRA_ENV=""
WAIT_MS=$saved_wait
expect_aside "UserPromptSubmit with a 99999 ms wait asked"
grep -q 'UserPromptSubmit waiting up to 10000 ms for the native mark' <<<"$ERR" || fail "UserPromptSubmit did not cap a 99999 ms wait at 10000 ms (stderr: ${ERR:0:400})"
pass "UserPromptSubmit caps a 99999 ms wait at 10000 ms"
check_mark() { # <label> <mark name> [stamp]
  reset_state; write_hint UserPromptSubmit; write_mark "$2" "${3:-}"
  run_adapter "$P1"; expect_answers "$1"
}
check_mark "mark of another session" "$(mark_key other-session UserPromptSubmit "$(payload other-session turn-1)")"
check_mark "mark of another turn of the same session" "$(mark_key "$SID" UserPromptSubmit "$(payload "$SID" turn-2)")"
check_mark "mark of another event" "$(mark_key "$SID" PreToolUse "$P1")"
check_mark "mark keyed without the session" "$(mark_key "" UserPromptSubmit "$P1")"
# Root B, a second HQ root with the same hooks: root A's mark for the very
# same payload must not make B stand aside (review R13); B's own mark does.
ROOT_B="$TMP/hq-b"
mkdir -p "$ROOT_B"
(cd "$FIX" && tar -cf - --exclude ./workspace .) | tar -xf - -C "$ROOT_B"
mkdir -p "$ROOT_B/workspace"
reset_state; rm -rf "$ROOT_B/workspace/orchestrator"; write_hint UserPromptSubmit; write_mark "$K1"
RUN_ROOT="$ROOT_B"; run_adapter "$P1"; RUN_ROOT=""
expect_answers "root B's adapter with root A's mark for the same payload"
[ -e "$MARKS/$K1" ] || fail "root B's adapter consumed root A's mark"
reset_state; write_hint UserPromptSubmit; write_mark "$(mark_key "$SID" UserPromptSubmit "$P1" "$ROOT_B")"
RUN_ROOT="$ROOT_B"; run_adapter "$P1"; RUN_ROOT=""
expect_aside "root B's adapter with root B's own mark"
check_mark "mark for another HQ root (root B) at root A" "$(mark_key "$SID" UserPromptSubmit "$P1" "$ROOT_B")"
check_mark "stale mark (60 s old)" "$K1" "$(( $(now_s) - 60 ))"
check_mark "mark stamped in the future" "$K1" "$(( $(now_s) + 60 ))"
reset_state; write_hint UserPromptSubmit; write_mark "$K1"
mv "$MARKS/$K1" "$TMP/real-mark"; ln -s "$TMP/real-mark" "$MARKS/$K1"
run_adapter "$P1"; expect_answers "mark is a symlink"
reset_state; write_hint UserPromptSubmit "$(( $(now_s) - 8 * 86400 ))"; write_mark "$K1"
run_adapter "$P1"; expect_answers "stale hint (8 days)"
# Same stale hint with no mark, so a wait (if any) would start and trace.
reset_state; write_hint UserPromptSubmit "$(( $(now_s) - 8 * 86400 ))"
EXTRA_ENV="HQ_HOOK_TRACE=1"; run_adapter "$P1"; EXTRA_ENV=""
expect_answers "stale hint (8 days), no mark"
# Whether it waited is read from the adapter's own trace, not from the run
# time: the shell answer alone takes about 3 s on the ubuntu-latest runners
# (no-engine case: 3208 ms), longer than WAIT_MS, so elapsed time cannot tell
# a skipped wait from a taken one there.
! grep -q 'waiting up to [0-9]* ms for the native mark' <<<"$ERR" || fail "a stale hint still waited (stderr: ${ERR:0:400})"
pass "a stale hint does not wait"

echo "3. mark present, the adapter still answers and leaves it"
check_escape() { # <label> [adapter args...]
  local label="$1"; shift
  reset_state; write_hint UserPromptSubmit; write_mark "$K1"
  run_adapter "$P1" "$@"; expect_answers "$label"
  [ -e "$MARKS/$K1" ] || fail "$label: the mark was consumed"
}
check_escape "engine hand-back (event argument)" UserPromptSubmit
for kill in HQ_CORE_NEXT=off HQ_CORE_NEXT=OFF HQ_CORE_NEXT=0 HQ_HOOK_ENGINE=off HQ_CODEX_NATIVE_STEP_ASIDE=0; do
  EXTRA_ENV="$kill"; check_escape "$kill"
done
EXTRA_ENV=""
mkdir -p "$HOME_DIR/.hq/state"
reset_state; write_hint UserPromptSubmit; write_mark "$K1"
mkdir -p "$HOME_DIR/.hq/state"; : > "$HOME_DIR/.hq/state/core-next.off"
run_adapter "$P1"; expect_answers "~/.hq/state/core-next.off"
reset_state; write_hint UserPromptSubmit; write_mark "$K1"
mkdir -p "$HOME_DIR/.hq"; : > "$HOME_DIR/.hq/hook-engine.off"
run_adapter "$P1"; expect_answers "~/.hq/hook-engine.off"
reset_state; write_hint UserPromptSubmit; write_mark "$K1"
OUT="$(cd "$FIX" && printf '%s' "$P1" | env -i PATH="$PATH" HOME="$HOME_DIR" TMPDIR="$TMP" HQ_NO_UPDATE_CHECK=1 \
  HQ_TELEMETRY=0 CNSA_TRACE="$TRACE" HQ_HOOK_STATE_DIR=relative/state /bin/bash "$ADAPTER" 2>/dev/null)" || true
master_ran || fail "relative HQ_HOOK_STATE_DIR: master-hook.sh never started"
pass "relative HQ_HOOK_STATE_DIR: answers"

echo "LATENCY mark-present-ms=$LAT_PRESENT mark-during-wait-ms=$LAT_LATE no-engine-ms=$LAT_NONE hint-no-mark-ms=$LAT_NOMARK wait-ms=$WAIT_MS"

fi

if [ "$TIMEOUT_FIT" = 1 ]; then
echo "4. each Codex event, engine silent, still answers inside its config.toml timeout"
# Codex kills a hook at the event's timeout; a killed adapter leaves the event
# unanswered. Worst case: the engine answered this event before (hint), writes
# no mark now, and HQ_CODEX_NATIVE_WAIT_MS asks for more than any cap. The
# adapter must answer as it does with no engine at all, at least 1 s before the
# timeout. Events whose timeout is under 15 s run that worst case under their
# real timeout. For the others the no-engine answer time plus the 10 s cap plus
# 1 s must fit, and UserPromptSubmit runs the worst case to show the cap holds.
CAP_LONG_MS=10000 # codex_native_wait_cap_ms in the adapter, for every event but SessionEnd
EVENT_TIMEOUTS="$(awk '
  /^\[\[hooks\.[A-Za-z]+\]\]$/ { ev = $0; gsub(/^\[\[hooks\.|\]\]$/, "", ev); next }
  /^timeout *= *[0-9]+ *$/ && ev != "" { t = $0; sub(/^timeout *= */, "", t); sub(/ *$/, "", t); print ev, t; ev = "" }
' "$FIX/.codex/config.toml")"
[ -n "$EVENT_TIMEOUTS" ] || fail "no hook timeouts found in .codex/config.toml"
grep -q '^SessionEnd [0-9]' <<<"$EVENT_TIMEOUTS" || fail "no SessionEnd timeout in .codex/config.toml"
KILL_AFTER=""
while read -r ev timeout_s; do
  [ -n "$ev" ] || continue
  limit_ms=$(( (timeout_s - 1) * 1000 ))
  pe="$(event_payload "$ev" "turn-timeout")"
  reset_state
  KILL_AFTER="$timeout_s"; run_adapter "$pe"; KILL_AFTER=""
  base_code=$CODE base_ms=$ELAPSED base_ran=no
  if master_ran; then base_ran=yes; fi
  [ "$base_code" -ne 142 ] || fail "$ev: no engine at all, the adapter outran the ${timeout_s} s timeout"
  if [ "$timeout_s" -lt 15 ] || [ "$ev" = UserPromptSubmit ]; then
    reset_state; write_hint "$ev"
    saved_wait=$WAIT_MS; WAIT_MS=99999
    KILL_AFTER="$timeout_s"; run_adapter "$pe"; KILL_AFTER=""
    WAIT_MS=$saved_wait
    [ "$CODE" -ne 142 ] || fail "$ev: killed at its ${timeout_s} s timeout while waiting for a mark"
    [ "$CODE" -eq "$base_code" ] || fail "$ev: exit $CODE with a silent engine, $base_code with none"
    ran=no; if master_ran; then ran=yes; fi
    [ "$ran" = "$base_ran" ] || fail "$ev: master-hook ran=$ran with a silent engine, ran=$base_ran with none"
    [ "$ELAPSED" -le "$limit_ms" ] || fail "$ev: answered in ${ELAPSED} ms, over ${limit_ms} ms (timeout ${timeout_s} s less 1 s)"
    if [ "$timeout_s" -ge 15 ]; then
      [ "$ELAPSED" -ge "$CAP_LONG_MS" ] || fail "$ev: waited less than the ${CAP_LONG_MS} ms cap (${ELAPSED} ms)"
    fi
    pass "$ev: silent engine, answers in ${ELAPSED} ms within ${timeout_s} s less 1 s (no engine ${base_ms} ms)"
    echo "LATENCY timeout-fit event=$ev timeout-s=$timeout_s no-engine-ms=$base_ms silent-engine-ms=$ELAPSED"
  else
    [ $(( base_ms + CAP_LONG_MS )) -le "$limit_ms" ] \
      || fail "$ev: no-engine answer ${base_ms} ms plus the ${CAP_LONG_MS} ms cap is over ${limit_ms} ms"
    pass "$ev: no-engine answer ${base_ms} ms plus the ${CAP_LONG_MS} ms cap fits ${timeout_s} s less 1 s"
    echo "LATENCY timeout-fit event=$ev timeout-s=$timeout_s no-engine-ms=$base_ms"
  fi
done <<EOF
$EVENT_TIMEOUTS
EOF
fi

if [ -n "${HQ_TEST_HQ_HOOK:-}" ]; then
  echo "5. the real engine and the adapter at once"
  [ -x "$HQ_TEST_HQ_HOOK" ] || fail "HQ_TEST_HQ_HOOK is not executable: $HQ_TEST_HQ_HOOK"
  reset_state
  run_engine() { # <payload> -> engine stdout in $TMP/engine.out
    printf '%s' "$1" | (cd "$FIX" && env -i PATH="$PATH" HOME="$HOME_DIR" TMPDIR="$TMP" HQ_ROOT="$FIX" \
      CLAUDE_PROJECT_DIR="$FIX" HQ_HOOK_STATE_DIR="$STATE" HQ_NO_UPDATE_CHECK=1 HQ_TELEMETRY=0 \
      "$HQ_TEST_HQ_HOOK" run --host codex UserPromptSubmit --hq-root "$FIX") > "$TMP/engine.out" 2> "$TMP/engine.err"
  }
  # First answer on this account: it writes the hint the adapter waits on.
  run_engine "$(payload warm-up turn-0)" || fail "engine warm-up failed: $(cat "$TMP/engine.err")"
  [ -f "$MARKS/event-UserPromptSubmit" ] || fail "the engine wrote no event hint"
  P2="$(payload "$SID" turn-real)"
  ( run_engine "$P2"; echo "$?" > "$TMP/engine.code" ) &
  BG_PIDS="$BG_PIDS $!"
  run_adapter "$P2"
  wait
  [ "$(cat "$TMP/engine.code")" = "0" ] || fail "engine exit $(cat "$TMP/engine.code"): $(cat "$TMP/engine.err")"
  jq -e '.hookSpecificOutput.hookEventName == "UserPromptSubmit"' "$TMP/engine.out" >/dev/null \
    || [ ! -s "$TMP/engine.out" ] || fail "engine answer is not a Codex answer: $(head -c 300 "$TMP/engine.out")"
  expect_aside "the real engine answered, the adapter stood aside"
  echo "LATENCY real-engine-adapter-ms=$ELAPSED"
fi

echo "PASS: codex-adapter-native-steps-aside"
