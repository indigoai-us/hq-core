#!/usr/bin/env bash
# hq-core: public
# master-hook-timeout-journal-size-bound.test.sh — the two per-session files in
# workspace/.hook-timeout-journal stay small while their session runs.
#
# <session>.tsv, the timing journal, gets one row per dispatched hook. Its
# reader takes the last 40 rows, and the journal was cut back to 40 rows only
# when a timeout was reported, so a session that reported none kept every row.
# master-hook.sh now cuts it back on a timer (stamp:
# <session>.tsv.compact-stamp), with no process on an event that is not due.
#
# <session>.tsv.meta gets four lines from the policy injector on every run.
# master-hook.sh rewrites the file at the start of an event only while its
# timeout sentry is on, so with the sentry off, or with the injector run by an
# adapter and no master hook, the file grew by four lines per run. The
# injector now rewrites the file instead of appending to it.
#
# Sections:
#   [a] a new session: the journal gets its rows and, from the second event,
#       a compaction stamp
#   [b] a stamp older than the interval: the next dispatch keeps the newest 40
#       rows and refreshes the stamp
#   [c] a fresh stamp: the journal is left alone and wc is not started
#   [d] a long session never holds more than 40 rows plus one interval's rows
#   [e] rows written by the adapter core are cut back by the dispatcher too
#   [f] the compaction lock: a live owner is respected, a dead one is replaced
#   [g] the metadata file: one set of policy lines however often the injector
#       runs, with and without master-hook.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
MASTER="$ROOT/.claude/hooks/master-hook.sh"
INJECTOR="$ROOT/.claude/hooks/inject-policy-on-trigger.sh"

pass=0
fail=0
ok() { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; }

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq unavailable" >&2; exit 0; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/mh-journal-size.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
TMP="$(cd "$TMP" && pwd -P)"
FAKE_HOME="$TMP/home"
CACHE="$FAKE_HOME/.cache"
SHIMS="$TMP/shims"
KEEP=40                # rows the reader takes, and a compaction keeps
INTERVAL_SECONDS=600   # JOURNAL_COMPACT_SECONDS in master-hook.sh
# The interpreter under test is pinned: HQ_TEST_BASH when set, else /bin/bash
# (what settings.json resolves on macOS), else the first bash on PATH.
TEST_BASH="${HQ_TEST_BASH:-/bin/bash}"
[ -x "$TEST_BASH" ] || TEST_BASH="$(command -v bash)"
echo "interpreter under test: $TEST_BASH ($("$TEST_BASH" -c 'echo "$BASH_VERSION"'))"
mkdir -p "$FAKE_HOME" "$CACHE" "$SHIMS" "$TMP/bin"

# A wc that records each start, then runs the real one. master-hook.sh starts
# wc only in compact_timeout_journal, so the log shows whether an event ran
# the compaction check as a process.
REAL_WC="$(command -v wc)"
cat > "$SHIMS/wc" <<SHIM
#!/usr/bin/env bash
printf 'wc\n' >> "$TMP/wc.log"
exec "$REAL_WC" "\$@"
SHIM
chmod +x "$SHIMS/wc"
wc_starts() { [ -f "$TMP/wc.log" ] || { echo 0; return; }; grep -c . "$TMP/wc.log" || true; }

# Trigger facts for the injector, so its result does not depend on an hq CLI
# being installed on the host.
cat > "$TMP/bin/hq" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "--version" ]; then
  printf '%s\n' 'hq 5.342.5'
  exit 0
fi
with_intent=0
for arg in "$@"; do
  case "$arg" in --with-assistant-intent) with_intent=1 ;; esac
done
if [ "$with_intent" -eq 1 ]; then
  printf '%s\n\n' 'git push completed'
else
  printf '%s\n' 'git push completed'
fi
EOF
chmod +x "$TMP/bin/hq"

