#!/usr/bin/env bash
# hq-core: public
# master-hook-replay-recorder.test.sh — master-hook.sh hands each event to
# `hq-hook record` when the flag core.replay-recorder is true in the cached
# person flag snapshot, and does nothing otherwise. The recorder never changes
# the hook's output or exit code.
#
# A stub hq-hook in the temp dir logs each call (arguments, stdin, the harness
# variables) so the hand-off can be checked without the real engine.
#
# Sections:
#   [a] flag snapshot absent: no call; output and exit code byte-identical to
#       a dispatcher with the recorder call removed
#   [b] flag on: one call with the event, exit code and start time; stdin is
#       <payload> 0x1E <stdout JSON> 0x1E <stdout plain>; output unchanged
#   [c] HQ_REPLAY_RECORDER=off and ~/.hq/replay-recorder.off: no call
#   [d] flag false, a non-boolean value, a company snapshot: no call; the
#       permission-fallback snapshot under the temporary folder is read too,
#       and ignored when it or its folder is a symlink or another user's
#   [e] ~/.hq/bin/hq-hook/current discovers the binary; no binary: no call
#   [f] a recorder that fails, prints, or hangs changes nothing and is not
#       waited for
#   [g] a blocked event is recorded with exit code 2 and the blocking hook
#   [h] every host reaches the call: Codex and Grok harness (registry pass
#       skipped), the local-bot adapter, the fleet session launcher payload
#   [i] with a real engine (HQ_REPLAY_RECORDER_TEST_BIN): a token-like string
#       in a Bash call is stored redacted
#
# `--bench [runs]` prints the cost of the recorder function per event, flag off
# and flag on, and runs no assertions.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
MASTER="$ROOT/.claude/hooks/master-hook.sh"

pass=0
fail=0
ok() { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; }

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq unavailable" >&2; exit 0; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/mh-replay-recorder.XXXXXX")"
# A recorder started detached may still be writing when the test ends.
trap 'rm -rf "$TMP" 2>/dev/null || { sleep 2; rm -rf "$TMP"; }' EXIT
TMP="$(cd "$TMP" && pwd -P)"
FIX="$TMP/hq"
FIX_REFERENCE="$TMP/hq-reference"
FAKE_HOME="$TMP/home"
CACHE="$FAKE_HOME/.cache"
SNAPSHOT="$CACHE/hq/flags/snapshot-person.json"
# The CLI's permission-fallback snapshot lives under the temporary folder, so
# the dispatcher under test gets its own.
FAKE_TMP="$TMP/tmp"
FALLBACK="$FAKE_TMP/hq-cli-flag-snapshots-$UID/hq/flags/snapshot-person.json"
ENGINE="$TMP/engine"
STUB="$ENGINE/hq-hook"
CALLS="$ENGINE/calls.log"
HOOK_TIMEOUT=7
RS=$'\x1e'
TEST_BASH="${HQ_TEST_BASH:-/bin/bash}"
[ -x "$TEST_BASH" ] || TEST_BASH="$(command -v bash)"
echo "interpreter under test: $TEST_BASH ($("$TEST_BASH" -c 'echo "$BASH_VERSION"'))"
mkdir -p "$FAKE_HOME" "$CACHE/hq/flags" "$ENGINE" "$FAKE_TMP"

CALL_SITE='master_replay_record || true'
n="$(grep -c "^$CALL_SITE\$" "$MASTER")"
[ "$n" = "1" ] || { echo "FAIL: expected one recorder call site in master-hook.sh, found $n" >&2; exit 1; }

