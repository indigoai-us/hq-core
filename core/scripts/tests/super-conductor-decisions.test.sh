#!/usr/bin/env bash
# super-conductor-decisions.mjs: the owner decision queue.
#   - add prints an id and refuses the same source+ref twice (exit 3, same id);
#   - two to four options, the first recommended unless --recommended names another;
#   - next returns the oldest open row, critical rows first; exit 3 when none;
#   - answer needs --answer and moves open→answered; relayed moves answered→relayed;
#   - answered→answered and relayed→answered are refused; drop works from open and answered;
#   - watch --for desk|conductor prints each wake line once (seen file);
#   - a "|" or newline in a question never adds a field to a wake line;
#   - drop needs --note; stale lists open rows older than --after;
#   - watch --for desk prints one STALE-DECISION line per row left open past --stale-after;
#   - an answer with --relay-by desk is left to the desk; the conductor's ANSWER line
#     waits the grace period, and a relayed row never gets one;
#   - next --count claims up to n distinct rows in one call, skips another desk's
#     fresh claim, re-returns this desk's own claims, and keeps critical rows alone;
#   - count reports per status.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
DQ="$ROOT/core/scripts/super-conductor-decisions.mjs"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
fail=0
check() { if [[ "$2" -ne 0 ]]; then echo "FAIL: $1" >&2; fail=1; fi; }
# Every answer is written by the desk that claimed the row.
dqa() { local f=$1 id=$2; shift 2; node "$DQ" claim --file "$f" --id "$id" --desk t-desk >/dev/null 2>&1; node "$DQ" answer --file "$f" --id "$id" --desk t-desk "$@"; }
Q="$tmp/cl-test-decisions.jsonl"
# Standing answers come from a file under personal/; tests never read the machine's.
export SC_STANDING_FILE="$tmp/standing.json"

# add
id1="$(node "$DQ" add --file "$Q" --source ask --ref 'local_1:ask_1' --question 'Merge PR 12?' --option 'Merge::merge now' --option 'Hold::wait for CI' --relay-session local_1 --relay-child lane-a --relay-link cl-test --at 2026-10-20T01:00:00Z)"; rc=$?
check "add prints an id (rc $rc, got: $id1)" "$([[ $rc -eq 0 && "$id1" == dq_20261020010000_* ]]; echo $?)"
dup="$(node "$DQ" add --file "$Q" --source ask --ref 'local_1:ask_1' --question 'Merge PR 12?' --option a --option b 2>/dev/null)"; rc=$?
check "the same source and ref exits 3 with the existing id (rc $rc, got: $dup)" "$([[ $rc -eq 3 && "$dup" == "$id1" ]]; echo $?)"
node "$DQ" add --file "$Q" --source conductor --ref one-opt --question q --option only >/dev/null 2>&1; rc=$?
check "one option is refused (rc $rc)" "$([[ $rc -eq 2 ]]; echo $?)"
node "$DQ" add --file "$Q" --source conductor --ref five-opt --question q --option a --option b --option c --option d --option e >/dev/null 2>&1; rc=$?
check "five options are refused (rc $rc)" "$([[ $rc -eq 2 ]]; echo $?)"
node "$DQ" add --file "$Q" --source carrier --ref x --question q --option a --option b >/dev/null 2>&1; rc=$?
check "an unknown source is refused (rc $rc)" "$([[ $rc -eq 2 ]]; echo $?)"
out="$(node "$DQ" count --file "$Q")"
check "refused adds write nothing (got: $out)" "$([[ "$out" == '{"open":1}' ]]; echo $?)"

# recommended
out="$(node "$DQ" list --file "$Q" --json | grep "$id1")"
grep -q '"options":\[{"label":"Merge","description":"merge now","recommended":true},{"label":"Hold","description":"wait for CI","recommended":false}\]' <<<"$out"
check "the first option is recommended by default and descriptions are kept (got: $out)" $?
id2="$(node "$DQ" add --file "$Q" --source ledger --ref rq_2 --question 'Deploy tonight?' --option 'Yes' --option 'No' --option 'Tomorrow' --recommended Tomorrow --asked-by ada --at 2026-10-20T01:01:00Z)"
out="$(node "$DQ" list --file "$Q" --json | grep "$id2")"
grep -q '"label":"Yes","recommended":false.*"label":"Tomorrow","recommended":true' <<<"$out"
check "--recommended names the recommended option (got: $out)" $?
grep -q '"asked_by":"ada"' <<<"$out"; check "asked_by is kept (got: $out)" $?

# next: oldest open, critical first
out="$(node "$DQ" next --file "$Q")"
check "next returns the oldest open row (got: $out)" "$([[ "$out" == "$id1 | open | normal | "* ]]; echo $?)"
grep -q 'Merge (Recommended) / Hold' <<<"$out"; check "next marks the recommended option (got: $out)" $?
id3="$(node "$DQ" add --file "$Q" --source conductor --ref 'prod-down' --question 'Roll back prod?' --option 'Roll back' --option 'Leave it' --priority critical --at 2026-10-20T01:02:00Z)"
out="$(node "$DQ" next --file "$Q" --json)"
grep -q "\"id\":\"$id3\".*\"priority\":\"critical\"" <<<"$out"; check "a critical row goes ahead of an older normal one (got: $out)" $?

# transitions
dqa "$Q" "$id3" >/dev/null 2>&1; rc=$?
check "answer without --answer is refused (rc $rc)" "$([[ $rc -eq 2 ]]; echo $?)"
out="$(dqa "$Q" "$id3" --answer 'Roll back')"
check "answer moves open to answered (got: $out)" "$([[ "$out" == "$id3 open → answered" ]]; echo $?)"
dqa "$Q" "$id3" --answer 'Leave it' >/dev/null 2>&1; rc=$?
check "answered to answered is refused (rc $rc)" "$([[ $rc -eq 2 ]]; echo $?)"
out="$(node "$DQ" next --file "$Q")"
check "an answered row leaves next (got: $out)" "$([[ "$out" == "$id1 "* ]]; echo $?)"
node "$DQ" relayed --file "$Q" --id "$id1" >/dev/null 2>&1; rc=$?
check "open to relayed is refused (rc $rc)" "$([[ $rc -eq 2 ]]; echo $?)"
out="$(node "$DQ" relayed --file "$Q" --id "$id3" --result 'link:sent')"
check "relayed moves answered to relayed (got: $out)" "$([[ "$out" == "$id3 answered → relayed" ]]; echo $?)"
dqa "$Q" "$id3" --answer 'again' >/dev/null 2>&1; rc=$?
check "relayed to answered is refused (rc $rc)" "$([[ $rc -eq 2 ]]; echo $?)"
dqa "$Q" dq_missing --answer x >/dev/null 2>&1; rc=$?
check "an unknown id is refused (rc $rc)" "$([[ $rc -eq 2 ]]; echo $?)"
out="$(node "$DQ" list --file "$Q" --json | grep "$id3")"
grep -q '"answer":"Roll back".*"result":"link:sent"\|"result":"link:sent".*"answer":"Roll back"' <<<"$out"; check "earlier fields survive later rows (got: $out)" $?
grep -q '"at":"2026-10-20T01:02:00Z"' <<<"$out"; check "at stays the first-seen time (got: $out)" $?

