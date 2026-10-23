#!/usr/bin/env bash
# Pins the critical-channel path and the answered-in-source guard, the two
# fixes from the 2026-10-20 latency evaluation (owner: "still too slow to
# surface hq dms from team on critical channels", "decisions are being
# surfaced minutes after I already answered them in the source session"):
#   - prefs.mjs critical prints "<channels>\t<team>\t<max_delay>";
#   - a message on a critical channel prints a SUPER-CONDUCTOR CRITICAL line
#     at once even while --min-wake-gap holds a normal item back;
#   - an HQ DM from a listed teammate is critical; one from anyone else is not;
#   - critical ledger rows carry priority: critical and every row seen_at;
#   - requests.mjs list --priority critical keeps only those rows;
#   - a channel read asks for 50 messages, not 10;
#   - with critical channels set, the watcher stays on --interval when away;
#   - the heartbeat passes --critical/--team from the settings and clamps the
#     watch interval to max_delay/2;
#   - open-asks.mjs check exits 3 while an ask is open, 0 with answered_at once
#     its tool_result exists, and a queued ask the owner answered in its own
#     window is closed by `watch` with one ASK-ANSWERED line, printed once;
#   - the triage daemon and the answer watch start under the heartbeat with
#     the same --parent-pid as the other watchers (the winpid under MSYS),
#     relay an answered decision as one ANSWER line, triage new rows, stop on
#     TERM with no EXITED line, and print TRIAGE-EXITED when killed;
#   - a next-step card is answered by a later owner turn or a conductor relay,
#     not by its own tool_result, a reminder, or a sibling session's relay;
#   - a post that is only a link is work, never closed as fyi.
# Review fixes from hq-core-staging #1490 (reviewer, 2026-10-20).
set -uo pipefail

ROOT="${HQ_TEST_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
WATCH="$ROOT/core/scripts/super-conductor-message-watch.mjs"
PREFS="$ROOT/core/scripts/super-conductor-prefs.mjs"
RQ="$ROOT/core/scripts/super-conductor-requests.mjs"
OA="$ROOT/core/scripts/super-conductor-open-asks.mjs"
HB="$ROOT/core/scripts/super-conductor-heartbeat.sh"
tmp="$(mktemp -d)"
hb_pid=""
trap '[[ -n "$hb_pid" ]] && kill "$hb_pid" 2>/dev/null; rm -rf "$tmp"' EXIT
fail=0
check() { if [[ "$2" -ne 0 ]]; then echo "FAIL: $1" >&2; fail=1; fi; }

# 1. prefs: the critical line.
cat >"$tmp/prefs.yaml" <<'EOF'
channels:
  - hq_dms
work_hours: {timezone: UTC, days: sun-sat, start: "00:00", end: "24:00"}
critical_channels:
  - hq_channel:project-core-pr-reviews-6e234042
  - hq_dm:team
team:
  - Sam Rivera
  - Kai Osei
critical_wake:
  max_delay: 40
EOF
out="$(node "$PREFS" --file "$tmp/prefs.yaml" critical)"
check "prefs critical prints channels, team and max_delay (got: $out)" "$([[ "$out" == $'hq_channel:project-core-pr-reviews-6e234042,hq_dm:team\tSam Rivera,Kai Osei\t40' ]]; echo $?)"
printf 'channels:\n  - hq_dms\n' >"$tmp/none.yaml"
out="$(node "$PREFS" --file "$tmp/none.yaml" critical)"
check "prefs critical is empty fields with the default delay when unset (got: $out)" "$([[ "$out" == $'\t\t60' ]]; echo $?)"

# Fake hq, as in the message-watch test.
mkdir -p "$tmp/fx"
cat >"$tmp/hq" <<'EOF'
#!/usr/bin/env bash
fx="$(dirname "$0")/fx"
echo "$*" >>"$(dirname "$0")/calls"
case "$1 $2" in
  "whoami --json") cat "$fx/whoami.json" ;;
  "dm inbox") cat "$fx/inbox.json" ;;
  "channels changes") if [[ "${3:-}" == --cursor ]]; then cat "$fx/delta.json"; else cat "$fx/snapshot.json"; fi ;;
  "dm channel") cat "$fx/chan-$3.json" ;;
  *) echo "unexpected: $*" >&2; exit 9 ;;
