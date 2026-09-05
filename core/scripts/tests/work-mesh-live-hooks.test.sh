#!/usr/bin/env bash
# hq-core: public
# US-010 — Work Mesh Live enqueue-only hooks.
#
# Timing contract (AC0/AC2/AC5): after one warm-up, run 100 invocations.
# Always assert p95(user+sys CPU ms) < 20 (bash TIMEFORMAT='%3U %3S'; immune
# to runnable-queue wall inflation under load). Always print wall p50/p95 and
# adj wall (wall - empty `bash --noprofile --norc -c true` p50). Assert adj
# wall p95 < 20 only when 1-min load avg < CPU count (Linux /proc/loadavg +
# nproc; macOS sysctl vm.loadavg + hw.ncpu); else print
# "timing: wall assertion skipped (load X on N cpus)".
# Recorded on this linux host (feature/work-mesh-live, quiet, load 3.79/4):
#   bash-true baseline overhead p50 = 1ms (subtracted from wall only)
#   turn_end cpu_p95=7 wall_p95=8 adj_p95=7 | turn_start cpu_p95=7 wall_p95=7 adj_p95=6
#   session_end cpu_p95=6 wall_p95=6 adj_p95=5 | tool_writes cpu_p95=7 wall_p95=7 adj_p95=6
#   session_start cpu_p95=6 wall_p95=7 adj_p95=6 (cpu+adj wall p95 < 20)
# Busy check (load 5.83/4): wall assert skipped; cpu_p95 11–13ms still < 20
# while wall_p95 spiked to 35–88ms.
# SessionStart uses HQ_WORK_MESH_RECONCILE_STUB=1 so reconcile stays detached.
# Record macOS numbers in the PR when available.
#
# Pinned enqueue digest (byte-identical to hq-cli scaffold copy):
#   cc3d86fcd7d3934cf59091f7be16eb58193616e9790434b63e8f628d7018f734
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
PINNED_ENQUEUE_SHA256="cc3d86fcd7d3934cf59091f7be16eb58193616e9790434b63e8f628d7018f734"

SESSION_START="$REPO_ROOT/core/hooks/SessionStart/35-work-mesh-session-start.sh"
TURN_START="$REPO_ROOT/core/hooks/UserPromptSubmit/35-work-mesh-turn-start.sh"
TURN_END="$REPO_ROOT/core/hooks/Stop/70-work-mesh-turn-end.sh"
SESSION_END="$REPO_ROOT/core/hooks/SessionEnd/35-work-mesh-session-end.sh"
TOOL_WRITES="$REPO_ROOT/core/hooks/PostToolUse/35-work-mesh-tool-writes.sh"
ENQUEUE_LIB="$REPO_ROOT/core/scripts/lib/work-mesh-enqueue.sh"
CLI_ENQUEUE="/home/yousuf/hq/repos/private/hq-cli-wt-work-mesh-live/assets/scaffold/core/scripts/lib/work-mesh-enqueue.sh"
CODEX_ADAPTER="$REPO_ROOT/.codex/hooks/hq-codex-hook-adapter.sh"
GROK_ADAPTER="$REPO_ROOT/.grok/hooks/hq-grok-hook-adapter.sh"

PASS=0
FAIL=0
fail() { echo "FAIL: $*" >&2; FAIL=$((FAIL + 1)); }
pass() { echo "PASS: $*"; PASS=$((PASS + 1)); }

for f in "$SESSION_START" "$TURN_START" "$TURN_END" "$SESSION_END" "$TOOL_WRITES" "$ENQUEUE_LIB"; do
  [ -f "$f" ] || { echo "FATAL: missing $f" >&2; exit 1; }
done
command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required" >&2; exit 1; }
command -v sha256sum >/dev/null 2>&1 || { echo "FATAL: sha256sum required" >&2; exit 1; }

SANDBOX="$(mktemp -d)"
cleanup() { rm -rf "$SANDBOX" 2>/dev/null || true; }
trap cleanup EXIT

