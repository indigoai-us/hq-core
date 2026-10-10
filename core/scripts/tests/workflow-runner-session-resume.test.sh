#!/bin/bash
# hq-core: public
# Regression test for engine-session resume in `workflow-runner.mjs --loop`.
#
# Fake claude, codex and grok binaries record their argv and report a session
# id the way the real CLIs do (claude: session_id in the JSON envelope, grok:
# sessionId in the envelope, codex: a "session id: <uuid>" log line). Covered:
#   1. claude: first phase of a story starts fresh with --session-id and
#      records the id under sessions/<story>.json; the next phase of the same
#      story runs with --resume <that id>
#   2. codex: a later phase of the same story runs `exec resume ... -- <id>`;
#      a phase of a different story has no resume, records a new id, and the
#      old story's record is gone
#   3. grok: resume uses --resume <id> (never --continue); an envelope that
#      reports a different session counts as a failed resume and reruns fresh
#   4. a stale session id that the engine rejects is retried once fresh, and
#      the result file records the fallback
#   5. --no-resume: two phases of one story, neither argv resumes
#      and a codex call with no session-id header records nothing
#   6. "fresh": true on one envelope forces a fresh call for that phase only

# The check "$([ cond ]; echo $?)" idiom reads the condition's status on purpose.
# shellcheck disable=SC2319
set -uo pipefail
unset HQ_SPAWN_COMPANY HQ_SESSION_ID HQ_PARENT_SESSION_ID HQ_WORKFLOW_NO_RESUME HQ_CONDUCT_RUN_DIR
# Isolation: this suite never inherits the caller's session. Its own session id,
# and (below) its own HQ_ROOT with workspace/sessions and run dirs under a temp root,
# keep every pool call, lane and signal inside what this test started.
export HQ_SESSION_ID="test-workflow-runner-session-resume-$$"

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
RUNNER="$REPO_ROOT/core/scripts/workflow-runner.mjs"

pass=0
fail=0
check() {
  if [ "$2" -eq 0 ]; then printf 'ok   - %s\n' "$1"; pass=$((pass + 1))
  else printf 'FAIL - %s\n' "$1"; fail=$((fail + 1)); fi
}

TMP="$(mktemp -d /tmp/workflow-runner-resume-test.XXXXXX)"
TMP="$(cd "$TMP" && pwd -P)"
LANE_PID=""
cleanup() {
  [ -n "$LANE_PID" ] && kill "$LANE_PID" 2>/dev/null
  rm -rf "$TMP"
}
trap cleanup EXIT

mkdir -p "$TMP/bin" "$TMP/rec"
HQROOT="$TMP/hqroot"
mkdir -p "$HQROOT/.claude" "$HQROOT/workspace"
printf '{}\n' > "$HQROOT/.claude/settings.json"

# Shared fake: records "<engine> <argv joined by |>" per call. Ids listed in
# $FAKE_REC_DIR/reject make a resume fail like an unknown session would.
cat > "$TMP/bin/fake-engine" <<'FAKE'
#!/usr/bin/env bash
eng="$1"; shift
rec="${FAKE_REC_DIR:?}"
line="$eng"
for a in "$@"; do line="$line|$a"; done
printf '%s\n' "$line" | tr '\n' ' ' >> "$rec/calls"; printf '\n' >> "$rec/calls"
resume=""; newid=""; prompt=""; out=""; codex_resume=0; after_dd=0; pos=()
[ "$eng" = codex ] && [ "${2:-}" = resume ] && codex_resume=1
while [ $# -gt 0 ]; do
  if [ $after_dd = 1 ]; then pos+=("$1"); shift; continue; fi
  case "$1" in
    --) after_dd=1; shift ;;
    --resume) resume="$2"; shift 2 ;;
    --session-id) newid="$2"; shift 2 ;;
    --output-last-message) out="$2"; shift 2 ;;
    -p|--single) prompt="$2"; shift 2 ;;
    *) shift ;;
  esac
done
if [ "$eng" = codex ]; then
  if [ $codex_resume = 1 ]; then resume="${pos[0]}"; prompt="${pos[1]}"; else prompt="${pos[0]}"; fi
fi
tag="$(printf '%s' "$prompt" | sed -n 's/.*TAG=\([A-Za-z0-9_-]*\).*/\1/p')"
if [ -n "$resume" ] && [ -f "$rec/reject" ] && grep -qx "$resume" "$rec/reject"; then
  echo "fake $eng: no conversation found with session id $resume" >&2; exit 1
fi
sid="${resume:-${newid:-$(uuidgen | tr 'A-Z' 'a-z')}}"
case "$eng" in
  claude) printf '{"type":"result","subtype":"success","is_error":false,"result":"done %s","session_id":"%s"}\n' "$tag" "$sid" ;;
  grok)
    [ -n "$resume" ] && [ -f "$rec/grok-wrong" ] && sid="$(cat "$rec/grok-wrong")"
    printf '{"text":"done %s","stopReason":"EndTurn","sessionId":"%s"}\n' "$tag" "$sid" ;;
  codex)
    [ -f "$rec/codex-no-header" ] || echo "session id: $sid" >&2
    printf 'done %s' "$tag" > "$out" ;;
