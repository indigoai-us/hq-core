#!/usr/bin/env bash
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"; w="$here/../ontology-source-worklist.sh"
fail=0; pass=0
check() { if [ "$2" = "$3" ]; then pass=$((pass+1)); else echo "FAIL: $1 — want '$3' got '$2'"; fail=$((fail+1)); fi; }
t="$(mktemp -d)"; trap 'rm -rf "$t"' EXIT
mkdir -p "$t/core/scripts" "$t/companies/acme/sources/meetings"
cp "$here"/../{knowledge-prefs.sh,ontology-candidate.sh,source-yaml-validate.sh,ontology-source-worklist.sh} "$t/core/scripts/"
M="$t/companies/acme/sources/meetings"
printf 'channel: meetings\nkind: meeting\narrives: cloud\naudience_rule: attendees\nprocessor: ontology/process-source\nrun: local\nschedule: on-close\n' > "$M/source.yaml"
printf -- '---\nid: m1\nattendees: [a@x.com, B@x.com]\n---\nbody\n' > "$M/m1.md"
printf -- '---\nid: m2\n---\nbody\n' > "$M/m2.md"
printf -- '---\nid: m3\n---\nbody\n' > "$M/m3.md"
cat > "$t/hq" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *"acl sources/meetings/m2.md"*) echo '{"direct":[{"granteeType":"person","granteeId":"prs_01ABC","permission":"read"},{"granteeType":"email","granteeId":"c@x.com","permission":"read"}]}' ;;
  *) echo '{"direct":[]}' ;;
esac
STUB
chmod +x "$t/hq"; export HQ_ROOT="$t" HQ_BIN="$t/hq"
out="$(bash "$w" --company acme --channel meetings)"
check "three items listed" "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" 3
check "frontmatter attendees used" "$(printf '%s\n' "$out" | jq -r 'select(.file|endswith("m1.md")) | .audience | join(",")')" "a@x.com,B@x.com"
check "same key as writer" "$(printf '%s\n' "$out" | jq -r 'select(.file|endswith("m1.md")) | .audience_key')" "$(bash "$t/core/scripts/ontology-candidate.sh" key 'a@x.com,b@x.com')"
check "acl attendees used, uid case kept" "$(printf '%s\n' "$out" | jq -r 'select(.file|endswith("m2.md")) | .audience | sort | join(",")')" "c@x.com,prs_01ABC"
check "no audience is a skip, not company" "$(printf '%s\n' "$out" | jq -r 'select(.file|endswith("m3.md")) | .skip')" "no-audience"
bash "$w" --company acme --channel meetings --mark-done "$M/m1.md"
check "mark-done removes from worklist" "$(bash "$w" --company acme --channel meetings | grep -c m1.md)" 0
# --- Slack DM frontmatter: resolved_participants-only (regression for feedback_b8d61e28) ---
mkdir -p "$t/companies/acme/sources/slack-dm"
S="$t/companies/acme/sources/slack-dm"
printf 'channel: slack-dm\nkind: slack\narrives: cloud\naudience_rule: thread\nprocessor: ontology/process-source\nrun: local\nschedule: on-close\n' > "$S/source.yaml"
printf -- '---\nid: dm1\nresolved_participants:\n  - person_uid: prs_01ALICE\n    slack_user_id: U001\n  - email: bob@x.com\n    slack_user_id: U002\n  - slack_user_id: U003\n---\nhello\n' > "$S/dm1.md"
printf -- '---\nid: dm2\n---\nhello\n' > "$S/dm2.md"
printf -- '---\nid: dm3\nresolved_participants:\n  - slack_user_id: U100\n  - slack_user_id: U101\n---\nhello\n' > "$S/dm3.md"
outdm="$(bash "$w" --company acme --channel slack-dm)"
check "dm resolved_participants: person_uid + email become audience" \
  "$(printf '%s\n' "$outdm" | jq -r 'select(.file|endswith("dm1.md")) | .audience | sort | join(",")')" \
  "bob@x.com,prs_01ALICE"
