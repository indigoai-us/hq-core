#!/usr/bin/env bash
# super-conductor-triage.mjs: the background triage daemon.
#   - fyi rows are closed (done, kind fyi, triaged) with a result;
#   - decision rows queue one decision (source ledger, ref = request id, the
#     request's priority) and move to waiting_owner;
#   - work rows get kind work and stay new for the conductor to route;
#   - a second run changes nothing and prints nothing;
#   - critical rows go before older normal rows;
#   - rows of another company are untouched;
#   - row text never puts a "|" inside the TRIAGE line's fields;
#   - watch --once prints the TRIAGE line once.
set -u
ROOT="${HQ_TEST_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
RQ="$ROOT/core/scripts/super-conductor-requests.mjs"
DQ="$ROOT/core/scripts/super-conductor-decisions.mjs"
TR="$ROOT/core/scripts/super-conductor-triage.mjs"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
fail=0
check() { if [[ "$2" -ne 0 ]]; then echo "FAIL: $1" >&2; fail=1; fi; }
# Every answer is written by the desk that claimed the row.
dqa() { local f=$1 id=$2; shift 2; node "$DQ" claim --file "$f" --id "$id" --desk t-desk >/dev/null 2>&1; node "$DQ" answer --file "$f" --id "$id" --desk t-desk "$@"; }
L="$tmp/requests.jsonl"
export SC_STANDING_FILE="$tmp/standing.json"
D="$tmp/decisions.jsonl"
row() { node "$RQ" list --file "$L" --json | grep "\"id\":\"$1\""; }

# Oldest first: a normal decision, then a work row, then an fyi, then a
# critical decision whose text carries a "|", then another company's row.
id_dec="$(node "$RQ" add --file "$L" --source hq_dm --ref ev_1 --from ada --kind work --text 'Can you approve the deploy?' --company co-a --at 2026-10-20T01:00:00Z)"
id_work="$(node "$RQ" add --file "$L" --source hq_channel --ref ev_2 --from bo --kind work --text 'Please fix the login page' --company co-a --at 2026-10-20T01:01:00Z)"
id_fyi="$(node "$RQ" add --file "$L" --source slack --ref 'C1:1.1' --from cy --kind work --text 'Deployed v2 to staging' --company co-a --at 2026-10-20T01:02:00Z)"
id_crit="$(node "$RQ" add --file "$L" --source hq_dm --ref ev_3 --from dee --kind work --text 'Should we ship | tonight?' --priority critical --at 2026-10-20T01:03:00Z)"
id_other="$(node "$RQ" add --file "$L" --source hq_channel --ref ev_4 --from eve --kind work --text 'Can you approve this?' --company co-b --at 2026-10-20T00:30:00Z)"
# A reviewer verdict addressed to a PR author is work for that session, not a decision.
id_verdict="$(node "$RQ" add --file "$L" --source hq_channel --ref ev_5 --from kai --kind work --text '#Project core-pr-reviews: @Pat Lee Approved on GitHub at f47e4d8d: 0 critical. Merge when ready?' --company co-a --at 2026-10-20T01:04:00Z)"

out="$(node "$TR" run --ledger "$L" --decisions "$D" --company co-a)"; rc=$?
check "run exits 0 (rc $rc)" "$([[ $rc -eq 0 ]]; echo $?)"
check "run prints exactly one TRIAGE line (got: $out)" "$([[ "$(wc -l <<<"$out")" -eq 1 && "$out" == "SUPER-CONDUCTOR TRIAGE 20"* ]]; echo $?)"
check "the TRIAGE line carries the counts (got: $out)" "$([[ "$out" == *'| 5 rows: 1 fyi closed, 2 decisions queued, 2 work pending, 1 critical |'* ]]; echo $?)"
check "the TRIAGE line ends with the route hint (got: $out)" "$([[ "$out" == *'| Route the work rows (requests.mjs list --open --kind work --triaged); decisions are on the queue.' ]]; echo $?)"
check "row text never adds a field to the TRIAGE line (got: $out)" "$([[ "$(tr -cd '|' <<<"$out" | wc -c)" -eq 2 && "$out" != *'ship'* ]]; echo $?)"

