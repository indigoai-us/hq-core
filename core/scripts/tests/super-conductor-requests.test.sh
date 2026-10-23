#!/usr/bin/env bash
# super-conductor-requests.mjs: the request ledger.
#   - add records one row per inbound item and refuses the same source+ref twice;
#   - set moves a request through allowed states only, and done needs a result;
#   - list folds the append-only rows to the latest state, oldest first;
#   - text stays on one line with "|" replaced; a torn last line is skipped;
#   - the ledger is a file, so nothing is lost between runs;
#   - the skill records every inbound item and reads the ledger after a compact.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
RQ="$ROOT/core/scripts/super-conductor-requests.mjs"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
fail=0
check() { if [[ "$2" -ne 0 ]]; then echo "FAIL: $1" >&2; fail=1; fi; }
L="$tmp/requests.jsonl"

id1="$(node "$RQ" add --file "$L" --source hq_dm --ref ev_1 --from ada --kind work --text 'Please fix the login page' --at 2026-10-20T01:00:00Z)"
check "add prints an id (got: $id1)" "$([[ "$id1" == rq_20261020010000_* ]]; echo $?)"
dup="$(node "$RQ" add --file "$L" --source hq_dm --ref ev_1 --from ada --kind work 2>/dev/null)"; rc=$?
check "the same source and ref is refused with the existing id (rc $rc, got: $dup)" "$([[ $rc -eq 3 && "$dup" == "$id1" ]]; echo $?)"
id2="$(node "$RQ" add --file "$L" --source slack --ref 'C1:1.2' --from bo --kind decision --text $'Ship | now?\nsecond line' --at 2026-10-20T01:01:00Z)"
id3="$(node "$RQ" add --file "$L" --source session --ref local_3 --from lane-x --kind work --at 2026-10-20T01:02:00Z)"
node "$RQ" add --file "$L" --source carrier --ref x --from y --kind work >/dev/null 2>&1; rc=$?
check "an unknown source is refused (rc $rc)" "$([[ $rc -eq 2 ]]; echo $?)"

out="$(node "$RQ" list --file "$L")"
check "list prints every request oldest first (got: $out)" "$([[ "$(wc -l <<<"$out")" -eq 3 && "$(head -1 <<<"$out")" == "$id1 "* ]]; echo $?)"
grep -q 'Ship / now? second line' <<<"$out"; check "text is one line with the pipe replaced (got: $out)" $?

node "$RQ" set --file "$L" --id "$id1" --status routed --lane lane-7 >/dev/null
node "$RQ" set --file "$L" --id "$id2" --status waiting_owner >/dev/null
node "$RQ" set --file "$L" --id "$id2" --status routed >/dev/null 2>&1; rc=$?
check "waiting_owner cannot go back to routed (rc $rc)" "$([[ $rc -eq 2 ]]; echo $?)"
node "$RQ" set --file "$L" --id "$id1" --status done >/dev/null 2>&1; rc=$?
check "done without a result is refused (rc $rc)" "$([[ $rc -eq 2 ]]; echo $?)"
node "$RQ" set --file "$L" --id "$id1" --status done --result 'pr:123' >/dev/null
node "$RQ" set --file "$L" --id "$id1" --status routed >/dev/null 2>&1; rc=$?
check "a done request cannot move again (rc $rc)" "$([[ $rc -eq 2 ]]; echo $?)"
node "$RQ" set --file "$L" --id rq_missing --status dropped >/dev/null 2>&1; rc=$?
check "an unknown id is refused (rc $rc)" "$([[ $rc -eq 2 ]]; echo $?)"