# drop from open and from answered
idd1="$(node "$DQ" add --file "$Q" --source ask --ref 'local_9:ask_1' --question 'Not mine' --option a --option b --at 2026-10-20T01:03:00Z)"
out="$(node "$DQ" drop --file "$Q" --id "$idd1" --note 'answered in source')"
check "drop works from open (got: $out)" "$([[ "$out" == "$idd1 open → dropped" ]]; echo $?)"
idd2="$(node "$DQ" add --file "$Q" --source ask --ref 'local_9:ask_2' --question 'Stale' --option a --option b --at 2026-10-20T01:04:00Z)"
dqa "$Q" "$idd2" --answer a >/dev/null
out="$(node "$DQ" drop --file "$Q" --id "$idd2" --note 'child closed')"
check "drop works from answered (got: $out)" "$([[ "$out" == "$idd2 answered → dropped" ]]; echo $?)"
node "$DQ" drop --file "$Q" --id "$idd2" --note again >/dev/null 2>&1; rc=$?
check "a dropped row cannot move again (rc $rc)" "$([[ $rc -eq 2 ]]; echo $?)"
idd3="$(node "$DQ" add --file "$Q" --source ask --ref 'local_9:ask_1' --question 'Not mine' --option a --option b --at 2026-10-20T01:05:00Z)"; rc=$?
check "a dropped source+ref can be queued again (rc $rc, got: $idd3)" "$([[ $rc -eq 0 && "$idd3" != "$idd1" ]]; echo $?)"
node "$DQ" drop --file "$Q" --id "$idd3" --note test >/dev/null
idd4="$(node "$DQ" add --file "$Q" --source ask --ref 'local_9:ask_4' --question 'Why dropped?' --option a --option b --at 2026-10-20T01:06:00Z)"
node "$DQ" drop --file "$Q" --id "$idd4" >/dev/null 2>&1; rc=$?
check "drop without --note is refused (rc $rc)" "$([[ $rc -eq 2 ]]; echo $?)"
node "$DQ" drop --file "$Q" --id "$idd4" --note '  ' >/dev/null 2>&1; rc=$?
check "drop with a blank --note is refused (rc $rc)" "$([[ $rc -eq 2 ]]; echo $?)"
node "$DQ" drop --file "$Q" --id "$idd4" --note 'duplicate of rq_1' --by desk >/dev/null
out="$(node "$DQ" list --file "$Q" --json | grep "$idd4")"
grep -q '"status":"dropped".*"note":"duplicate of rq_1".*"by":"desk"' <<<"$out"; check "drop records the note and who dropped it (got: $out)" $?
node "$DQ" drop --file "$Q" --id "$idd1" --note x --by robot >/dev/null 2>&1; rc=$?
check "--by takes desk or conductor only (rc $rc)" "$([[ $rc -eq 2 ]]; echo $?)"

# stale: open rows older than --after
out="$(node "$DQ" stale --file "$Q" --after 300 --now 2026-10-20T01:05:30Z)"
check "stale lists open rows older than --after, oldest first (got: $out)" "$([[ "$(wc -l <<<"$out")" -eq 1 && "$out" == "$id1 | open | "* ]]; echo $?)"
node "$DQ" stale --file "$Q" --after 300 --now 2026-10-20T01:00:30Z >/dev/null; rc=$?
check "stale exits 3 when no open row is that old (rc $rc)" "$([[ $rc -eq 3 ]]; echo $?)"

# watch --for desk: one DECISION line per new open row, printed once
W="$tmp/cl-watch-decisions.jsonl"
out="$(node "$DQ" watch --file "$W" --for desk --once --now 2026-10-20T02:00:30Z)"
check "watch desk prints nothing for a missing queue (got: $out)" "$([[ -z "$out" ]]; echo $?)"
wid="$(node "$DQ" add --file "$W" --source ask --ref 'local_2:ask_7' --question $'Ship | now?\nsecond line' --option 'Ship::go' --option 'Wait' --relay-session local_2 --relay-child lane-b --at 2026-10-20T02:00:00Z)"
out="$(node "$DQ" watch --file "$W" --for desk --once --now 2026-10-20T02:00:30Z)"
check "watch desk prints one DECISION line for a new open row (got: $out)" "$([[ "$(wc -l <<<"$out")" -eq 1 && "$out" == 'SUPER-CONDUCTOR DECISION '* ]]; echo $?)"
grep -q "1 open: Ship / now? second line \[Ship / Wait\] | id $wid | Send the owner one push notification (PushNotification) with the open count only (never the question text), then run /decision-desk now: up to four rows per picker" <<<"$out"; check "the DECISION line names the question, options, id, and the desk (got: $out)" $?
check "a pipe or newline in the question adds no field to the DECISION line (got: $out)" "$([[ "$(tr -cd '|' <<<"$out" | wc -c)" -eq 3 ]]; echo $?)"
[[ -f "$tmp/cl-watch-decisions-desk-seen.json" ]]; check "watch desk writes its seen file next to the queue" $?
out="$(node "$DQ" watch --file "$W" --for desk --once --now 2026-10-20T02:00:40Z)"
check "a second desk run prints nothing (got: $out)" "$([[ -z "$out" ]]; echo $?)"
wid2="$(node "$DQ" add --file "$W" --source conductor --ref urgent --question 'Pay the invoice?' --option Pay --option Hold --priority critical --at 2026-10-20T02:01:00Z)"
out="$(node "$DQ" watch --file "$W" --for desk --once --now 2026-10-20T02:01:30Z)"
check "a new critical row wakes the desk once with critical first (got: $out)" "$([[ "$(wc -l <<<"$out")" -eq 1 && "$out" == *"1 open, critical first: Pay the invoice?"*"id $wid2"* ]]; echo $?)"

