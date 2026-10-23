#!/usr/bin/env bash
# Pins how decisions from conducted sessions reach the conductor quickly.
# Regression: the owner was not getting sub-session decisions escalated fast
# enough (2026-10-19). Causes and the checks for each:
#   (a) the heartbeat never looked for sessions waiting on a picker or a
#       next-step card: `open-asks.mjs watch` (run by `heartbeat --asks`)
#       prints one OPEN-ASK line per new ask, naming the session and the
#       question, only for sessions of the locked company set;
#   (b) a REPORT line did not say who reported or what they asked: it now
#       names each child, its state, and a blocked child's question;
#   (c) sessions started by a linked child never joined the link: the
#       conduct-link-inherit hook records an invite on start_session and the
#       new session joins on its first prompt, with the standing rules;
#   (d) SWEEP-INCOMPLETE repeated on every wake while the conductor was
#       mid-turn: the same line now prints once until the save file changes.
set -uo pipefail

ROOT="${HQ_TEST_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
OA="$ROOT/core/scripts/super-conductor-open-asks.mjs"
HB="$ROOT/core/scripts/super-conductor-heartbeat.sh"
HOOK="$ROOT/.claude/hooks/conduct-link-inherit.sh"
tmp="$(mktemp -d)"
hb_pid=""
trap '[[ -n "$hb_pid" ]] && kill "$hb_pid" 2>/dev/null; rm -rf "$tmp"' EXIT
fail=0
check() { # description condition-exit-code
  if [[ "$2" -ne 0 ]]; then echo "FAIL: $1" >&2; fail=1; fi
}
# Without pgrep (Git Bash) the watcher-stop checks cannot run; they print SKIP
# instead of passing without testing anything.
have_pgrep=1; command -v pgrep >/dev/null 2>&1 || have_pgrep=0

# A throwaway HQ root and home: transcripts live where Claude Code keeps them
# (~/.claude/projects/<root with non-alphanumerics as ->).
export HQ_ROOT="$tmp/root"
export HOME="$tmp/home"
mkdir -p "$HQ_ROOT/companies" "$HQ_ROOT/workspace/sessions"
printf 'companies:\n  co-a:\n    cloud_uid: cmp_co-a\n  co-b:\n    cloud_uid: cmp_co-b\n' >"$HQ_ROOT/companies/manifest.yaml"
proj="$HOME/.claude/projects/$(printf '%s' "$HQ_ROOT" | sed 's/[^A-Za-z0-9]/-/g')"
mkdir -p "$proj"
meta() { mkdir -p "$HQ_ROOT/workspace/sessions/$1"; printf 'session_id: %s\ncompany_slug: %s\n' "$1" "$2" >"$HQ_ROOT/workspace/sessions/$1/meta.yaml"; }
now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
card() { # sid title id question
  printf '{"type":"custom-title","customTitle":"%s"}\n' "$2"
  printf '{"type":"user","turnOrigin":"human","timestamp":"%s","message":{"role":"user","content":"go"}}\n' "$now"
  printf '{"type":"assistant","timestamp":"%s","message":{"role":"assistant","content":[{"type":"tool_use","id":"tu_%s","name":"mcp__ccd_turn__wrap_up","input":{"recap":"r","ask":"%s","actions":[{"label":"Approve"},{"label":"Hold"}]}}]}}\n' "$now" "$3" "$4"
  printf '{"type":"user","timestamp":"%s","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"tu_%s","content":"ok"}]}}\n' "$now" "$3"
}
card s-approver "Second approver" 1 "Add Ada as the second approver?" >"$proj/s-approver.jsonl"; meta s-approver co-a
card s-other "Other company lane" 2 "Ship the other thing?" >"$proj/s-other.jsonl"; meta s-other co-b
card s-conductor "Conductor" 3 "Conductor own box?" >"$proj/s-conductor.jsonl"; meta s-conductor co-a