esac
EOF
chmod +x "$tmp/hq"
export HQ_BIN="$tmp/hq"
mkdir -p "$tmp/root/companies"
printf 'companies:\n  co-a:\n    cloud_uid: cmp_co-a\n' >"$tmp/root/companies/manifest.yaml"
export HQ_ROOT="$tmp/root"
export SC_PREFS_FILE="$tmp/prefs.yaml"
echo '{"personUid":"prs_owner","email":"owner@example.com"}' >"$tmp/fx/whoami.json"
echo '[]' >"$tmp/fx/inbox.json"
cat >"$tmp/fx/snapshot.json" <<'EOF'
{"snapshot":true,"cursor":"c1","rows":[
 {"channelId":"chn_rev","type":"project","companyUid":"cmp_co-a","slug":"project-core-pr-reviews-6e234042","name":"Project core-pr-reviews","lastHumanMessageAt":"2026-10-20T10:00:00Z"},
 {"channelId":"chn_dev","type":"company","companyUid":"cmp_co-a","slug":"hq-dev","name":"hq-dev","lastHumanMessageAt":"2026-10-20T10:00:00Z"}
],"changed":[],"removedChannelIds":[]}
EOF
echo '{"snapshot":false,"cursor":"c2","rows":[],"changed":[],"removedChannelIds":[]}' >"$tmp/fx/delta.json"
L="$tmp/requests.jsonl"
run() { node "$WATCH" --state "$tmp/state.json" --company co-a --min-wake-gap 3600 --ledger "$L" --critical hq_channel:project-core-pr-reviews-6e234042,hq_dm:team --team "sam rivera,kai osei" --once; }

out="$(run)"
check "baseline prints nothing (got: $out)" "$([[ -z "$out" ]]; echo $?)"

# 2. A normal channel post is held by the gap; a review-channel post prints CRITICAL now.
cat >"$tmp/fx/delta.json" <<'EOF'
{"snapshot":false,"cursor":"c3","rows":[],"removedChannelIds":[],"changed":[
 {"channelId":"chn_dev","type":"company","companyUid":"cmp_co-a","slug":"hq-dev","name":"hq-dev","lastHumanMessageAt":"2026-10-20T15:00:00Z"},
 {"channelId":"chn_rev","type":"project","companyUid":"cmp_co-a","slug":"project-core-pr-reviews-6e234042","name":"Project core-pr-reviews","lastHumanMessageAt":"2026-10-20T15:00:10Z"}
]}
EOF
echo '[{"eventId":"dev_1","fromPersonUid":"prs_l","fromDisplayName":"Lizzie","text":"design round posted","createdAt":"2026-10-20T15:00:00Z"}]' >"$tmp/fx/chan-chn_dev.json"
echo '[{"eventId":"rev_1","fromPersonUid":"prs_s","fromDisplayName":"Kai Osei","text":"Review please: https://github.com/x/y/pull/9","createdAt":"2026-10-20T15:00:10Z"}]' >"$tmp/fx/chan-chn_rev.json"
# The gap clock starts now: a MESSAGE line would be held for an hour.
node -e 'const f=process.argv[1];const s=JSON.parse(require("fs").readFileSync(f));s.last_wake_at=new Date().toISOString();require("fs").writeFileSync(f,JSON.stringify(s))' "$tmp/state.json"
rm -f "$tmp/calls"
out="$(run)"
grep -q '^SUPER-CONDUCTOR CRITICAL .* 1 critical: #project-core-pr-reviews-6e234042 (Kai Osei) |' <<<"$out"; check "a review-channel post prints a CRITICAL line at once (got: $out)" $?
check "the normal post is still held by the gap (got: $out)" "$(! grep -q 'SUPER-CONDUCTOR MESSAGE' <<<"$out"; echo $?)"
grep -q 'dm channel chn_rev --json --limit 50' "$tmp/calls"; check "a channel read asks for 50 messages" $?
crit="$(node "$RQ" list --file "$L" --json --priority critical)"
grep -q '"ref":"rev_1"' <<<"$crit" && ! grep -q '"ref":"dev_1"' <<<"$crit"; check "only the review-channel row is priority critical (got: $crit)" $?
grep -q '"priority":"critical"' <<<"$crit"; check "the critical row carries priority: critical" $?
grep -q '"kind":"decision"' <<<"$crit"; check "Review please is guessed as a decision" $?
all="$(node "$RQ" list --file "$L" --json)"
check "every row carries seen_at" "$([[ "$(grep -c '"seen_at":"' <<<"$all")" -eq 2 ]]; echo $?)"