# watch --for desk: one STALE-DECISION line per row left open past --stale-after
out="$(node "$DQ" watch --file "$W" --for desk --once --stale-after 300 --now 2026-10-20T02:04:00Z)"
check "no STALE line before --stale-after (got: $out)" "$([[ -z "$out" ]]; echo $?)"
out="$(node "$DQ" watch --file "$W" --for desk --once --stale-after 300 --now 2026-10-20T02:06:00Z)"
check "one STALE-DECISION line once a row waited past --stale-after (got: $out)" "$([[ "$(wc -l <<<"$out")" -eq 1 && "$out" == 'SUPER-CONDUCTOR STALE-DECISION '* ]]; echo $?)"
grep -q "2 waiting over 6m, critical: Ship / now? second line | id $wid | Send the owner one push notification (PushNotification)" <<<"$out"; check "the STALE line names the wait, the oldest question, the id, and the push (got: $out)" $?
check "a pipe in the question adds no field to the STALE line (got: $out)" "$([[ "$(tr -cd '|' <<<"$out" | wc -c)" -eq 3 ]]; echo $?)"
out="$(node "$DQ" watch --file "$W" --for desk --once --stale-after 300 --now 2026-10-20T02:30:00Z)"
check "a stale row is announced once (got: $out)" "$([[ -z "$out" ]]; echo $?)"

# watch --for conductor: one ANSWER line per newly answered row, printed once
out="$(node "$DQ" watch --file "$W" --for conductor --once)"
check "watch conductor prints nothing while no row is answered (got: $out)" "$([[ -z "$out" ]]; echo $?)"
dqa "$W" "$wid" --answer $'Ship | it\nnow' >/dev/null
out="$(node "$DQ" watch --file "$W" --for conductor --once)"
check "watch conductor prints one ANSWER line for a newly answered row (got: $out)" "$([[ "$(wc -l <<<"$out")" -eq 1 && "$out" == 'SUPER-CONDUCTOR ANSWER '* ]]; echo $?)"
grep -q "Ship / now? second line → Ship / it now | relay to lane-b (local_2) | id $wid | Relay it as a quoted OWNER GO on the link and by direct message in this turn, then decisions.mjs relayed --id $wid" <<<"$out"
check "the ANSWER line names the answer, the relay child and session, and the id (got: $out)" $?
check "a pipe or newline in the question or answer adds no field to the ANSWER line (got: $out)" "$([[ "$(tr -cd '|' <<<"$out" | wc -c)" -eq 4 ]]; echo $?)"
out="$(node "$DQ" watch --file "$W" --for conductor --once)"
check "a second conductor run prints nothing (got: $out)" "$([[ -z "$out" ]]; echo $?)"
dqa "$W" "$wid2" --answer Pay >/dev/null
out="$(node "$DQ" watch --file "$W" --for conductor --once)"
check "a row with no relay target says so (got: $out)" "$([[ "$(wc -l <<<"$out")" -eq 1 && "$out" == *'| relay to no relay target |'* ]]; echo $?)"
out="$(node "$DQ" watch --file "$W" --for desk --once --now 2026-10-20T02:31:00Z)"
check "answering a row does not wake the desk again (got: $out)" "$([[ -z "$out" ]]; echo $?)"

# --relay-by desk: the desk delivers; the conductor only steps in after the grace period.
wid3="$(node "$DQ" add --file "$W" --source ask --ref 'local_3:ask_1' --question 'Deploy?' --option Yes --option No --relay-session local_3 --relay-child lane-c --relay-link cl-w --at 2026-10-20T03:00:00Z)"
wid4="$(node "$DQ" add --file "$W" --source ledger --ref rq_9 --question 'Reply?' --option Yes --option No --asked-by bo --at 2026-10-20T03:00:01Z)"
dqa "$W" "$wid4" --answer Yes --relay-by desk >/dev/null 2>&1; rc=$?
check "--relay-by desk needs a relay target on the row (rc $rc)" "$([[ $rc -eq 2 ]]; echo $?)"
dqa "$W" "$wid4" --answer Yes --relay-by conductor >/dev/null 2>&1; rc=$?
check "--relay-by takes desk only (rc $rc)" "$([[ $rc -eq 2 ]]; echo $?)"
dqa "$W" "$wid3" --answer Yes --relay-by desk --at 2026-10-20T03:01:00Z >/dev/null
out="$(node "$DQ" list --file "$W" --json | grep "$wid3")"
grep -q '"relay_by":"desk"' <<<"$out"; check "the answer records relay_by desk (got: $out)" $?
out="$(node "$DQ" watch --file "$W" --for conductor --once --now 2026-10-20T03:01:30Z)"
check "the conductor gets no ANSWER line for a desk-relayed row inside the grace period (got: $out)" "$([[ -z "$out" ]]; echo $?)"
node "$DQ" relayed --file "$W" --id "$wid3" --result 'link:sent' --by desk >/dev/null
out="$(node "$DQ" watch --file "$W" --for conductor --once --now 2026-10-20T03:10:00Z)"
check "a row the desk relayed never gets an ANSWER line (got: $out)" "$([[ -z "$out" ]]; echo $?)"
wid5="$(node "$DQ" add --file "$W" --source ask --ref 'local_5:ask_1' --question 'Merge?' --option Yes --option No --relay-session local_5 --at 2026-10-20T03:02:00Z)"
dqa "$W" "$wid5" --answer Yes --relay-by desk --at 2026-10-20T03:03:00Z >/dev/null
out="$(node "$DQ" watch --file "$W" --for conductor --once --now 2026-10-20T03:06:00Z)"
check "a desk-relayed row still answered after the grace period wakes the conductor (got: $out)" "$([[ "$(wc -l <<<"$out")" -eq 1 && "$out" == *"id $wid5"* ]]; echo $?)"
node "$DQ" relayed --file "$W" --id "$wid5" --by conductor >/dev/null
node "$DQ" drop --file "$W" --id "$wid4" --note 'test: no relay target' --by conductor >/dev/null
node "$DQ" watch --file "$W" --once >/dev/null 2>&1; rc=$?
check "watch without --for is refused (rc $rc)" "$([[ $rc -eq 2 ]]; echo $?)"

# findDuplicate: same words, same person or thread, same company, not dropped.
out="$(node -e 'import("'"$DQ"'").then(({findDuplicate})=>{const rows=[{id:"d1",at:"2026-10-20T01:00:00Z",status:"open",question:"ada (hq_dm): Can you approve the deploy?",company:"co-a",asked_by:"ada",reply_to:{source:"hq_dm",ref:"ev_1",from:"ada"}},{id:"d2",at:"2026-10-20T01:00:00Z",status:"dropped",note:"not now",question:"bo (hq_dm): Should we roll back?",company:"co-a",asked_by:"bo"}];const now=Date.parse("2026-10-20T02:00:00Z");const f=(a,n)=>{const r=findDuplicate(rows,a,n||now);return r?r.id:"-"};process.stdout.write([f({question:"can you approve the deploy",from:"Ada",company:"co-a"}),f({question:"can you approve the deploy",from:"izzy",company:"co-a"}),f({question:"can you approve the deploy",from:"ada",company:"co-b"}),f({question:"can you approve the deploy",from:"bot",company:"co-a",source:"hq_dm",ref:"ev_1"}),f({question:"should we roll back now?",from:"bo",company:"co-a"}),f({question:"Should we roll back?",from:"bo",company:"co-a"}),f({question:"can you approve the deploy",from:"ada",company:"co-a"},Date.parse("2026-10-21T02:00:00Z"))].join(","))})')"
check "findDuplicate: same person matches, other person and other company do not, same thread matches, a dropped row never anchors, the window is 24 h (got: $out)" "$([[ "$out" == "d1,-,-,d1,-,-,-" ]]; echo $?)"