make_fixture() { # <root>
  local root="$1"
  mkdir -p "$root/.claude/hooks" "$root/core/scripts/lib" "$root/workspace/orchestrator"
  cp "$MASTER" "$root/.claude/hooks/master-hook.sh"
  for f in hook-timeout-probe.sh hook-timeout-watchdog.sh hook-gate.sh; do
    cp "$ROOT/.claude/hooks/$f" "$root/.claude/hooks/"
  done
  cp "$ROOT/core/scripts/lib/hook-adapter-core.sh" "$ROOT/core/scripts/lib/trigger-fact-text.awk" "$root/core/scripts/lib/"
  cp "$ROOT/core/scripts/resolve-hq-root.sh" "$root/core/scripts/"
  printf 'hqVersion: "15.0.131"\n' > "$root/core/core.yaml"
  # One registry hook that injects context as JSON, one that prints plain
  # text, and one guard that blocks a command containing "blockme".
  cat > "$root/.claude/hooks/fixture-context.sh" <<'HOOK'
#!/usr/bin/env bash
cat >/dev/null
printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","additionalContext":"context from fixture-context"}}\n'
exit 0
HOOK
  cat > "$root/.claude/hooks/fixture-guard.sh" <<'HOOK'
#!/usr/bin/env bash
payload="$(cat)"
case "$payload" in
  *blockme*) echo "fixture-guard: blocked" >&2; exit 2 ;;
esac
exit 0
HOOK
  chmod +x "$root/.claude/hooks/fixture-context.sh" "$root/.claude/hooks/fixture-guard.sh"
  jq -nc --argjson t "$HOOK_TIMEOUT" '
    {hooks: {PreToolUse: [{matcher: "Bash", hooks: [
      {id: "fixture-guard", script: ".claude/hooks/fixture-guard.sh", timeout: $t, gated: false, runner: "exec", args: []},
      {id: "fixture-context", script: ".claude/hooks/fixture-context.sh", timeout: $t, gated: false, runner: "exec", args: []}
    ]}]}}' > "$root/.claude/hooks/hook-registry.json"
}
make_fixture "$FIX"
make_fixture "$FIX_REFERENCE"
# Reference dispatcher: the same file with the recorder call removed.
grep -v "^$CALL_SITE\$" "$FIX_REFERENCE/.claude/hooks/master-hook.sh" > "$FIX_REFERENCE/.claude/hooks/master-hook.sh.new"
mv -f "$FIX_REFERENCE/.claude/hooks/master-hook.sh.new" "$FIX_REFERENCE/.claude/hooks/master-hook.sh"

# Stub hq-hook: one directory per call, named in the order the calls arrive.
cat > "$STUB" <<'STUB'
#!/usr/bin/env bash
set -u
here="$(cd "$(dirname "$0")" && pwd)"
[ "${1:-}" = "record" ] || { echo "stub hq-hook: unexpected command ${1:-}" >&2; exit 2; }
shift
call="$(mktemp -d "$here/call.XXXXXX")"
cat > "$call/stdin"
printf '%s\n' "$@" > "$call/args"
printf 'harness=%s runtime=%s\n' "${HQ_HARNESS-<unset>}" "${HQ_CHECKPOINT_RUNTIME-<unset>}" > "$call/env"
printf 'record %s\n' "$*" >> "$here/calls.log"
if [ -f "$here/noise" ]; then
  echo "recorder noise on stdout"
  echo "recorder noise on stderr" >&2
fi
if [ -f "$here/sleep" ]; then
  printf '%s\n' "$$" > "$here/sleep-pid"
  exec sleep "$(cat "$here/sleep")"
fi
[ ! -f "$here/rc" ] || exit "$(cat "$here/rc")"
exit 0
STUB
chmod +x "$STUB"

payload_for() { # <command>
  jq -nc --arg d "$FIX" --arg c "$1" '{session_id:"recorder-test",hook_event_name:"PreToolUse",tool_name:"Bash",cwd:$d,tool_input:{command:$c}}'
}
PAYLOAD="$(payload_for 'echo hi')"

flag_snapshot() { # <flags object as JSON text>
  printf '{"scope":"person","fetched_at":"%s","flags":%s}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" > "$SNAPSHOT"
}
flag_on() { flag_snapshot '{"another.flag":false,"core.replay-recorder":true,"zz.flag":true}'; }
fallback_snapshot() { # <flags object as JSON text>
  (umask 077; mkdir -p "${FALLBACK%/*}")
  printf '{"scope":"person","fetched_at":"%s","flags":%s}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" > "$FALLBACK"
}
reset() {
  rm -rf "$ENGINE"/call.* "$CALLS" "$ENGINE/noise" "$ENGINE/sleep" "$ENGINE/sleep-pid" "$ENGINE/rc" \
    "$FAKE_HOME/.hq" "$SNAPSHOT" "$CACHE/hq/flags"/snapshot-cmp_*.json "$FALLBACK"
}