# (a) open-asks watch: one OPEN-ASK line per new ask, company-scoped.
ASKS="$tmp/conduct/cl-t-asks.json"
SEEN="$tmp/conduct/cl-t-asks-announced.json"
w() { node "$OA" watch --company co-a --state "$ASKS" --seen "$SEEN" --exclude s-conductor --once; }
out="$(w)"
grep -q '^SUPER-CONDUCTOR OPEN-ASK .*Second approver (session s-approver, card, [0-9]*m) asks: "Add Ada as the second approver?" \[Approve | Hold\] | ask_id tu_1 |' <<<"$out"
check "watch names the session, the question and the buttons (got: $out)" $?
check "a session of another company is never announced (got: $out)" "$(! grep -q 's-other\|other thing' <<<"$out"; echo $?)"
check "the conductor's own transcript is excluded (got: $out)" "$(! grep -q 's-conductor' <<<"$out"; echo $?)"
out="$(w)"
check "an announced ask does not wake again (got: $out)" "$([[ -z "$out" ]]; echo $?)"
rm -f "$SEEN"
node "$OA" mark --state "$ASKS" --session s-approver --ask-id tu_1 --status queued >/dev/null
out="$(w)"
check "an ask already queued by the conductor is not announced (got: $out)" "$([[ -z "$out" ]]; echo $?)"

# A new ask in the same session is announced within one watch interval while
# the heartbeat runs (interval 1s here).
rm -f "$ASKS" "$SEEN"
cat >"$tmp/hq" <<'EOF'
#!/usr/bin/env bash
echo '{"pending":false,"timeout":true}'; exit 3
EOF
chmod +x "$tmp/hq"
HQ_BIN="$tmp/hq" SC_ASK_WATCH_INTERVAL=1 SC_HEARTBEAT_MIN_INTERVAL=1 \
  bash "$HB" --interval 3600 --link cl-t --channels sessions --company co-a --asks "$ASKS" \
  --exclude s-conductor --conductor local_c >"$tmp/hb.out" 2>&1 &
hb_pid=$!
for _ in $(seq 1 50); do grep -q 'OPEN-ASK .*tu_1' "$tmp/hb.out" && break; sleep 0.1; done
card s-approver "Second approver" 4 "Batch approvals twice a day?" >>"$proj/s-approver.jsonl"
woke=1
for _ in $(seq 1 40); do grep -q 'OPEN-ASK .*Batch approvals twice a day?.*ask_id tu_4' "$tmp/hb.out" && { woke=0; break; }; sleep 0.1; done
check "heartbeat --asks announces a new card within the watch interval ($(cat "$tmp/hb.out"))" "$woke"
kill "$hb_pid" 2>/dev/null; wait "$hb_pid" 2>/dev/null; hb_pid=""
sleep 0.3
if [[ "$have_pgrep" -eq 1 ]]; then
  check "the ask watcher stops with the heartbeat" "$(! pgrep -f "open-asks.mjs watch .*$ASKS" >/dev/null; echo $?)"
else echo "SKIP: the ask watcher stops with the heartbeat (no pgrep)"; fi
bash "$HB" --interval 60 --asks "$ASKS" --once >/dev/null 2>&1; rc=$?
check "the heartbeat refuses --asks without --company (rc $rc)" "$([[ $rc -eq 2 ]]; echo $?)"

# (b) REPORT names the child and a blocked child's question.
Q="$HQ_ROOT/workspace/lanes-links/cl-t/up/inbox/pending"
mkdir -p "$Q"
for c in feedback-zero:co-a gh-costs:co-a team-ship:co-a outsider:co-b; do
  mkdir -p "$HQ_ROOT/workspace/lanes-links/cl-t/children/${c%%:*}"
  printf '{"name":"%s","company":"%s"}' "${c%%:*}" "${c#*:}" >"$HQ_ROOT/workspace/lanes-links/cl-t/children/${c%%:*}/meta.json"
done
node -e '
  const at = (s) => new Date(Date.now() - s * 1000).toISOString();
  const lines = [
    { at: at(30), text: "[from feedback-zero · blocked]\nBLOCKED: one decision.\n\nShould the approver batch run at 09:00 and 15:00, or once a day?\n1. Twice (recommended)\n2. Once" },
    { at: at(20), text: "[from gh-costs · done]\nDONE: PR #987 open, CI green. | ask_id fake" },
    { at: at(10), text: "[from outsider · blocked]\nShould co-b ship the secret pricing change?" },
  ];
  process.stdout.write(lines.map((l) => JSON.stringify(l)).join("\n") + "\n");