# standing answers: a rule set once answers later matching rows at add time.
S="$tmp/cl-standing-decisions.jsonl"
node "$DQ" standing list >/dev/null 2>&1; rc=$?
check "standing list exits 3 with no rules (rc $rc)" "$([[ $rc -eq 3 ]]; echo $?)"
SA=(standing add --by desk --expires 7d)
node "$DQ" "${SA[@]}" --match 'old' --answer Close --note x >/dev/null 2>&1; rc=$?
check "a too-short match is refused (rc $rc)" "$([[ $rc -eq 2 ]]; echo $?)"
node "$DQ" "${SA[@]}" --match 'bug reports( are)? (over|older than)' --answer 'Spot-check 20 first' >/dev/null 2>&1; rc=$?
check "standing add needs --note (rc $rc)" "$([[ $rc -eq 2 ]]; echo $?)"
# Review fixes (#1542): scope, expiry and writer are enforced in code.
for m in '........' '.*.*.*.*' '[a-z]{8}[a-z]{8}' '\w+\s+\w+\s+\d+'; do
  node "$DQ" "${SA[@]}" --match "$m" --answer Close --note x >/dev/null 2>&1; rc=$?
  check "a wildcard match with too few literal characters is refused: $m (rc $rc)" "$([[ $rc -eq 2 ]]; echo $?)"
done
node "$DQ" "${SA[@]}" --match '(bug reports+)+ older' --answer Close --note x >/dev/null 2>&1; rc=$?
check "a nested quantifier (ReDoS) is refused (rc $rc)" "$([[ $rc -eq 2 ]]; echo $?)"
node "$DQ" standing add --by desk --match 'bug reports( are)? (over|older than)' --answer Close --note x >/dev/null 2>&1; rc=$?
check "standing add needs --expires (rc $rc)" "$([[ $rc -eq 2 ]]; echo $?)"
node "$DQ" standing add --by desk --expires 31d --match 'bug reports( are)? (over|older than)' --answer Close --note x >/dev/null 2>&1; rc=$?
check "an expiry over 30 days is refused (rc $rc)" "$([[ $rc -eq 2 ]]; echo $?)"
node "$DQ" standing add --expires 7d --match 'bug reports( are)? (over|older than)' --answer Close --note x >/dev/null 2>&1; rc=$?
check "standing add without --by desk is refused (rc $rc)" "$([[ $rc -eq 2 ]]; echo $?)"
node "$DQ" standing add --by conductor --expires 7d --match 'bug reports( are)? (over|older than)' --answer Close --note x >/dev/null 2>&1; rc=$?
check "the conductor cannot write a rule (rc $rc)" "$([[ $rc -eq 2 ]]; echo $?)"
node "$DQ" "${SA[@]}" --match 'bug reports( are)? (over|older than)' --answer Close --note x --critical --free >/dev/null 2>&1; rc=$?
check "a free-text rule for critical rows is refused (rc $rc)" "$([[ $rc -eq 2 ]]; echo $?)"
node "$DQ" "${SA[@]}" --match 'bug reports( are)? (over|older than)' --answer Close --note x --standing-file "$tmp/other.json" >/dev/null 2>&1; rc=$?
check "--standing-file is no longer accepted (rc $rc)" "$([[ $rc -eq 2 && ! -e "$tmp/other.json" ]]; echo $?)"
[[ ! -e "$SC_STANDING_FILE" ]]; check "no refused rule was written" $?
sa1="$(node "$DQ" "${SA[@]}" --match 'bug reports( are)? (over|older than)' --answer 'Close, won'"'"'t do' --note 'owner 2026-10-21: stale reports close')"; rc=$?
check "standing add prints an id (rc $rc, got: $sa1)" "$([[ $rc -eq 0 && "$sa1" == sa_* ]]; echo $?)"
grep -q "\"op\":\"add\".*\"id\":\"$sa1\"" "$SC_STANDING_FILE.log.jsonl"; check "every rule add is logged next to the rules file" $?
dupsa="$(node "$DQ" "${SA[@]}" --match 'bug reports( are)? (over|older than)' --answer 'Close, won'"'"'t do' --note again 2>/dev/null)"; rc=$?
check "the same rule twice exits 3 with the existing id (rc $rc)" "$([[ $rc -eq 3 && "$dupsa" == "$sa1" ]]; echo $?)"
out="$(node "$DQ" standing list)"
check "standing list shows the rule, its answer, expiry and note (got: $out)" "$([[ "$out" == "$sa1 | on | /bug reports( are)? (over|older than)/ → Close, won't do | until 20"*" | owner 2026-10-21: stale reports close" ]]; echo $?)"
out="$(node "$DQ" add --file "$S" --source conductor --ref fb1 --question '164 open bug reports are older than two weeks. Close them?' --option 'Close, won'"'"'t do' --option 'Spot-check 20 first (Recommended)' --option 'Leave them' --at 2026-10-21T01:00:00Z)"
check "a matching row is answered at add time by the rule (got: $out)" "$([[ "$out" == "dq_20261021010000_"*" answered by standing $sa1: Close, won't do" ]]; echo $?)"
sid="${out%% *}"
r="$(node "$DQ" list --file "$S" --json | grep "$sid")"
check "the row is answered, by standing, with the rule in its note (got: $r)" "$([[ "$r" == *'"status":"answered"'* && "$r" == *'"by":"standing"'* && "$r" == *"\"note\":\"standing $sa1\""* ]]; echo $?)"
out="$(node "$DQ" watch --file "$S" --for desk --once --now 2026-10-21T01:00:10Z)"
check "the desk is never woken for a standing-answered row (got: $out)" "$([[ -z "$out" ]]; echo $?)"
out="$(node "$DQ" watch --file "$S" --for conductor --once --now 2026-10-21T01:00:10Z)"
check "the conductor's ANSWER line names the rule (got: $out)" "$([[ "$(wc -l <<<"$out")" -eq 1 && "$out" == *"→ Close, won't do | relay to no relay target | answered by standing $sa1, never asked | id $sid |"* ]]; echo $?)"
out="$(node "$DQ" add --file "$S" --source conductor --ref fb2 --question '12 bug reports are older than a month. Close them?' --option 'Archive' --option 'Leave them' --at 2026-10-21T01:01:00Z)"
check "a rule whose answer is not one of the row's options does not fire (got: $out)" "$([[ "$out" == dq_20261021010100_* && "$out" != *standing* ]]; echo $?)"
out="$(node "$DQ" add --file "$S" --source conductor --ref fb3 --question '9 bug reports are older than a month. Close them?' --option 'Close, won'"'"'t do' --option 'Leave them' --priority critical --at 2026-10-21T01:02:00Z)"
check "a critical row is never answered by a rule without --critical (got: $out)" "$([[ "$out" != *standing* ]]; echo $?)"
out="$(node "$DQ" add --file "$S" --source conductor --ref fb4 --question '3 bug reports are older than a month. Close them?' --option 'Close, won'"'"'t do' --option 'Leave them' --no-standing --at 2026-10-21T01:03:00Z)"
check "--no-standing skips the rules for one row (got: $out)" "$([[ "$out" != *standing* ]]; echo $?)"
sa2="$(node "$DQ" "${SA[@]}" --match 'review (my|the) pr' --answer 'Handle it' --source ledger --from ada --company co-a --note 'owner: ada handles her own reviews')"
out="$(node "$DQ" add --file "$S" --source ledger --ref rq_a --question 'ada (hq_dm): Can you review my PR?' --option 'Handle it (Recommended)' --option Hold --asked-by ada --company co-a --at 2026-10-21T01:04:00Z)"
check "a rule scoped to source, from and company fires when all three match (got: $out)" "$([[ "$out" == *"answered by standing $sa2: Handle it" ]]; echo $?)"
out="$(node "$DQ" add --file "$S" --source ledger --ref rq_b --question 'bo (hq_dm): Can you review my PR?' --option 'Handle it (Recommended)' --option Hold --asked-by bo --company co-a --at 2026-10-21T01:05:00Z)"
check "the same words from another person do not fire a from-scoped rule (got: $out)" "$([[ "$out" != *standing* ]]; echo $?)"
out="$(node "$DQ" standing disable --id "$sa1" --by desk --note 'owner: stop')"
check "standing disable (got: $out)" "$([[ "$out" == "$sa1 disabled" ]]; echo $?)"
out="$(node "$DQ" add --file "$S" --source conductor --ref fb5 --question '2 bug reports are older than a month. Close them?' --option 'Close, won'"'"'t do' --option 'Leave them' --at 2026-10-21T01:06:00Z)"
check "a disabled rule does not fire (got: $out)" "$([[ "$out" != *standing* ]]; echo $?)"
out="$(node "$DQ" standing remove --id "$sa2" --by desk)"
check "standing remove (got: $out)" "$([[ "$out" == "$sa2 removed" ]]; echo $?)"
node "$DQ" standing remove --id sa_nope --by desk >/dev/null 2>&1; rc=$?
check "removing an unknown rule exits 2 (rc $rc)" "$([[ $rc -eq 2 ]]; echo $?)"
out="$(node "$DQ" standing list --json | wc -l)"
check "one rule remains (got $out)" "$([[ "$out" -eq 1 ]]; echo $?)"