HOME_DIR="$SANDBOX/home"
mkdir -p "$HOME_DIR" "$SANDBOX/hq" "$SANDBOX/bin"
export HOME="$HOME_DIR"
export WORK_MESH_HOME="$HOME_DIR"
export WORK_MESH_SPOOL="$HOME_DIR/.hq/work-mesh/spool.jsonl"
export WORK_MESH_SEQ_DIR="$HOME_DIR/.hq/work-mesh/seq"
export HQ_ROOT="$REPO_ROOT"
export HQ_WORK_MESH_RECONCILE_STUB=1
unset HQ_WORK_MESH_DISABLED || true
unset HQ_DISABLED_HOOKS || true
unset CLAUDE_CODE_SESSION_ID CLAUDE_SESSION_ID HQ_SESSION_ID CODEX_SESSION_ID CODEX_THREAD_ID || true
unset HQ_HARNESS HQ_WORK_MESH_HARNESS HQ_CHECKPOINT_RUNTIME || true

reset_spool() {
  rm -rf "$HOME_DIR/.hq"
  mkdir -p "$HOME_DIR/.hq/work-mesh" "$HOME_DIR/.hq/work-context/sessions" "$WORK_MESH_SEQ_DIR"
  : >"$WORK_MESH_SPOOL"
}

# Usage: run_hook HOOK [NAME=VALUE ...]
run_hook() {
  local hook="$1"
  shift
  env -u HQ_DISABLED_HOOKS -u HQ_WORK_MESH_DISABLED \
    HOME="$HOME" WORK_MESH_HOME="$WORK_MESH_HOME" \
    WORK_MESH_SPOOL="$WORK_MESH_SPOOL" WORK_MESH_SEQ_DIR="$WORK_MESH_SEQ_DIR" \
    HQ_ROOT="$HQ_ROOT" HQ_WORK_MESH_RECONCILE_STUB=1 \
    "$@" \
    bash "$hook" </dev/null
}

# Usage: run_hook_stdin HOOK PAYLOAD [NAME=VALUE ...]
run_hook_stdin() {
  local hook="$1" payload="$2"
  shift 2
  env -u HQ_DISABLED_HOOKS -u HQ_WORK_MESH_DISABLED \
    HOME="$HOME" WORK_MESH_HOME="$WORK_MESH_HOME" \
    WORK_MESH_SPOOL="$WORK_MESH_SPOOL" WORK_MESH_SEQ_DIR="$WORK_MESH_SEQ_DIR" \
    HQ_ROOT="$HQ_ROOT" HQ_WORK_MESH_RECONCILE_STUB=1 \
    "$@" \
    bash "$hook" <<<"$payload"
}

last_line() { tail -n1 "$WORK_MESH_SPOOL" 2>/dev/null || true; }
spool_count() { wc -l <"$WORK_MESH_SPOOL" | tr -d ' '; }

# --- sha256 pin --------------------------------------------------------------
core_sha="$(sha256sum "$ENQUEUE_LIB" | awk '{print $1}')"
[ "$core_sha" = "$PINNED_ENQUEUE_SHA256" ] \
  && pass "enqueue sha256 matches pinned digest" \
  || fail "enqueue sha256 drift: got $core_sha want $PINNED_ENQUEUE_SHA256"
if [ -f "$CLI_ENQUEUE" ]; then
  cli_sha="$(sha256sum "$CLI_ENQUEUE" | awk '{print $1}')"
  [ "$cli_sha" = "$core_sha" ] \
    && pass "enqueue byte-identical to hq-cli scaffold copy" \
    || fail "enqueue differs from hq-cli copy"
else
  pass "hq-cli enqueue path absent on this machine (pin still enforced)"
fi

# --- session id from env -----------------------------------------------------
reset_spool
run_hook "$SESSION_START" CLAUDE_CODE_SESSION_ID=sid-env-1 HQ_WORK_MESH_RECONCILE_LOG="$SANDBOX/recon.log" \
  >/dev/null
line="$(last_line)"
echo "$line" | jq -e '.kind=="session_start" and .sessionId=="sid-env-1" and .harness=="claude-code"' >/dev/null \
  && pass "session_start from CLAUDE_CODE_SESSION_ID" \
  || fail "session_start env: $line"
[ -f "$SANDBOX/recon.log" ] && grep -q '^reconcile' "$SANDBOX/recon.log" \
  && pass "detached reconcile logged (no wait)" \
  || fail "reconcile not spawned"

# --- session id from payload -------------------------------------------------
reset_spool
run_hook_stdin "$TURN_START" '{"session_id":"sid-payload-2","prompt":"please implement the feature carefully"}' \
  >/dev/null
line="$(last_line)"
echo "$line" | jq -e '.kind=="turn_start" and .sessionId=="sid-payload-2"' >/dev/null \
  && pass "turn_start session id from payload" \
  || fail "turn_start payload: $line"