out="$(node "$RQ" list --file "$L" --open)"
check "--open hides done requests (got: $out)" "$(! grep -q "$id1" <<<"$out" && grep -q "$id2" <<<"$out" && grep -q "$id3" <<<"$out"; echo $?)"
out="$(node "$RQ" list --file "$L" --status waiting_owner --json)"
grep -q "\"id\":\"$id2\".*\"status\":\"waiting_owner\"" <<<"$out"; check "--status filters and --json folds to the latest state (got: $out)" $?
grep -q '"history":\[' <<<"$out"; check "the folded row keeps its history (got: $out)" $?
out="$(node "$RQ" list --file "$L" --json | grep "$id1")"
grep -q '"lane":"lane-7".*"result":"pr:123"\|"result":"pr:123".*"lane":"lane-7"' <<<"$out"; check "earlier fields survive later rows (got: $out)" $?
node "$RQ" set --file "$L" --id "$id3" --kind info >/dev/null
out="$(node "$RQ" list --file "$L" --json | grep "$id3")"
grep -q '"kind":"info".*"status":"new"\|"status":"new".*"kind":"info"' <<<"$out"; check "set --kind corrects the kind without a status change (got: $out)" $?
grep -q '"triaged":true' <<<"$out"; check "set --kind marks the row triaged (got: $out)" $?
out="$(node "$RQ" list --file "$L" --open --triaged)"
check "--triaged keeps only rows whose kind was confirmed (got: $out)" "$([[ "$(wc -l <<<"$out")" -eq 1 && "$out" == "$id3 "* ]]; echo $?)"
node "$RQ" set --file "$L" --id "$id3" --kind carrier >/dev/null 2>&1; rc=$?
check "an unknown kind is refused (rc $rc)" "$([[ $rc -eq 2 ]]; echo $?)"
out="$(node "$RQ" list --file "$L" --json | grep "$id1")"
grep -q '"at":"2026-10-20T01:00:00Z"' <<<"$out"; check "at stays the first-seen time after later rows (got: $out)" $?
grep -q '"updated_at":"20' <<<"$out"; check "updated_at is the latest row's time (got: $out)" $?
idc="$(node "$RQ" add --file "$L" --source hq_channel --ref ev_c --from dee --kind work --company co-b --at 2026-10-20T01:03:00Z)"
out="$(node "$RQ" list --file "$L" --company co-b)"
check "--company filters rows by company (got: $out)" "$([[ "$(wc -l <<<"$out")" -eq 1 && "$out" == "$idc "* ]]; echo $?)"
node "$RQ" set --file "$L" --id "$idc" --status dropped --note test >/dev/null
# Concurrent adds of the same message produce one row.
for i in 1 2 3 4 5 6; do node "$RQ" add --file "$L" --source slack --ref 'C9:9.9' --from eve --kind work >/dev/null 2>&1 & done; wait
out="$(node "$RQ" list --file "$L" --json | grep -c '"ref":"C9:9.9"')"
check "six concurrent adds of one message leave one row (got: $out)" "$([[ "$out" -eq 1 ]]; echo $?)"
out="$(node -e 'import("'"$RQ"'").then(({guessKind})=>process.stdout.write([guessKind("Deployed v2 to staging"),guessKind("Can you approve the deploy?"),guessKind("please fix the build")].join(",")))')"
check "guessKind: status posts are fyi, questions are decisions, the rest is work (got: $out)" "$([[ "$out" == "fyi,decision,work" ]]; echo $?)"
out="$(node -e 'import("'"$RQ"'").then(({guessKind})=>process.stdout.write([guessKind("#Project core-pr-reviews 6e234042: @Pat Lee Approved on GitHub at f47e4d8d: 0 critical. Merge when ready?"),guessKind("@Pat Changes requested on GitHub at 422c8481: 1 critical. Could you fix?"),guessKind("@Sam Rivera Approved on GitHub at 65df22ff: 0 critical, CI green."),guessKind("Approved on GitHub at a80daa06 — should I merge?")].join(",")))')"
check "guessKind: a reviewer verdict addressed to a PR author is work for that session, never an owner decision (got: $out)" "$([[ "$out" == "work,work,work,work" ]]; echo $?)"
out="$(node -e 'import("'"$RQ"'").then(({guessKind})=>process.stdout.write([guessKind("Update the README please"),guessKind("Done? can you merge")].join(",")))')"
check "guessKind: an imperative or a question that starts with a status word is not fyi (got: $out)" "$([[ "$out" == "work,decision" ]]; echo $?)"
out="$(node "$RQ" count --file "$L")"
check "count reports per status (got: $out)" "$([[ "$out" == *'"done":1'* && "$out" == *'"waiting_owner":1'* && "$out" == *'"new":2'* && "$out" == *'"dropped":1'* ]]; echo $?)"

# A torn last line (a crash mid-append) does not break the ledger.
printf '{"id":"rq_torn","at":"2026' >>"$L"
out="$(node "$RQ" count --file "$L")"
check "a torn last line is skipped (got: $out)" "$([[ "$out" == *'"done":1'* ]]; echo $?)"
out="$(node "$RQ" list --file "$tmp/none.jsonl")"
check "a missing ledger lists nothing" "$([[ -z "$out" ]]; echo $?)"

# Skill contract.
SC="$ROOT/.claude/skills/super-conductor/SKILL.md"
grep -q 'super-conductor-requests.mjs add' "$SC"; check "the skill records every inbound item with requests.mjs add" $?
grep -q 'super-conductor-requests.mjs list --file <ledger> --open' "$SC" || grep -q 'requests.mjs list .*--open' "$SC"; check "the skill reads the open requests after a compact" $?
grep -q 'node core/scripts/super-conductor-requests.mjs' <(sed -n 1,6p "$SC"); check "the skill allows the requests command" $?

[[ "$fail" -eq 0 ]] || exit 1
echo "super-conductor-requests: ok"