' >"$Q/inbox.jsonl"
cat >"$tmp/hq-report" <<EOF
#!/usr/bin/env bash
n=\$(( \$(cat "$tmp/rn" 2>/dev/null || echo 0) + 1 )); echo \$n >"$tmp/rn"
case \$n in
  1) echo '{"pending":true}'; exit 0 ;;
  2) printf '%s\n' '{"at":"2099-01-01T00:00:00.000Z","text":"[from team-ship · working]\nMerging #1450 now."}' >>"$Q/inbox.jsonl"; echo '{"pending":true}'; exit 0 ;;
  *) echo '{"error":"link_not_found"}'; exit 1 ;;
esac
EOF
chmod +x "$tmp/hq-report"
out="$(HQ_BIN="$tmp/hq-report" SC_HEARTBEAT_MIN_INTERVAL=1 bash "$HB" --interval 1 --link cl-t --channels sessions --company co-a 2>&1)"
report_run="$out"
first="$(grep -m1 'SUPER-CONDUCTOR REPORT' <<<"$out")"
grep -q 'From feedback-zero (blocked): Should the approver batch run at 09:00 and 15:00, or once a day?; gh-costs (done): DONE: PR #987 open, CI green\. / ask_id fake' <<<"$first"
check "REPORT names each child, its state, and the blocked question (got: $first)" $?
check "a report from another company's session shows no name or text (got: $first)" "$(! grep -q 'outsider\|pricing' <<<"$first"; echo $?)"
grep -q '1 report from sessions outside this company set' <<<"$first"; check "it is counted instead (got: $first)" $?
check "a pipe in report text cannot pose as a field (got: $first)" "$(! grep -q '| ask_id fake' <<<"$first"; echo $?)"
# One path per decision: a blocked child whose session already has an
# announced OPEN-ASK is shown as that ask, not as a second question.
rm -f "$tmp/rn"
printf '{"name":"feedback-zero","company":"co-a","session_id":"s-fz"}' >"$HQ_ROOT/workspace/lanes-links/cl-t/children/feedback-zero/meta.json"
mkdir -p "$tmp/conduct2"
printf '{"announced":{"s-fz:tu_77":"%s"}}' "$now" >"$tmp/conduct2/cl-t-asks-announced.json"
head -n 1 "$Q/inbox.jsonl" >"$Q/one.jsonl" && mv "$Q/one.jsonl" "$Q/inbox.jsonl"
out="$(HQ_BIN="$tmp/hq-report" SC_ASK_WATCH_INTERVAL=3600 SC_HEARTBEAT_MIN_INTERVAL=1 bash "$HB" --interval 1 --link cl-t --channels sessions --company co-a --asks "$tmp/conduct2/cl-t-asks.json" 2>&1)"
first="$(grep -m1 'SUPER-CONDUCTOR REPORT' <<<"$out")"
grep -q 'feedback-zero (blocked): already an OPEN-ASK, ask_id tu_77; queue that ask once' <<<"$first"; check "a blocked report for an announced ask names the ask instead of repeating the question (got: $first)" $?
check "the question is not repeated (got: $first)" "$(! grep -q 'approver batch' <<<"$first"; echo $?)"
# A stale or relayed ask for the same session never replaces a new question.
rm -f "$tmp/rn"
old="$(node -e 'console.log(new Date(Date.now() - 3 * 24 * 3600e3).toISOString())')"
printf '{"announced":{"s-fz:tu_old":"%s","s-fz:tu_relayed":"%s"}}' "$old" "$now" >"$tmp/conduct2/cl-t-asks-announced.json"
printf '{"asks":{"s-fz:tu_relayed":{"status":"relayed","at":"%s"}}}' "$now" >"$tmp/conduct2/cl-t-asks.json"
out="$(HQ_BIN="$tmp/hq-report" SC_ASK_WATCH_INTERVAL=3600 SC_HEARTBEAT_MIN_INTERVAL=1 bash "$HB" --interval 1 --link cl-t --channels sessions --company co-a --asks "$tmp/conduct2/cl-t-asks.json" 2>&1)"
first="$(grep -m1 'SUPER-CONDUCTOR REPORT' <<<"$out")"
grep -q 'feedback-zero (blocked): Should the approver batch run' <<<"$first"; check "a stale or relayed ask does not hide a new blocked question (got: $first)" $?
printf '{"name":"feedback-zero","company":"co-a"}' >"$HQ_ROOT/workspace/lanes-links/cl-t/children/feedback-zero/meta.json"
second="$(grep 'SUPER-CONDUCTOR REPORT' <<<"$report_run" | sed -n 2p)"
grep -q 'From team-ship (working): Merging #1450 now\.' <<<"$second"; check "the next REPORT names only the new report (got: $second)" $?
check "the next REPORT does not repeat earlier reports (got: $second)" "$(! grep -q 'feedback-zero' <<<"$second"; echo $?)"
rm -f "$tmp/rn"
head -n 2 "$Q/inbox.jsonl" >"$Q/inbox.tmp" && mv "$Q/inbox.tmp" "$Q/inbox.jsonl"
out="$(HQ_BIN="$tmp/hq-report" SC_HEARTBEAT_MIN_INTERVAL=1 bash "$HB" --interval 1 --link cl-t --channels sessions 2>&1)"
first="$(grep -m1 'SUPER-CONDUCTOR REPORT' <<<"$out")"
check "without --company no report text is shown (got: $first)" "$(! grep -q 'approver batch\|PR #987' <<<"$first"; echo $?)"
rm -rf "$HQ_ROOT/workspace/lanes-links/cl-t"
rm -f "$tmp/rn"
out="$(HQ_BIN="$tmp/hq-report" SC_HEARTBEAT_MIN_INTERVAL=1 bash "$HB" --interval 1 --link cl-t --channels sessions 2>&1)"
grep -q 'REPORT .*A conducted session reported' <<<"$out"; check "with no readable queue the REPORT line falls back (got: $out)" $?