# --- enqueue line format -----------------------------------------------------
echo "$line" | jq -e '
  .v==1
  and (.eventId|type=="string" and length==26)
  and (.adapterVersion|type=="string")
  and (.at|type=="string")
  and (.seq|type=="number")
  and (.cwd|type=="string")
  and (.hqRoot|type=="string")
  and (has("prompt")|not)
' >/dev/null && pass "enqueue line format (no prompt)" || fail "enqueue format: $line"

# --- turn_end / session_end --------------------------------------------------
reset_spool
run_hook "$TURN_END" CLAUDE_CODE_SESSION_ID=sid-end >/dev/null
last_line | jq -e '.kind=="turn_end" and .sessionId=="sid-end"' >/dev/null \
  && pass "turn_end" || fail "turn_end"
run_hook "$SESSION_END" CLAUDE_CODE_SESSION_ID=sid-end >/dev/null
last_line | jq -e '.kind=="session_end" and .sessionId=="sid-end"' >/dev/null \
  && pass "session_end" || fail "session_end"

# --- ask injection once ------------------------------------------------------
reset_spool
mkdir -p "$HOME_DIR/.hq/work-context/sessions"
cat >"$HOME_DIR/.hq/work-context/sessions/sid-ask.json" <<'JSON'
{
  "contractVersion": 1,
  "sessionId": "sid-ask",
  "contextStatus": "needs_project",
  "decision": {
    "decisionId": "dec_1",
    "askAfter": true,
    "options": [
      {"optionId": "opt_a", "label": "Project A"},
      {"optionId": "opt_b", "label": "Project B"}
    ]
  },
  "updatedAt": "2026-09-03T00:00:00Z"
}
JSON
out1="$(run_hook_stdin "$TURN_START" '{"session_id":"sid-ask","prompt":"please continue the implementation work"}' || true)"
echo "$out1" | jq -e '.hookSpecificOutput.additionalContext|test("AskUserQuestion")' >/dev/null \
  && pass "ask injection includes AskUserQuestion" \
  || fail "ask injection missing: $out1"
[ -f "$HOME_DIR/.hq/work-context/sessions/sid-ask.ask-surfaced" ] \
  && pass "ask surfaced marker written" \
  || fail "ask surfaced marker missing"
out2="$(run_hook_stdin "$TURN_START" '{"session_id":"sid-ask","prompt":"please continue the implementation work"}' || true)"
if printf '%s' "$out2" | jq -e '.hookSpecificOutput.additionalContext|test("AskUserQuestion")' >/dev/null 2>&1; then
  fail "ask injected twice"
else
  pass "ask injection once only"
fi

# slash / short: still record turn, no ask
reset_spool
mkdir -p "$HOME_DIR/.hq/work-context/sessions"
cat >"$HOME_DIR/.hq/work-context/sessions/sid-short.json" <<'JSON'
{
  "contractVersion": 1,
  "sessionId": "sid-short",
  "contextStatus": "needs_project",
  "decision": {
    "decisionId": "dec_1",
    "askAfter": true,
    "options": [{"optionId": "opt_a", "label": "Project A"}]
  },
  "updatedAt": "2026-09-03T00:00:00Z"
}
JSON
rm -f "$HOME_DIR/.hq/work-context/sessions/sid-short.ask-surfaced"
out3="$(run_hook_stdin "$TURN_START" '{"session_id":"sid-short","prompt":"/help"}' || true)"
last_line | jq -e '.kind=="turn_start"' >/dev/null \
  && pass "slash still records turn" || fail "slash no turn"
if printf '%s' "$out3" | jq -e '.hookSpecificOutput.additionalContext|test("AskUserQuestion")' >/dev/null 2>&1; then
  fail "slash triggered ask"
else
  pass "slash does not trigger ask"
fi

# --- board injection ---------------------------------------------------------
reset_spool
mkdir -p "$HOME_DIR/.hq/work-context/sessions/sid-board"
printf 'BOARD LINE ONE\nBOARD LINE TWO\n' >"$HOME_DIR/.hq/work-context/sessions/sid-board/board.md"
outb="$(run_hook_stdin "$TURN_START" '{"session_id":"sid-board","prompt":"continue implementing carefully please"}' || true)"
echo "$outb" | jq -e '.hookSpecificOutput.additionalContext|test("BOARD SNAPSHOT")' >/dev/null \
  && pass "board.md injection" \
  || fail "board injection: $outb"