# run <root> <event> [ENV=VALUE ...] -> RC, stdout in $TMP/out, stderr in $TMP/err
run() {
  local root="$1" event="$2"; shift 2
  RC=0
  printf '%s' "$PAYLOAD" | (cd "$root" && env HOME="$FAKE_HOME" XDG_CACHE_HOME="$CACHE" TMPDIR="$FAKE_TMP" \
    HQ_HOOK_PROFILE=standard CLAUDE_PROJECT_DIR="$root" HQ_ROOT="$root" \
    HQ_HOOK_DEDUPE=0 HQ_HOOK_TIMEOUT_SENTRY=0 HQ_FLAGS_API_URL= HQ_COMPANY_UID= \
    HQ_HOOK_ENGINE=off HQ_HOOK_ENGINE_BIN="$STUB" \
    "$@" "$TEST_BASH" "$root/.claude/hooks/master-hook.sh" "$event") \
    >"$TMP/out" 2>"$TMP/err" || RC=$?
}
calls() { [ -f "$CALLS" ] && wc -l < "$CALLS" | tr -d ' ' || echo 0; }
# The recorder is started detached, so give a call up to 5 s to arrive.
wait_calls() { # <count>
  local tries=0
  while [ "$(calls)" -lt "$1" ] && [ "$tries" -lt 50 ]; do
    sleep 0.1
    tries=$((tries + 1))
  done
  [ "$(calls)" = "$1" ]
}
# A call that must not happen: allow the same 0.5 s for a stray one to land.
no_call() { sleep 0.5; [ "$(calls)" = "0" ]; }
last_call() { ls -d "$ENGINE"/call.* 2>/dev/null | tail -n 1; }
arg_after() { # <call dir> <option> -> the argument following it
  awk -v want="$2" 'found { print; exit } $0 == want { found = 1 }' "$1/args"
}

if [ "${1:-}" = "--bench" ]; then
  # Cost of master_replay_record per event, measured on the function itself so
  # the rest of the dispatcher does not hide it. The function is taken from
  # master-hook.sh as written.
  RUNS="${2:-500}"
  BENCH_BIN="${HQ_REPLAY_RECORDER_TEST_BIN:-$STUB}"
  awk '/^master_replay_record\(\) \{$/ { on = 1 } on { print } on && /^}$/ { exit }' "$MASTER" > "$TMP/function.sh"
  grep -q 'record --event' "$TMP/function.sh" || { echo "FAIL: could not extract master_replay_record" >&2; exit 1; }
  cat > "$TMP/bench.sh" <<'BENCH'