# make_fixture <dir>: an HQ root with master-hook.sh, two registry hooks on
# PreToolUse and the real policy injector on PostToolUse.
make_fixture() {
  local fix="$1" id
  mkdir -p "$fix/.claude/hooks" "$fix/core/scripts/lib" "$fix/core/policies" "$fix/workspace/orchestrator"
  cp "$MASTER" "$fix/.claude/hooks/master-hook.sh"
  for id in hook-timeout-probe.sh hook-timeout-watchdog.sh hook-gate.sh; do
    cp "$ROOT/.claude/hooks/$id" "$fix/.claude/hooks/"
  done
  cp "$ROOT/core/scripts/lib/hook-adapter-core.sh" "$ROOT/core/scripts/lib/trigger-fact-text.awk" "$fix/core/scripts/lib/"
  [ ! -f "$ROOT/core/scripts/lib/perl-child-locale.sh" ] \
    || cp "$ROOT/core/scripts/lib/perl-child-locale.sh" "$fix/core/scripts/lib/"
  cp "$ROOT/core/scripts/resolve-hq-root.sh" "$fix/core/scripts/"
  printf 'hqVersion: "15.0.131"\n' > "$fix/core/core.yaml"
  cat > "$fix/core/policies/size-bound-fixture.md" <<'EOF'
---
when: git && push
---
## Rule
Fixture policy.
EOF
  for id in fixture-one fixture-two; do
    cat > "$fix/.claude/hooks/$id.sh" <<HOOK
#!/usr/bin/env bash
cat >/dev/null
here="\$(cd "\$(dirname "\$0")" && pwd)"
printf '$id\n' >> "\$here/ran.log"
exit 0
HOOK
    chmod +x "$fix/.claude/hooks/$id.sh"
  done
  # The injector under test, run against this fixture root.
  cat > "$fix/.claude/hooks/inject-policy-on-trigger.sh" <<HOOK
#!/usr/bin/env bash
PATH="$TMP/bin:\$PATH" exec bash "$INJECTOR" "\$@"
HOOK
  chmod +x "$fix/.claude/hooks/inject-policy-on-trigger.sh"
  jq -nc '
    {hooks: {
      PreToolUse: [{matcher: "Bash", hooks: [
        {id: "fixture-one", script: ".claude/hooks/fixture-one.sh", timeout: 7, gated: false, runner: "exec", args: ["PreToolUse"]},
        {id: "fixture-two", script: ".claude/hooks/fixture-two.sh", timeout: 7, gated: false, runner: "exec", args: ["PreToolUse"]}
      ]}],
      PostToolUse: [{matcher: "Bash", hooks: [
        {id: "inject-policy-on-trigger", script: ".claude/hooks/inject-policy-on-trigger.sh", timeout: 20, gated: false, runner: "exec", args: ["PostToolUse"]}
      ]}]
    }}' > "$fix/.claude/hooks/hook-registry.json"
}
payload() { # <fixture> <session> <event>
  jq -nc --arg d "$1" --arg s "$2" --arg e "$3" \
    '{session_id:$s,hook_event_name:$e,tool_name:"Bash",cwd:$d,tool_input:{command:"git push origin test"},tool_response:{stdout:"completed"}}'
}
# dispatch <fixture> <session> <event> [ENV=VALUE ...] -> RC. The timeout
# sentry is on unless an ENV argument turns it off.
dispatch() {
  local fix="$1" sid="$2" hook_event="$3"
  shift 3
  RC=0
  payload "$fix" "$sid" "$hook_event" | (cd "$fix" && env HOME="$FAKE_HOME" XDG_CACHE_HOME="$CACHE" \
    PATH="$SHIMS:$PATH" HQ_HOOK_PROFILE=standard CLAUDE_PROJECT_DIR="$fix" HQ_ROOT="$fix" HQ_HARNESS=claude \
    HQ_HOOK_DEDUPE=0 HQ_HOOK_TIMEOUT_SENTRY=1 HQ_DISABLED_HOOKS= HQ_FLAGS_API_URL= HQ_COMPANY_UID= \
    "$@" "$TEST_BASH" "$fix/.claude/hooks/master-hook.sh" "$hook_event") \
    >"$TMP/out" 2>"$TMP/err" || RC=$?
}
lines() { [ -f "$1" ] || { echo 0; return; }; "$REAL_WC" -l < "$1" | tr -d '[:space:]'; }
bytes() { [ -f "$1" ] || { echo 0; return; }; "$REAL_WC" -c < "$1" | tr -d '[:space:]'; }
now_s() { date +%s; }
session_file() { # <journal dir> <name pattern>
  find "$1" -maxdepth 1 -type f -name "$2" ! -name '*.debug.tsv' 2>/dev/null | head -n 1
}