# Review fixes (#1542): what a rule may answer is checked at match time.
G="$tmp/cl-gate-decisions.jsonl"
sa3="$(node "$DQ" "${SA[@]}" --match 'PR 12 to main' --answer Merge --note 'owner: test')"
out="$(node "$DQ" add --file "$G" --source conductor --ref g1 --question 'Merge PR 12 to main?' --option Merge --option Hold --at 2026-10-21T03:00:00Z)"
check "a rule never answers a merge without --irreversible (got: $out)" "$([[ "$out" != *standing* ]]; echo $?)"
sa4="$(node "$DQ" "${SA[@]}" --match 'approve the (prod )?release' --answer 'Handle it' --note 'owner: test')"
out="$(node "$DQ" add --file "$G" --source conductor --ref g2 --question 'Can you approve the prod release?' --option 'Handle it' --option Hold --at 2026-10-21T03:01:00Z)"
check "an irreversible verb in the question blocks the rule (got: $out)" "$([[ "$out" != *standing* ]]; echo $?)"
sa5="$(node "$DQ" "${SA[@]}" --match 'PR 14 to main' --answer Merge --irreversible --note 'owner: merge PR 14 when green')"
out="$(node "$DQ" add --file "$G" --source conductor --ref g3 --question 'Merge PR 14 to main?' --option Merge --option Hold --at 2026-10-21T03:02:00Z)"
check "an --irreversible rule the owner set does answer it (got: $out)" "$([[ "$out" == *"answered by standing $sa5: Merge" ]]; echo $?)"
sa6="$(node "$DQ" "${SA[@]}" --match 'look at my draft' --answer 'Handle it' --source ledger --note 'owner: test')"
out="$(node "$DQ" add --file "$G" --source ledger --ref g4 --question 'bo (hq_dm): Can you look at my draft?' --option 'Handle it' --option Hold --asked-by bo --at 2026-10-21T03:03:00Z)"
check "a rule without --from never answers a teammate's request (got: $out)" "$([[ "$out" != *standing* ]]; echo $?)"
node "$DQ" "${SA[@]}" --match 'tidy the backlog labels' --answer Yes --note 'owner: test' >/dev/null
out="$(node "$DQ" add --file "$G" --source conductor --ref g5 --question 'Tidy the backlog labels?' --option Yes --option No --priority Critical --at 2026-10-21T03:04:00Z)"
r="$(node "$DQ" list --file "$G" --json | grep '"ref":"g5"')"
check "--priority Critical is stored as critical, so a non-critical rule skips it (got: $out / $r)" "$([[ "$out" != *standing* && "$r" == *'"priority":"critical"'* ]]; echo $?)"
node "$DQ" add --file "$G" --source conductor --ref g6 --question 'x?' --option Yes --option No --priority urgent >/dev/null 2>&1; rc=$?
check "an unknown --priority is refused (rc $rc)" "$([[ $rc -eq 2 ]]; echo $?)"
# A hand-edited rule with no expiry, or an expired one, never fires.
HF="$tmp/hand.json"
cat >"$HF" <<'JSON'
[{"id":"sa_hand1","match":"rotate the staging keys","answer":"Yes","critical":true,"at":"2020-01-01T00:00:00Z"},
 {"id":"sa_hand2","match":"rename the wiki pages","answer":"Yes","note":"owner","at":"2026-10-01T00:00:00Z","expires":"2026-10-05T00:00:00Z"}]