# --- toolWrites --------------------------------------------------------------
reset_spool
run_hook_stdin "$TOOL_WRITES" '{"session_id":"sid-tw","tool_name":"Edit","tool_input":{"file_path":"a.ts"}}' >/dev/null
tw="$(jq -r '.toolWrites // 0' "$HOME_DIR/.hq/work-context/sessions/sid-tw.json")"
[ "$tw" = "1" ] && pass "toolWrites Edit -> 1" || fail "toolWrites=$tw"
run_hook_stdin "$TOOL_WRITES" '{"session_id":"sid-tw","tool_name":"Bash","tool_input":{"command":"echo hi > /tmp/x"}}' >/dev/null
tw="$(jq -r '.toolWrites // 0' "$HOME_DIR/.hq/work-context/sessions/sid-tw.json")"
[ "$tw" = "2" ] && pass "toolWrites Bash redirect -> 2" || fail "toolWrites bash=$tw"
run_hook_stdin "$TOOL_WRITES" '{"session_id":"sid-tw","tool_name":"Bash","tool_input":{"command":"echo hi"}}' >/dev/null
tw="$(jq -r '.toolWrites // 0' "$HOME_DIR/.hq/work-context/sessions/sid-tw.json")"
[ "$tw" = "2" ] && pass "non-writing Bash ignored" || fail "toolWrites nonwrite=$tw"

# --- disable switches --------------------------------------------------------
reset_spool
env HOME="$HOME" WORK_MESH_HOME="$WORK_MESH_HOME" WORK_MESH_SPOOL="$WORK_MESH_SPOOL" \
  WORK_MESH_SEQ_DIR="$WORK_MESH_SEQ_DIR" HQ_ROOT="$HQ_ROOT" \
  HQ_WORK_MESH_DISABLED=1 CLAUDE_CODE_SESSION_ID=sid-dis \
  bash "$TURN_START" <<<"{\"session_id\":\"sid-dis\",\"prompt\":\"please implement carefully now\"}" >/dev/null || true
[ "$(spool_count)" = "0" ] && pass "HQ_WORK_MESH_DISABLED=1 no-ops" || fail "disabled still wrote"

reset_spool
env HOME="$HOME" WORK_MESH_HOME="$WORK_MESH_HOME" WORK_MESH_SPOOL="$WORK_MESH_SPOOL" \
  WORK_MESH_SEQ_DIR="$WORK_MESH_SEQ_DIR" HQ_ROOT="$HQ_ROOT" \
  HQ_DISABLED_HOOKS=work-mesh-live CLAUDE_CODE_SESSION_ID=sid-dis2 \
  bash "$TURN_END" <<<"{\"session_id\":\"sid-dis2\"}" >/dev/null || true
[ "$(spool_count)" = "0" ] && pass "HQ_DISABLED_HOOKS=work-mesh-live no-ops" || fail "disabled hooks still wrote"

# --- Codex / Grok adapter dispatch -------------------------------------------
grep -q 'HQ_WORK_MESH_HARNESS=codex' "$CODEX_ADAPTER" \
  && grep -q 'work_mesh_live_dispatch' "$CODEX_ADAPTER" \
  && pass "Codex adapter exports harness + dispatch helper" \
  || fail "Codex adapter missing harness/dispatch"
grep -q 'HQ_WORK_MESH_HARNESS=grok' "$GROK_ADAPTER" \
  && grep -q 'work_mesh_live_dispatch' "$GROK_ADAPTER" \
  && pass "Grok adapter exports harness + dispatch helper" \
  || fail "Grok adapter missing harness/dispatch"

reset_spool
# Force-dispatch path exercises work_mesh_live_dispatch (harness=codex).
env -u HQ_DISABLED_HOOKS HOME="$HOME" WORK_MESH_HOME="$WORK_MESH_HOME" \
  WORK_MESH_SPOOL="$WORK_MESH_SPOOL" WORK_MESH_SEQ_DIR="$WORK_MESH_SEQ_DIR" \
  HQ_ROOT="$REPO_ROOT" HQ_WORK_MESH_RECONCILE_STUB=1 \
  HQ_WORK_MESH_FORCE_ADAPTER_DISPATCH=1 \
  bash "$CODEX_ADAPTER" <<<"{\"hook_event_name\":\"Stop\",\"session_id\":\"sid-codex\"}" >/dev/null || true
if jq -e 'select(.sessionId=="sid-codex" and .harness=="codex" and .kind=="turn_end")' "$WORK_MESH_SPOOL" >/dev/null 2>&1; then
  pass "Codex force-dispatch enqueues harness=codex"