check "dm with no participant info is skipped as no-audience" \
  "$(printf '%s\n' "$outdm" | jq -r 'select(.file|endswith("dm2.md")) | .skip')" "no-audience"
check "dm with only slack_user_id entries is skipped (never widened)" \
  "$(printf '%s\n' "$outdm" | jq -r 'select(.file|endswith("dm3.md")) | .skip')" "no-audience"

# --- Auto-reprocess of previously-skipped no-audience DMs after parser upgrade ---
mkdir -p "$t/companies/acme/sources/slack-dm2"
R="$t/companies/acme/sources/slack-dm2"
printf 'channel: slack-dm2\nkind: slack\narrives: cloud\naudience_rule: thread\nprocessor: ontology/process-source\nrun: local\nschedule: on-close\n' > "$R/source.yaml"
# Shape the OLD parser could not read (resolved_participants only). First run
# must skip it as no-audience and record it in .skipped. Second run (same
# parser version) must NOT re-emit it; it is already recorded.
printf -- '---\nid: dmR\nresolved_participants:\n  - person_uid: prs_01REUSE\n---\nhello\n' > "$R/dmR.md"
out1="$(bash "$w" --company acme --channel slack-dm2)"
check "dmR picked up as work on first run (parser can read it)" \
  "$(printf '%s\n' "$out1" | jq -r 'select(.file|endswith("dmR.md")) | .audience | join(",")')" "prs_01REUSE"
# Simulate the historical bug: a prior caller marked dmR done even though no
# candidates were ever written. The heal pass must drop it from .processed on
# the next run because the file carries `resolved_participants:` frontmatter,
# so dmR must be re-emitted as work.
echo "dmR.md" >> "$R/.processed"
out2="$(bash "$w" --company acme --channel slack-dm2)"
check "pre-fix DM entry in .processed is healed and re-emitted" \
  "$(printf '%s\n' "$out2" | jq -r 'select(.file|endswith("dmR.md")) | .audience | join(",")')" "prs_01REUSE"
check ".processed healed (dmR removed)" \
  "$(grep -c '^dmR.md$' "$R/.processed" || true)" 0
# No-audience skip gets recorded in .skipped and is NOT re-emitted next run.
printf -- '---\nid: dmS\n---\nhello\n' > "$R/dmS.md"
out3="$(bash "$w" --company acme --channel slack-dm2)"
check "dmS first run emits no-audience skip" \
  "$(printf '%s\n' "$out3" | jq -r 'select(.file|endswith("dmS.md")) | .skip')" "no-audience"
check "dmS recorded in .skipped at current parser version" \
  "$(grep -c $'^dmS.md\tno-audience\t' "$R/.skipped" || true)" 1
out4="$(bash "$w" --company acme --channel slack-dm2)"
check "dmS not re-emitted while parser version unchanged" \
  "$(printf '%s\n' "$out4" | jq -r 'select(.file|endswith("dmS.md")) | .skip // empty' | wc -l | tr -d ' ')" 0
# Parser bump: drop version stamp (simulates older recorded version) → re-eval.
sed -i.bak 's/\tno-audience\t.*/\tno-audience\t1/' "$R/.skipped"; rm -f "$R/.skipped.bak"
out5="$(bash "$w" --company acme --channel slack-dm2)"
check "dmS re-evaluated after parser version bump" \
  "$(printf '%s\n' "$out5" | jq -r 'select(.file|endswith("dmS.md")) | .skip')" "no-audience"