JSON
out="$(SC_STANDING_FILE="$HF" node "$DQ" add --file "$G" --source conductor --ref g7 --question 'Rotate the staging keys?' --option Yes --option No --at 2026-10-21T03:05:00Z)"
check "a hand-edited rule with no note or expiry never fires (got: $out)" "$([[ "$out" != *standing* ]]; echo $?)"
out="$(SC_STANDING_FILE="$HF" node "$DQ" add --file "$G" --source conductor --ref g8 --question 'Rename the wiki pages?' --option Yes --option No --at 2026-10-21T03:06:00Z)"
check "an expired rule never fires (got: $out)" "$([[ "$out" != *standing* ]]; echo $?)"
out="$(SC_STANDING_FILE="$HF" node "$DQ" standing list)"
check "standing list marks bad and expired rules (got: $out)" "$([[ "$out" == *"sa_hand1 | ignored (needs note and at)"* && "$out" == *"sa_hand2 | expired"* ]]; echo $?)"
for id in "$sa3" "$sa4" "$sa5" "$sa6"; do node "$DQ" standing remove --id "$id" --by desk >/dev/null; done

# Review fixes (#1545): a claim restricts who writes the answer.
K="$tmp/cl-claim-decisions.jsonl"
kid="$(node "$DQ" add --file "$K" --source conductor --ref k1 --question 'Ship the beta?' --option Ship --option Wait --no-standing)"
node "$DQ" next --file "$K" --claim desk-a >/dev/null
node "$DQ" answer --file "$K" --id "$kid" --answer Ship --by conductor >/dev/null 2>&1; rc=$?
check "the conductor cannot answer a row a desk claimed (rc $rc)" "$([[ $rc -eq 2 ]]; echo $?)"
node "$DQ" answer --file "$K" --id "$kid" --answer Ship --desk desk-b >/dev/null 2>&1; rc=$?
check "another desk cannot answer a claimed row (rc $rc)" "$([[ $rc -eq 2 ]]; echo $?)"
node "$DQ" answer --file "$K" --id "$kid" --answer Ship >/dev/null 2>&1; rc=$?
check "an answer with no desk name cannot answer a claimed row (rc $rc)" "$([[ $rc -eq 2 ]]; echo $?)"
out="$(node "$DQ" answer --file "$K" --id "$kid" --answer Ship --desk desk-a)"
check "the claiming desk answers its row (got: $out)" "$([[ "$out" == "$kid open → answered" ]]; echo $?)"
kc="$(node "$DQ" add --file "$K" --source conductor --ref k2 --question 'Rotate the bot token?' --option Rotate --option Wait --priority critical --no-standing)"
node "$DQ" answer --file "$K" --id "$kc" --answer Rotate --by conductor --desk conductor >/dev/null 2>&1; rc=$?
check "the conductor cannot answer a row it did not claim (rc $rc)" "$([[ $rc -eq 2 ]]; echo $?)"
node "$DQ" next --file "$K" --claim conductor >/dev/null
out="$(node "$DQ" answer --file "$K" --id "$kc" --answer Rotate --by conductor --desk conductor)"
check "the conductor answers a critical row after claiming it (got: $out)" "$([[ "$out" == "$kc open → answered" ]]; echo $?)"
kf="$(node "$DQ" add --file "$K" --source conductor --ref k3 --question 'Rename the channel?' --option Yes --option No --no-standing)"
node "$DQ" next --file "$K" --claim desk-a --now 2099-01-01T00:00:00Z >/dev/null
r="$(node "$DQ" list --file "$K" --json | grep '"ref":"k3"')"
check "a claim cannot be dated in the future with --now (got: $r)" "$([[ "$r" != *'"claimed_at":"2099'* ]]; echo $?)"
out="$(node "$DQ" next --file "$K" --claim desk-b --json --now 2099-01-01T00:20:00Z)"
check "a future --now claim lapses on real time, so another desk can ask the row (got: $out)" "$([[ "$out" == *"\"id\":\"$kf\""* ]]; echo $?)"

# Review fixes (#1583, second review): the claim gate is unconditional.
U="$tmp/cl-uncond-decisions.jsonl"
uc="$(node "$DQ" add --file "$U" --source conductor --ref 'merge x/y 7 abcdef1' --question 'Merge x/y 7 at abcdef1?' --option Merge --option Hold --priority critical --no-standing)"
node "$DQ" answer --file "$U" --id "$uc" --answer Merge >/dev/null 2>&1; rc=$?
check "answer with no --desk is refused, even on an unclaimed row (rc $rc)" "$([[ $rc -eq 2 ]]; echo $?)"
node "$DQ" answer --file "$U" --id "$uc" --answer Merge --desk desk-x >/dev/null 2>&1; rc=$?
check "answer from a desk that did not claim the row is refused (rc $rc)" "$([[ $rc -eq 2 ]]; echo $?)"
out="$(node "$DQ" claim --file "$U" --id "$uc" --desk desk-x)"; rc=$?
check "claim --id claims one named open row (rc $rc, got: $out)" "$([[ $rc -eq 0 && "$out" == "$uc claimed by desk-x" ]]; echo $?)"
node "$DQ" claim --file "$U" --id "$uc" --desk desk-y >/dev/null 2>&1; rc=$?
check "claim --id refuses a row another desk holds (rc $rc)" "$([[ $rc -eq 3 ]]; echo $?)"
out="$(node "$DQ" answer --file "$U" --id "$uc" --answer Merge --desk desk-x)"
check "the claiming desk answers (got: $out)" "$([[ "$out" == "$uc open → answered" ]]; echo $?)"
un="$(node "$DQ" add --file "$U" --source conductor --ref n1 --question 'Rename the board?' --option Yes --option No --no-standing)"
node "$DQ" claim --file "$U" --id "$un" --desk conductor >/dev/null 2>&1; rc=$?
check "the conductor cannot claim a normal row (rc $rc)" "$([[ $rc -eq 2 ]]; echo $?)"
node "$DQ" next --file "$U" --claim conductor >/dev/null 2>&1; rc=$?
check "next --claim conductor returns no normal row (rc $rc)" "$([[ $rc -eq 3 ]]; echo $?)"
node "$DQ" claim --file "$U" --id "$un" --desk desk-x >/dev/null
node "$DQ" answer --file "$U" --id "$un" --answer Yes --desk conductor --by conductor >/dev/null 2>&1; rc=$?
check "the conductor never answers a normal row (rc $rc)" "$([[ $rc -eq 2 ]]; echo $?)"