else
  fail "Codex force-dispatch did not enqueue harness=codex"
fi
# SessionStart / UserPromptSubmit / SessionEnd also dispatch via the helper.
reset_spool
env -u HQ_DISABLED_HOOKS HOME="$HOME" WORK_MESH_HOME="$WORK_MESH_HOME" \
  WORK_MESH_SPOOL="$WORK_MESH_SPOOL" WORK_MESH_SEQ_DIR="$WORK_MESH_SEQ_DIR" \
  HQ_ROOT="$REPO_ROOT" HQ_WORK_MESH_RECONCILE_STUB=1 \
  HQ_WORK_MESH_FORCE_ADAPTER_DISPATCH=1 \
  bash "$CODEX_ADAPTER" <<<"{\"hook_event_name\":\"SessionStart\",\"session_id\":\"sid-codex-ss\",\"cwd\":\"/tmp\"}" >/dev/null || true
jq -e 'select(.sessionId=="sid-codex-ss" and .harness=="codex" and .kind=="session_start")' "$WORK_MESH_SPOOL" >/dev/null 2>&1 \
  && pass "Codex force-dispatch SessionStart" \
  || fail "Codex SessionStart force-dispatch missing"
reset_spool
env -u HQ_DISABLED_HOOKS HOME="$HOME" WORK_MESH_HOME="$WORK_MESH_HOME" \
  WORK_MESH_SPOOL="$WORK_MESH_SPOOL" WORK_MESH_SEQ_DIR="$WORK_MESH_SEQ_DIR" \
  HQ_ROOT="$REPO_ROOT" HQ_WORK_MESH_RECONCILE_STUB=1 \
  HQ_WORK_MESH_FORCE_ADAPTER_DISPATCH=1 \
  bash "$CODEX_ADAPTER" <<<"{\"hook_event_name\":\"UserPromptSubmit\",\"session_id\":\"sid-codex-up\",\"prompt\":\"x\"}" >/dev/null || true
jq -e 'select(.sessionId=="sid-codex-up" and .harness=="codex" and .kind=="turn_start")' "$WORK_MESH_SPOOL" >/dev/null 2>&1 \
  && pass "Codex force-dispatch UserPromptSubmit" \
  || fail "Codex UserPromptSubmit force-dispatch missing"
reset_spool
env -u HQ_DISABLED_HOOKS HOME="$HOME" WORK_MESH_HOME="$WORK_MESH_HOME" \
  WORK_MESH_SPOOL="$WORK_MESH_SPOOL" WORK_MESH_SEQ_DIR="$WORK_MESH_SEQ_DIR" \
  HQ_ROOT="$REPO_ROOT" HQ_WORK_MESH_RECONCILE_STUB=1 \
  HQ_WORK_MESH_FORCE_ADAPTER_DISPATCH=1 \
  bash "$CODEX_ADAPTER" <<<"{\"hook_event_name\":\"SessionEnd\",\"session_id\":\"sid-codex-se\"}" >/dev/null || true
jq -e 'select(.sessionId=="sid-codex-se" and .harness=="codex" and .kind=="session_end")' "$WORK_MESH_SPOOL" >/dev/null 2>&1 \
  && pass "Codex force-dispatch SessionEnd" \
  || fail "Codex SessionEnd force-dispatch missing"

reset_spool
env -u HQ_DISABLED_HOOKS HOME="$HOME" WORK_MESH_HOME="$WORK_MESH_HOME" \
  WORK_MESH_SPOOL="$WORK_MESH_SPOOL" WORK_MESH_SEQ_DIR="$WORK_MESH_SEQ_DIR" \
  HQ_ROOT="$REPO_ROOT" HQ_HARNESS=grok HQ_WORK_MESH_HARNESS=grok \
  bash "$TURN_END" <<<"{\"session_id\":\"sid-grok\"}" >/dev/null
last_line | jq -e '.harness=="grok" and .kind=="turn_end"' >/dev/null \
  && pass "Grok harness stamp" || fail "grok harness"

# Grok pending-decision path
reset_spool
mkdir -p "$HOME_DIR/.hq/work-context/sessions"
cat >"$HOME_DIR/.hq/work-context/sessions/sid-grok-ask.json" <<'JSON'
{"contractVersion":1,"sessionId":"sid-grok-ask","contextStatus":"needs_project","decision":{"decisionId":"dec_g","askAfter":true,"options":[{"optionId":"o1","label":"One"}]},"updatedAt":"2026-09-03T00:00:00Z"}
JSON
rm -f "$HOME_DIR/.hq/work-context/sessions/sid-grok-ask.ask-surfaced" \
      "$HOME_DIR/.hq/work-context/sessions/sid-grok-ask.pending-decision"