# --- .processed is parser-version-stamped: a successfully processed DM stays
#     processed on a second run (regression: the pre-fix heal re-stripped every
#     slack-dm basename on every run because the file carries
#     resolved_participants:, so successfully processed DMs were reprocessed
#     forever). ---
mkdir -p "$t/companies/acme/sources/slack-dm3"
P="$t/companies/acme/sources/slack-dm3"
printf 'channel: slack-dm3\nkind: slack\narrives: cloud\naudience_rule: thread\nprocessor: ontology/process-source\nrun: local\nschedule: on-close\n' > "$P/source.yaml"
printf -- '---\nid: dmP\nresolved_participants:\n  - person_uid: prs_01KEEP\n---\nhello\n' > "$P/dmP.md"
outP1="$(bash "$w" --company acme --channel slack-dm3)"
check "dmP first run emits work" \
  "$(printf '%s\n' "$outP1" | jq -r 'select(.file|endswith("dmP.md")) | .audience | join(",")')" "prs_01KEEP"
bash "$w" --company acme --channel slack-dm3 --mark-done "$P/dmP.md"
check ".processed records dmP stamped at current parser version" \
  "$(grep -c $'^dmP.md\t2$' "$P/.processed" || true)" 1
outP2="$(bash "$w" --company acme --channel slack-dm3)"
check "processed DM is NOT re-emitted on second run (no reprocess loop)" \
  "$(printf '%s\n' "$outP2" | jq -r 'select(.file|endswith("dmP.md"))' | wc -l | tr -d ' ')" 0
check "processed DM stamp survives the heal" \
  "$(grep -c $'^dmP.md\t2$' "$P/.processed" || true)" 1

# --- Legacy unstamped ledger converges after one run: an unstamped entry
#     whose file carries NO resolved_participants is upgraded in place to a
#     stamp (never re-stripped on the next run). ---
mkdir -p "$t/companies/acme/sources/slack-dm4"
L="$t/companies/acme/sources/slack-dm4"
printf 'channel: slack-dm4\nkind: slack\narrives: cloud\naudience_rule: thread\nprocessor: ontology/process-source\nrun: local\nschedule: on-close\n' > "$L/source.yaml"
printf -- '---\nid: dmL\nattendees: [a@x.com]\n---\nhello\n' > "$L/dmL.md"
echo "dmL.md" >> "$L/.processed"
bash "$w" --company acme --channel slack-dm4 >/dev/null
check "legacy unstamped non-DM entry upgraded to stamped" \
  "$(grep -c $'^dmL.md\t2$' "$L/.processed" || true)" 1
check "legacy plain line removed after convergence" \
  "$(grep -c '^dmL.md$' "$L/.processed" || true)" 0

# --- CRLF: resolved_participants in a CRLF file still yields clean ids. ---
mkdir -p "$t/companies/acme/sources/slack-dm5"
C="$t/companies/acme/sources/slack-dm5"
printf 'channel: slack-dm5\nkind: slack\narrives: cloud\naudience_rule: thread\nprocessor: ontology/process-source\nrun: local\nschedule: on-close\n' > "$C/source.yaml"
printf -- '---\r\nid: dmC\r\nresolved_participants:\r\n  - person_uid: prs_01CRLF\r\n  - email: crlf@x.com\r\n---\r\nhello\r\n' > "$C/dmC.md"
outC="$(bash "$w" --company acme --channel slack-dm5)"
check "CRLF resolved_participants parses to clean ids (no stray \\r)" \
  "$(printf '%s\n' "$outC" | jq -r 'select(.file|endswith("dmC.md")) | .audience | sort | join(",")')" "crlf@x.com,prs_01CRLF"

# --- Newest-first ordering: unprocessed items are listed by the meeting's own
#     date (scheduled_start_time, then meeting_start, when, created_at, date),
#     newest first, before --limit applies. Filenames are ids, so glob order
#     says nothing about recency. ---
mkdir -p "$t/companies/acme/sources/meetings-order"
O="$t/companies/acme/sources/meetings-order"
printf 'channel: meetings-order\nkind: meeting\narrives: cloud\naudience_rule: attendees\nprocessor: ontology/process-source\nrun: local\nschedule: on-close\n' > "$O/source.yaml"
# 25 items; item i gets day (i*7 mod 25)+1 in October, so name order and date order disagree.
i=1
while [ "$i" -le 25 ]; do
  d=$(( (i * 7) % 25 + 1 ))
  printf -- '---\nid: o%02d\nscheduled_start_time: "2026-10-%02dT10:00:00Z"\ningested_at: "2026-11-01T00:00:00Z"\nattendees: [a@example.test]\n---\nbody\n' "$i" "$d" > "$O/o$(printf '%02d' "$i").md"
  i=$((i+1))