# standingFile() resolves the HQ root from the script path, so a root with a
# space (or a Windows drive path) reads and writes the right rules file.
SP="$tmp/my hq"
mkdir -p "$SP/core/scripts/lib"
cp "$DQ" "$SP/core/scripts/"
cp "$ROOT/core/scripts/lib/super-conductor-scope.mjs" "$ROOT/core/scripts/lib/super-conductor-lock.mjs" "$SP/core/scripts/lib/"
(unset SC_STANDING_FILE HQ_ROOT; node "$SP/core/scripts/super-conductor-decisions.mjs" standing add --by desk --expires 7d --match 'rename the wiki pages' --answer Yes --note 'owner: test' >/dev/null)
[[ -f "$SP/personal/settings/super-conductor-standing-answers.json" ]]; check "a root with a space gets its rules file under that root" $?

# Desk lanes and claims: several desks serve one queue and never ask the same row.
LQ="$tmp/cl-lanes-decisions.jsonl"
lm="$(node "$DQ" add --file "$LQ" --source conductor --ref 'merge hq-cli 2067' --question 'Merge hq-cli 2067 now?' --option Merge --option Hold --no-standing --at 2026-10-21T02:00:00Z)"
la="$(node "$DQ" add --file "$LQ" --source ledger --ref rq_l1 --question 'ada (hq_dm): Can you look at my draft?' --option 'Handle it' --option Hold --asked-by ada --no-standing --at 2026-10-21T02:00:01Z)"
lg="$(node "$DQ" add --file "$LQ" --source conductor --ref price-tier --question 'Which volume tier for the asset library?' --option '80% GM' --option '70% GM' --no-standing --at 2026-10-21T02:00:02Z)"
lx="$(node "$DQ" add --file "$LQ" --source ledger --ref rq_l2 --question 'bo (hq_dm): Pricing copy ok?' --option Yes --option No --asked-by bo --lane general --no-standing --at 2026-10-21T02:00:03Z)"
out="$(node "$DQ" list --file "$LQ" --lane merges)"
check "a merge/release go lands in the merges lane (got: $out)" "$([[ "$(wc -l <<<"$out")" -eq 1 && "$out" == "$lm | open | normal | merges | "* ]]; echo $?)"
out="$(node "$DQ" list --file "$LQ" --lane asks)"
check "a teammate request lands in the asks lane (got: $out)" "$([[ "$(wc -l <<<"$out")" -eq 1 && "$out" == "$la | "* ]]; echo $?)"
out="$(node "$DQ" list --file "$LQ" --lane general | cut -d' ' -f1 | tr '\n' ' ')"
check "the rest, and an explicit --lane general, land in general (got: $out)" "$([[ "$out" == "$lg $lx " ]]; echo $?)"
node "$DQ" add --file "$LQ" --source conductor --ref x --question q --option a --option b --lane bogus >/dev/null 2>&1; rc=$?
check "an unknown --lane is refused (rc $rc)" "$([[ $rc -eq 2 ]]; echo $?)"
out="$(node "$DQ" watch --file "$LQ" --for desk --lane merges --once --now 2026-10-21T02:00:10Z)"
check "the merges desk wakes only for its lane (got: $out)" "$([[ "$(wc -l <<<"$out")" -eq 1 && "$out" == *"1 open: Merge hq-cli 2067 now?"*"id $lm"* ]]; echo $?)"
[[ -f "$tmp/cl-lanes-decisions-desk-merges-seen.json" ]]; check "each lane keeps its own seen file" $?
out="$(node "$DQ" watch --file "$LQ" --for desk --lane asks --once --now 2026-10-21T02:00:10Z)"
check "the asks desk wakes only for its lane (got: $out)" "$([[ "$(wc -l <<<"$out")" -eq 1 && "$out" == *"id $la"* ]]; echo $?)"
# Two desks with no lane split race for the same row: the first claim wins.
out="$(node "$DQ" next --file "$LQ" --claim desk-a --json --now 2026-10-21T02:01:00Z)"
check "next --claim returns the oldest row and records the claim (got: $out)" "$([[ "$out" == *"\"id\":\"$lm\""* && "$out" == *'"claimed_by":"desk-a"'* && "$out" == *'"lane":"merges"'* ]]; echo $?)"
out="$(node "$DQ" next --file "$LQ" --claim desk-b --json --now 2026-10-21T02:01:05Z)"
check "a second desk skips the row the first desk claimed (got: $out)" "$([[ "$out" == *"\"id\":\"$la\""* ]]; echo $?)"
out="$(node "$DQ" next --file "$LQ" --claim desk-a --json --now 2026-10-21T02:01:10Z)"
check "the claiming desk gets its own claimed row again (got: $out)" "$([[ "$out" == *"\"id\":\"$lm\""* ]]; echo $?)"
out="$(node "$DQ" watch --file "$LQ" --for desk --desk desk-c --once --now 2026-10-21T02:01:20Z)"
check "a third desk is woken only for unclaimed rows (got: $out)" "$([[ "$out" != *"id $lm"* && "$out" != *"id $la"* && "$out" == *"2 open:"* ]]; echo $?)"
out="$(node "$DQ" next --file "$LQ" --claim desk-b --json --now 2026-10-21T02:20:00Z)"
check "a claim older than 15 minutes lapses and another desk can ask the row (got: $out)" "$([[ "$out" == *"\"id\":\"$lm\""* && "$out" == *'"claimed_by":"desk-b"'* ]]; echo $?)"
dqa "$LQ" "$lm" --answer Merge >/dev/null
out="$(node "$DQ" next --file "$LQ" --lane merges --claim desk-m --now 2026-10-21T02:21:00Z)"; rc=$?
check "an answered row leaves its lane; next exits 3 when the lane is empty (rc $rc)" "$([[ $rc -eq 3 ]]; echo $?)"
# Six desks racing for one row: exactly one claim wins.
RQF="$tmp/cl-race-decisions.jsonl"
node "$DQ" add --file "$RQF" --source conductor --ref race --question 'Ship it?' --option Yes --option No --no-standing >/dev/null
for i in 1 2 3 4 5 6; do (node "$DQ" next --file "$RQF" --claim "desk-$i" --json >"$tmp/race-$i.out" 2>/dev/null) & done; wait
n="$(cat "$tmp"/race-*.out | grep -c '"id":"dq_')"
check "six desks racing for one row: exactly one gets it (got $n)" "$([[ "$n" -eq 1 ]]; echo $?)"

# count
out="$(node "$DQ" count --file "$Q")"
check "count reports per status (got: $out)" "$([[ "$out" == '{"open":2,"relayed":1,"dropped":4}' ]]; echo $?)"
out="$(node "$DQ" count --file "$W")"
check "count on the watched queue (got: $out)" "$([[ "$out" == '{"answered":2,"relayed":2,"dropped":1}' ]]; echo $?)"
node "$DQ" next --file "$W" >/dev/null; rc=$?
check "next exits 3 when no row is open (rc $rc)" "$([[ $rc -eq 3 ]]; echo $?)"

