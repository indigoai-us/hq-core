#!/usr/bin/env bash
# Pins super-conductor-open-asks.mjs, the check that finds sessions which ended
# their turn waiting on the owner:
#   - a desktop next-step box (wrap_up with ask) with nothing after it is open;
#   - an owner-typed turn, or a conductor's relayed cross-session message,
#     answers it; a cross-session message from another session does not;
#   - a wrap_up with no ask, or further tool work after the box, is not open;
#   - an unanswered AskUserQuestion is open; one with a tool_result is not;
#   - system reminders and task notifications never count as answers;
#   - --exclude and --max-age-hours skip sessions;
#   - only sessions inside the --company set are read;
#   - `mark` lets each ask be queued once and relayed once;
#   - the session id is the file name, never an id inside the transcript;
#   - a transcript over the 2 MB tail still yields its ask and its title;
#   - --dir is repeatable (worktree sessions keep their own folders).
# Regression: the System One lane sat on a wrap_up box for ~4h unseen, and
# lanes-eval stayed "open" after the conductor relayed the owner's "hold".
set -uo pipefail

ROOT="${HQ_TEST_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
OA="$ROOT/core/scripts/super-conductor-open-asks.mjs"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fail=0
check() { # description condition-exit-code
  if [[ "$2" -ne 0 ]]; then echo "FAIL: $1" >&2; fail=1; fi
}
CONDUCTOR=local_conductor-1

# Transcript builders (one JSON object per line, the desktop transcript shape).
human() { printf '{"type":"user","turnOrigin":"human","promptSource":"sdk","timestamp":"%s","message":{"role":"user","content":"<system-reminder>\\nLinked sessions now: x</system-reminder>\\n%s"}}\n' "$1" "$2"; }
relay() { printf '{"type":"user","turnOrigin":"sdk","promptSource":"sdk","timestamp":"%s","message":{"role":"user","content":"<system-reminder>\\nnote</system-reminder>\\n<cross-session-message from=\\"%s\\" name=\\"Conduct\\">\\nOwner says: %s\\n</cross-session-message>"}}\n' "$1" "$2" "$3"; }
peer_relay() { printf '{"type":"user","isMeta":true,"turnOrigin":"peer","timestamp":"%s","message":{"role":"user","content":"Another Claude session sent a message:\\n<cross-session-message from=\\"%s\\" name=\\"Conduct\\">\\nOwner approved.\\n</cross-session-message>"}}\n' "$1" "$2"; }
notice() { printf '{"type":"user","turnOrigin":"task_notification","promptSource":"system","timestamp":"%s","message":{"role":"user","content":"<task-notification>done</task-notification>"}}\n' "$1"; }
reminder() { printf '{"type":"user","isMeta":true,"timestamp":"%s","message":{"role":"user","content":"Stop hook feedback: checkpoint"}}\n' "$1"; }
card() { printf '{"type":"assistant","timestamp":"%s","message":{"role":"assistant","content":[{"type":"tool_use","id":"tu_%s","name":"mcp__ccd_turn__wrap_up","input":{"recap":"r","ask":"%s","actions":[{"label":"Ship it"},{"label":"Hold"}]}}]}}\n' "$1" "$2" "$3"; }
plain_wrap() { printf '{"type":"assistant","timestamp":"%s","message":{"role":"assistant","content":[{"type":"tool_use","id":"tu_%s","name":"mcp__ccd_turn__wrap_up","input":{"recap":"done"}}]}}\n' "$1" "$2"; }
result() { printf '{"type":"user","timestamp":"%s","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"tu_%s","content":"ok"}]}}\n' "$1" "$2"; }
tool() { printf '{"type":"assistant","timestamp":"%s","message":{"role":"assistant","content":[{"type":"tool_use","id":"tu_%s","name":"Bash","input":{"command":"ls"}}]}}\n' "$1" "$2"; }
picker() { printf '{"type":"assistant","timestamp":"%s","message":{"role":"assistant","content":[{"type":"tool_use","id":"tu_%s","name":"AskUserQuestion","input":{"questions":[{"question":"%s","options":[{"label":"A"},{"label":"B"}]}]}}]}}\n' "$1" "$2" "$3"; }
title() { printf '{"type":"custom-title","customTitle":"%s","sessionId":"%s"}\n' "$1" "$2"; }