esac
FAKE
chmod +x "$TMP/bin/fake-engine"
for e in claude codex grok; do
  printf '#!/usr/bin/env bash\nexec "%s" %s "$@"\n' "$TMP/bin/fake-engine" "$e" > "$TMP/bin/$e"
  chmod +x "$TMP/bin/$e"
done

export HQ_ROOT="$HQROOT"
export HQ_WORKFLOW_CLAUDE_BIN="$TMP/bin/claude"
export HQ_WORKFLOW_CODEX_BIN="$TMP/bin/codex"
export HQ_WORKFLOW_GROK_BIN="$TMP/bin/grok"
export HQ_WORKFLOW_CLAUDE_EXEC_MODEL="fake-model"
export HQ_WORKFLOW_CPU_CHECK=0
export HQ_WORKFLOW_LOOP_POLL_MS=50
export FAKE_REC_DIR="$TMP/rec"

wait_for() { # wait_for <secs> <command...>
  local limit=$(( $1 * 10 )); shift
  local i=0
  while [ $i -lt $limit ]; do "$@" && return 0; sleep 0.1; i=$((i + 1)); done
  return 1
}

# start_lane <name> [runner flags...]
start_lane() {
  LANE="$TMP/lane-$1"; shift
  mkdir -p "$LANE"
  : > "$TMP/rec/calls"
  node "$RUNNER" --loop --quiet --run-dir "$LANE" "$@" > "$LANE.out" 2> "$LANE.err" &
  LANE_PID=$!
  wait_for 10 test -f "$LANE/loop.json"
}
stop_lane() {
  mkdir -p "$LANE/inbox/pending"
  printf '%s\n' '{"kind":"stop"}' > "$LANE/inbox/pending/$(date -u +%Y%m%d%H%M%S)-$$-stop.msg"
  wait "$LANE_PID" 2>/dev/null
  LANE_PID=""
}
# phase <engine> <story> <id> [extra json fields]  -> runs it, waits for result
phase() {
  local extra="${4:-}"
  mkdir -p "$LANE/inbox/pending"
  printf '%s\n' \
    "{\"kind\":\"phase\",\"engine\":\"$1\",\"tier\":\"exec\",\"story_id\":\"$2\",\"id\":\"$3\",\"result_path\":\"$TMP/res/$3.json\",\"prompt\":\"TAG=$3\"$extra}" \
    > "$LANE/inbox/pending/$(date -u +%Y%m%d%H%M%S)-$$-$3.msg"
  wait_for 20 test -f "$TMP/res/$3.json"
}
call() { sed -n "${1}p" "$TMP/rec/calls"; }        # argv of the Nth engine call
jget() { node -e 'const j=require(process.argv[1]); const v=process.argv[2].split(".").reduce((o,k)=>o==null?o:o[k],j); process.stdout.write(v==null?"":String(v))' "$1" "$2"; }
stored() { jget "$LANE/sessions/$1.json" session_id 2>/dev/null; }
mkdir -p "$TMP/res"

# ---- 1. claude: fresh with --session-id, then --resume <id> -------------------
start_lane claude
phase claude US-A c1
sidA="$(stored US-A)"
check "claude phase 1: session id recorded under sessions/US-A.json" "$([ -n "$sidA" ]; echo $?)"
check "claude phase 1: argv starts the session with --session-id $sidA" \
  "$(call 1 | grep -q -- "|--session-id|$sidA" && ! call 1 | grep -q -- '|--resume|'; echo $?)"
check "claude phase 1: result records mode fresh" "$([ "$(jget "$TMP/res/c1.json" session.mode)" = fresh ]; echo $?)"
phase claude US-A c2
check "claude phase 2 of US-A: argv contains --resume $sidA" "$(call 2 | grep -q -- "|--resume|$sidA"; echo $?)"
check "claude phase 2: result records mode resume and the same id" \
  "$([ "$(jget "$TMP/res/c2.json" session.mode)" = resume ] && [ "$(jget "$TMP/res/c2.json" session.session_id)" = "$sidA" ]; echo $?)"
check "claude phase 2: reply returned" "$([ "$(jget "$TMP/res/c2.json" value)" = 'done c2' ]; echo $?)"
stop_lane

# ---- 2. codex: exec resume inside a story, fresh across the boundary ----------
start_lane codex
phase codex US-A x1
cA="$(stored US-A)"
check "codex phase 1: session id read from the log and recorded" "$([ -n "$cA" ]; echo $?)"
check "codex phase 1: plain exec, no resume" "$(call 1 | grep -q '^codex|exec|' && ! call 1 | grep -q '|resume|'; echo $?)"
phase codex US-A x2
check "codex phase 2 of US-A: argv is exec resume ... -- $cA <prompt>" \
  "$(call 2 | grep -q "^codex|exec|resume|.*|--|$cA|TAG=x2" ; echo $?)"