set -uo pipefail
. "$1"
runs="$2"
EVENT=PreToolUse
exit_code=0
has_blocking_json=0
blocking_hook_sources=()
MASTER_STARTED_MS=999999999
INPUT="$(cat "$3")"
json_result="$(cat "$4")"
plain_buf=""
now_ms() { perl -MTime::HiRes=time -e 'printf "%.3f", time() * 1000'; }
empty_loop() { local i=0; while [ "$i" -lt "$runs" ]; do :; i=$((i + 1)); done; }
record_loop() { local i=0; while [ "$i" -lt "$runs" ]; do master_replay_record || true; i=$((i + 1)); done; }
t0="$(now_ms)"; empty_loop; t1="$(now_ms)"; record_loop; t2="$(now_ms)"
perl -e 'printf "%.4f\n", (($ARGV[2] - $ARGV[1]) - ($ARGV[1] - $ARGV[0])) / $ARGV[3]' "$t0" "$t1" "$t2" "$runs"
wait
BENCH
  # A snapshot the size the CLI writes (about 440 flags on one line).
  bench_snapshot() { # <true|false>
    jq -nc --argjson on "$1" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
      {scope: "person", fetched_at: $at,
       flags: ([range(0; 440) | {key: "example.flag-number-\(.)", value: (. % 3 == 0)}] | from_entries
               + {"core.replay-recorder": $on})}' > "$SNAPSHOT"
  }
  payload_for 'git status --short && echo benchmark' > "$TMP/bench-payload.json"
  jq -nc '{hookSpecificOutput:{hookEventName:"PreToolUse",additionalContext:("policy reminder line\n" * 200)}}' > "$TMP/bench-answer.json"
  # Nine batches of RUNS calls each; the figure is the median batch mean.
  bench() { # <label> [ENV=VALUE ...]
    local label="$1" batch=0 values=""; shift
    while [ "$batch" -lt 9 ]; do
      values="$values$(env HOME="$FAKE_HOME" XDG_CACHE_HOME="$CACHE" TMPDIR="$FAKE_TMP" HQ_HOOK_ENGINE_BIN="$BENCH_BIN" "$@" \
        "$TEST_BASH" "$TMP/bench.sh" "$TMP/function.sh" "$RUNS" "$TMP/bench-payload.json" "$TMP/bench-answer.json")"$'\n'
      batch=$((batch + 1))
    done
    printf '%-42s median %s ms, worst batch %s ms per event\n' "$label" \
      "$(printf '%s' "$values" | sort -n | sed -n 5p)" "$(printf '%s' "$values" | sort -n | sed -n 9p)"
  }
  # The whole dispatcher on the fixture, flag off and flag on in turn.
  bench_dispatcher() { # <runs>
    perl -MTime::HiRes=time -e '
      my ($runs, $snapshot, $on, $off, @cmd) = @ARGV;
      my %ms = (off => [], on => []);
      sub put { open(my $in, "<", $_[0]) or die; local $/; my $text = <$in>; close $in;
                open(my $out, ">", $snapshot) or die; print $out $text; close $out }
      for my $i (1 .. $runs + 3) {
        for my $mode ("off", "on") {
          put($mode eq "on" ? $on : $off);
          my $t = time(); system(@cmd); my $took = (time() - $t) * 1000;
          push @{$ms{$mode}}, $took if $i > 3;
        }
      }
      for my $mode ("off", "on") {
        my @s = sort { $a <=> $b } @{$ms{$mode}};
        printf "whole dispatcher, flag %-19s median %.1f ms, p95 %.1f ms (%d runs)\n", $mode, $s[int($#s / 2)], $s[int($#s * 0.95)], scalar @s;
      }
    ' "$1" "$SNAPSHOT" "$TMP/snapshot-on.json" "$TMP/snapshot-off.json" \
      env HOME="$FAKE_HOME" XDG_CACHE_HOME="$CACHE" TMPDIR="$FAKE_TMP" HQ_HOOK_PROFILE=standard CLAUDE_PROJECT_DIR="$FIX" HQ_ROOT="$FIX" \
      HQ_HOOK_DEDUPE=0 HQ_HOOK_TIMEOUT_SENTRY=0 HQ_FLAGS_API_URL= HQ_COMPANY_UID= HQ_HOOK_ENGINE=off HQ_HOOK_ENGINE_BIN="$BENCH_BIN" \
      "$TEST_BASH" -c 'cd "$1" && exec "$2" "$1/.claude/hooks/master-hook.sh" PreToolUse < "$3" > /dev/null 2>&1' _ "$FIX" "$TEST_BASH" "$TMP/bench-payload.json"
  }
  echo "runs per case: $RUNS; recorder binary: $BENCH_BIN"
  echo "snapshot bytes: $(bench_snapshot false; wc -c < "$SNAPSHOT" | tr -d ' ')"
  rm -f "$SNAPSHOT"
  bench "flag off: no snapshot file"
  bench_snapshot false
  bench "flag off: snapshot present, flag false"
  bench "flag off: kill switch variable" HQ_REPLAY_RECORDER=off
  bench_snapshot true
  bench "flag on: recorder started detached"
  cp "$SNAPSHOT" "$TMP/snapshot-on.json"
  bench_snapshot false
  cp "$SNAPSHOT" "$TMP/snapshot-off.json"
  bench_dispatcher 60
  exit 0
fi

# [a] flag snapshot absent
reset
run "$FIX_REFERENCE" PreToolUse
REF_RC="$RC"; cp "$TMP/out" "$TMP/ref.out"; cp "$TMP/err" "$TMP/ref.err"
grep -q 'context from fixture-context' "$TMP/ref.out" && ok "[a] reference dispatcher answers with the fixture context" || bad "[a] reference output missing the fixture context: $(cat "$TMP/ref.out")"
run "$FIX" PreToolUse
[ "$RC" = "$REF_RC" ] && cmp -s "$TMP/out" "$TMP/ref.out" && cmp -s "$TMP/err" "$TMP/ref.err" && ok "[a] flag absent: output and exit code identical to the reference" || bad "[a] flag absent: output differs from the reference"
no_call && ok "[a] flag absent: recorder not started" || bad "[a] flag absent: recorder was started"
[ ! -e "$FAKE_HOME/.hq" ] && ok "[a] flag absent: nothing created under ~/.hq" || bad "[a] flag absent: ~/.hq was created"

# [b] flag on
reset; flag_on
run "$FIX" PreToolUse
[ "$RC" = "$REF_RC" ] && cmp -s "$TMP/out" "$TMP/ref.out" && cmp -s "$TMP/err" "$TMP/ref.err" && ok "[b] flag on: output and exit code identical to the reference" || bad "[b] flag on: output differs from the reference"
if wait_calls 1; then
  ok "[b] flag on: recorder started once"
  call="$(last_call)"
  [ "$(arg_after "$call" --event)" = "PreToolUse" ] && ok "[b] --event is the hook event" || bad "[b] --event: $(cat "$call/args")"
  [ "$(arg_after "$call" --exit-code)" = "$REF_RC" ] && ok "[b] --exit-code is the hook's exit code" || bad "[b] --exit-code: $(cat "$call/args")"
  case "$(arg_after "$call" --started-ms)" in
    ''|*[!0-9]*) bad "[b] --started-ms is not a number: $(arg_after "$call" --started-ms)" ;;
    *) ok "[b] --started-ms is the dispatcher's start time" ;;
  esac
  frame="$(cat "$call/stdin")"
  [ "${frame%%"$RS"*}" = "$PAYLOAD" ] && ok "[b] stdin starts with the payload as received" || bad "[b] payload section: ${frame%%"$RS"*}"
  rest="${frame#*"$RS"}"
  [ "${rest%%"$RS"*}" = "$(cat "$TMP/ref.out")" ] && ok "[b] second section is the JSON the hook wrote" || bad "[b] JSON section: ${rest%%"$RS"*}"
  [ -z "${rest#*"$RS"}" ] && ok "[b] third section is empty when no plain text was written" || bad "[b] plain section: ${rest#*"$RS"}"