FIX="$TMP/hq"
make_fixture "$FIX"
JOURNAL="$FIX/workspace/.hook-timeout-journal"
run() { dispatch "$FIX" size-bound PreToolUse; }
ran() { [ -f "$FIX/.claude/hooks/ran.log" ] || { echo 0; return; }; grep -c "^$1\$" "$FIX/.claude/hooks/ran.log" || true; }
reset_logs() { rm -f "$FIX/.claude/hooks/ran.log" "$TMP/wc.log"; }
both_ran() { [ "$RC" = "0" ] && [ "$(ran fixture-one)" = "1" ] && [ "$(ran fixture-two)" = "1" ]; }
run_detail() { printf 'rc=%s ran=%s/%s err=%s' "$RC" "$(ran fixture-one)" "$(ran fixture-two)" "$(head -c 300 "$TMP/err")"; }
# plant <count> <tag>: journal rows in the dispatcher's seven-field form, the
# hook named <tag>-<n>.sh, appended to the session journal.
plant() {
  awk -v n="$1" -v tag="$2" 'BEGIN { for (i = 1; i <= n; i++) printf "%s-%d.sh\tPreToolUse\t1\tplanted\t0\t0\t-\n", tag, i }' >> "$TSV"
}
stamp_back() { printf '%s\n' "$(( $(now_s) - INTERVAL_SECONDS - 60 ))" > "$STAMP_FILE"; }

echo "[a] a new session"
reset_logs
run
both_ran && ok "both hooks ran (rc 0)" || bad "$(run_detail)"
TSV="$(session_file "$JOURNAL" '*.tsv')"
[ -n "$TSV" ] && [ "$(lines "$TSV")" = "2" ] && ok "the session journal has one row per hook" \
  || bad "no session journal with 2 rows in $JOURNAL (the timeout sentry is off here, so the fixture is not exercising the journal)"
[ -n "$TSV" ] || { echo; echo "passed: $pass  failed: $fail"; exit 1; }
STAMP_FILE="$TSV.compact-stamp"
[ ! -e "$STAMP_FILE" ] && ok "the first event, which has no journal yet, writes no compaction stamp" \
  || bad "the first event wrote a compaction stamp before the journal existed"
reset_logs
run
[ -s "$STAMP_FILE" ] && ok "the second event writes the compaction stamp" || bad "no compaction stamp at $STAMP_FILE"
[ "$(lines "$TSV")" = "4" ] && ok "rows are appended (4 after two events)" || bad "$(lines "$TSV") rows after two events, expected 4"
[ "$(wc_starts)" = "0" ] && ok "a session with a new stamp starts no wc" \
  || bad "the event that wrote the stamp started wc $(wc_starts) time(s)"

echo "[b] a stamp older than the interval"
: > "$TSV"
plant 500 old
stamp_back
before_s="$(now_s)"
reset_logs
run
both_ran && ok "dispatch rc 0, both hooks ran" || bad "$(run_detail)"
[ "$(lines "$TSV")" = "$((KEEP + 2))" ] && ok "500 rows cut to the newest $KEEP, plus this event's 2" \
  || bad "$(lines "$TSV") rows after a due dispatch, expected $((KEEP + 2))"
first="$(head -n 1 "$TSV" | cut -f1)"
[ "$first" = "old-$((500 - KEEP + 1)).sh" ] && ok "the rows kept are the newest ones (first is $first)" \
  || bad "the first row kept is '$first', expected old-$((500 - KEEP + 1)).sh"
last_two="$(tail -n 2 "$TSV" | cut -f1 | tr '\n' ' ')"
[ "$last_two" = "fixture-one.sh fixture-two.sh " ] && ok "this event's rows follow the kept rows" \
  || bad "the last two rows are '$last_two'"
stamp_value="$(head -n 1 "$STAMP_FILE" 2>/dev/null | tr -d '[:space:]')"
case "$stamp_value" in
  ''|*[!0-9]*) bad "the stamp does not hold a time: '$stamp_value'" ;;
  *) [ "$stamp_value" -ge "$before_s" ] && ok "the stamp is refreshed" \
      || bad "the stamp still holds the old time ($stamp_value)" ;;
esac
[ "$(wc_starts)" = "1" ] && ok "a due event starts wc once" || bad "a due event started wc $(wc_starts) time(s), expected 1"
[ ! -e "$TSV.lock" ] && ok "the compaction lock is released" || bad "the compaction lock was left at $TSV.lock"
leftover="$(find "$JOURNAL" -maxdepth 1 -name '*.tmp.*' 2>/dev/null | grep -c . || true)"
[ "$leftover" = "0" ] && ok "no temporary file is left" || bad "$leftover temporary file(s) left in $JOURNAL"