T0=2026-10-19T14:50:00Z; T1=2026-10-19T14:53:00Z; T2=2026-10-19T15:10:00Z
{ title "System One lane" s-card; human $T0 "go"; card $T1 1 "What should this lane do next?"; result $T1 1; notice $T2; reminder $T2; } >"$tmp/s-card.jsonl"
{ human $T0 "go"; card $T1 2 "Ship?"; result $T1 2; relay $T2 "$CONDUCTOR" "hold"; } >"$tmp/s-relayed.jsonl"
{ human $T0 "go"; card $T1 3 "Ship?"; result $T1 3; relay $T2 local_other-session "my report"; } >"$tmp/s-sibling.jsonl"
{ human $T0 "go"; card $T1 10 "Ship?"; result $T1 10; peer_relay $T2 "$CONDUCTOR"; } >"$tmp/s-peer-relayed.jsonl"
{ human $T0 "go"; card $T1 11 "Ship?"; result $T1 11; peer_relay $T2 local_other-session; } >"$tmp/s-peer-sibling.jsonl"
{ human $T0 "go"; card $T1 4 "Ship?"; result $T1 4; human $T2 "ship it"; } >"$tmp/s-human.jsonl"
{ human $T0 "go"; plain_wrap $T1 5; result $T1 5; } >"$tmp/s-noask.jsonl"
{ human $T0 "go"; card $T1 6 "Ship?"; result $T1 6; tool $T2 7; result $T2 7; } >"$tmp/sess-co-a-001.jsonl"
{ human $T0 "go"; picker $T1 8 "Which option?"; } >"$tmp/s-picker.jsonl"
{ human $T0 "go"; picker $T1 9 "Which option?"; result $T2 9; } >"$tmp/s-picker-done.jsonl"
cp "$tmp/s-card.jsonl" "$tmp/s-excluded.jsonl"
cp "$tmp/s-card.jsonl" "$tmp/s-old.jsonl"
touch -t 202610170000 "$tmp/s-old.jsonl"
# Copies of s-card under their own session ids (the title row names the id).
for s in s-co-b s-nometa s-mixed; do
  sed "s/\"sessionId\":\"s-card\"/\"sessionId\":\"$s\"/" "$tmp/s-card.jsonl" >"$tmp/$s.jsonl"
done