else
  bad "[b] flag on: expected 1 recorder call, saw $(calls)"
fi

# [c] kill switches
reset; flag_on
run "$FIX" PreToolUse HQ_REPLAY_RECORDER=OFF
no_call && ok "[c] HQ_REPLAY_RECORDER=OFF: recorder not started" || bad "[c] kill switch variable ignored"
reset; flag_on; mkdir -p "$FAKE_HOME/.hq"; : > "$FAKE_HOME/.hq/replay-recorder.off"
run "$FIX" PreToolUse
no_call && ok "[c] ~/.hq/replay-recorder.off: recorder not started" || bad "[c] kill switch file ignored"

# [d] flag values that are not the boolean true
for flags in '{"core.replay-recorder":false}' '{"core.replay-recorder":"on"}' '{"core.replay-recorder":"true"}' '{"core.replay-recorder-v2":true}' '{}'; do
  reset; flag_snapshot "$flags"
  run "$FIX" PreToolUse
  no_call && ok "[d] flags $flags: recorder not started" || bad "[d] flags $flags: recorder was started"
done
reset
printf '{"company_uid":"cmp_123456","fetched_at":"%s","flags":{"core.replay-recorder":true}}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$CACHE/hq/flags/snapshot-cmp_123456.json"
run "$FIX" PreToolUse
no_call && ok "[d] a company snapshot alone does not turn the recorder on" || bad "[d] company snapshot turned the recorder on"
# A snapshot written on several lines is not the CLI's spelling: off.
reset
printf '{\n  "scope": "person",\n  "fetched_at": "%s",\n  "flags": {\n    "core.replay-recorder": true\n  }\n}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$SNAPSHOT"
run "$FIX" PreToolUse
no_call && ok "[d] a snapshot that is not one compact line reads as off" || bad "[d] multi-line snapshot turned the recorder on"
if [ "$(id -u)" != "0" ]; then
  reset; flag_on; chmod 000 "$SNAPSHOT"
  run "$FIX" PreToolUse
  chmod 600 "$SNAPSHOT"
  [ "$RC" = "$REF_RC" ] && cmp -s "$TMP/out" "$TMP/ref.out" && cmp -s "$TMP/err" "$TMP/ref.err" && no_call \
    && ok "[d] an unreadable snapshot reads as off and prints nothing" || bad "[d] unreadable snapshot: rc=$RC err=$(cat "$TMP/err")"