echo "[c] a fresh stamp"
plant 500 fresh
stamp_before="$(cat "$STAMP_FILE")"
reset_logs
run
both_ran && ok "dispatch rc 0, both hooks ran" || bad "$(run_detail)"
[ "$(lines "$TSV")" = "$((KEEP + 2 + 500 + 2))" ] && ok "the journal is left alone until the interval has passed" \
  || bad "$(lines "$TSV") rows, expected $((KEEP + 2 + 500 + 2)): the journal is compacted on every event"
[ "$(wc_starts)" = "0" ] && ok "an event that is not due starts no wc" \
  || bad "an event that is not due started wc $(wc_starts) time(s)"
[ "$(cat "$STAMP_FILE")" = "$stamp_before" ] && ok "the stamp is not rewritten" || bad "the stamp was rewritten on an event that is not due"
printf 'not-a-number\n' > "$STAMP_FILE"
run
[ "$(lines "$TSV")" = "$((KEEP + 2))" ] && ok "an unreadable stamp is treated as due" \
  || bad "unreadable stamp: $(lines "$TSV") rows, expected $((KEEP + 2))"

echo "[d] a long session"
# 120 events, with the stamp set back every 20 events to stand for the
# interval passing. Without the timer the journal ends at 240 rows or more.
EVENTS=120
PER_INTERVAL=20
LIMIT=$((KEEP + 2 * PER_INTERVAL + 2))
: > "$TSV"
stamp_back
max_rows=0
failed_runs=0
i=0
while [ "$i" -lt "$EVENTS" ]; do
  i=$((i + 1))
  run
  [ "$RC" = "0" ] || failed_runs=$((failed_runs + 1))
  rows="$(lines "$TSV")"
  [ "$rows" -le "$max_rows" ] || max_rows="$rows"
  [ $((i % PER_INTERVAL)) -ne 0 ] || stamp_back
done
[ "$failed_runs" = "0" ] && ok "$EVENTS dispatches, all rc 0" || bad "$failed_runs of $EVENTS dispatches failed"
[ "$max_rows" -le "$LIMIT" ] && ok "the journal never held more than $max_rows rows (limit $LIMIT: $KEEP plus one interval's rows)" \
  || bad "the journal reached $max_rows rows (limit $LIMIT)"
echo "     journal after $EVENTS events: $(lines "$TSV") rows, $(bytes "$TSV") bytes; without the timer: $((2 * EVENTS)) rows"

echo "[e] rows written by the adapter core"
# The Codex and Grok adapters write their registry hooks' rows to the same
# journal with hqad_event_watchdog_child_end, then run master-hook.sh for the
# event.
cat > "$TMP/adapter-rows.sh" <<'EOF'
#!/usr/bin/env bash
# adapter-rows.sh <adapter core> <journal> <rows>
. "$1" || exit 1
HQAD_EVENT_WATCHDOG_JOURNAL_FILE="$2"
HQAD_EVENT_WATCHDOG_ACTIVE_FILE="$2.adapterinvocation.active"
HQAD_EVENT_WATCHDOG_INVOCATION_ID=adapterinvocation
i=0
while [ "$i" -lt "$3" ]; do
  i=$((i + 1))
  hqad_event_watchdog_child_start "adapter-hook-$i.sh" PreToolUse
  hqad_event_watchdog_child_end
done
rm -f "$HQAD_EVENT_WATCHDOG_ACTIVE_FILE"
EOF
: > "$TSV"
HQ_ROOT="$FIX" "$TEST_BASH" "$TMP/adapter-rows.sh" "$FIX/core/scripts/lib/hook-adapter-core.sh" "$TSV" 150 >/dev/null 2>"$TMP/adapter.err"
adapter_rows="$(lines "$TSV")"
[ "$adapter_rows" = "150" ] && ok "the adapter core wrote 150 rows to the session journal" \
  || bad "the adapter core wrote $adapter_rows rows, expected 150: $(head -c 300 "$TMP/adapter.err")"
stamp_back
reset_logs
run
both_ran && ok "dispatch rc 0, both hooks ran" || bad "$(run_detail)"
[ "$(lines "$TSV")" = "$((KEEP + 2))" ] && ok "the dispatcher cut the adapter's rows to the newest $KEEP" \
  || bad "$(lines "$TSV") rows after a due dispatch, expected $((KEEP + 2))"