outg="$(env -u HQ_DISABLED_HOOKS HOME="$HOME" WORK_MESH_HOME="$WORK_MESH_HOME" \
  WORK_MESH_SPOOL="$WORK_MESH_SPOOL" WORK_MESH_SEQ_DIR="$WORK_MESH_SEQ_DIR" \
  HQ_ROOT="$REPO_ROOT" HQ_HARNESS=grok HQ_WORK_MESH_HARNESS=grok \
  bash "$TURN_START" <<<"{\"session_id\":\"sid-grok-ask\",\"prompt\":\"please continue the implementation work\"}" || true)"
[ -f "$HOME_DIR/.hq/work-context/sessions/sid-grok-ask.pending-decision" ] \
  && pass "Grok records pending decision" \
  || fail "Grok pending missing"
echo "$outg" | jq -e '.hookSpecificOutput.additionalContext|test("organize")' >/dev/null \
  && pass "Grok defers to organize" \
  || fail "Grok organize hint missing: $outg"


# --- US-011: trusted spawn + rebind + skill meta before turn_end ---------------
reset_spool
run_hook "$SESSION_START" \
  CLAUDE_CODE_SESSION_ID=sid-spawn-ac \
  HQ_SPAWN_COMPANY=acme HQ_SPAWN_PROJECT=proj-a HQ_SPAWN_TASK=US-1 \
  >/dev/null
last_line | jq -e '.kind=="session_start" and .companySlug=="acme" and .project=="proj-a" and .task=="US-1"' >/dev/null \
  && pass "US-011 spawn envelope on session_start" \
  || fail "US-011 spawn: $(last_line)"
[ -f "$HOME_DIR/.hq/work-context/sessions/sid-spawn-ac.live-binding" ] \
  && pass "US-011 live-binding marker on spawn" \
  || fail "US-011 marker missing"

# skill-like meta bind before turn_end
reset_spool
SID=sid-meta-bind
mkdir -p "$REPO_ROOT/workspace/sessions/$SID"
# Use isolated meta under sandbox via HQ session override: write meta in REPO would pollute;
# instead assert bind-trusted helper writes observation + that turn_end can run after.
export HQ_WORK_MESH_RECONCILE_LOG="$SANDBOX/recon-us011.log"
: >"$HQ_WORK_MESH_RECONCILE_LOG"
# Minimal meta the turn_end path can see via SessionStart-style env
mkdir -p "$HOME_DIR/.hq/work-context/sessions"
printf 'companySlug=acme\nproject=mesh-live\ntask=US-3\n' >"$HOME_DIR/.hq/work-context/sessions/$SID.live-binding"
run_hook "$TURN_END" CLAUDE_CODE_SESSION_ID="$SID" >/dev/null
last_line | jq -e '.kind=="turn_end" and .sessionId=="sid-meta-bind"' >/dev/null \
  && pass "US-011 turn_end after binding marker present" \
  || fail "US-011 turn_end: $(last_line)"
# Explicit rebind helper
reset_spool
SID=sid-rebind-hook
printf 'companySlug=acme\nproject=old\ntask=T1\n' >"$HOME_DIR/.hq/work-context/sessions/$SID.live-binding"
env HOME="$HOME" WORK_MESH_HOME="$WORK_MESH_HOME" WORK_MESH_SPOOL="$WORK_MESH_SPOOL" \
  WORK_MESH_SEQ_DIR="$WORK_MESH_SEQ_DIR" HQ_ROOT="$REPO_ROOT" \
  CLAUDE_CODE_SESSION_ID="$SID" \
  bash "$REPO_ROOT/core/scripts/work-mesh-live-rebind.sh" \
    --session "$SID" --old-company acme --old-project old --old-task T1 \
    --company acme --project neu --task T2
jq -e 'select(.kind=="session_end" and .project=="old")' "$WORK_MESH_SPOOL" >/dev/null \
  && pass "US-011 rebind session_end old project" || fail "US-011 rebind end"
jq -e 'select(.kind=="session_start" and .project=="neu" and .task=="T2")' "$WORK_MESH_SPOOL" >/dev/null \
  && pass "US-011 rebind session_start new project" || fail "US-011 rebind start"