r="$(row "$id_fyi")"
check "an fyi row is done with kind fyi and triaged (got: $r)" "$([[ "$r" == *'"status":"done"'* && "$r" == *'"kind":"fyi"'* && "$r" == *'"triaged":true'* && "$r" == *'"result":"fyi: no action (triage)"'* ]]; echo $?)"
r="$(row "$id_work")"
check "a work row gets kind work, triaged, and stays new (got: $r)" "$([[ "$r" == *'"status":"new"'* && "$r" == *'"kind":"work"'* && "$r" == *'"triaged":true'* ]]; echo $?)"
r="$(row "$id_dec")"
check "a decision row moves to waiting_owner with kind decision (got: $r)" "$([[ "$r" == *'"status":"waiting_owner"'* && "$r" == *'"kind":"decision"'* && "$r" == *'"note":"decision dq_'* ]]; echo $?)"
r="$(row "$id_verdict")"
check "a reviewer verdict to a PR author is work, not a decision (got: $r)" "$([[ "$r" == *'"status":"new"'* && "$r" == *'"kind":"work"'* && "$r" == *'"triaged":true'* ]]; echo $?)"
r="$(row "$id_other")"
check "another company's row is untouched (got: $r)" "$([[ "$r" == *'"status":"new"'* && "$r" != *'"triaged"'* ]]; echo $?)"

