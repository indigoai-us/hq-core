#!/usr/bin/env bash
# Pins HQ DM routing between several /super-conductor sessions on one machine
# (core/scripts/lib/super-conductor-dm-route.mjs, used by the message watcher):
#   - one conductor alone takes every DM (the single-conductor behavior);
#   - with two live conductors, a DM from a person only in this conductor's
#     companies is taken here, with the company on its ledger row;
#   - a DM from a person in both conductors' companies, or in neither, goes to
#     the primary conductor only (never handled twice);
#   - a DM from a person only in the other conductor's companies is dropped
#     here, unrecorded;
#   - primary is `primary: true` in a save file, else the earliest heartbeat;
#   - a stale save file (stopped conductor) does not count;
#   - a conductor whose own roster is not published yet keeps every DM;
#   - the watcher publishes its roster (dm_route) into its save file;
#   - the filter-dms CLI applies the same rule to a raw inbox for the sweep;
#   - the skill documents multi-conductor operation.
# Uses a fake `hq`; no network.
set -uo pipefail

ROOT="${HQ_TEST_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
WATCH="$ROOT/core/scripts/super-conductor-message-watch.mjs"
ROUTE="$ROOT/core/scripts/lib/super-conductor-dm-route.mjs"
REQ="$ROOT/core/scripts/super-conductor-requests.mjs"
STATE="$ROOT/core/scripts/super-conductor-state.mjs"
SC="$ROOT/.claude/skills/super-conductor/SKILL.md"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fail=0
check() { if [[ "$2" -ne 0 ]]; then echo "FAIL: $1" >&2; fail=1; fi; }

mkdir -p "$tmp/fx" "$tmp/conduct" "$tmp/root/companies"
cat >"$tmp/hq" <<'EOS'
#!/usr/bin/env bash
fx="$(dirname "$0")/fx"
echo "$1 $2 $3 $4" >>"$(dirname "$0")/calls"
case "$1 $2" in
  "whoami --json") echo '{"personUid":"prs_owner","email":"owner@example.com"}' ;;
  "dm inbox") cat "$fx/inbox.json" ;;
  "channels changes") echo '{"snapshot":true,"cursor":"c1","rows":[],"changed":[],"removedChannelIds":[]}' ;;
  "members list") cat "$fx/members-$4.json" ;;
  *) echo "unexpected: $1 $2" >&2; exit 9 ;;
esac
EOS
chmod +x "$tmp/hq"
export HQ_BIN="$tmp/hq"
printf 'companies:\n  co-a:\n    cloud_uid: cmp_co-a\n  co-b:\n    cloud_uid: cmp_co-b\n' >"$tmp/root/companies/manifest.yaml"
export HQ_ROOT="$tmp/root"
printf 'work_hours: {timezone: UTC, days: sun-sat, start: "00:00", end: "24:00"}\n' >"$tmp/always.yaml"
export SC_PREFS_FILE="$tmp/always.yaml"

# Rosters: Ada is only in co-a, Bob only in co-b, Cy in both. Dee is nobody's.
echo '{"members":[{"person_id":"prs_ada","email":"ada@example.com","status":"active"},{"person_id":"prs_cy","email":"cy@example.com","status":"active"},{"person_id":"prs_gone","email":"gone@example.com","status":"removed"}]}' >"$tmp/fx/members-co-a.json"
echo '{"members":[{"person_id":"prs_bob","email":"bob@example.com","status":"active"},{"person_id":"prs_cy","email":"cy@example.com","status":"active"}]}' >"$tmp/fx/members-co-b.json"
echo '[]' >"$tmp/fx/inbox.json"

A="$tmp/conduct/cl-aaa-state.json"; B="$tmp/conduct/cl-bbb-state.json"
now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
# A started first (primary by default); both fresh.
printf '{"link":"cl-aaa","updated_at":"%s","heartbeat":{"started_at":"2026-10-25T00:13:54Z"}}\n' "$now" >"$A"
printf '{"link":"cl-bbb","company":"co-b","updated_at":"%s","heartbeat":{"started_at":"2026-10-25T00:15:49Z"}}\n' "$now" >"$B"