# A torn last line (a crash mid-append) does not break the queue.
printf '{"id":"dq_torn","at":"2026' >>"$Q"
out="$(node "$DQ" count --file "$Q")"
check "a torn last line is skipped (got: $out)" "$([[ "$out" == '{"open":2,"relayed":1,"dropped":4}' ]]; echo $?)"

# Concurrent adds of the same ask produce one row.
for i in 1 2 3 4 5 6; do node "$DQ" add --file "$Q" --source ask --ref 'local_7:ask_1' --question q --option a --option b >/dev/null 2>&1 & done; wait
out="$(node "$DQ" list --file "$Q" --json | grep -c '"ref":"local_7:ask_1"')"
check "six concurrent adds of one ask leave one row (got: $out)" "$([[ "$out" -eq 1 ]]; echo $?)"

# next --count claims distinct rows in one call (one desk drain never repeats a row).
refs() { node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{const a=JSON.parse(s||"[]");console.log(Array.isArray(a),a.length,new Set(a.map(r=>r.id)).size,a.map(r=>r.ref).join(","),a.every(r=>r.claimed_by==="desk"))})'; }
C="$tmp/cl-count-decisions.jsonl"
for n in 1 2 3 4; do node "$DQ" add --file "$C" --source conductor --ref "count-$n" --question "Q$n?" --option a --option b --at "2026-10-20T0$n:00:00Z" >/dev/null; done
out="$(node "$DQ" next --file "$C" --json --claim desk --count 4 --now 2026-10-20T05:00:00Z | refs)"
check "4 open rows with --count 4 return 4 distinct claimed rows, oldest first (got: $out)" "$([[ "$out" == "true 4 4 count-1,count-2,count-3,count-4 true" ]]; echo $?)"
out="$(node "$DQ" next --file "$C" --json --claim desk --count 4 --now 2026-10-20T05:01:00Z | refs)"
check "a restarted desk re-asks its own fresh claims (got: $out)" "$([[ "$out" == "true 4 4 count-1,count-2,count-3,count-4 true" ]]; echo $?)"
node "$DQ" next --file "$C" --json --claim desk-2 --count 4 --now 2026-10-20T05:02:00Z >/dev/null; rc=$?
check "another desk gets none of the four freshly claimed rows (rc $rc)" "$([[ $rc -eq 3 ]]; echo $?)"
C1="$tmp/cl-count1-decisions.jsonl"
node "$DQ" add --file "$C1" --source conductor --ref only --question 'Only one?' --option a --option b >/dev/null
out="$(node "$DQ" next --file "$C1" --json --claim desk --count 4 | refs)"
check "1 open row with --count 4 returns a one-row array (got: $out)" "$([[ "$out" == "true 1 1 only true" ]]; echo $?)"
C2="$tmp/cl-count2-decisions.jsonl"
for n in 1 2 3; do node "$DQ" add --file "$C2" --source conductor --ref "other-$n" --question "O$n?" --option a --option b --at "2026-10-20T0$n:00:00Z" >/dev/null; done
node "$DQ" next --file "$C2" --json --claim desk-2 --now 2026-10-20T05:00:00Z >/dev/null
out="$(node "$DQ" next --file "$C2" --json --claim desk --count 4 --now 2026-10-20T05:05:00Z | refs)"
check "another desk's fresh claim is still skipped with --count (got: $out)" "$([[ "$out" == "true 2 2 other-2,other-3 true" ]]; echo $?)"
out="$(node "$DQ" next --file "$C2" --json --claim desk --count 4 --now 2026-10-20T05:20:00Z | refs)"
check "another desk's claim lapses after the TTL (got: $out)" "$([[ "$out" == "true 3 3 other-1,other-2,other-3 true" ]]; echo $?)"
C3="$tmp/cl-count3-decisions.jsonl"
node "$DQ" add --file "$C3" --source conductor --ref routine --question 'Routine?' --option a --option b --at 2026-10-20T01:00:00Z >/dev/null
node "$DQ" add --file "$C3" --source conductor --ref urgent --question 'Urgent?' --option a --option b --priority critical --at 2026-10-20T02:00:00Z >/dev/null
out="$(node "$DQ" next --file "$C3" --json --claim desk --count 4 | refs)"
check "a critical row comes back on its own (got: $out)" "$([[ "$out" == "true 1 1 urgent true" ]]; echo $?)"
out="$(node "$DQ" next --file "$C3" --json)"
check "next without --count still prints one object (got: $out)" "$([[ "$out" == '{"id":'* ]]; echo $?)"
node "$DQ" next --file "$C3" --count 0 >/dev/null 2>&1; rc=$?
check "--count 0 is refused (rc $rc)" "$([[ $rc -eq 2 ]]; echo $?)"

# Skill contract.
DESK="$ROOT/.claude/skills/decision-desk/SKILL.md"
DQS="$ROOT/.claude/skills/decision-queue/SKILL.md"
grep -q 'node core/scripts/super-conductor-decisions.mjs' <(sed -n 1,6p "$DESK"); check "the desk skill allows the decisions command" $?
grep -q -- "--for desk --interval 5" "$DESK"; check "the desk skill arms the desk watcher" $?
grep -q 'answer --file <queue> --id <id> --answer' "$DESK"; check "the desk skill writes answers with answer --id" $?
grep -q 'STALE-DECISION' "$DESK" && grep -q 'PushNotification' "$DESK"; check "the desk skill pushes a phone notification on STALE-DECISION" $?
grep -q -- '--relay-by desk' "$DESK" && grep -q 'hq lanes link send' "$DESK"; check "the desk skill relays answers to child sessions itself" $?
grep -q 'drop --file <queue> --id <id> --note' "$DESK"; check "the desk skill drops with a note" $?
grep -q -- '--claim <desk name> --count 4' "$DESK"; check "the desk skill claims a drain's rows in one next --count call" $?
grep -q 'standing add --by desk' "$DESK"; check "the desk skill writes a standing rule from the owner's words" $?
grep -q -- '--claim' "$DESK" && grep -q -- '--lane' "$DESK"; check "the desk skill claims rows and serves one lane" $?
grep -q 'standing' "$DQS"; check "conductor mode knows standing answers" $?
grep -q 'super-conductor-decisions.mjs add' "$DQS"; check "conductor mode queues owner items with decisions.mjs add" $?
grep -q 'SUPER-CONDUCTOR ANSWER' "$DQS"; check "conductor mode relays on the ANSWER line" $?
grep -q 'relayed --file <queue> --id <id>' "$DQS"; check "conductor mode marks the row relayed" $?

[[ "$fail" -eq 0 ]] || exit 1
echo "super-conductor-decisions: ok"