fi
# The snapshot the CLI writes under the temporary folder when it cannot write
# the cache folder. Either file holding the flag starts the recorder, which
# reads both in full and lets the newer one decide.
reset; fallback_snapshot '{"core.replay-recorder":true}'
run "$FIX" PreToolUse
wait_calls 1 && ok "[d] the fallback snapshot alone starts the recorder" || bad "[d] fallback snapshot alone: saw $(calls) calls"
reset; flag_snapshot '{"core.replay-recorder":false}'; fallback_snapshot '{"core.replay-recorder":true}'
run "$FIX" PreToolUse
wait_calls 1 && ok "[d] cache snapshot off and fallback on: the recorder is started to decide" || bad "[d] cache off, fallback on: saw $(calls) calls"
reset; fallback_snapshot '{"core.replay-recorder":false}'
run "$FIX" PreToolUse
no_call && ok "[d] a fallback snapshot with the flag off starts nothing" || bad "[d] fallback snapshot with the flag off started the recorder"
# The fallback folder is under a shared temporary folder, so a planted link or
# a file owned by someone else is ignored.
FALLBACK_DIR="$FAKE_TMP/hq-cli-flag-snapshots-$UID"
PLANTED="$TMP/planted"
mkdir -p "$PLANTED/hq/flags"
printf '{"scope":"person","fetched_at":"%s","flags":{"core.replay-recorder":true}}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$PLANTED/hq/flags/snapshot-person.json"
reset; mkdir -p "${FALLBACK%/*}"; ln -s "$PLANTED/hq/flags/snapshot-person.json" "$FALLBACK"
run "$FIX" PreToolUse
[ "$RC" = "$REF_RC" ] && cmp -s "$TMP/out" "$TMP/ref.out" && no_call \
  && ok "[d] a fallback snapshot that is a symlink is ignored" || bad "[d] symlinked fallback snapshot: saw $(calls) calls, rc=$RC"
reset; rm -rf "$FALLBACK_DIR"; ln -s "$PLANTED" "$FALLBACK_DIR"
run "$FIX" PreToolUse
[ "$RC" = "$REF_RC" ] && cmp -s "$TMP/out" "$TMP/ref.out" && no_call \
  && ok "[d] a fallback folder that is a symlink is ignored" || bad "[d] symlinked fallback folder: saw $(calls) calls, rc=$RC"
rm -f "$FALLBACK_DIR"
if [ "$(id -u)" = "0" ] && id nobody >/dev/null 2>&1; then
  reset; fallback_snapshot '{"core.replay-recorder":true}'; chown nobody "$FALLBACK"
  run "$FIX" PreToolUse
  no_call && ok "[d] a fallback snapshot owned by another user is ignored" || bad "[d] fallback owned by another user started the recorder"
  reset; fallback_snapshot '{"core.replay-recorder":true}'; chown nobody "$FALLBACK_DIR"
  run "$FIX" PreToolUse
  no_call && ok "[d] a fallback folder owned by another user is ignored" || bad "[d] fallback folder owned by another user started the recorder"
  chown "$(id -u)" "$FALLBACK_DIR"