watch() { # save company state-suffix
  node "$WATCH" --state "$tmp/watch-$3.json" --company "$2" --save "$1" --ledger "${1%-state.json}-requests.jsonl" --min-wake-gap 0 --once
}
ledger() { node "$REQ" list --file "${1%-state.json}-requests.jsonl" --json; }
jcheck() { node -e "$1" "${@:2}"; }

# 1. Baseline polls publish each conductor's roster into its save file.
watch "$A" co-a a >/dev/null; watch "$B" co-b b >/dev/null
jcheck 'const j=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")); const m=j.dm_route&&j.dm_route.members["co-a"]; process.exit(m&&m.uids.join()==="prs_ada,prs_cy"&&m.emails.includes("ada@example.com")&&!m.uids.includes("prs_gone")&&j.dm_route.companies.join()==="co-a"?0:1)' "$A"
check "watcher publishes dm_route (active members only) into its save file" $?
jcheck 'const j=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")); process.exit(j.dm_route.members["co-b"].uids.join()==="prs_bob,prs_cy"?0:1)' "$B"
check "second conductor publishes its own roster" $?
[[ "$(grep -c "members list --company" "$tmp/calls")" == 2 ]]; check "one members call per company on the baseline" $?

# 2. Primary resolution: earliest heartbeat wins, then primary: true.
out="$(node "$ROUTE" primary --save "$A")"; [[ "$out" == "cl-aaa primary" ]]; check "earliest-started conductor is primary ($out)" $?
out="$(node "$ROUTE" primary --save "$B")"; [[ "$out" == "cl-aaa secondary" ]]; check "later conductor sees itself as secondary ($out)" $?

# 3. Four DMs arrive: Ada (co-a only), Bob (co-b only), Cy (both), Dee (none).
cat >"$tmp/fx/inbox.json" <<'EOS'
[{"eventId":"ev_ada","fromPersonUid":"prs_ada","fromEmail":"ada@example.com","fromDisplayName":"Ada","body":"can you merge?","createdAt":"2026-10-25T01:00:00Z"},
 {"eventId":"ev_bob","fromPersonUid":"prs_bob","fromEmail":"bob@example.com","fromDisplayName":"Bob","body":"status?","createdAt":"2026-10-25T01:00:01Z"},
 {"eventId":"ev_cy","fromPersonUid":"prs_cy","fromDisplayName":"Cy","body":"both","createdAt":"2026-10-25T01:00:02Z"},
 {"eventId":"ev_dee","fromPersonUid":"prs_dee","fromDisplayName":"Dee","body":"hello","createdAt":"2026-10-25T01:00:03Z"}]
EOS
outA="$(watch "$A" co-a a)"; outB="$(watch "$B" co-b b)"
grep -q 'DM from Ada' <<<"$outA"; check "A (co-a) wakes on Ada" $?
grep -q 'DM from Cy' <<<"$outA"; check "A (primary) wakes on Cy, who is in both companies" $?
grep -q 'DM from Dee' <<<"$outA"; check "A (primary) wakes on Dee, who is in no company" $?
! grep -q 'DM from Bob' <<<"$outA"; check "A never names Bob (co-b only)" $?
grep -q 'DM from Bob' <<<"$outB"; check "B (co-b) wakes on Bob" $?
! grep -q 'DM from Ada' <<<"$outB"; check "B never names Ada" $?
! grep -q 'DM from Cy' <<<"$outB"; check "B (secondary) does not take Cy" $?
! grep -q 'DM from Dee' <<<"$outB"; check "B (secondary) does not take Dee" $?
la="$(ledger "$A")"; lb="$(ledger "$B")"
jcheck 'const rows=require("fs").readFileSync(0,"utf8").trim().split("\n").map(JSON.parse); const by=Object.fromEntries(rows.map(r=>[r.ref,r])); process.exit(by.ev_ada&&by.ev_ada.company==="co-a"&&by.ev_cy&&by.ev_cy.company===undefined&&by.ev_dee&&!by.ev_bob?0:1)' <<<"$la"
check "A's ledger: Ada carries company co-a, Cy and Dee no company, no Bob row" $?
jcheck 'const rows=require("fs").readFileSync(0,"utf8").trim().split("\n").map(JSON.parse); const refs=rows.map(r=>r.ref).sort().join(); process.exit(refs==="ev_bob"&&rows[0].company==="co-b"?0:1)' <<<"$lb"
check "B's ledger: only Bob, with company co-b" $?