# 3. A team DM is critical; a DM from anyone else is not.
cat >"$tmp/fx/inbox.json" <<'EOF'
[{"eventId":"dm_sam","fromPersonUid":"prs_sr","fromDisplayName":"Sam Rivera","text":"go on 1456 canary?","createdAt":"2026-10-20T15:01:00Z"},
 {"eventId":"dm_other","fromPersonUid":"prs_o","fromDisplayName":"Jonathan Drake","text":"llms.txt PRs ready","createdAt":"2026-10-20T15:01:01Z"}]
EOF
out="$(run)"
grep -q 'SUPER-CONDUCTOR CRITICAL .* 1 critical: DM from Sam Rivera |' <<<"$out"; check "a team DM prints CRITICAL (got: $out)" $?
check "the non-team DM is held by the gap (got: $out)" "$(! grep -q 'DM from Jonathan' <<<"$out"; echo $?)"
out="$(run)"
check "a reported critical item never prints twice (got: $out)" "$([[ -z "$out" ]]; echo $?)"

# 4. Away cadence: with critical channels the poll stays on --interval.
printf 'work_hours: {timezone: UTC, days: mon-fri, start: "09:00", end: "09:01"}\ncritical_channels: [hq_dm:team]\n' >"$tmp/away.yaml"
SC_PREFS_FILE="$tmp/away.yaml" node "$WATCH" --state "$tmp/state2.json" --company co-a --interval 1 --away-interval 30 --critical hq_dm:team --parent-pid $$ >"$tmp/away.out" 2>&1 &
wp=$!
sleep 4
kill "$wp" 2>/dev/null; wait "$wp" 2>/dev/null
polls="$(grep -c 'dm inbox' "$tmp/calls")"
check "away with critical channels still polls every --interval (inbox reads in 4s: $polls)" "$([[ "$polls" -ge 4 ]]; echo $?)"

# 5. The heartbeat passes the settings to the watcher and clamps the interval.
rm -f "$tmp/calls"
SC_PREFS_FILE="$tmp/prefs.yaml" bash "$HB" --interval 60 --message-watch "$tmp/hb-state.json" --company co-a --state "$tmp/hb-save-state.json" >"$tmp/hb.out" 2>&1 &
hb_pid=$!
args=""
for _ in $(seq 1 50); do
  wp="$(pgrep -f "message-watch.mjs --state $tmp/hb-state.json" | head -n1)"
  [[ -n "$wp" ]] && { args="$(ps -o args= -p "$wp")"; break; }
  sleep 0.1
done
grep -q -- '--critical hq_channel:project-core-pr-reviews-6e234042,hq_dm:team' <<<"$args"; check "the heartbeat passes --critical from the settings (got: $args)" $?
grep -q -- '--team Sam Rivera,Kai Osei' <<<"$args"; check "the heartbeat passes --team from the settings" $?
grep -q -- '--interval 20 ' <<<"$args"; check "the watch interval is clamped to max_delay/2 (got: $args)" $?
kill "$hb_pid" 2>/dev/null; wait "$hb_pid" 2>/dev/null; hb_pid=""