[ "$(head -n 1 "$TSV" | cut -f1)" = "adapter-hook-$((150 - KEEP + 1)).sh" ] && ok "the adapter rows kept are the newest ones" \
  || bad "the first row kept is '$(head -n 1 "$TSV" | cut -f1)'"

echo "[f] the compaction lock"
: > "$TSV"
plant 300 held
mkdir -p "$TSV.lock"
printf '%s\n' "$$" > "$TSV.lock/pid"
stamp_back
reset_logs
run
both_ran && ok "a lock held by a live process: dispatch rc 0, both hooks ran" || bad "$(run_detail)"
[ "$(lines "$TSV")" = "302" ] && ok "the journal is not cut while another process holds the lock" \
  || bad "$(lines "$TSV") rows with the lock held, expected 302"
[ "$(cat "$TSV.lock/pid" 2>/dev/null)" = "$$" ] && ok "the live owner's lock is left in place" \
  || bad "the live owner's lock was removed or rewritten"
( : ) &
dead_pid=$!
wait "$dead_pid" 2>/dev/null
printf '%s\n' "$dead_pid" > "$TSV.lock/pid"
stamp_back
reset_logs
run
both_ran && ok "a lock left by a dead process: dispatch rc 0, both hooks ran" || bad "$(run_detail)"
[ "$(lines "$TSV")" = "$((KEEP + 2))" ] && ok "the dead owner's lock is replaced and the journal is cut" \
  || bad "$(lines "$TSV") rows with a dead lock owner, expected $((KEEP + 2))"
[ ! -e "$TSV.lock" ] && ok "the lock is released afterwards" || bad "the lock was left at $TSV.lock"

echo "[g] the metadata file"
POLICY_LINES='policy_trigger_script=inject-policy-on-trigger.sh
policy_trigger_event=PostToolUse
ledger_bytes_bucket=<16K
facts_bytes_bucket=<16K'
# inject <root> <session>: the injector with no master hook, as an adapter
# runtime starts it (no HQ_HOOK_TIMEOUT_JOURNAL_FILE in the environment).
inject() {
  payload "$1" "$2" PostToolUse | (unset HQ_HOOK_TIMEOUT_JOURNAL_FILE; env HOME="$FAKE_HOME" XDG_CACHE_HOME="$CACHE" \
    PATH="$TMP/bin:$PATH" HQ_ROOT="$1" CLAUDE_PROJECT_DIR="$1" HQ_HARNESS=codex \
    "$TEST_BASH" "$INJECTOR") >/dev/null 2>"$TMP/inject.err"
}
ALONE="$TMP/alone"
mkdir -p "$ALONE/core/policies"
cp "$FIX/core/policies/size-bound-fixture.md" "$ALONE/core/policies/"
ALONE_JOURNAL="$ALONE/workspace/.hook-timeout-journal"
inject_failed=0
i=0
while [ "$i" -lt 30 ]; do
  i=$((i + 1))
  inject "$ALONE" meta-alone || inject_failed=$((inject_failed + 1))
done
[ "$inject_failed" = "0" ] && ok "the injector ran 30 times with no master hook (rc 0)" \
  || bad "$inject_failed of 30 injector runs failed: $(head -c 300 "$TMP/inject.err")"