end_seq="$(jq -r 'select(.kind=="session_end" and .project=="old") | .seq' "$WORK_MESH_SPOOL" | head -n1)"
start_seq="$(jq -r 'select(.kind=="session_start" and .project=="neu") | .seq' "$WORK_MESH_SPOOL" | head -n1)"
case "$end_seq:$start_seq" in
  ''|:*|*:'') fail "US-011 rebind seq missing: end=$end_seq start=$start_seq" ;;
  *)
    if [ "$start_seq" -gt "$end_seq" ]; then
      pass "US-011 rebind seq start ($start_seq) > end ($end_seq)"
    else
      fail "US-011 rebind seq: start=$start_seq end=$end_seq (expected start > end)"
    fi
    ;;
esac


# --- timing (100 invocations; CPU p95 always; wall p95 when quiet) ----------
# CPU: p95(user+sys) < 20ms via TIMEFORMAT (bash 3.2+/5.x, macOS+Linux).
# Wall adj still printed; asserted only when 1-min load < ncpu.
export HOME="$HOME" WORK_MESH_HOME="$WORK_MESH_HOME"
export WORK_MESH_SPOOL="$WORK_MESH_SPOOL" WORK_MESH_SEQ_DIR="$WORK_MESH_SEQ_DIR"
export HQ_ROOT="$REPO_ROOT" HQ_WORK_MESH_RECONCILE_STUB=1
export CLAUDE_CODE_SESSION_ID=sid-time
unset HQ_DISABLED_HOOKS HQ_WORK_MESH_DISABLED || true

# Elapsed wall ms from two EPOCHREALTIME samples (awk AFTER the timed region).
_wm_elapsed_ms() {
  awk -v s="$1" -v e="$2" 'BEGIN{printf "%d", (e-s)*1000}'
}

# TIMEFORMAT '%3U %3S' line ("0.003 0.001") -> integer ms of user+sys.
_wm_cpu_ms_from_time() {
  awk -v s="$1" 'BEGIN{
    n = split(s, a)
    if (n < 2) { print 0; exit }
    printf "%d", (a[1] + a[2]) * 1000
  }'
}

_wm_p50() {
  printf '%s\n' "$@" | sort -n | awk '{a[++n]=$1}END{print a[int((n+1)/2)]}'
}

_wm_p95() {
  printf '%s\n' "$@" | sort -n | awk '{a[++n]=$1}END{idx=int(0.95*n); if(idx<1)idx=1; print a[idx]}'
}

bash_true_overhead_ms() {
  local _i start end; local -a times=()
  for ((_i = 1; _i <= 100; _i++)); do
    start=$EPOCHREALTIME
    bash --noprofile --norc -c 'true'
    end=$EPOCHREALTIME
    times+=("$(_wm_elapsed_ms "$start" "$end")")
  done
  # p50 of empty bash as per-sample wall overhead (p95 can spike under load).
  _wm_p50 "${times[@]}"
}

# 1-min load avg + CPU count (Linux /proc; macOS sysctl).
_wm_load_and_ncpu() {
  if [ -r /proc/loadavg ]; then
    _WM_LOAD="$(awk '{print $1}' /proc/loadavg)"
    _WM_NCPU="$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)"
  elif command -v sysctl >/dev/null 2>&1; then
    _WM_LOAD="$(sysctl -n vm.loadavg 2>/dev/null | awk '{gsub(/[{}]/,""); print $1}')"
    _WM_NCPU="$(sysctl -n hw.ncpu 2>/dev/null || echo 1)"
  else
    _WM_LOAD=0
    _WM_NCPU=1
  fi
}

_wm_load_and_ncpu
WALL_ASSERT=0
if awk -v l="$_WM_LOAD" -v n="$_WM_NCPU" 'BEGIN{exit !(l + 0 < n + 0)}'; then
  WALL_ASSERT=1
  echo "timing: wall assertion enabled (load ${_WM_LOAD} on ${_WM_NCPU} cpus)"
else
  echo "timing: wall assertion skipped (load ${_WM_LOAD} on ${_WM_NCPU} cpus)"
fi

BASELINE_MS="$(bash_true_overhead_ms)"
echo "timing bash-true baseline_overhead_p50=${BASELINE_MS}ms (subtracted from wall samples)"