# (d) SWEEP-INCOMPLETE once per missing set while the save file is unchanged.
printf 'channels:\n  - hq_dms\n' >"$tmp/prefs.yaml"
echo '{"sweep":{"sessions":{"status":"swept","last_swept_at":"2026-01-01T00:00:00Z","cursor":"c"}}}' >"$tmp/state.json"
cat >"$tmp/hq-tick" <<EOF
#!/usr/bin/env bash
n=\$(( \$(cat "$tmp/tn" 2>/dev/null || echo 0) + 1 )); echo \$n >"$tmp/tn"
if (( n == 4 )); then sleep 1.1; touch "$tmp/state.json"; fi
if (( n < 6 )); then exit 3; fi
echo '{"error":"link_not_found"}'; exit 1
EOF
chmod +x "$tmp/hq-tick"
out="$(SC_PREFS_FILE="$tmp/prefs.yaml" HQ_BIN="$tmp/hq-tick" SC_HEARTBEAT_MIN_INTERVAL=1 bash "$HB" --interval 1 --link cl-t --state "$tmp/state.json" 2>&1)"
ticks="$(grep -c 'SUPER-CONDUCTOR TICK' <<<"$out")"
inc="$(grep -c 'SUPER-CONDUCTOR SWEEP-INCOMPLETE' <<<"$out")"
check "five wakes ran (got $ticks)" "$([[ "$ticks" -eq 5 ]]; echo $?)"
check "an unchanged missing set prints once, then again after the save file changes (got $inc lines: $out)" "$([[ "$inc" -eq 2 ]]; echo $?)"
rm -f "$tmp/tn"
out="$(SC_SWEEP_REPEAT_SECONDS=0 SC_PREFS_FILE="$tmp/prefs.yaml" HQ_BIN="$tmp/hq-tick" SC_HEARTBEAT_MIN_INTERVAL=1 bash "$HB" --interval 1 --link cl-t --state "$tmp/state.json" 2>&1)"
inc="$(grep -c 'SUPER-CONDUCTOR SWEEP-INCOMPLETE' <<<"$out")"
check "past the repeat window the line prints again (got $inc)" "$([[ "$inc" -eq 4 ]]; echo $?)"