phase codex US-B x3
cB="$(stored US-B)"
check "codex phase of US-B: argv has no resume" "$(! call 3 | grep -q '|resume|'; echo $?)"
check "codex phase of US-B: a new session id is recorded" "$([ -n "$cB" ] && [ "$cB" != "$cA" ]; echo $?)"
check "codex phase of US-B: US-A's stored session was cleared" "$([ ! -f "$LANE/sessions/US-A.json" ]; echo $?)"
phase codex US-A x4
check "back on US-A after US-B: fresh again, not the old US-A session" \
  "$(! call 4 | grep -q '|resume|' && ! call 4 | grep -q -- "$cA"; echo $?)"
touch "$TMP/rec/codex-no-header"
phase codex US-C x5
check "codex with no session-id header records nothing (no invented id)" \
  "$([ ! -f "$LANE/sessions/US-C.json" ] && [ "$(jget "$TMP/res/x5.json" status)" = ok ]; echo $?)"
rm -f "$TMP/rec/codex-no-header"
stop_lane

# ---- 3. grok: --resume <id>, wrong-session envelope falls back fresh ----------
start_lane grok
phase grok US-G g1
gA="$(stored US-G)"
check "grok phase 1: fresh session named with --session-id" \
  "$([ -n "$gA" ] && call 1 | grep -q -- "|--session-id|$gA"; echo $?)"
phase grok US-G g2
check "grok phase 2: argv contains --resume $gA and never --continue" \
  "$(call 2 | grep -q -- "|--resume|$gA" && ! grep -q -- '|--continue' "$TMP/rec/calls" && ! grep -q -- '|-c|' "$TMP/rec/calls"; echo $?)"
check "grok phase 2: resume proven by the envelope's sessionId" \
  "$([ "$(jget "$TMP/res/g2.json" session.mode)" = resume ]; echo $?)"
echo "99999999-9999-4999-8999-999999999999" > "$TMP/rec/grok-wrong"
phase grok US-G g3
check "grok resume that lands in another session is rerun fresh" \
  "$([ "$(jget "$TMP/res/g3.json" session.mode)" = fresh-fallback ] && [ "$(jget "$TMP/res/g3.json" status)" = ok ] && ! call 4 | grep -q -- '|--resume|'; echo $?)"
rm -f "$TMP/rec/grok-wrong"
stop_lane

# ---- 4. stale session id: one fresh retry, fallback recorded ------------------
start_lane stale
STALE="11111111-2222-4333-8444-555555555555"
echo "$STALE" > "$TMP/rec/reject"
printf '{"story_id":"US-S","engine":"claude","session_id":"%s"}\n' "$STALE" > "$LANE/sessions/US-S.json"
phase claude US-S s1
check "stale id: first call tried --resume $STALE" "$(call 1 | grep -q -- "|--resume|$STALE"; echo $?)"
check "stale id: retried once as a fresh call" \
  "$([ "$(wc -l < "$TMP/rec/calls" | tr -d ' ')" = 2 ] && ! call 2 | grep -q -- '|--resume|'; echo $?)"
check "stale id: result is ok and records the fallback" \
  "$([ "$(jget "$TMP/res/s1.json" status)" = ok ] && [ "$(jget "$TMP/res/s1.json" session.fallback)" = true ] \
     && [ "$(jget "$TMP/res/s1.json" session.resumed_from)" = "$STALE" ] && [ -n "$(jget "$TMP/res/s1.json" session.resume_error)" ]; echo $?)"
check "stale id: the new session replaced the stale record" \
  "$([ -n "$(stored US-S)" ] && [ "$(stored US-S)" != "$STALE" ]; echo $?)"
rm -f "$TMP/rec/reject"
stop_lane

# ---- 5. --no-resume: every phase fresh ---------------------------------------
start_lane noresume --no-resume
phase claude US-N n1
phase claude US-N n2
check "--no-resume: neither argv contains a resume argument" \
  "$(! grep -q -- '|--resume|' "$TMP/rec/calls" && [ "$(wc -l < "$TMP/rec/calls" | tr -d ' ')" = 2 ]; echo $?)"
check "--no-resume: result says why" "$([ "$(jget "$TMP/res/n2.json" session.fresh_reason)" = no-resume ]; echo $?)"
stop_lane

# ---- 6. envelope fresh:true forces one fresh call ----------------------------
start_lane fresh
phase claude US-F f1
phase claude US-F f2 ',"fresh":true'
phase claude US-F f3
check "fresh:true phase has no --resume" "$(! call 2 | grep -q -- '|--resume|'; echo $?)"
check "next phase resumes the session the fresh phase started" \
  "$(call 3 | grep -q -- "|--resume|$(jget "$TMP/res/f2.json" session.session_id)"; echo $?)"
stop_lane

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