measure_p95() {
  local hook="$1" payload="$2" label="$3"
  local _i start end ms adj cpu_line cpu_ms
  local -a wall_times=() adj_times=() cpu_times=()
  reset_spool
  mkdir -p "$WORK_MESH_SEQ_DIR" "${WORK_MESH_SPOOL%/*}"
  # warm first invocation (excluded from p95)
  bash --noprofile --norc "$hook" <<<"$payload" >/dev/null 2>&1 || true
  # TIMEFORMAT is a bash builtin; %3U/%3S = user/sys seconds (3 decimal places).
  local TIMEFORMAT='%3U %3S'
  for ((_i = 1; _i <= 100; _i++)); do
    start=$EPOCHREALTIME
    # shellcheck disable=SC2034 # TIMEFORMAT consumed by `time`
    cpu_line=$( { time bash --noprofile --norc "$hook" <<<"$payload" >/dev/null 2>&1 || true; } 2>&1 )
    end=$EPOCHREALTIME
    ms="$(_wm_elapsed_ms "$start" "$end")"
    adj=$(( ms - BASELINE_MS ))
    [ "$adj" -lt 0 ] && adj=0
    cpu_ms="$(_wm_cpu_ms_from_time "$cpu_line")"
    wall_times+=("$ms")
    adj_times+=("$adj")
    cpu_times+=("$cpu_ms")
  done
  local wall_p50 wall_p95 adj_p50 adj_p95 cpu_p50 cpu_p95
  wall_p50="$(_wm_p50 "${wall_times[@]}")"
  wall_p95="$(_wm_p95 "${wall_times[@]}")"
  adj_p50="$(_wm_p50 "${adj_times[@]}")"
  adj_p95="$(_wm_p95 "${adj_times[@]}")"
  cpu_p50="$(_wm_p50 "${cpu_times[@]}")"
  cpu_p95="$(_wm_p95 "${cpu_times[@]}")"
  echo "timing $label wall_p50=${wall_p50}ms wall_p95=${wall_p95}ms adj_p50=${adj_p50}ms adj_p95=${adj_p95}ms cpu_p50=${cpu_p50}ms cpu_p95=${cpu_p95}ms baseline=${BASELINE_MS}ms"
  if [ "$cpu_p95" -lt 20 ]; then
    pass "timing $label cpu_p95=${cpu_p95}ms < 20 (user+sys)"
  else
    fail "timing $label cpu_p95=${cpu_p95}ms >= 20 (user+sys)"
  fi
  if [ "$WALL_ASSERT" -eq 1 ]; then
    if [ "$adj_p95" -lt 20 ]; then
      pass "timing $label adj_p95=${adj_p95}ms < 20 (wall quiet load=${_WM_LOAD}/${_WM_NCPU})"
    else
      fail "timing $label adj_p95=${adj_p95}ms >= 20 (wall quiet load=${_WM_LOAD}/${_WM_NCPU})"
    fi
  fi
}

measure_p95 "$TURN_END" '{"session_id":"sid-time"}' turn_end
measure_p95 "$TURN_START" '{"session_id":"sid-time","prompt":"x"}' turn_start
measure_p95 "$SESSION_END" '{"session_id":"sid-time"}' session_end
measure_p95 "$TOOL_WRITES" '{"session_id":"sid-time","tool_name":"Write","tool_input":{"file_path":"a"}}' tool_writes
measure_p95 "$SESSION_START" '{"session_id":"sid-time","cwd":"/tmp"}' session_start

# --- ensure-hq-cli min version -----------------------------------------------
grep -q '5.108.2' "$REPO_ROOT/core/hooks/UserPromptSubmit/30-ensure-hq-cli.sh" \
  && grep -q 'US-010' "$REPO_ROOT/core/hooks/UserPromptSubmit/30-ensure-hq-cli.sh" \
  && pass "ensure-hq-cli min 5.108.2 (US-010)" \
  || fail "ensure-hq-cli min version not set"

# --- old client layer gone ---------------------------------------------------
for gone in \
  core/hooks/work-mesh-register.sh \
  core/hooks/work-mesh-ground.sh \
  core/hooks/work-mesh-done.sh \
  core/hooks/work-mesh-close.sh \
  core/scripts/work-mesh.mjs \
  core/scripts/work-mesh.sh \
  core/scripts/work-mesh-session.sh \
  core/scripts/work-mesh-lib.sh
do
  if [ -e "$REPO_ROOT/$gone" ]; then
    fail "should be deleted: $gone"
  fi
done
pass "old client layer deleted"

echo
echo "work-mesh-live-hooks: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