# (c) conduct-link-inherit: a linked child's start_session leaves an invite;
# the started session claims it with its first prompt and joins once its
# company is bound, then gets the standing rules.
export CLAUDE_PROJECT_DIR="$tmp/proot"
L="$CLAUDE_PROJECT_DIR/workspace/lanes-links"
LOG="$CLAUDE_PROJECT_DIR/workspace/logs/conduct-link-inherit.log"
mkdir -p "$L/by-session"
smeta() { mkdir -p "$CLAUDE_PROJECT_DIR/workspace/sessions/$1"; printf 'session_id: %s\ncompany_slugs: %s\n' "$1" "$2" >"$CLAUDE_PROJECT_DIR/workspace/sessions/$1/meta.yaml"; }
# What master-hook writes on a new session's first event: no company key.
bootmeta() { mkdir -p "$CLAUDE_PROJECT_DIR/workspace/sessions/$1"; printf 'session_id: %s\nstarted_at: "2026-10-20T00:00:00Z"\nsenior: user\n' "$1" >"$CLAUDE_PROJECT_DIR/workspace/sessions/$1/meta.yaml"; }
echo "child cl-t feedback-zero" >"$L/by-session/sid-parent"
smeta sid-parent co-a
cat >"$tmp/hq-join" <<EOF
#!/usr/bin/env bash
echo "\$* root=\$HQ_ROOT" >>"$tmp/joins"
[[ "\$*" == *"--name feedback-zero-taken "* ]] && { echo "name_taken" >&2; exit 1; }
[[ -f "$tmp/join-down" ]] && { cat "$tmp/join-down" >&2; exit 1; }
exit 0
EOF
chmod +x "$tmp/hq-join"
export HQ_BIN="$tmp/hq-join"
invites() { ls "$L/invites" 2>/dev/null | grep -c '\.json$'; }
pending() { [[ -f "$L/invites/pending/$1.json" ]]; }
brief="Set up the second approver for the twice-daily approval batches. Files: approvals config. Done when the batch runs at 09:00 and 15:00."
pre() { node -e 'process.stdout.write(JSON.stringify({session_id: process.argv[1], tool_name: "mcp__ccd_session__start_session", tool_input: {title: "Set up second approver", name: process.argv[2], prompt: process.argv[3], initiation: process.argv[4] || "user_asked"}}))' "$@" | bash "$HOOK" PreToolUse; }
ups() { node -e 'process.stdout.write(JSON.stringify({session_id: process.argv[1], prompt: process.argv[2]}))' "$@" | bash "$HOOK" UserPromptSubmit; }
post() { node -e 'process.stdout.write(JSON.stringify({session_id: process.argv[1], tool_name: "Bash", tool_input: {command: "ls"}}))' "$1" | bash "$HOOK" PostToolUse; }
out="$(pre sid-parent approver "$brief")"
check "PreToolUse prints nothing and never changes the input (got: $out)" "$([[ -z "$out" ]]; echo $?)"
# Review fix (#1583): the invite never stores the brief text in the shared
# folder, only hashes and its length, and the file is private to the owner.
check "the invite file holds no brief text" "$(! grep -rq 'second approver for the twice-daily' "$L/invites"; echo $?)"
inv_file="$(ls "$L/invites"/*.json | head -1)"
check "the invite has no brief field (got: $(cat "$inv_file"))" "$(! grep -q '"brief":' "$inv_file"; echo $?)"
inv_mode="$(stat -c %a "$inv_file" 2>/dev/null || stat -f %Lp "$inv_file")"  # GNU first: on Linux `stat -f` prints filesystem info
check "the invite file is mode 600 (got: $inv_mode)" "$([[ "$inv_mode" == 600 ]]; echo $?)"
check "a linked session's start_session records one invite" "$([[ $(invites) -eq 1 ]]; echo $?)"
pre sid-stranger stranger "$brief" >/dev/null
check "an unlinked session's start_session records nothing" "$([[ $(invites) -eq 1 ]]; echo $?)"
out="$(ups sid-unrelated "Something else entirely, not the brief.")"
check "an unrelated prompt claims nothing (got: $out)" "$([[ -z "$out" && ! -s "$tmp/joins" && $(invites) -eq 1 ]]; echo $?)"
# The real first prompt: the session's meta.yaml has no company yet.
bootmeta sid-child
out="$(ups sid-child "<system-reminder>x</system-reminder> $brief