else
  echo "note [d] ownership cases skipped: they need root to give a file to another user"
fi

# [e] binary discovery
reset; flag_on; mkdir -p "$FAKE_HOME/.hq/bin/hq-hook"; printf '%s\n' "$STUB" > "$FAKE_HOME/.hq/bin/hq-hook/current"
run "$FIX" PreToolUse HQ_HOOK_ENGINE_BIN=
wait_calls 1 && ok "[e] pointer file discovers the engine" || bad "[e] pointer file: saw $(calls) calls"
reset; flag_on
run "$FIX" PreToolUse HQ_HOOK_ENGINE_BIN=
[ "$RC" = "$REF_RC" ] && cmp -s "$TMP/out" "$TMP/ref.out" && no_call && ok "[e] no engine installed: nothing started, output unchanged" || bad "[e] no engine installed changed the result"

# [f] recorder faults
reset; flag_on; : > "$ENGINE/noise"; echo 1 > "$ENGINE/rc"
run "$FIX" PreToolUse
[ "$RC" = "$REF_RC" ] && cmp -s "$TMP/out" "$TMP/ref.out" && cmp -s "$TMP/err" "$TMP/ref.err" && ok "[f] a recorder that fails and prints leaves output and exit code unchanged" || bad "[f] failing recorder changed the result: rc=$RC out=$(cat "$TMP/out") err=$(cat "$TMP/err")"
wait_calls 1 || bad "[f] failing recorder was not started"
reset; flag_on; echo 30 > "$ENGINE/sleep"
started="$(date +%s)"
run "$FIX" PreToolUse
elapsed=$(( $(date +%s) - started ))
[ "$RC" = "$REF_RC" ] && cmp -s "$TMP/out" "$TMP/ref.out" && [ "$elapsed" -lt 20 ] && ok "[f] a recorder that hangs is not waited for (${elapsed}s)" || bad "[f] hanging recorder: rc=$RC elapsed=${elapsed}s"
wait_calls 1 || bad "[f] hanging recorder was not started"
[ ! -f "$ENGINE/sleep-pid" ] || kill "$(cat "$ENGINE/sleep-pid")" 2>/dev/null || true
reset; flag_on; printf '#!/usr/bin/env bash\nexit 126\n' > "$ENGINE/broken"; chmod -x "$ENGINE/broken"
run "$FIX" PreToolUse HQ_HOOK_ENGINE_BIN="$ENGINE/broken"
[ "$RC" = "$REF_RC" ] && cmp -s "$TMP/out" "$TMP/ref.out" && cmp -s "$TMP/err" "$TMP/ref.err" && ok "[f] an engine that cannot be executed changes nothing" || bad "[f] unexecutable engine changed the result"

# [g] a blocked event
reset
PAYLOAD="$(payload_for 'echo blockme')"
run "$FIX_REFERENCE" PreToolUse
BLOCK_RC="$RC"; cp "$TMP/out" "$TMP/block.out"; cp "$TMP/err" "$TMP/block.err"
[ "$BLOCK_RC" = "2" ] && ok "[g] reference dispatcher blocks the command" || bad "[g] reference exit code $BLOCK_RC, expected 2"
flag_on
run "$FIX" PreToolUse
[ "$RC" = "2" ] && cmp -s "$TMP/out" "$TMP/block.out" && cmp -s "$TMP/err" "$TMP/block.err" && ok "[g] block decision identical with the recorder on" || bad "[g] recorder changed a block decision: rc=$RC"
if wait_calls 1; then
  call="$(last_call)"
  [ "$(arg_after "$call" --exit-code)" = "2" ] && ok "[g] recorded exit code is 2" || bad "[g] --exit-code: $(cat "$call/args")"
  [ "$(arg_after "$call" --blocked-by)" = "fixture-guard.sh" ] && ok "[g] recorded the blocking hook" || bad "[g] --blocked-by: $(cat "$call/args")"