# A throwaway HQ root: every session is a co-a session except s-co-b
# (co-b), s-mixed (co-a and co-b) and s-nometa (no meta.yaml).
export HQ_ROOT="$tmp/root"
for f in "$tmp"/*.jsonl; do
  s="$(basename "$f" .jsonl)"
  case "$s" in s-co-b|s-mixed|s-nometa) continue ;; esac
  mkdir -p "$HQ_ROOT/workspace/sessions/$s"
  printf 'session_id: %s\ncompany_slug: co-a\n' "$s" >"$HQ_ROOT/workspace/sessions/$s/meta.yaml"
done
mkdir -p "$HQ_ROOT/workspace/sessions/s-co-b" "$HQ_ROOT/workspace/sessions/s-mixed"
printf 'session_id: s-co-b\ncompany_slug: co-b\n' >"$HQ_ROOT/workspace/sessions/s-co-b/meta.yaml"
printf 'session_id: s-mixed\ncompany_slugs: "co-a,co-b"\n' >"$HQ_ROOT/workspace/sessions/s-mixed/meta.yaml"

out="$(node "$OA" --dir "$tmp" --company co-a --conductor "$CONDUCTOR" --exclude s-excluded --now 2026-10-19T18:53:00Z --max-age-hours 24)"
has() { grep -q "\"session\":\"$1\"" <<<"$out"; }
lacks() { ! grep -q "\"session\":\"$1\"" <<<"$out"; }

has s-card; check "a wrap_up box with nothing after it is open (got: $out)" $?
grep -q '"question":"What should this lane do next?"' <<<"$out"; check "the box's question is reported" $?
grep -q '"actions":\["Ship it","Hold"\]' <<<"$out"; check "the box's buttons are reported" $?
grep -q '"title":"System One lane"' <<<"$out"; check "the session title is reported" $?
grep -q '"age_minutes":240' <<<"$out"; check "age is measured from the ask (4h)" $?
check "notifications and hook feedback do not answer the box" "$(has s-card; echo $?)"
lacks s-relayed; check "a conductor relay answers the box (lanes-eval false positive)" $?
has s-sibling; check "a cross-session message from another session does not answer the box" $?
lacks s-peer-relayed; check "a conductor relay delivered as a peer (meta) entry answers the box" $?
has s-peer-sibling; check "a peer entry from another session does not answer the box" $?
lacks s-human; check "an owner-typed turn answers the box" $?
lacks s-noask; check "a wrap_up without an ask is not a decision" $?
lacks sess-co-a-001; check "tool work after the box closes it" $?
has s-picker; check "an unanswered AskUserQuestion is open" $?
grep -q '"kind":"picker".*"question":"Which option?"' <<<"$out"; check "the picker's question is reported" $?
lacks s-picker-done; check "an answered AskUserQuestion is not open" $?
lacks s-excluded; check "--exclude skips the conductor's own session" $?
lacks s-old; check "--max-age-hours skips stale transcripts" $?

# Company scope: only sessions inside the locked set are read.
lacks s-co-b; check "a co-b session is skipped under --company co-a" $?
lacks s-mixed; check "a session that also holds co-b is skipped under --company co-a" $?
lacks s-nometa; check "a session with no meta.yaml is skipped" $?
out3="$(node "$OA" --dir "$tmp" --company co-a --company co-b --conductor "$CONDUCTOR" --now 2026-10-19T18:53:00Z --max-age-hours 24)"
grep -q '"session":"s-co-b"' <<<"$out3"; check "with both companies locked, the co-b session is read (got: $out3)" $?
grep -q '"session":"s-mixed"' <<<"$out3"; check "with both companies locked, the mixed session is read" $?
node "$OA" --dir "$tmp" --now 2026-10-19T18:53:00Z >/dev/null 2>&1; rc=$?
check "open-asks refuses to run without --company (rc $rc)" "$([[ $rc -eq 2 ]]; echo $?)"

# Without --conductor, no relay counts as an answer.
out2="$(node "$OA" --dir "$tmp" --company co-a --now 2026-10-19T18:53:00Z --max-age-hours 9999)"
grep -q '"session":"s-relayed"' <<<"$out2"; check "relays count only from a named conductor" $?

# Default transcript folder: every non-alphanumeric character becomes '-'
# (Claude Code's naming), including spaces, underscores and Windows paths.
names="$(node --input-type=module -e "
  const m = await import('$OA');
  console.log([m.projectDirName('/home/a/Documents/HQ'), m.projectDirName('/home/a/Library/Application Support/my_hq'), m.projectDirName('C:\\\\work\\\\a\\\\HQ')].join(' '));
")"
check "folder name for a plain path ($names)" "$([[ "$names" == "-home-a-Documents-HQ "* ]]; echo $?)"
grep -q -- '-home-a-Library-Application-Support-my-hq' <<<"$names"; check "spaces and underscores become '-' ($names)" $?
grep -q -- 'C--work-a-HQ' <<<"$names"; check "Windows drive and backslashes become '-' ($names)" $?

# The session id is the transcript's file name: a resumed transcript can carry
# an older id inside it, and the ask must point at the file's session.
mkdir -p "$tmp/more"
{ title "Resumed lane" s-older-id; human $T0 "go"; card $T1 20 "Resumed ask?"; result $T1 20; } >"$tmp/more/s-resumed.jsonl"
# A transcript larger than the 2 MB tail: the ask at the end and the title at
# the start are both found.
pad="$(printf 'x%.0s' $(seq 1 1000))"
{ title "Big session" s-big; for _ in $(seq 1 2600); do human $T0 "$pad"; done; card $T1 21 "Big ask?"; result $T1 21; } >"$tmp/more/s-big.jsonl"
for sid in s-resumed s-big; do
  mkdir -p "$HQ_ROOT/workspace/sessions/$sid"
  printf 'session_id: %s\ncompany_slug: co-a\n' "$sid" >"$HQ_ROOT/workspace/sessions/$sid/meta.yaml"
done
big="$(wc -c <"$tmp/more/s-big.jsonl" | tr -d ' ')"
check "the big fixture is over 2 MB ($big bytes)" "$([[ "$big" -gt 2097152 ]]; echo $?)"
out5="$(node "$OA" --dir "$tmp" --dir "$tmp/more" --company co-a --conductor "$CONDUCTOR" --now 2026-10-19T18:53:00Z --max-age-hours 24)"
grep -q '"session":"s-resumed"' <<<"$out5"; check "the session id comes from the file name (got: $out5)" $?
check "an id inside the transcript is never reported as the session" "$(! grep -q '"session":"s-older-id"' <<<"$out5"; echo $?)"
grep -q '"session":"s-big","title":"Big session".*"question":"Big ask?"' <<<"$out5"; check "a transcript over the tail size still yields its ask and title" $?
grep -q '"session":"s-card"' <<<"$out5"; check "every --dir is read" $?

# Each ask is queued once and relayed once. `mark` exits 0 when it moves the
# ask forward and 3 when the ask is already there; --state hides recorded asks.
ASKS="$tmp/asks.json"
ask_id="$(grep '"session":"s-card"' <<<"$out" | node -e 'process.stdout.write(JSON.parse(require("fs").readFileSync(0,"utf8")).ask_id||"")')"
check "each open ask carries an ask_id (got: $ask_id)" "$([[ -n "$ask_id" ]]; echo $?)"
mk() { node "$OA" mark --state "$ASKS" --session s-card --ask-id "$ask_id" --status "$1" >/dev/null 2>&1; echo $?; }
rc="$(mk queued)"; check "the first queue of an ask is allowed (rc $rc)" "$([[ $rc -eq 0 ]]; echo $?)"
rc="$(mk queued)"; check "a second queue of the same ask is refused (rc $rc)" "$([[ $rc -eq 3 ]]; echo $?)"
out4="$(node "$OA" --dir "$tmp" --company co-a --conductor "$CONDUCTOR" --state "$ASKS" --now 2026-10-19T18:53:00Z --max-age-hours 24)"
check "a queued ask is not listed again" "$(! grep -q '"session":"s-card"' <<<"$out4"; echo $?)"
grep -q '"session":"s-picker"' <<<"$out4"; check "other open asks are still listed with --state" $?
rc="$(mk relayed)"; check "the first relay of an ask is allowed (rc $rc)" "$([[ $rc -eq 0 ]]; echo $?)"
rc="$(mk relayed)"; check "a second relay of the same ask is refused (rc $rc)" "$([[ $rc -eq 3 ]]; echo $?)"
rc="$(mk queued)"; check "a relayed ask cannot be queued again (rc $rc)" "$([[ $rc -eq 3 ]]; echo $?)"
node "$OA" mark --state "$ASKS" --session s-picker --ask-id x --status sent >/dev/null 2>&1; rc=$?
check "mark refuses an unknown status (rc $rc)" "$([[ $rc -eq 2 ]]; echo $?)"

# A queued ask with no relay after the stale window is listed again with
# stale: true, announced again by watch once per window, and `queued` prints
# it with the question kept by mark, so a compaction mid-picker loses nothing.
ASKS2="$tmp/asks2.json"
pid="$(grep '"session":"s-picker"' <<<"$out" | node -e 'process.stdout.write(JSON.parse(require("fs").readFileSync(0,"utf8")).ask_id||"")')"
node "$OA" mark --state "$ASKS2" --session s-picker --ask-id "$pid" --status queued --question "Which fix first?" --title "picker session" >/dev/null
out6="$(node "$OA" queued --state "$ASKS2")"
grep -q '"question":"Which fix first?"' <<<"$out6"; check "queued prints the ask with the question mark kept (got: $out6)" $?
out7="$(SC_ASK_STALE_MINUTES=1 node "$OA" --dir "$tmp" --company co-a --conductor "$CONDUCTOR" --state "$ASKS2" --now 2026-10-19T18:53:00Z --max-age-hours 24)"
check "a freshly queued ask is hidden (got: $out7)" "$(! grep -q '"session":"s-picker"' <<<"$out7"; echo $?)"
node -e '
const f=process.argv[1]; const s=JSON.parse(require("fs").readFileSync(f,"utf8"));
for (const k of Object.keys(s.asks)) s.asks[k].at="2026-10-19T18:38:00Z";
require("fs").writeFileSync(f, JSON.stringify(s));' "$ASKS2"
out8="$(SC_ASK_STALE_MINUTES=10 node "$OA" --dir "$tmp" --company co-a --conductor "$CONDUCTOR" --state "$ASKS2" --now 2026-10-19T18:53:00Z --max-age-hours 24)"
grep -q '"session":"s-picker".*"stale":true' <<<"$out8"; check "a queued ask with no relay for 15 minutes is listed again as stale (got: $out8)" $?
node -e '
const f=process.argv[1]; const s=JSON.parse(require("fs").readFileSync(f,"utf8"));
for (const k of Object.keys(s.asks)) s.asks[k].at=new Date(Date.now()-15*60e3).toISOString();
require("fs").writeFileSync(f, JSON.stringify(s));' "$ASKS2"
SEEN2="$tmp/seen2.json"
printf '{"announced":{"s-picker\u0000%s":"%s"}}' "$pid" "$(node -e 'process.stdout.write(new Date(Date.now()-15*60e3).toISOString())')" >"$SEEN2"
out9="$(SC_ASK_STALE_MINUTES=10 node "$OA" watch --dir "$tmp" --company co-a --conductor "$CONDUCTOR" --state "$ASKS2" --seen "$SEEN2" --once --max-age-hours 24)"
grep -q 'OPEN-ASK .*s-picker.*stale: queued with no answer' <<<"$out9"; check "watch announces a stale ask again (got: $out9)" $?
out10="$(SC_ASK_STALE_MINUTES=10 node "$OA" watch --dir "$tmp" --company co-a --conductor "$CONDUCTOR" --state "$ASKS2" --seen "$SEEN2" --once --max-age-hours 24)"
check "a stale ask is announced once per window, not every poll (got: $out10)" "$([[ -z "$out10" ]]; echo $?)"
node -e '
const f=process.argv[1]; const s=JSON.parse(require("fs").readFileSync(f,"utf8"));
for (const k of Object.keys(s.announced)) s.announced[k]=new Date(Date.now()-40*60e3).toISOString();
require("fs").writeFileSync(f, JSON.stringify(s));' "$SEEN2"
out10b="$(SC_ASK_STALE_MINUTES=10 node "$OA" watch --dir "$tmp" --company co-a --conductor "$CONDUCTOR" --state "$ASKS2" --seen "$SEEN2" --once --max-age-hours 24)"
check "a stale ask is re-announced once in total, never again later (got: $out10b)" "$([[ -z "$out10b" ]]; echo $?)"
node "$OA" mark --state "$ASKS2" --session s-picker --ask-id "$pid" --status relayed >/dev/null
out11="$(SC_ASK_STALE_MINUTES=0.0001 node "$OA" --dir "$tmp" --company co-a --conductor "$CONDUCTOR" --state "$ASKS2" --now 2026-10-19T18:53:00Z --max-age-hours 24)"
check "a relayed ask is never stale (got: $out11)" "$(! grep -q '"session":"s-picker"' <<<"$out11"; echo $?)"

# Skill contract: every wakeup runs the checker and treats boxes as decisions.
SC="$ROOT/.claude/skills/super-conductor/SKILL.md"
need() { grep -Eq -- "$1" "$SC" || { echo "FAIL: skill: $2" >&2; fail=1; }; }
need 'super-conductor-open-asks\.mjs' 'every wakeup runs the open-asks checker'
need 'wrap_up' 'the next-step box (wrap_up with ask) is a decision source'
need '--conductor <this session' 'the checker is given the conductor id so relays count'
need 'open-asks\.mjs --conductor .*\\$' 'the open-asks command continues onto the --company line'
need '^  --session-companies --state workspace/reports/conduct/<link>-asks\.json' 'open-asks reads the locked company set itself'
need 'filter-channels --session-companies' 'the hq_channels sweep filter reads the locked company set itself'
need 'mark --state workspace/reports/conduct/<link>-asks\.json' 'asks are recorded before queueing and relaying'
need 'filter-channels' 'the hq_channels sweep filters to the locked company set'
need 'MESSAGE-WATCH-EXITED' 'the wake table covers a stopped watcher'

[[ "$fail" -eq 0 ]] || exit 1
echo "super-conductor-open-asks: ok"