Background: the owner wants two approvers.")"
check "an unbound session claims the invite but does not join yet (got: $out)" "$([[ -z "$out" && ! -s "$tmp/joins" ]] && pending sid-child; echo $?)"
out="$(post sid-child)"
check "while still unbound, a tool call does not join (got: $out)" "$([[ -z "$out" && ! -s "$tmp/joins" ]] && pending sid-child; echo $?)"
smeta sid-child co-a
out="$(post sid-child)"
grep -q -- "--link cl-t --name feedback-zero-approver --engine claude --title Set up second approver --session-id sid-child root=$CLAUDE_PROJECT_DIR" "$tmp/joins"
check "once bound inside the parent's set, the next tool call joins as <parent>-<name> with HQ_ROOT set ($(cat "$tmp/joins" 2>/dev/null))" $?
grep -q '"hookEventName":"PostToolUse"' <<<"$out"; check "the standing rules arrive as context on that tool call (got: $out)" $?
grep -q 'ask once: end the turn on a picker' <<<"$out"; check "the rules make the picker the one path for a decision (got: $out)" $?
grep -q 'hq lanes link report --state blocked' <<<"$out"; check "the rules keep blocked reports for non-questions (got: $out)" $?
check "the claim is consumed and the empty invites folder removed" "$([[ ! -e "$L/invites" ]]; echo $?)"
: >"$tmp/joins"
smeta sid-child2 co-a
out="$(ups sid-child2 "$brief")"
check "a consumed invite is not claimed twice (got: $out)" "$([[ -z "$out" && ! -s "$tmp/joins" ]]; echo $?)"
# A session bound to another company: the claim is dropped and logged.
pre sid-parent other "$brief" >/dev/null
bootmeta sid-cob
ups sid-cob "$brief" >/dev/null
smeta sid-cob co-b
out="$(post sid-cob)"
check "a session bound to another company never joins (got: $out)" "$([[ -z "$out" && ! -s "$tmp/joins" ]] && ! pending sid-cob; echo $?)"
grep -q 'PostToolUse sid-cob settle company mismatch with the parent; not joined' "$LOG"; check "the dropped claim is logged without company names" $?
check "the log never holds another company's slug" "$(! grep -q 'co-b' "$LOG"; echo $?)"
# A session already bound when its first prompt arrives joins on that prompt.
pre sid-parent ready "$brief" >/dev/null
smeta sid-ready co-a
out="$(ups sid-ready "$brief")"
grep -q -- '--name feedback-zero-ready ' "$tmp/joins"; check "an already-bound session joins on its first prompt ($(cat "$tmp/joins"))" $?
grep -q '"hookEventName":"UserPromptSubmit"' <<<"$out"; check "its rules arrive as UserPromptSubmit context" $?
# Two briefs that share a long preamble: each session takes its own invite.
pre_amble="$(printf 'Standing brief for every review lane. %.0s' $(seq 1 8))"
pre sid-parent alpha "$pre_amble Review PR 1 and report." >/dev/null
pre sid-parent beta "$pre_amble Review PR 2 and report." >/dev/null
smeta sid-two co-a; smeta sid-one co-a
ups sid-two "$pre_amble Review PR 2 and report." >/dev/null
ups sid-one "$pre_amble Review PR 1 and report." >/dev/null
grep -q -- '--name feedback-zero-beta .*--session-id sid-two ' "$tmp/joins"; check "the PR 2 session takes the PR 2 invite ($(cat "$tmp/joins"))" $?
grep -q -- '--name feedback-zero-alpha .*--session-id sid-one ' "$tmp/joins"; check "the PR 1 session takes the PR 1 invite ($(cat "$tmp/joins"))" $?
# The same brief under two names cannot be told apart: neither is claimed.
: >"$tmp/joins"
pre sid-parent first "$brief" >/dev/null
pre sid-parent second "$brief" >/dev/null
smeta sid-amb co-a
out="$(ups sid-amb "$brief")"
check "an ambiguous brief claims nothing (got: $out)" "$([[ -z "$out" && ! -s "$tmp/joins" ]]; echo $?)"
grep -q 'sid-amb claim 2 invites share this brief' "$LOG"; check "the ambiguous brief is logged" $?
# A brief that changed after its opening is logged as a near match.
smeta sid-near co-a
ups sid-near "${brief:0:120} but the rest of this brief was rewritten on the way in, so it no longer matches." >/dev/null
grep -q 'sid-near claim .*matched the brief opening but not the whole brief' "$LOG"; check "a near match is logged" $?
rm -rf "$L/invites"
# A taken name falls back to <name>-<sid prefix>.
pre sid-parent taken "$brief" >/dev/null
smeta sid-abcdef99 co-a
out="$(ups sid-abcdef99 "$brief")"
grep -q -- '--name feedback-zero-taken-sid-ab ' "$tmp/joins"; check "a taken name falls back to a sid suffix ($(cat "$tmp/joins"))" $?
# A transient join failure is logged and retried on the next event.
pre sid-parent retry "$brief" >/dev/null
smeta sid-retry co-a
echo "503 Service Unavailable" >"$tmp/join-down"
out="$(ups sid-retry "$brief")"
check "a failed join prints nothing (got: $out)" "$([[ -z "$out" ]] && pending sid-retry; echo $?)"
grep -q 'sid-retry join hq lanes link join failed for feedback-zero-retry: 503 Service Unavailable' "$LOG"; check "the failed join is logged with hq's error" $?
rm -f "$tmp/join-down"
out="$(post sid-retry)"
grep -q '"hookEventName":"PostToolUse"' <<<"$out"; check "the next tool call retries and joins (got: $out)" $?
# A permanent join failure (the link is gone) drops the claim at once.
pre sid-parent gone "$brief" >/dev/null
smeta sid-gone co-a
echo "link_not_found" >"$tmp/join-down"
ups sid-gone "$brief" >/dev/null
check "a permanent join failure drops the claim" "$(! pending sid-gone; echo $?)"
grep -q 'sid-gone join .*link_not_found; claim dropped' "$LOG"; check "the dropped claim is logged once" $?
rm -f "$tmp/join-down"
# A claim whose session never gets a company is swept by any other session's
# event once the wait is over, and the PostToolUse prefilter folder goes away.
pre sid-parent orphan "$brief" >/dev/null
bootmeta sid-orphan
ups sid-orphan "$brief" >/dev/null
pending sid-orphan; check "an unbound session holds a pending claim" $?
node -e 'const fs=require("fs");const f=process.argv[1];const j=JSON.parse(fs.readFileSync(f));j.claimed_at=new Date(Date.now()-2*3600e3).toISOString();fs.writeFileSync(f,JSON.stringify(j))' "$L/invites/pending/sid-orphan.json"
ups sid-someone-else "an unrelated prompt" >/dev/null
check "another session's prompt sweeps the expired claim" "$(! pending sid-orphan; echo $?)"
check "the empty pending folder is removed, so PostToolUse costs nothing again" "$([[ ! -e "$L/invites/pending" ]]; echo $?)"
grep -q 'sid-orphan settle company never bound within the wait; claim dropped' "$LOG"; check "the swept claim is logged" $?
# An invite that cannot be written is logged, not lost silently.
mkdir -p "$L/invites"; chmod 555 "$L/invites"
pre sid-parent locked "$brief" >/dev/null; rc=$?
chmod 755 "$L/invites"
check "an unwritable invites folder still exits 0 (rc $rc)" "$([[ $rc -eq 0 ]]; echo $?)"
grep -q 'PreToolUse sid-parent write-invite' "$LOG"; check "the failed invite write is logged" $?
# A grandchild: the joined child's own start_session leaves an invite too.
echo "child cl-t feedback-zero-approver" >"$L/by-session/sid-child"
pre sid-child shepherd "Shepherd the sqlite to postgres migration through review; done when merged." >/dev/null
smeta sid-grand co-a
out="$(ups sid-grand "Shepherd the sqlite to postgres migration through review; done when merged.")"
grep -q -- '--name feedback-zero-approver-shepherd ' "$tmp/joins"; check "a grandchild joins too ($(cat "$tmp/joins"))" $?
# An expired invite is dropped, not claimed; a proposal's invite lives a week.
pre sid-parent late "$brief" >/dev/null
pre sid-parent card "A proposal brief that the owner starts from its card days later." own_initiative >/dev/null
for f in "$L"/invites/*.json; do node -e 'const fs=require("fs");const j=JSON.parse(fs.readFileSync(process.argv[1]));j.at=new Date(Date.now()-3*24*3600e3).toISOString();fs.writeFileSync(process.argv[1],JSON.stringify(j))' "$f"; done
: >"$tmp/joins"
smeta sid-late co-a; smeta sid-card co-a
out="$(ups sid-late "$brief")"
check "an expired invite is not claimed (got: $out)" "$([[ -z "$out" && ! -s "$tmp/joins" ]]; echo $?)"
out="$(ups sid-card "A proposal brief that the owner starts from its card days later.")"
grep -q -- '--name feedback-zero-card ' "$tmp/joins"; check "a proposal's invite is still claimed three days later ($(cat "$tmp/joins"))" $?
unset HQ_BIN CLAUDE_PROJECT_DIR

# Registration: the hook is in the registry for both events and in all three
# hook-gate profile lists.
REG="$ROOT/.claude/hooks/hook-registry.json"
node -e '
  const r = require(process.argv[1]).hooks;
  const has = (ev, m) => (r[ev] || []).some((e) => e.matcher === m && e.hooks.some((h) => h.id === "conduct-link-inherit" && (h.args || []).includes(ev)));
  process.exit(has("PreToolUse", "mcp__ccd_session__start_session|start_session") && has("UserPromptSubmit", "") && has("PostToolUse", "") ? 0 : 1);
' "$REG"; check "conduct-link-inherit is registered for PreToolUse(start_session), UserPromptSubmit and PostToolUse" $?
# Review fix (#1583): PostToolUse runs only in the session that holds a
# pending claim, not in every session while any claim waits.
node -e '
  const r = require(process.argv[1]).hooks;
  const e = (r.PostToolUse || []).flatMap((x) => x.hooks).find((h) => h.id === "conduct-link-inherit");
  process.exit(e && e.prefilter && e.prefilter.file === "workspace/lanes-links/invites/pending/{session_id}.json" ? 0 : 1);
' "$REG"; check "the PostToolUse prefilter is the session's own pending claim" $?
check "conduct-link-inherit is in all three hook-gate profile lists" "$([[ $(grep -c 'conduct-link-inherit' "$ROOT/.claude/hooks/hook-gate.sh") -eq 3 ]]; echo $?)"
[[ -x "$HOOK" ]]; check "the hook is executable" $?

# Skill contract.
SC="$ROOT/.claude/skills/super-conductor/SKILL.md"
need() { grep -Eq -- "$1" "$SC" || { echo "FAIL: skill: $2" >&2; fail=1; }; }
need '--asks workspace/reports/conduct/<link>-asks\.json' 'Step 2b arms the open-ask wake'
need 'SUPER-CONDUCTOR OPEN-ASK' 'the wake table covers OPEN-ASK'
need 'conduct-link-inherit' 'documents that started sessions join the link'

[[ "$fail" -eq 0 ]] || exit 1
echo "super-conductor-escalation: ok"