META="$(session_file "$ALONE_JOURNAL" '*.tsv.meta')"
if [ -n "$META" ]; then
  [ "$(lines "$META")" = "6" ] && ok "30 runs leave 6 lines in the metadata file ($(bytes "$META") bytes)" \
    || bad "30 runs left $(lines "$META") lines ($(bytes "$META") bytes), expected 6: the injector appends on every run"
  expected="$(printf 'bash_env_set=unset\ntiming_precision=ms\n%s' "$POLICY_LINES")"
  [ "$(cat "$META")" = "$expected" ] && ok "the file holds the default runtime lines and one set of policy lines" \
    || bad "unexpected metadata content: $(tr '\n' '|' < "$META" | head -c 300)"
  [ -z "$(session_file "$ALONE_JOURNAL" '*.tsv')" ] && ok "the session has no journal, as on a run with no master hook" \
    || bad "fixture: a journal was written beside the metadata file"

  printf 'bash_env_set=set\ntiming_precision=s\n' > "$META"
  awk 'BEGIN { for (i = 0; i < 3; i++) printf "policy_trigger_script=inject-policy-on-trigger.sh\npolicy_trigger_event=UserPromptSubmit\nledger_bytes_bucket=>128K\nfacts_bytes_bucket=16-64K\n" }' >> "$META"
  inject "$ALONE" meta-alone
  expected="$(printf 'bash_env_set=set\ntiming_precision=s\n%s' "$POLICY_LINES")"
  [ "$(cat "$META")" = "$expected" ] && ok "the runtime lines written by the master hook are kept and old policy lines replaced" \
    || bad "unexpected metadata content: $(tr '\n' '|' < "$META" | head -c 300)"

  printf 'bash_env_set=set\ntiming_precision=s\n' > "$META"
  awk 'BEGIN { for (i = 0; i < 20000; i++) printf "policy_trigger_script=inject-policy-on-trigger.sh\npolicy_trigger_event=PreToolUse\nledger_bytes_bucket=16-64K\nfacts_bytes_bucket=<16K\n" }' >> "$META"
  grown="$(bytes "$META")"
  inject "$ALONE" meta-alone
  [ "$(cat "$META")" = "$expected" ] && ok "a file that grew to $grown bytes under the old append is rewritten to $(bytes "$META") bytes by one run" \
    || bad "the grown file has $(lines "$META") lines after one run, expected 6"
else
  bad "the injector wrote no metadata file in $ALONE_JOURNAL: $(head -c 300 "$TMP/inject.err")"
fi

# master-hook.sh with the injector as its registry hook.
FIX2="$TMP/hq2"
make_fixture "$FIX2"
JOURNAL2="$FIX2/workspace/.hook-timeout-journal"
failed_runs=0
i=0
while [ "$i" -lt 10 ]; do
  i=$((i + 1))
  dispatch "$FIX2" meta-sentry-off PostToolUse HQ_HOOK_TIMEOUT_SENTRY=0
  [ "$RC" = "0" ] || failed_runs=$((failed_runs + 1))
done
[ "$failed_runs" = "0" ] && ok "sentry off: 10 PostToolUse dispatches, all rc 0" \
  || bad "sentry off: $failed_runs of 10 dispatches failed: $(head -c 300 "$TMP/err")"
META2="$(session_file "$JOURNAL2" '*.tsv.meta')"
if [ -n "$META2" ]; then
  [ "$(lines "$META2")" = "6" ] && ok "sentry off: 10 events leave 6 lines in the metadata file" \
    || bad "sentry off: 10 events left $(lines "$META2") lines, expected 6"
  [ -z "$(session_file "$JOURNAL2" '*.tsv')" ] && ok "sentry off: master-hook.sh keeps no journal, so it does not rewrite the file" \
    || bad "fixture: a journal was written with the sentry off"
else
  bad "sentry off: the injector wrote no metadata file in $JOURNAL2"
fi
rm -rf "$JOURNAL2"
failed_runs=0
i=0
while [ "$i" -lt 5 ]; do
  i=$((i + 1))
  dispatch "$FIX2" meta-sentry-on PostToolUse
  [ "$RC" = "0" ] || failed_runs=$((failed_runs + 1))
done
[ "$failed_runs" = "0" ] && ok "sentry on: 5 PostToolUse dispatches, all rc 0" \
  || bad "sentry on: $failed_runs of 5 dispatches failed: $(head -c 300 "$TMP/err")"
META2="$(session_file "$JOURNAL2" '*.tsv.meta')"
if [ -n "$META2" ]; then
  [ "$(lines "$META2")" = "6" ] && ok "sentry on: 5 events leave 6 lines in the metadata file" \
    || bad "sentry on: 5 events left $(lines "$META2") lines, expected 6"
  [ "$(sed -n '1p' "$META2" | cut -d= -f1)" = "bash_env_set" ] && [ "$(sed -n '2p' "$META2" | cut -d= -f1)" = "timing_precision" ] \
    && [ "$(tail -n 4 "$META2")" = "$POLICY_LINES" ] \
    && ok "sentry on: master-hook.sh's runtime lines head the file, followed by one set of policy lines" \
    || bad "sentry on: unexpected metadata content: $(tr '\n' '|' < "$META2" | head -c 300)"
  [ -n "$(session_file "$JOURNAL2" '*.tsv')" ] && ok "sentry on: the injector's row is in the session journal" \
    || bad "sentry on: no session journal in $JOURNAL2"
else
  bad "sentry on: no metadata file in $JOURNAL2"
fi

echo
echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]