done
want_order=""
d=25
while [ "$d" -ge 6 ]; do
  i=1
  while [ "$i" -le 25 ]; do
    [ $(( (i * 7) % 25 + 1 )) -eq "$d" ] && want_order="$want_order o$(printf '%02d' "$i").md"
    i=$((i+1))
  done
  d=$((d-1))
done
outO="$(bash "$w" --company acme --channel meetings-order --limit 20)"
check "limit 20 over 25 items lists 20" "$(printf '%s\n' "$outO" | wc -l | tr -d ' ')" 20
check "the 20 newest by scheduled_start_time are listed newest first" \
  "$(printf '%s\n' "$outO" | jq -r '.file' | sed 's#.*/##' | tr '\n' ' ' | sed 's/ $//')" "${want_order# }"
newest="${want_order# }"; newest="${newest%% *}"
bash "$w" --company acme --channel meetings-order --mark-done "$O/$newest"
check "mark-done drops the newest item from the next run" \
  "$(bash "$w" --company acme --channel meetings-order --limit 20 | jq -r '.file' | grep -c "/$newest$" || true)" 0
bash "$w" --company acme --channel meetings-order --redo "sources/meetings-order/$newest"
check "--redo exits 0 for an item in the channel" "$?" 0
check "--redo removes the item from .processed" "$(grep -c "^$newest	" "$O/.processed" || true)" 0
check "--redo lists the item again, first by date" \
  "$(bash "$w" --company acme --channel meetings-order --limit 20 | head -1 | jq -r '.file' | sed 's#.*/##')" "$newest"
# --redo also clears a .skipped entry
printf -- '---\nid: onone\nscheduled_start_time: "2026-12-01T10:00:00Z"\n---\nbody\n' > "$O/onone.md"
bash "$w" --company acme --channel meetings-order --limit 1 >/dev/null
check "no-audience item recorded in .skipped" "$(grep -c '^onone.md	no-audience	' "$O/.skipped" || true)" 1
bash "$w" --company acme --channel meetings-order --redo "$O/onone.md"
check "--redo removes the item from .skipped" "$(grep -c '^onone.md	' "$O/.skipped" || true)" 0
check "--redo of a skipped item lists it again" \
  "$(bash "$w" --company acme --channel meetings-order --limit 1 | jq -r '.file' | sed 's#.*/##')" "onone.md"
# --redo refuses paths outside the channel directory and leaves the ledgers alone
bash "$w" --company acme --channel meetings-order --mark-done "$O/$newest"
cp "$O/.processed" "$t/processed.before"
bash "$w" --company acme --channel meetings-order --redo "$t/companies/acme/sources/slack-dm/dm1.md" >/dev/null 2>&1
check "--redo refuses an item in another channel" "$?" 2
bash "$w" --company acme --channel meetings-order --redo "../slack-dm/dm1.md" >/dev/null 2>&1
check "--redo refuses a traversal path" "$?" 2
bash "$w" --company acme --channel meetings-order --redo "sources/meetings-order/../meetings-order/$newest" >/dev/null 2>&1
check "--redo refuses a path with a .. segment" "$?" 2
bash "$w" --company acme --channel meetings-order --redo "missing.md" >/dev/null 2>&1
check "--redo refuses an item that does not exist" "$?" 2
check "refused --redo leaves .processed unchanged" "$(cmp -s "$O/.processed" "$t/processed.before"; echo $?)" 0