# 6. open-asks: check and the ASK-ANSWERED wake.
mkdir -p "$tmp/tx"
picker() { printf '{"type":"assistant","timestamp":"%s","message":{"role":"assistant","content":[{"type":"tool_use","id":"tu_%s","name":"AskUserQuestion","input":{"questions":[{"question":"%s","options":[{"label":"A"},{"label":"B"}]}]}}]}}\n' "$1" "$2" "$3"; }
result() { printf '{"type":"user","timestamp":"%s","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"tu_%s","content":"A"}]}}\n' "$1" "$2"; }
human() { printf '{"type":"user","turnOrigin":"human","timestamp":"%s","message":{"role":"user","content":"%s"}}\n' "$1" "$2"; }
{ human 2026-10-20T16:37:00Z go; picker 2026-10-20T16:37:50Z 1 "Re-run the speed test?"; } >"$tmp/tx/s-open.jsonl"
node "$OA" check --session s-open --ask-id tu_1 --dir "$tmp/tx" >"$tmp/chk.out" 2>&1; rc=$?
check "check exits 3 while the ask is open (rc $rc)" "$([[ $rc -eq 3 ]]; echo $?)"
node "$OA" check --session s-missing --ask-id tu_1 --dir "$tmp/tx" >/dev/null 2>&1; rc=$?
check "check exits 2 for a missing transcript (rc $rc)" "$([[ $rc -eq 2 ]]; echo $?)"
A="$tmp/asks.json"; S="$tmp/seen.json"
node "$OA" mark --state "$A" --session s-open --ask-id tu_1 --status queued --title "unstick own PRs" >/dev/null
out="$(node "$OA" watch --company co-a --dir "$tmp/tx" --state "$A" --seen "$S" --once --max-age-hours 100000)"
check "watch prints no ASK-ANSWERED while the ask is open (got: $out)" "$(! grep -q ASK-ANSWERED <<<"$out"; echo $?)"
result 2026-10-20T16:39:13Z 1 >>"$tmp/tx/s-open.jsonl"
out="$(node "$OA" check --session s-open --ask-id tu_1 --dir "$tmp/tx")"; rc=$?
check "check exits 0 with answered_at once the tool_result exists (rc $rc, got: $out)" "$([[ $rc -eq 0 ]] && grep -q '"answered_at":"2026-10-20T16:39:13Z"' <<<"$out"; echo $?)"
out="$(node "$OA" watch --company co-a --dir "$tmp/tx" --state "$A" --seen "$S" --once --max-age-hours 100000)"
grep -q '^SUPER-CONDUCTOR ASK-ANSWERED .* unstick own PRs answered its own picker at 2026-10-20T16:39:13Z | ask_id tu_1 |' <<<"$out"; check "watch closes the queued ask with one ASK-ANSWERED line (got: $out)" $?
grep -q '"status": "answered_in_source"' "$A"; check "the ask is recorded answered_in_source" $?
out="$(node "$OA" watch --company co-a --dir "$tmp/tx" --state "$A" --seen "$S" --once --max-age-hours 100000)"
check "ASK-ANSWERED is printed once (got: $out)" "$([[ -z "$out" ]]; echo $?)"
node "$OA" mark --state "$A" --session s-open --ask-id tu_1 --status relayed >/dev/null 2>&1; rc=$?
check "an answered_in_source ask cannot be marked relayed afterwards (rc $rc)" "$([[ $rc -eq 3 ]]; echo $?)"

# 7. The triage daemon and the answer watch start under the heartbeat, get the
#    same parent pid as the other watchers (the winpid under MSYS), stop on
#    TERM without an EXITED line, and print EXITED when they die.
echo '[]' >"$tmp/fx/inbox.json"
sleep 30 & fake_win=$!
hb_tmp="$tmp/hb2"; mkdir -p "$hb_tmp"
SC_PROC_ROOT="$tmp/proc" SC_PREFS_FILE="$tmp/none.yaml" SC_TRIAGE_INTERVAL=1 SC_ANSWER_WATCH_INTERVAL=1 \
  bash -c 'mkdir -p "$SC_PROC_ROOT/$$"; echo "'"$fake_win"'" >"$SC_PROC_ROOT/$$/winpid"; exec bash "$0" "$@"' \
  "$HB" --interval 3600 --channels hq_dms --message-watch "$hb_tmp/cl-x-message-watch.json" --state "$hb_tmp/cl-x-state.json" --company co-a >"$hb_tmp/out" 2>&1 &
hb_pid=$!
tri=""; ans=""
for _ in $(seq 1 50); do
  tri="$(pgrep -f "super-conductor-triage.mjs watch --ledger $hb_tmp/cl-x-requests.jsonl" | head -n1)"
  ans="$(pgrep -f "super-conductor-decisions.mjs watch --file $hb_tmp/cl-x-decisions.jsonl --for conductor" | head -n1)"
  [[ -n "$tri" && -n "$ans" ]] && break
  sleep 0.1