dq="$(node "$DQ" list --file "$D" --json)"
check "exactly two decisions are queued (got: $dq)" "$([[ "$(wc -l <<<"$dq")" -eq 2 ]]; echo $?)"
d1="$(grep "\"ref\":\"$id_dec\"" <<<"$dq")"
check "the decision carries source ledger, ref = request id, normal priority, askedBy (got: $d1)" "$([[ "$d1" == *'"source":"ledger"'* && "$d1" == *'"priority":"normal"'* && "$d1" == *'"asked_by":"ada"'* && "$d1" == *'"company":"co-a"'* && "$d1" == *'ada (hq_dm): Can you approve the deploy?'* ]]; echo $?)"
d2="$(grep "\"ref\":\"$id_crit\"" <<<"$dq")"
check "a critical request queues a critical decision (got: $d2)" "$([[ "$d2" == *'"priority":"critical"'* ]]; echo $?)"
grep -q '"label":"Handle it (Recommended)".*"recommended":true' <<<"$d1"; check "the recommended option is Handle it (got: $d1)" $?
# Decision rows are appended in processing order: the critical one first, even though it is newer.
first_ref="$(head -1 <<<"$dq" | sed 's/.*"source":"ledger","ref":"\([^"]*\)".*/\1/')"
check "the critical row is processed before the older normal row (first ref $first_ref)" "$([[ "$first_ref" == "$id_crit" ]]; echo $?)"
# The ledger's note for the decision row names the decision id.
dec_id="$(sed 's/.*"id":"\([^"]*\)".*/\1/' <<<"$d1")"
r="$(row "$id_dec")"
check "the request note names the queued decision id (got: $r)" "$([[ "$r" == *"decision $dec_id queued"* ]]; echo $?)"

out="$(node "$TR" run --ledger "$L" --decisions "$D" --company co-a 2>"$tmp/err")"; rc=$?
check "a second run prints nothing and exits 0 (rc $rc, got: $out, err: $(cat "$tmp/err"))" "$([[ $rc -eq 0 && -z "$out" && ! -s "$tmp/err" ]]; echo $?)"
n="$(node "$RQ" list --file "$L" --json | wc -l)"
check "a second run adds no ledger rows (got $n folded rows)" "$([[ "$n" -eq 6 ]]; echo $?)"
dq2="$(node "$DQ" list --file "$D" --json | wc -l)"
check "a second run adds no decisions (got $dq2)" "$([[ "$dq2" -eq 2 ]]; echo $?)"

# The same words again from the same person (or the same source thread) in
# the same company within 24 h is a duplicate: closed, never queued twice.
# A different person asking the same generic question is a new decision with
# its own reply path, and another company's row never matches.
id_echo="$(node "$RQ" add --file "$L" --source hq_dm --ref ev_6 --from ada --kind work --text 'Can you approve the deploy?' --company co-a --at 2026-10-20T01:10:00Z)"
id_echo2="$(node "$RQ" add --file "$L" --source slack --ref 'C1:2.2' --from Ada --kind work --text 'CAN you approve the deploy??' --company co-a --at 2026-10-20T01:11:00Z)"
id_other_person="$(node "$RQ" add --file "$L" --source hq_dm --ref ev_10 --from izzy --kind work --text 'Can you approve the deploy?' --company co-a --at 2026-10-20T01:11:30Z)"
id_other_co="$(node "$RQ" add --file "$L" --source hq_dm --ref ev_11 --from ada --kind work --text 'Can you approve the deploy?' --company co-b --at 2026-10-20T01:11:40Z)"
out="$(node "$TR" run --ledger "$L" --decisions "$D" --company co-a,co-b)"
check "the TRIAGE line counts duplicates closed and the new decisions (eve, co-b, pending from above, is triaged too) (got: $out)" "$([[ "$out" == *'| 5 rows: 0 fyi closed, 3 decisions queued, 2 duplicates closed, 0 work pending |'* ]]; echo $?)"
r="$(row "$id_echo")"
check "the same person repeating is done as a duplicate naming the queued decision (got: $r)" "$([[ "$r" == *'"status":"done"'* && "$r" == *"\"result\":\"duplicate of $dec_id (triage): open"* ]]; echo $?)"
r="$(row "$id_echo2")"
check "punctuation, case and the channel do not defeat the duplicate check (got: $r)" "$([[ "$r" == *"duplicate of $dec_id (triage)"* ]]; echo $?)"
r="$(row "$id_other_person")"
check "a different person asking the same words gets their own decision (got: $r)" "$([[ "$r" == *'"status":"waiting_owner"'* && "$r" == *'"note":"decision dq_'* ]]; echo $?)"
r="$(row "$id_other_co")"
check "another company's row with the same words never matches (got: $r)" "$([[ "$r" == *'"status":"waiting_owner"'* ]]; echo $?)"
dq3="$(node "$DQ" list --file "$D" --json | wc -l)"
check "three new decisions were queued, none for the duplicates (got $dq3)" "$([[ "$dq3" -eq 5 ]]; echo $?)"
d_izzy="$(node "$DQ" list --file "$D" --json | grep "\"ref\":\"$id_other_person\"")"
check "the other person's decision carries their own reply path (got: $d_izzy)" "$([[ "$d_izzy" == *'"reply_to":{"source":"hq_dm","ref":"ev_10","from":"izzy"}'* ]]; echo $?)"
# After the owner answers, a repeat from the same person still closes and carries the answer.
dqa "$D" "$dec_id" --answer 'Handle it' >/dev/null
id_echo3="$(node "$RQ" add --file "$L" --source hq_dm --ref ev_7 --from ada --kind work --text 'Can you approve the deploy?' --company co-a --at 2026-10-20T01:12:00Z)"
node "$TR" run --ledger "$L" --decisions "$D" --company co-a >/dev/null
r="$(row "$id_echo3")"
check "a repeat of an answered question carries the answer (got: $r)" "$([[ "$r" == *"duplicate of $dec_id (triage): answered → Handle it"* ]]; echo $?)"
# A dropped decision does not anchor: the repeat is asked again.
dq_izzy="$(sed 's/.*"id":"\([^"]*\)".*/\1/' <<<"$d_izzy")"
node "$DQ" drop --file "$D" --id "$dq_izzy" --note 'not now' --by desk >/dev/null
id_after_drop="$(node "$RQ" add --file "$L" --source hq_dm --ref ev_12 --from izzy --kind work --text 'Can you approve the deploy?' --company co-a --at 2026-10-20T01:12:30Z)"
node "$TR" run --ledger "$L" --decisions "$D" --company co-a >/dev/null
r="$(row "$id_after_drop")"
check "a repeat after a drop is queued again, not closed (got: $r)" "$([[ "$r" == *'"status":"waiting_owner"'* ]]; echo $?)"
# Two repeats in one pass: the second matches the first, queued in the same pass.
id_p1="$(node "$RQ" add --file "$L" --source hq_dm --ref ev_13 --from bo --kind work --text 'Should we roll back the canary tonight?' --company co-a --at 2026-10-20T01:12:40Z)"
id_p2="$(node "$RQ" add --file "$L" --source hq_dm --ref ev_14 --from bo --kind work --text 'Should we roll back the canary tonight?' --company co-a --at 2026-10-20T01:12:50Z)"
out="$(node "$TR" run --ledger "$L" --decisions "$D" --company co-a)"
check "a repeat later in the same pass matches the row queued earlier in it (got: $out)" "$([[ "$out" == *'| 2 rows: 0 fyi closed, 1 decisions queued, 1 duplicates closed, 0 work pending |'* ]]; echo $?)"
# A short question is never matched on text alone.
id_short="$(node "$RQ" add --file "$L" --source hq_dm --ref ev_8 --from bo --kind work --text 'Approve?' --company co-a --at 2026-10-20T01:13:00Z)"
id_short2="$(node "$RQ" add --file "$L" --source hq_dm --ref ev_9 --from bo --kind work --text 'Approve?' --company co-a --at 2026-10-20T01:14:00Z)"
node "$TR" run --ledger "$L" --decisions "$D" --company co-a >/dev/null
dq4="$(node "$DQ" list --file "$D" --json | wc -l)"
check "two short questions are both queued, never matched as duplicates (got $dq4)" "$([[ "$dq4" -eq 9 ]]; echo $?)"

# A standing rule answers a ledger decision at queue time: the ledger note says
# so, the TRIAGE line counts it, the desk never sees it.
# Review fix (#1542): a rule never answers a deploy unless the owner set
# --irreversible, so a non-critical rule cannot approve a prod deploy.
sa0="$(node "$DQ" standing add --by desk --expires 7d --match 'approve the (prod )?deploy' --answer 'Handle it' --source ledger --from cy --company co-a --note 'owner: test')"
id_sa0="$(node "$RQ" add --file "$L" --source hq_dm --ref ev_19 --from cy --kind work --text 'Can you approve the prod deploy?' --company co-a --at 2026-10-20T01:14:30Z)"
node "$TR" run --ledger "$L" --decisions "$D" --company co-a >/dev/null
d_sa0="$(node "$DQ" list --file "$D" --json | grep "\"ref\":\"$id_sa0\"")"
check "a rule without --irreversible leaves a deploy for the desk (got: $d_sa0)" "$([[ "$d_sa0" == *'"status":"open"'* && "$d_sa0" != *'"by":"standing"'* ]]; echo $?)"
node "$DQ" standing remove --id "$sa0" --by desk >/dev/null
sa="$(node "$DQ" standing add --by desk --expires 7d --match 'approve the (prod )?deploy' --answer 'Handle it' --irreversible --source ledger --from cy --company co-a --note 'owner: cy may deploy')"
id_sa="$(node "$RQ" add --file "$L" --source hq_dm --ref ev_20 --from cy --kind work --text 'Can you approve the deploy?' --company co-a --at 2026-10-20T01:15:00Z)"
out="$(node "$TR" run --ledger "$L" --decisions "$D" --company co-a)"
check "the TRIAGE line counts standing answers (got: $out)" "$([[ "$out" == *'| 1 rows: 0 fyi closed, 1 decisions queued (1 answered by standing rules), 0 work pending |'* ]]; echo $?)"
r="$(row "$id_sa")"
check "the ledger note names the rule and the answer (got: $r)" "$([[ "$r" == *'"status":"waiting_owner"'* && "$r" == *"answered by standing $sa: Handle it"* ]]; echo $?)"
d_sa="$(node "$DQ" list --file "$D" --json | grep "\"ref\":\"$id_sa\"")"
check "the decision is answered by standing (got: $d_sa)" "$([[ "$d_sa" == *'"status":"answered"'* && "$d_sa" == *'"by":"standing"'* ]]; echo $?)"
node "$DQ" standing remove --id "$sa" --by desk >/dev/null