# --- Date keys, offsets and mtime fallback ---
mkdir -p "$t/companies/acme/sources/meetings-keys"
K="$t/companies/acme/sources/meetings-keys"
printf 'channel: meetings-keys\nkind: meeting\narrives: cloud\naudience_rule: attendees\nprocessor: ontology/process-source\nrun: local\nschedule: on-close\n' > "$K/source.yaml"
# scheduled_start_time wins over a later created_at (a mirror refresh rewrites ingest stamps)
printf -- '---\nid: k1\nscheduled_start_time: 2026-03-01T10:00:00Z\ncreated_at: 2026-11-01T10:00:00Z\nattendees: [a@example.test]\n---\nb\n' > "$K/k1.md"
printf -- '---\nid: k2\ncreated_at: "2026-04-01T10:00:00.000Z"\nattendees: [a@example.test]\n---\nb\n' > "$K/k2.md"
printf -- '---\nid: k3\nmeeting_start: 2026-05-01T10:00:00Z\nattendees: [a@example.test]\n---\nb\n' > "$K/k3.md"
printf -- '---\nid: k4\ndate: 2026-02-01\nattendees: [a@example.test]\n---\nb\n' > "$K/k4.md"
# offsets: k5 is 2026-06-01T20:00Z, k6 is 2026-06-01T22:00Z
printf -- '---\nid: k5\nscheduled_start_time: "2026-06-02T01:00:00+05:00"\nattendees: [a@example.test]\n---\nb\n' > "$K/k5.md"
printf -- '---\nid: k6\nscheduled_start_time: "2026-06-01T22:00:00Z"\nattendees: [a@example.test]\n---\nb\n' > "$K/k6.md"
# no date in frontmatter: fall back to file mtime
printf -- '---\nid: k0old\nattendees: [a@example.test]\n---\nb\n' > "$K/a-nodate-old.md"; touch -t 202001011200 "$K/a-nodate-old.md"
printf -- '---\nid: k0new\nattendees: [a@example.test]\n---\nb\n' > "$K/z-nodate-new.md"; touch -t 203001011200 "$K/z-nodate-new.md"
printf 'no frontmatter at all\n' > "$K/m-nofm.md"; touch -t 202501011200 "$K/m-nofm.md"
outK="$(bash "$w" --company acme --channel meetings-keys)"
check "date keys, offsets and mtime fallback order newest first" \
  "$(printf '%s\n' "$outK" | jq -r '.file' | sed 's#.*/##' | tr '\n' ' ' | sed 's/ $//')" \
  "z-nodate-new.md k6.md k5.md k3.md k2.md k1.md k4.md m-nofm.md a-nodate-old.md"
# equal dates break ties by filename
printf -- '---\nid: t2\nscheduled_start_time: 2026-07-01T10:00:00Z\nattendees: [a@example.test]\n---\nb\n' > "$K/tie-b.md"
printf -- '---\nid: t1\nscheduled_start_time: 2026-07-01T10:00:00Z\nattendees: [a@example.test]\n---\nb\n' > "$K/tie-a.md"
check "equal dates order by filename" \
  "$(bash "$w" --company acme --channel meetings-keys --limit 3 | jq -r '.file' | sed 's#.*/##' | tr '\n' ' ' | sed 's/ $//')" \
  "z-nodate-new.md tie-a.md tie-b.md"

sed -i.bak 's/run: local/run: cloud/' "$M/source.yaml"
bash "$w" --company acme --channel meetings >/dev/null 2>&1; check "run: cloud refuses locally" "$?" 4
bash "$w" --company acme --channel meetings --force >/dev/null 2>&1; check "--force overrides" "$?" 0
sed -i.bak '/audience_rule/d' "$M/source.yaml"
bash "$w" --company acme --channel meetings --force >/dev/null 2>&1; check "invalid source.yaml exits 2" "$?" 2
echo "ontology-source-worklist: $pass passed, $fail failed"; [ "$fail" -eq 0 ]