done
check "the heartbeat starts the triage daemon (pid: '$tri')" "$([[ -n "$tri" ]]; echo $?)"
check "the heartbeat starts the answer watch (pid: '$ans')" "$([[ -n "$ans" ]]; echo $?)"
targs="$(ps -o args= -p "${tri:-0}" 2>/dev/null)"; aargs="$(ps -o args= -p "${ans:-0}" 2>/dev/null)"
grep -q -- "--parent-pid $fake_win" <<<"$targs"; check "the triage daemon gets the winpid as --parent-pid (got: $targs)" $?
grep -q -- "--parent-pid $fake_win" <<<"$aargs"; check "the answer watch gets the winpid as --parent-pid (got: $aargs)" $?
# A decision answered while the heartbeat runs reaches the conductor as one ANSWER line.
DQ="$hb_tmp/cl-x-decisions.jsonl"
node "$ROOT/core/scripts/super-conductor-decisions.mjs" add --file "$DQ" --source conductor --ref t1 --question "Merge it?" --option Merge --option Hold --relay-child child-a >/dev/null
did="$(node "$ROOT/core/scripts/super-conductor-decisions.mjs" next --file "$DQ" --json | sed -E 's/.*"id":"([^"]+)".*/\1/')"
node "$ROOT/core/scripts/super-conductor-decisions.mjs" claim --file "$DQ" --id "$did" --desk desk >/dev/null
node "$ROOT/core/scripts/super-conductor-decisions.mjs" answer --file "$DQ" --id "$did" --desk desk --answer Merge >/dev/null
for _ in $(seq 1 50); do grep -q 'SUPER-CONDUCTOR ANSWER' "$hb_tmp/out" && break; sleep 0.1; done
grep -q 'SUPER-CONDUCTOR ANSWER .* Merge it? → Merge | relay to child-a |' "$hb_tmp/out"; check "an answered decision prints one ANSWER line through the heartbeat (got: $(cat "$hb_tmp/out"))" $?
# A new ledger row is triaged by the daemon: an fyi closes, a bare URL stays work and open.
node "$RQ" add --file "$hb_tmp/cl-x-requests.jsonl" --source hq_channel --ref m1 --from Kai --kind work --text "#rev: In review (Kai)" --company co-a >/dev/null
node "$RQ" add --file "$hb_tmp/cl-x-requests.jsonl" --source hq_channel --ref m2 --from Sam --kind work --text "#rev: https://github.com/x/y/pull/7" --company co-a >/dev/null
for _ in $(seq 1 50); do grep -q 'SUPER-CONDUCTOR TRIAGE' "$hb_tmp/out" && break; sleep 0.1; done
grep -q 'SUPER-CONDUCTOR TRIAGE .* 2 rows: 1 fyi closed, 0 decisions queued, 1 work pending' "$hb_tmp/out"; check "the triage daemon classifies new rows under the heartbeat (got: $(grep TRIAGE "$hb_tmp/out"))" $?
rows="$(node "$RQ" list --file "$hb_tmp/cl-x-requests.jsonl" --json)"
grep -q '"ref":"m2".*"status":"new"' <<<"$rows" || grep -q '"ref":"m2"' <<<"$(node "$RQ" list --file "$hb_tmp/cl-x-requests.jsonl" --open --json)"; check "a bare-URL post is not auto-closed (got: $rows)" $?
kill -TERM "$hb_pid"; wait "$hb_pid" 2>/dev/null; hb_pid=""
sleep 0.5
check "TERM stops the triage daemon" "$(! kill -0 "$tri" 2>/dev/null; echo $?)"
check "TERM stops the answer watch" "$(! kill -0 "$ans" 2>/dev/null; echo $?)"
check "a clean stop prints no EXITED line (got: $(grep EXITED "$hb_tmp/out"))" "$(! grep -q 'EXITED' "$hb_tmp/out"; echo $?)"
kill "$fake_win" 2>/dev/null; wait "$fake_win" 2>/dev/null
# A daemon that dies on its own is reported once.
hb_tmp2="$tmp/hb3"; mkdir -p "$hb_tmp2"
SC_PREFS_FILE="$tmp/none.yaml" bash "$HB" --interval 3600 --channels hq_dms --message-watch "$hb_tmp2/cl-y-message-watch.json" --state "$hb_tmp2/cl-y-state.json" --company co-a >"$hb_tmp2/out" 2>&1 &
hb_pid=$!
tri=""
for _ in $(seq 1 50); do tri="$(pgrep -f "super-conductor-triage.mjs watch --ledger $hb_tmp2/cl-y-requests.jsonl" | head -n1)"; [[ -n "$tri" ]] && break; sleep 0.1; done
kill -KILL "$tri" 2>/dev/null
for _ in $(seq 1 50); do grep -q 'TRIAGE-EXITED' "$hb_tmp2/out" && break; sleep 0.1; done
grep -q '^SUPER-CONDUCTOR TRIAGE-EXITED .* the triage daemon stopped (exit 137)' "$hb_tmp2/out"; check "a dead triage daemon prints TRIAGE-EXITED (got: $(cat "$hb_tmp2/out"))" $?
kill -TERM "$hb_pid"; wait "$hb_pid" 2>/dev/null; hb_pid=""

# 8. answeredAt: a next-step card is answered by a later owner turn or a
#    conductor relay, not by its own tool_result, a reminder, or a sibling relay.
card() { printf '{"type":"assistant","timestamp":"%s","message":{"role":"assistant","content":[{"type":"tool_use","id":"tu_%s","name":"mcp__ccd_turn__wrap_up","input":{"recap":"r","ask":"%s","actions":[{"label":"Ship it"},{"label":"Hold"}]}}]}}\n' "$1" "$2" "$3"; }
reminder() { printf '{"type":"user","isMeta":true,"timestamp":"%s","message":{"role":"user","content":"Stop hook feedback: checkpoint"}}\n' "$1"; }
relay() { printf '{"type":"user","turnOrigin":"sdk","timestamp":"%s","message":{"role":"user","content":"<cross-session-message from=\\"%s\\" name=\\"Conduct\\">\\nOwner says: hold\\n</cross-session-message>"}}\n' "$1" "$2"; }
{ human 2026-10-20T16:00:00Z go; card 2026-10-20T16:01:00Z 9 "Ship?"; result 2026-10-20T16:01:00Z 9; reminder 2026-10-20T16:02:00Z; } >"$tmp/tx/c-open.jsonl"
node "$OA" check --session c-open --ask-id tu_9 --dir "$tmp/tx" >/dev/null 2>&1; rc=$?
check "a card's own tool_result and a reminder do not answer it (rc $rc)" "$([[ $rc -eq 3 ]]; echo $?)"
cp "$tmp/tx/c-open.jsonl" "$tmp/tx/c-sibling.jsonl"; relay 2026-10-20T16:03:00Z local_other >>"$tmp/tx/c-sibling.jsonl"
node "$OA" check --session c-sibling --ask-id tu_9 --dir "$tmp/tx" --conductor local_conductor-1 >/dev/null 2>&1; rc=$?
check "a relay from a non-conductor session does not answer a card (rc $rc)" "$([[ $rc -eq 3 ]]; echo $?)"
cp "$tmp/tx/c-open.jsonl" "$tmp/tx/c-relayed.jsonl"; relay 2026-10-20T16:03:00Z local_conductor-1 >>"$tmp/tx/c-relayed.jsonl"
out="$(node "$OA" check --session c-relayed --ask-id tu_9 --dir "$tmp/tx" --conductor local_conductor-1)"; rc=$?
check "the conductor's relay answers a card (rc $rc, got: $out)" "$([[ $rc -eq 0 ]] && grep -q '"answered_at":"2026-10-20T16:03:00Z"' <<<"$out"; echo $?)"
cp "$tmp/tx/c-open.jsonl" "$tmp/tx/c-human.jsonl"; human 2026-10-20T16:04:00Z "ship it" >>"$tmp/tx/c-human.jsonl"
out="$(node "$OA" check --session c-human --ask-id tu_9 --dir "$tmp/tx")"; rc=$?
check "a later owner turn answers a card (rc $rc, got: $out)" "$([[ $rc -eq 0 ]] && grep -q '"answered_at":"2026-10-20T16:04:00Z"' <<<"$out"; echo $?)"

# 8b. A baseline poll records no sweep evidence (reviewer, #1468): the full
#     sweep still reads the inbox once, so a DM waiting at watcher start is
#     seen; the next poll records evidence as before.
echo '[]' >"$tmp/fx/inbox.json"
echo '{"snapshot":true,"cursor":"b1","rows":[],"changed":[],"removedChannelIds":[]}' >"$tmp/fx/snapshot.json"
echo '{"snapshot":false,"cursor":"b2","rows":[],"changed":[],"removedChannelIds":[]}' >"$tmp/fx/delta.json"
rm -f "$tmp/save-b.json"
node "$WATCH" --state "$tmp/state-b.json" --company co-a --min-wake-gap 0 --ledger "$tmp/led-b.jsonl" --save "$tmp/save-b.json" --once >/dev/null
sleep 1
check "a baseline poll records no hq_dms or hq_channels evidence (got: $(cat "$tmp/save-b.json" 2>/dev/null))" "$(! grep -q 'hq_dms\|hq_channels' "$tmp/save-b.json" 2>/dev/null; echo $?)"
node "$WATCH" --state "$tmp/state-b.json" --company co-a --min-wake-gap 0 --ledger "$tmp/led-b.jsonl" --save "$tmp/save-b.json" --once >/dev/null
for _ in $(seq 1 30); do grep -q 'hq_channels' "$tmp/save-b.json" 2>/dev/null && break; sleep 0.2; done
grep -q 'hq_dms' "$tmp/save-b.json" && grep -q 'hq_channels' "$tmp/save-b.json"; check "the poll after the baseline records evidence for both targets (got: $(cat "$tmp/save-b.json" 2>/dev/null))" $?

# 8c. The lock module installs its signal handlers on first use, exits with
#     the signal's own code, and replaceFile falls back to a copy on EPERM.
LOCK="$ROOT/core/scripts/lib/super-conductor-lock.mjs"
out="$(node -e 'import("'"$LOCK"'").then((m)=>{const a=process.listenerCount("SIGINT");m.withLockSync("'"$tmp"'/lk.txt",()=>{});process.stdout.write(a+","+process.listenerCount("SIGINT"))})')"
check "importing the lock installs no signal handler; the first acquire installs one (got: $out)" "$([[ "$out" == "0,1" ]]; echo $?)"
node -e 'import("'"$LOCK"'").then((m)=>{m.withLockSync("'"$tmp"'/lk2.txt",()=>{});process.stdout.write("ready\n");setTimeout(()=>{},5000)})' >"$tmp/lk.out" & lp=$!
for _ in $(seq 1 50); do grep -q ready "$tmp/lk.out" 2>/dev/null && break; sleep 0.1; done
kill -INT "$lp"; wait "$lp"; rc=$?
check "SIGINT exits 130, not 143 (rc $rc)" "$([[ $rc -eq 130 ]]; echo $?)"
check "the lock is released on SIGINT" "$(! [[ -d "$tmp/lk2.txt.lock" ]]; echo $?)"
out="$(node -e 'import("'"$LOCK"'").then((m)=>{const fs=require("fs");const real=fs.renameSync;fs.renameSync=()=>{const e=new Error("EPERM");e.code="EPERM";throw e};fs.writeFileSync("'"$tmp"'/rf.tmp","new");fs.writeFileSync("'"$tmp"'/rf.txt","old");m.replaceFile("'"$tmp"'/rf.tmp","'"$tmp"'/rf.txt");fs.renameSync=real;process.stdout.write(fs.readFileSync("'"$tmp"'/rf.txt","utf8")+","+(fs.existsSync("'"$tmp"'/rf.tmp")?"tmp-left":"tmp-gone"))})')"
check "replaceFile copies the bytes into place when rename is refused (got: $out)" "$([[ "$out" == "new,tmp-gone" ]]; echo $?)"

# 9. guessKind: a post that is only a link is work, never fyi; a status prefix
#    followed by a question or a decision word is a decision (reviewer, #1490).
out="$(node -e 'import("'"$RQ"'").then(({guessKind})=>process.stdout.write([guessKind("#rev: https://github.com/x/hq-cli/pull/2034"),guessKind("https://github.com/x/y/pull/1"),guessKind("#rev: In review (Kai)")].join(",")))')"
check "guessKind: a bare link is work, a status post is fyi (got: $out)" "$([[ "$out" == "work,work,fyi" ]]; echo $?)"
out="$(node -e 'import("'"$RQ"'").then(({guessKind})=>process.stdout.write([guessKind("FYI can you approve the prod deploy?"),guessKind("Heads up: sync is down, should we roll back?"),guessKind("FYI deployed the fix"),guessKind("Updated the README please")].join(",")))')"
check "guessKind: a status prefix with a question or decision word is a decision, a plain status is fyi, 'Updated…' is not a status word (got: $out)" "$([[ "$out" == "decision,decision,fyi,work" ]]; echo $?)"

# 10. The heartbeat reads max_delay even when the team list is empty.
printf 'channels:\n  - hq_dms\nwork_hours: {timezone: UTC, days: sun-sat, start: "00:00", end: "24:00"}\ncritical_channels:\n  - "hq_channel:project-core-pr-reviews-6e234042"\ncritical_wake:\n  max_delay: 30\n' >"$tmp/noteam.yaml"
hb_tmp3="$tmp/hb4"; mkdir -p "$hb_tmp3"
SC_PREFS_FILE="$tmp/noteam.yaml" SC_TRIAGE=0 bash "$HB" --interval 60 --message-watch "$hb_tmp3/hb-state.json" --company co-a >"$hb_tmp3/out" 2>&1 &
hb_pid=$!
args=""
for _ in $(seq 1 50); do
  wp="$(pgrep -f "message-watch.mjs --state $hb_tmp3/hb-state.json" | head -n1)"
  [[ -n "$wp" ]] && { args="$(ps -o args= -p "$wp")"; break; }
  sleep 0.1
done
grep -q -- '--interval 15 ' <<<"$args"; check "max_delay is honored with an empty team list (got: $args)" $?
check "no --team is passed when the team list is empty" "$(! grep -q -- '--team' <<<"$args"; echo $?)"
kill "$hb_pid" 2>/dev/null; wait "$hb_pid" 2>/dev/null; hb_pid=""

# 11. Triage reports row failures on stdout once per streak; a ledger-sourced
#     decision's ANSWER line names who asked and where.
TRI="$ROOT/core/scripts/super-conductor-triage.mjs"
DQ2="$tmp/dq2.jsonl"; L2="$tmp/led2.jsonl"
node "$RQ" add --file "$L2" --source hq_dm --ref q1 --from "Ada Example" --kind work --text "can you approve the deploy?" >/dev/null
node "$TRI" run --ledger "$L2" --decisions "$DQ2" --company co-a >/dev/null
out="$(node "$ROOT/core/scripts/super-conductor-decisions.mjs" next --file "$DQ2" --json)"
did="$(sed -E 's/.*"id":"([^"]+)".*/\1/' <<<"$out")"
node "$ROOT/core/scripts/super-conductor-decisions.mjs" claim --file "$DQ2" --id "$did" --desk desk >/dev/null
node "$ROOT/core/scripts/super-conductor-decisions.mjs" answer --file "$DQ2" --id "$did" --desk desk --answer "Approve" >/dev/null
rm -f "$tmp/dq2-conductor-seen.json"
out="$(node "$ROOT/core/scripts/super-conductor-decisions.mjs" watch --file "$DQ2" --for conductor --once)"
grep -q 'relay to Ada Example via hq_dm:q1 (reply where it was asked)' <<<"$out"; check "a ledger-sourced decision's ANSWER line names the asker and the source (got: $out)" $?
chmod 000 "$DQ2"
node "$RQ" add --file "$L2" --source hq_dm --ref q2 --from "Bo Example" --kind work --text "should we roll back?" >/dev/null
out="$(node "$TRI" run --ledger "$L2" --decisions "$DQ2" --company co-a 2>/dev/null)"
grep -q '^SUPER-CONDUCTOR TRIAGE-ERROR .* 1 row(s) could not be triaged' <<<"$out"; check "a row that cannot be triaged prints a TRIAGE-ERROR line on stdout (got: $out)" $?
chmod 644 "$DQ2"

if [[ "$fail" -eq 0 ]]; then echo "super-conductor-critical: ok"; else exit 1; fi