# 4. The dropped DMs are seen on B: a later poll does not replay them once B
# becomes primary.
node "$STATE" set "$B" primary true >/dev/null
out="$(node "$ROUTE" primary --save "$A")"; [[ "$out" == "cl-bbb secondary" ]]; check "primary: true overrides start order ($out)" $?
out="$(watch "$B" co-b b)"; [[ -z "$out" ]]; check "ids already seen never replay after a primary change" $?
echo '[{"eventId":"ev_dee2","fromPersonUid":"prs_dee","fromDisplayName":"Dee","body":"again","createdAt":"2026-10-25T01:10:00Z"}]' >"$tmp/fx/inbox.json"
outA="$(watch "$A" co-a a)"; outB="$(watch "$B" co-b b)"
grep -q 'DM from Dee' <<<"$outB"; check "the marked primary now takes the unknown sender" $?
! grep -q 'DM from Dee' <<<"$outA"; check "the former primary no longer takes it" $?

# 5. A stale conductor is ignored: A alone takes everything again.
jcheck 'const f=process.argv[1]; const j=JSON.parse(require("fs").readFileSync(f,"utf8")); j.updated_at="2026-10-20T00:00:00Z"; j.dm_route.at="2026-10-20T00:00:00Z"; require("fs").writeFileSync(f, JSON.stringify(j))' "$B"
echo '[{"eventId":"ev_bob2","fromPersonUid":"prs_bob","fromDisplayName":"Bob","body":"anyone?","createdAt":"2026-10-25T01:20:00Z"}]' >"$tmp/fx/inbox.json"
outA="$(watch "$A" co-a a)"
grep -q 'DM from Bob' <<<"$outA"; check "with the other conductor stale, this one takes its DMs" $?
out="$(node "$ROUTE" primary --save "$A")"; [[ "$out" == "cl-aaa primary" ]]; check "a stale save file is not a conductor ($out)" $?

# 6. A failed roster read is reported once and does not stop the wake.
rm "$tmp/fx/members-co-a.json"
jcheck 'const f=process.argv[1]; const j=JSON.parse(require("fs").readFileSync(f,"utf8")); j.dm_route.at="2026-10-20T00:00:00Z"; require("fs").writeFileSync(f, JSON.stringify(j))' "$A"
echo '[{"eventId":"ev_ada3","fromPersonUid":"prs_ada","fromDisplayName":"Ada","body":"ping","createdAt":"2026-10-25T01:30:00Z"}]' >"$tmp/fx/inbox.json"
outA="$(watch "$A" co-a a)"
grep -q 'MESSAGE-WATCH-DEGRADED.*DM routing roster' <<<"$outA"; check "a failed members read prints one DEGRADED line" $?
grep -q 'DM from Ada' <<<"$outA"; check "the last published roster still routes the DM" $?
echo '{"members":[{"person_id":"prs_ada","email":"ada@example.com","status":"active"},{"person_id":"prs_cy","email":"cy@example.com","status":"active"}]}' >"$tmp/fx/members-co-a.json"