# A question already on the queue (addDecision returns dup) still marks the row.
id_dup="$(node "$RQ" add --file "$L" --source slack --ref 'C2:2.2' --from gil --kind work --text 'Ok to merge?' --company co-a --at 2026-10-20T01:03:30Z)"
pre="$(node "$DQ" add --file "$D" --source ledger --ref "$id_dup" --question 'already asked' --option A --option B)"
out="$(node "$TR" run --ledger "$L" --decisions "$D" --company co-a)"
r="$(row "$id_dup")"
check "a duplicate decision still moves the request to waiting_owner naming the existing id (got: $r)" "$([[ "$r" == *'"status":"waiting_owner"'* && "$r" == *"decision $pre queued"* ]]; echo $?)"
check "a duplicate decision is counted as queued on the line (got: $out)" "$([[ "$out" == *'| 1 rows: 0 fyi closed, 1 decisions queued, 0 work pending |'* ]]; echo $?)"
dq3="$(node "$DQ" list --file "$D" --json | wc -l)"
check "no second decision row is added for the duplicate (got $dq3)" "$([[ "$dq3" -eq 12 ]]; echo $?)"
out="$(node -e 'import("'"$TR"'").then(({classify})=>process.stdout.write([classify({text:"Deployed v2"}).kind,classify({text:"Can we ship?"}).kind,classify({text:"fix it"}).kind,String(classify({text:"fix it",triaged:true}).kind)].join(",")))')"
check "classify: fyi, decision, work, and null for a triaged row (got: $out)" "$([[ "$out" == "fyi,decision,work,null" ]]; echo $?)"