else
  bad "[g] blocked event was not recorded"
fi
PAYLOAD="$(payload_for 'echo hi')"

# [h] every host reaches the call
host_case() { # <label> <event> <expected env line> [ENV=VALUE ...]
  local label="$1" event="$2" want="$3"; shift 3
  reset; flag_on
  run "$FIX" "$event" "$@"
  if wait_calls 1; then
    call="$(last_call)"
    [ "$(cat "$call/env")" = "$want" ] && [ "$(arg_after "$call" --event)" = "$event" ] \
      && ok "[h] $label: recorded as $event with $want" || bad "[h] $label: $(cat "$call/env") $(cat "$call/args" | tr '\n' ' ')"
  else
    bad "[h] $label: expected 1 recorder call, saw $(calls)"
  fi
}
host_case "Claude Code" PreToolUse "harness=<unset> runtime=<unset>"
host_case "Codex adapter" PreToolUse "harness=codex runtime=codex" HQ_HARNESS=codex HQ_CHECKPOINT_RUNTIME=codex
host_case "Grok adapter" PostToolUse "harness=grok runtime=grok" HQ_HARNESS=grok HQ_CHECKPOINT_RUNTIME=grok
host_case "local-bot adapter" PreToolUse "harness=codex runtime=hq-fleet-local" HQ_HARNESS=codex HQ_CHECKPOINT_RUNTIME=hq-fleet-local
PAYLOAD="$(jq -nc --arg d "$FIX" '{session_id:"agent-session",cwd:$d,hook_event_name:"UserPromptSubmit",source:"hq-agent-session",prompt:"summarise the open work"}')"
host_case "fleet session launcher" UserPromptSubmit "harness=<unset> runtime=<unset>"
frame="$(cat "$(last_call)/stdin" 2>/dev/null || true)"
case "${frame%%"$RS"*}" in
  *'"source":"hq-agent-session"'*) ok "[h] fleet session payload reaches the recorder with its source field" ;;
  *) bad "[h] fleet session payload: ${frame%%"$RS"*}" ;;
esac
PAYLOAD="$(payload_for 'echo hi')"

# [i] the real engine, when one is given
REAL="${HQ_REPLAY_RECORDER_TEST_BIN:-}"
if [ -n "$REAL" ] && [ -x "$REAL" ]; then
  reset; flag_on
  # Built from two pieces so this file holds no token-shaped literal.
  token="gh""p_aBcDeFgHiJkLmNoPqRsTuVwXyZ01234567"
  PAYLOAD="$(payload_for "curl -H 'Authorization: Bearer $token' https://example.test && echo $token")"
  run "$FIX" PreToolUse HQ_HOOK_ENGINE_BIN="$REAL"
  store="$FAKE_HOME/.hq/replay-recorder"
  tries=0
  while ! ls "$store"/segment-*.jsonl >/dev/null 2>&1 && [ "$tries" -lt 50 ]; do sleep 0.1; tries=$((tries + 1)); done
  if ls "$store"/segment-*.jsonl >/dev/null 2>&1; then
    sleep 0.2
    stored="$(cat "$store"/segment-*.jsonl)"
    case "$stored" in
      *"$token"*) bad "[i] the token reached the store" ;;
      *) ok "[i] real engine: the token is not in the store" ;;
    esac
    printf '%s\n' "$stored" | jq -e 'select(.host == "claude-code" and .event == "PreToolUse" and .decision.exit_code == 0 and (.payload.tool_input.command | contains("<REDACTED>")) and (.decision.stdout_json.hookSpecificOutput.additionalContext | contains("fixture-context")))' >/dev/null \
      && ok "[i] real engine: event stored with host, event, redacted command and the injected context" || bad "[i] stored record: $stored"
  else
    bad "[i] real engine wrote no store under $store"
  fi
  PAYLOAD="$(payload_for 'echo hi')"
else
  echo "note [i] skipped: set HQ_REPLAY_RECORDER_TEST_BIN to an hq-hook that has the record command"
fi

echo
echo "replay recorder: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