# 7. filter-dms for the sweep: same rule on a raw inbox.
printf '{"link":"cl-bbb","company":"co-b","updated_at":"%s","heartbeat":{"started_at":"2026-10-25T00:15:49Z"},"dm_route":{"companies":["co-b"],"members":{"co-b":{"uids":["prs_bob","prs_cy"],"emails":[]}},"at":"%s"}}\n' "$now" "$now" >"$B"
cat >"$tmp/inbox-all.json" <<'EOS'
[{"eventId":"e1","fromPersonUid":"prs_ada","fromDisplayName":"Ada"},{"eventId":"e2","fromPersonUid":"prs_bob","fromDisplayName":"Bob"},{"eventId":"e3","fromPersonUid":"prs_cy","fromDisplayName":"Cy"},{"eventId":"e4","fromEmail":"dee@example.com","fromDisplayName":"Dee"}]
EOS
out="$(node "$ROUTE" filter-dms --save "$A" <"$tmp/inbox-all.json")"
jcheck 'const j=JSON.parse(require("fs").readFileSync(0,"utf8")); const ids=j.map(r=>r.eventId).join(); const co=Object.fromEntries(j.map(r=>[r.eventId,[String(r._company),r._route].join("/")])); process.exit(ids==="e1,e3,e4"&&co.e1==="co-a/mine"&&co.e3==="null/shared"&&co.e4==="null/unknown"?0:1)' <<<"$out"
check "filter-dms keeps the primary's DMs with _company and _route" $?
out="$(node "$ROUTE" filter-dms --save "$B" <"$tmp/inbox-all.json")"
jcheck 'const j=JSON.parse(require("fs").readFileSync(0,"utf8")); process.exit(j.map(r=>r.eventId).join()==="e2"&&j[0]._company==="co-b"?0:1)' <<<"$out"
check "filter-dms keeps only the secondary's own-company DMs" $?
echo '{}' | node "$ROUTE" filter-dms --save "$A" >/dev/null 2>&1; [[ $? -eq 2 ]]; check "filter-dms refuses a non-array inbox" $?

# 7b. Self roster not yet published: a DM from a sender another conductor
# claims is kept here, not dropped (PR #1660 review). B has a roster; A has none.
printf '{"link":"cl-aaa","company":"co-a","updated_at":"%s","heartbeat":{"started_at":"2026-10-25T00:13:54Z"}}\n' "$now" >"$tmp/conduct/cl-ccc-state.json"
C="$tmp/conduct/cl-ccc-state.json"
jcheck 'const f=process.argv[1]; const j=JSON.parse(require("fs").readFileSync(f,"utf8")); j.link="cl-ccc"; j.heartbeat.started_at="2026-10-25T09:00:00Z"; require("fs").writeFileSync(f, JSON.stringify(j))' "$C"
node "$STATE" set "$B" primary true >/dev/null
echo '[{"eventId":"u1","fromPersonUid":"prs_cy","fromDisplayName":"Cy"},{"eventId":"u2","fromPersonUid":"prs_bob","fromDisplayName":"Bob"}]' >"$tmp/inbox-unpub.json"
out="$(node "$ROUTE" filter-dms --save "$C" <"$tmp/inbox-unpub.json")"
jcheck 'const j=JSON.parse(require("fs").readFileSync(0,"utf8")); process.exit(j.map(r=>r.eventId).join()==="u1,u2"&&j.every(r=>r._route==="unpublished")?0:1)' <<<"$out"
check "a secondary conductor with no published roster keeps DMs another conductor also claims" $?
# Once its roster is published, the normal rule applies again.
printf '{"link":"cl-ccc","company":"co-a","updated_at":"%s","heartbeat":{"started_at":"2026-10-25T09:00:00Z"},"dm_route":{"companies":["co-a"],"members":{"co-a":{"uids":["prs_ada"],"emails":[]}},"at":"%s"}}\n' "$now" "$now" >"$C"
out="$(node "$ROUTE" filter-dms --save "$C" <"$tmp/inbox-unpub.json")"
jcheck 'const j=JSON.parse(require("fs").readFileSync(0,"utf8")); process.exit(j.length===0?0:1)' <<<"$out"
check "with its roster published, a secondary drops senders only another conductor claims" $?
rm -f "$C"

# 8. Skill contract.
need() { grep -Eq -- "$1" "$SC" || { echo "FAIL: skill: $2" >&2; fail=1; }; }
need 'super-conductor-dm-route.mjs filter-dms' 'pipes the hq_dms sweep through filter-dms'
need 'super-conductor\.<company>\.yaml' 'documents the per-company settings overlay'
need 'primary: true' 'documents the primary conductor flag'
need '/conduct-join leave' 'documents /conduct-join leave when a child moves between links'
need '[Oo]ne conductor per company set' 'states one conductor per company set'
need 'super-conductor-prefs.mjs --company <slug>' 'documents --company on the prefs helper'

[[ "$fail" -eq 0 ]] || exit 1
echo "super-conductor dm route: ok"