# watch --once prints the TRIAGE line once for a fresh row and returns.
id_new="$(node "$RQ" add --file "$L" --source hq_dm --ref ev_5 --from fay --kind work --text 'Heads up: build is green' --at 2026-10-20T01:04:00Z)"
out="$(node "$TR" watch --ledger "$L" --decisions "$D" --company co-a --once --parent-pid $$)"; rc=$?
check "watch --once prints the TRIAGE line once and exits 0 (rc $rc, got: $out)" "$([[ $rc -eq 0 && "$(wc -l <<<"$out")" -eq 1 && "$out" == *'| 1 rows: 1 fyi closed, 0 decisions queued, 0 work pending |'* ]]; echo $?)"
r="$(row "$id_new")"
check "a row with no company is triaged (got: $r)" "$([[ "$r" == *'"status":"done"'* ]]; echo $?)"
out="$(node "$TR" watch --ledger "$L" --decisions "$D" --company co-a --once)"
check "watch --once prints nothing when nothing changed (got: $out)" "$([[ -z "$out" ]]; echo $?)"

# Bad arguments exit 2.
node "$TR" run --ledger "$L" --decisions "$D" >/dev/null 2>&1; rc=$?
check "run without --company exits 2 (rc $rc)" "$([[ $rc -eq 2 ]]; echo $?)"
node "$TR" run --decisions "$D" --company co-a >/dev/null 2>&1; rc=$?
check "run without --ledger exits 2 (rc $rc)" "$([[ $rc -eq 2 ]]; echo $?)"
node "$TR" bogus >/dev/null 2>&1; rc=$?
check "an unknown command exits 2 (rc $rc)" "$([[ $rc -eq 2 ]]; echo $?)"

[[ "$fail" -eq 0 ]] || exit 1
echo "super-conductor-triage: ok"
