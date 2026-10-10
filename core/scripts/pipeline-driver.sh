#!/bin/sh
# hq-core: public
# pipeline-driver.sh - the detached loop behind /run-project --pipeline.
#
# A lane cannot keep a child alive past its own engine call, so the loop that
# moves a pipeline forward does not live in a lane. The parent session starts
# this script through hq-detach.sh and arms a waiter on it. It makes no engine
# calls. Each pass it:
#   1. moves a stale handoff of a re-queued phase aside (handoffs/<id>-<phase>.failed.<n>.json),
#   2. accepts the handoff a loop lane wrote to result_path for any in-flight
#      phase (pipeline-conductor.sh accept),
#   3. runs recheck for every story awaiting it,
#   4. ticks the conductor to route the next phase or start the next story,
# and exits when the parent is needed or the run is over.
#
# A handoff with status `failed` is routed again until the phase has failed
# --max-phase-fails times. A handoff with status `blocked` is never routed
# again: the conductor holds that story as blocked_needs_owner and writes a
# decision item, and the driver keeps routing every story that does not depend
# on it. It exits 21 for the blocked story only when nothing else can move.
#
# Usage:
#   pipeline-driver.sh --prd <prd.json> --state <dir>
#                      [--worktree <dir> | --worktree <repo>=<dir> ...]
#                      [--story-branches] [--table <table.tsv>] [--interval <seconds>]
#                      [--max-phase-fails <n>] [--stall-window <seconds>]
#                      [--allow-repos-worktree]
#
# --allow-repos-worktree passes through to tick: a --worktree under repos/ is
# otherwise refused (pipeline-conductor.sh explains why), and with it every
# envelope routed there tells the worker to edit through the shell or apply_patch.
#
# --worktree is repeatable in the <repo>=<dir> form: each story's phases go to
# the worktree of the story's repo (pipeline-conductor.sh documents how the repo
# is resolved). The bare form serves a prd with one repo. --story-branches
# passes through to tick (one stacked branch per story instead of one feature
# branch per repo). --table is the confirmed worker table (pipeline/table.tsv);
# it passes through to tick, which records it in run.json, and the conductor
# then refuses to route a phase whose worker has no row in it (exit 27 below).
#
# Launch (from the HQ root):
#   bash core/scripts/hq-detach.sh --logfile <state>/driver/detach.log -- \
#     sh core/scripts/pipeline-driver.sh --prd <prd.json> --state <state> --worktree <dir>
#
# Files under <state>/driver/:
#   driver.pid   this driver's pid while it runs
#   stop.json    written by `pipeline-conductor.sh stop` (a stop envelope,
#                {"kind":"stop",...}); the driver reads it each pass and stops
#   lock/        held while it runs; a second copy against the same state dir
#                refuses to start (exit 24) unless the holder is dead
#   driver.log   append-only, one timestamped line per action
#   exit         "<code> <reason>" written on exit, for the parent's waiter
#
# Exit codes:
#   code  meaning                                          the parent then
#   0     every story finished (verified, failed_report,   reads report.md FINAL
#         accepted_partial or parked); report.md has FINAL
#   2     usage error                                      fixes the command
#   20    a regression gate is due                         runs it, records `gate
#                                                          result`, restarts
#   21    a decision is needed: a story is held for an     reads the decision item,
#         approval; a phase returned blocked, a story has  asks the owner once, runs
#         no worktree, or a story is awaiting_go, and      the matching command,
#         nothing else can move; the regression gate failed; or
#         a phase returned failed --max-phase-fails times  restarts the driver
#         (the story is then held as blocked_needs_owner
#         with decisions/<id>-blocked-<phase>.md)
#   22    an in-flight phase passed its envelope deadline  checks the lane
#   23    the conductor printed something unexpected, or   reads driver.log
#         a conductor call failed
#   24    another driver already runs against this state   leaves it running
#   25    retired: the stall check now fires the stall     -
#         event and exits 28
#   26    lane down: enqueue found a terminal loop lane;   relaunches the named
#         the mapping was dropped and the story stays      worker's loop lane,
#         queued; the reason names the lane                then restarts the driver
#   27    no lane: a phase's worker has no row in the     adds the row, launches
#         confirmed worker table (--table); the story      that lane, restarts the
#         stays queued; the reason names the worker        driver
#   28    stall event: for the whole --stall-window every  reads events.jsonl, checks
#         started lane is waiting with an empty queue and  the named lanes, restarts
#         a story is in flight, or an in-flight phase's    the driver (the same stall
#         envelope sits in its lane's queue with nothing   does not fire again)
#         active. <state>/events.jsonl gets
#         {"event":"stall","stories":[...],"lanes":[...],"since":<iso>}
#   29    stopped on request (driver/stop.json from       restarts the driver
#         `pipeline-conductor.sh stop`)                    when it wants to resume
#   130/143  interrupted / terminated                      restarts the driver
#
# Interrupted phases: on every stop (stop.json, SIGTERM, SIGINT) the driver runs
# `pipeline-conductor.sh interrupt`: each in_flight story is marked `interrupted`
# with the phase and time in stories/<id>.json, and its envelope is withdrawn
# from the lane queue when no lane picked it up (a partial handoff is kept as
# handoffs/<id>-<phase>.interrupted.<n>.json). A loop lane that exited on a stop
# envelope while a story was in flight on it (journal `loop-done` after the
# route, no handoff) marks that story the same way. The next driver start routes
# interrupted stories first, before reopened ones, at the interrupted phase; the
# envelope carries resumed_after_interrupt: true and prior_handoff when a
# partial handoff exists. TICK lines and report.md FINAL name interrupted
# stories until they are routed again.
#
# Early engine exit: when a loop lane's engine call for a phase returns without a
# usable handoff, the lane writes a failed handoff with exit_reason
# "engine_exited_early" and a `phase-exit` event (reason, elapsed seconds) to its
# journal.jsonl. A handoff whose status is not passed, failed or blocked is not
# accepted; with a phase-exit event in the lane's journal since the phase was
# routed it counts the same way. On the next tick the driver logs EARLY_EXIT with
# the story, phase and elapsed time and accepts it as a failed phase, which routes
# the phase once more to the same lane (the one restart in place). A second early
# exit of the same phase holds the story for the owner (exit 21, the reason names
# engine_exited_early). While the engine is still running the deadline path (22)
# is unchanged.
#
# Reopen: when a regression gate fails because of a story that is already
# verified, the parent records `pipeline-conductor.sh gate result fail --story
# <id> --note <text>` (or runs `reopen`). The conductor queues that story again
# at its first implementing phase with the note in the envelope, and the gate
# turns `reopened`, which does not stop routing. A restarted driver routes the
# reopened story before any other queued story; once it verifies again the gate
# is due (exit 20). Verified dependents are not reopened: report.md FINAL lists
# them as "verified before <id> was reopened".
#
# Awaiting go: a story that needs an explicit go (approval: "explicit", or the
# conductor's release detector) is held awaiting_go before its first
# implementing phase. The driver keeps routing the rest, appends the list of
# awaiting_go stories to every TICK line in driver.log, and names them in the
# exit 21 reason and in report.md FINAL. `pipeline-conductor.sh go --story <id>`
# releases one; restart the driver after it.
#
# Restart safety: every decision is read from the state dir, never from memory.
# The conductor only accepts a handoff for a story that is in_flight on that
# phase, so accepting the same handoff twice is a no-op, and a restarted
# driver resumes where the last one stopped.
#
# Stall check: --stall-window (default 600 seconds, env PIPELINE_DRIVER_STALL_SECS).
#   The stall starts at the later of the oldest in-flight phase's route time and
#   the last lane status change, and is kept in driver/stall.json so a restart
#   does not reset it. The lane state comes from `hq lanes list --json`
#   (loop state and queue depth). The event fires once per stall;
#   accepting any phase clears it. No notification hook exists for the driver,
#   so firing writes the event and exits 28 for the parent's waiter.
#
# Start: loop lanes own their lifecycle; the driver reads their loop state.
#
# Env: PIPELINE_DRIVER_CONDUCTOR (default: pipeline-conductor.sh next to this
#   script); PC_HQ (default: hq); every PC_* variable the conductor reads passes through.
#
# POSIX sh (dash-clean). Requires jq (JSON reads and small edits) and node
# (the state scan and stall check).

set -u

usage() { sed -n '3,/^# POSIX sh/p' "$0" >&2; exit 2; }

NL='
'
PRD=""; STATE=""; WT=""; SB=0; ALLOW_REPOS=0; TABLE=""; INTERVAL=15; MAX_FAILS=2; STALL="${PIPELINE_DRIVER_STALL_SECS:-600}"
while [ $# -gt 0 ]; do
  case "$1" in
    --prd|--state|--worktree|--interval|--max-phase-fails|--stall-window|--table)
      [ $# -ge 2 ] || { echo "pipeline-driver: $1 needs a value" >&2; exit 2; } ;;
  esac
  case "$1" in
    --prd) PRD="$2"; shift 2 ;;
    --state) STATE="$2"; shift 2 ;;
    --worktree) WT="${WT:+$WT$NL}$2"; shift 2 ;;
    --story-branches) SB=1; shift ;;
    --allow-repos-worktree) ALLOW_REPOS=1; shift ;;
    --table) TABLE="$2"; shift 2 ;;
    --interval) INTERVAL="$2"; shift 2 ;;
    --max-phase-fails) MAX_FAILS="$2"; shift 2 ;;
    --stall-window) STALL="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) echo "pipeline-driver: unknown argument: $1" >&2; exit 2 ;;
  esac
done
[ -n "$PRD" ] && [ -n "$STATE" ] || usage
[ -f "$PRD" ] || { echo "pipeline-driver: no such prd: $PRD" >&2; exit 2; }
case "$INTERVAL" in ''|*[!0-9.]*|.|*.*.*) echo "pipeline-driver: --interval must be a number of seconds" >&2; exit 2 ;; esac
case "$MAX_FAILS" in ''|*[!0-9]*|0) echo "pipeline-driver: --max-phase-fails must be a positive integer" >&2; exit 2 ;; esac
case "$STALL" in ''|*[!0-9]*|0) echo "pipeline-driver: --stall-window must be a positive number of seconds" >&2; exit 2 ;; esac
command -v jq >/dev/null 2>&1 || { echo "pipeline-driver: jq required" >&2; exit 2; }
command -v node >/dev/null 2>&1 || { echo "pipeline-driver: node required" >&2; exit 2; }

HERE="$(cd "$(dirname "$0")" && pwd)"
PC="${PIPELINE_DRIVER_CONDUCTOR:-$HERE/pipeline-conductor.sh}"
PC_HQ="${PC_HQ:-hq}"
export PC_HQ
mkdir -p "$STATE/stories" "$STATE/handoffs" "$STATE/envelopes" "$STATE/driver" || exit 2
STATE="$(cd "$STATE" && pwd)"
D="$STATE/driver"
LOG="$D/driver.log"
LOCK="$D/lock"
TAB="$(printf '\t')"

log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >>"$LOG"; }

# ---- one copy per state dir ----
is_driver() { # pid -> 0 when that pid is alive and is a pipeline-driver
  [ -n "$1" ] || return 1
  kill -0 "$1" 2>/dev/null || return 1
  ps -p "$1" -o args= 2>/dev/null | grep -q 'pipeline-driver' || return 1
}
OWN_LOCK=0
take_lock() {
  if mkdir "$LOCK" 2>/dev/null; then
    printf '%s\n' "$$" >"$LOCK/pid"; OWN_LOCK=1; return 0
  fi
  holder="$(cat "$LOCK/pid" 2>/dev/null || true)"
  if is_driver "$holder"; then return 1; fi
  log "STALE_LOCK pid=${holder:-none}; taking it over"
  rm -rf "$LOCK"
  mkdir "$LOCK" 2>/dev/null || return 1
  printf '%s\n' "$$" >"$LOCK/pid"; OWN_LOCK=1
}
if ! take_lock; then
  echo "pipeline-driver: another driver (pid $(cat "$LOCK/pid" 2>/dev/null)) runs against $STATE" >&2
  log "REFUSED second copy pid=$$ holder=$(cat "$LOCK/pid" 2>/dev/null)"
  exit 24
fi
printf '%s\n' "$$" >"$D/driver.pid"
rm -f "$D/exit"

cleanup() {
  if [ "$OWN_LOCK" = 1 ]; then rm -rf "$LOCK"; rm -f "$D/driver.pid"; fi
}
finish() { # code reason
  printf '%s %s\n' "$1" "$2" >"$D/exit"
  log "EXIT $1 $2"
  cleanup; OWN_LOCK=0
  exit "$1"
}
# stop_run code reason: mark in-flight phases interrupted, withdraw unpicked envelopes, exit
stop_run() {
  trap '' TERM INT
  OUT="$("$PC" interrupt --state "$STATE" --note "$2" 2>&1)"
  log "INTERRUPT rc=$?: $(printf '%s' "$OUT" | tr '\n' ' ')"
  stop_lanes
  rm -f "$D/stop.json"
  finish "$1" "$2"
}
stop_lanes() {
  [ -f "$STATE/lanes.json" ] || return 0
  local deadline lane_file
  lane_file="$STATE/lanes.json"
  while IFS= read -r lane; do
    [ -n "$lane" ] || continue
    "$PC_HQ" lanes stop "$lane" >/dev/null 2>&1 || true
  done <<EOF
$(jq -r 'to_entries[] | .value' "$STATE/lanes.json" 2>/dev/null)
EOF
  deadline=$(( $(date +%s) + 60 ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    local rows
    rows="$("$PC_HQ" lanes list --json 2>/dev/null)"
    if printf '%s' "$rows" | jq -e --slurpfile owned "$lane_file" '
      (if type == "array" then . else .lanes end) as $rows |
      ($rows | type == "array") and
      all($owned[0][]; . as $id | ([ $rows[] | select(.lane_id == $id) ] | length == 0 or .[0].loop.state == "stopped"))' >/dev/null 2>&1; then
      printf '{}\n' > "$lane_file"
      return 0
    fi
    sleep 2
  done
  log "LANE_STOP_TIMEOUT unable to confirm all mapped lanes stopped or absent within 60s"
  return 1
}
check_stop() {
  [ -f "$D/stop.json" ] || return 0
  stop_run 29 "stopped on request: $(tr '\n' ' ' <"$D/stop.json" 2>/dev/null)"
}
trap 'cleanup' EXIT
trap 'stop_run 143 "terminated"' TERM
trap 'stop_run 130 "interrupted"' INT

log "START pid=$$ prd=$PRD interval=${INTERVAL}s max_phase_fails=$MAX_FAILS stall_window=${STALL}s"
if [ -f "$D/stop.json" ]; then log "STALE_STOP removed driver/stop.json left from an earlier stop"; rm -f "$D/stop.json"; fi
# jq helpers: t = truthiness as JSON-writing tools treat it (null, false, 0,
# "", [], {} are false); ps = a value printed as text (null -> None).
JQ_DEFS='def t: . != null and . != false and . != 0 and . != "" and . != [] and . != {};
def ps: if . == null then "None" elif type == "string" then . elif . == true then "True" elif . == false then "False" else tojson end;'
# stories_jq <filter>: run <filter> over each readable, valid story file in
# byte-sorted name order; unreadable or invalid files are skipped
stories_jq() {
  LC_ALL=C ls -A "$STATE/stories" 2>/dev/null | while IFS= read -r n; do
    jq -rs "$JQ_DEFS if length == 1 then .[0] | ($1) else empty end" "$STATE/stories/$n" 2>/dev/null
  done
}
REOPENED="$(stories_jq 'select(type == "object") | .reopen as $ro
  | select(($ro | type) == "object" and ($ro.routed | t | not) and ($ro.done | t | not))
  | "\(.id | ps)@\($ro.phase | ps)"' | tr '\n' ' ')"
[ -n "$REOPENED" ] && log "REOPENED_FIRST $REOPENED"
INTERRUPTED="$(stories_jq 'select(type == "object") | .interrupted as $it
  | select(($it | type) == "object" and ($it.phase | t) and ($it.routed | t | not))
  | "\(.id | ps)@\($it.phase | ps)"' | tr '\n' ' ')"
[ -n "$INTERRUPTED" ] && log "INTERRUPTED_FIRST $INTERRUPTED"

# ---- scan: read the state dir, print what to do, one tab-separated line each ----
#   ARCHIVE <id> <phase> <handoff>   a queued/held story still has a handoff for its current phase
#   FAILCAP <id> <phase> <n> <why>   that phase returned status failed in <n> >= max attempts
#                                    (why: failed), or its engine exited early twice
#                                    (why: engine_exited_early)
#   EARLY   <id> <phase> <secs> <reason>  an in-flight phase's engine exited early
#   ACCEPT  <id> <phase> <handoff>   an in-flight phase has its handoff
#   RECHECK <id>                     a story is awaiting recheck
#   DEADLINE <id> <phase> <deadline> an in-flight phase is past its deadline with no handoff
#   INFLIGHT <id> <phase> <secs>     an in-flight phase with no handoff, routed <secs> ago
#   HELD    <id> <decision-file>     a story is held for an approval decision
#   BLOCKED <id> <phase> <decision>  a phase returned blocked (or cannot route); the owner decides
#   AWAITING_GO <id> <decision>      a story needs an explicit go
#   INTERRUPTED <id> <phase> <at>    a story was interrupted on a stop and is not routed again yet
#   LANE_STOPPED <id> <phase>        the in-flight phase's loop lane exited on a stop envelope
#   ACTIVE  <n>                      stories queued, in flight, held or awaiting recheck
scan() {
  PD_STATE="$STATE" PD_MAX="$MAX_FAILS" PD_HQ="$PC_HQ" node - <<'JS'
'use strict';
const fs = require('fs'), path = require('path'), cp = require('child_process');
const S = process.env.PD_STATE, MAX = parseInt(process.env.PD_MAX, 10), HQ = process.env.PD_HQ;
const TERMINAL = ['passed', 'failed', 'blocked'];
const EARLY = 'engine_exited_early';
const isObj = (v) => v !== null && typeof v === 'object' && !Array.isArray(v);
const isNum = (v) => typeof v === 'number';
const truthy = (v) => !(v === null || v === undefined || v === false || v === 0 || v === '' ||
  (Array.isArray(v) && !v.length) || (isObj(v) && !Object.keys(v).length));
const str = (v) => v === undefined || v === null ? 'None' : v === true ? 'True' : v === false ? 'False'
  : typeof v === 'string' ? v : JSON.stringify(v);
const get = (o, k, d) => (isObj(o) && Object.prototype.hasOwnProperty.call(o, k) ? o[k] : d);
const byteSort = (a) => a.sort((x, y) => Buffer.compare(Buffer.from(x), Buffer.from(y)));
function load(p) {
  try { return JSON.parse(fs.readFileSync(p, 'utf8')); } catch (e) { return null; }
}
// whole seconds since the epoch of "YYYY-MM-DDTHH:MM:SS" (first 19 chars); null when unparseable
function epoch(ts) {
  const m = /^(\d{4})-(\d{1,2})-(\d{1,2})T(\d{1,2}):(\d{1,2}):(\d{1,2})$/.exec(String(ts).slice(0, 19));
  if (!m) return null;
  const [y, mo, d, h, mi, s] = m.slice(1).map(Number);
  if (mo < 1 || mo > 12 || h > 23 || mi > 59 || s > 61) return null;
  const ms = Date.UTC(y, mo - 1, d, h, mi, s);
  if (d < 1 || new Date(Date.UTC(y, mo - 1, d)).getUTCDate() !== d) return null;
  return Math.floor(ms / 1000);
}
const now = () => Date.now() / 1000;
const isoNow = () => new Date().toISOString().slice(0, 19) + 'Z';
const collapse = (s) => Array.from(s.split(/\s+/).filter(Boolean).join(' ')).slice(0, 300).join('');
let lanes = null;
function laneRows() {
  if (lanes === null) {
    lanes = new Map();
    try {
      const owned = load(path.join(S, 'lanes.json')) || {};
      const r = cp.spawnSync(HQ, ['lanes', 'list', '--json'], { encoding: 'utf8', timeout: 30000 });
      if (!r.error) {
        const text = String(r.stdout || ''), starts = [text.indexOf('['), text.indexOf('{')].filter((n) => n >= 0);
        const parsed = JSON.parse(starts.length ? text.slice(Math.min(...starts)) : text);
        const rows = Array.isArray(parsed) ? parsed : (isObj(parsed) && Array.isArray(parsed.lanes) ? parsed.lanes : []);
        for (const x of rows) if (isObj(x) && Object.values(owned).includes(get(x, 'lane_id', null))) lanes.set(get(x, 'lane_id', null), x);
      }
    } catch (e) { /* no lanes */ }
  }
  return lanes;
}
function laneRow(worker) {
  const owned = load(path.join(S, 'lanes.json')) || {};
  return laneRows().get(owned[worker]) || null;
}
// journal events of a lane containing <needle>, filtered to those written after <since>
function journal(worker, needle, since, pick) {
  const rd = laneDir(worker);
  if (!truthy(rd)) return undefined;
  let lines;
  try { lines = fs.readFileSync(path.join(String(rd), 'journal.jsonl'), 'utf8').split('\n'); } catch (e) { return undefined; }
  let found = null;
  for (const line of lines) {
    if (!line.includes(needle)) continue;
    let ev;
    try { ev = JSON.parse(line); } catch (e) { continue; }
    if (!pick(ev)) continue;
    const ts = get(ev, 'ts', null);
    if (since !== null && typeof ts === 'string') {
      const t = epoch(ts);
      if (t !== null && t < since - 1) continue;
    }
    found = ev;
  }
  return found;
}
function laneStopped(worker, since) {
  const row = laneRow(worker);
  return !!row && get(get(row, 'loop', {}), 'state') === 'stopped';
}
function phaseExit(worker, sid, ph, since) {
  // the lane's last phase-exit event for this phase written after it was routed
  const row = laneRow(worker);
  if (!row) return null;
  const state = get(get(row, 'loop', {}), 'state');
  if (state === 'parked') return { reason: 'loop_stalled', phase: ph, story_id: sid };
  return state === 'failed' ? { reason: state, phase: ph, story_id: sid } : null;
}
function mtime(p) {
  try { return fs.statSync(p).mtimeMs / 1000; } catch (e) { return null; }
}
const out = []; let active = 0;
const sd = path.join(S, 'stories');
for (const n of byteSort(fs.readdirSync(sd))) {
  if (!n.endsWith('.json')) continue;
  const st = load(path.join(sd, n));
  if (!isObj(st) || !('id' in st)) continue;
  const sid = st.id, state = get(st, 'state', null);
  if (['queued', 'in_flight', 'held', 'awaiting_recheck', 'interrupted'].includes(state)) active++;
  const it = get(st, 'interrupted', null);
  if (isObj(it) && truthy(it.phase) && !truthy(it.routed)) out.push(['INTERRUPTED', sid, str(it.phase), str(get(it, 'at', ''))]);
  const phases = truthy(st.phases) ? st.phases : [];
  const cur = get(st, 'current', 0);
  if (!(Number.isInteger(cur) && cur >= 0 && cur < phases.length)) continue;
  const ph = phases[cur].phase;
  const worker = phases[cur].worker;
  const h = path.join(S, 'handoffs', `${sid}-${ph}.json`);
  if (state === 'queued' || state === 'held') {
    if (fs.existsSync(h)) out.push(['ARCHIVE', sid, ph, h]);
    // count attempts whose handoff said failed; blocked ones are the owner's, not a retry
    const hd = path.join(S, 'handoffs');
    // a retry by the owner starts the count over: archives up to fail_ack are acknowledged
    const fa = get(st, 'fail_ack', null);
    const ack = isObj(fa) ? Math.trunc(Number(get(fa, ph, 0) || 0)) : 0;
    const pre = `${sid}-${ph}.failed.`;
    const tried = fs.readdirSync(hd).filter((f) => {
      if (!f.startsWith(pre) || !f.endsWith('.json')) return false;
      const mid = f.slice(pre.length, -5);
      return /^\d+$/.test(mid) && parseInt(mid, 10) > ack;
    }).map((f) => path.join(hd, f));
    if (fs.existsSync(h)) tried.push(h);
    const hs = tried.map((f) => { const x = load(f); return isObj(x) ? x : {}; });
    const fails = hs.filter((x) => x.status === 'failed').length;
    const early = hs.filter((x) => x.status === 'failed' && x.exit_reason === EARLY).length;
    if (early >= 2) out.push(['FAILCAP', sid, ph, String(early), EARLY]);
    else if (fails >= MAX) out.push(['FAILCAP', sid, ph, String(fails), 'failed']);
    if (state === 'held') {
      const dp = path.join(S, 'decisions', `${sid}-${get(st, 'held_for', worker)}.md`);
      out.push(['HELD', sid, dp]);
    }
  } else if (state === 'in_flight') {
    const hd = load(h);
    let since = get(st, 'routed_at', null);
    if (!isNum(since)) since = mtime(path.join(S, 'envelopes', `${sid}-${ph}.json`));
    const mine = isObj(hd) && hd.phase === ph;
    const hstat = mine ? get(hd, 'status', null) : null;
    let ev = null;
    if (mine && TERMINAL.includes(hstat) && get(hd, 'exit_reason', null) !== EARLY) {
      out.push(['ACCEPT', sid, ph, h]);
    } else if (mine && get(hd, 'exit_reason', null) === EARLY) {
      let secs = get(hd, 'elapsed_s', null);
      if (!isNum(secs)) secs = since !== null ? Math.trunc(now() - since) : 0;
      const why = collapse(str(truthy(hd.notes) ? hd.notes : truthy(hd.summary) ? hd.summary : 'no reason given'));
      out.push(['EARLY', sid, ph, String(Math.trunc(secs)), why]);
    } else if ((!mine || !TERMINAL.includes(hstat)) && (ev = phaseExit(worker, sid, ph, since)) !== null) {
      let secs = get(ev, 'elapsed_s', null);
      if (!isNum(secs)) secs = since !== null ? Math.trunc(now() - since) : 0;
      const why = collapse(str(truthy(ev.reason) ? ev.reason : 'no reason given'));
      if (get(ev, 'reason', null) === 'loop_stalled') out.push(['LANE_STALLED', sid, ph, worker]);
      else out.push(['EARLY', sid, ph, String(Math.trunc(secs)), why]);
    } else if (laneStopped(worker, since)) {
      out.push(['LANE_STOPPED', sid, ph]);
    } else {
      const env = load(path.join(S, 'envelopes', `${sid}-${ph}.json`));
      const dl = get(env, 'deadline', null);
      if (typeof dl === 'string' && isoNow() > dl) out.push(['DEADLINE', sid, ph, dl]);
      if (since !== null) out.push(['INFLIGHT', sid, ph, String(Math.max(0, Math.trunc(now() - since)))]);
    }
  } else if (state === 'awaiting_go') {
    out.push(['AWAITING_GO', sid, path.join(S, 'decisions', `${sid}-go.md`)]);
  } else if (state === 'blocked_needs_owner') {
    out.push(['BLOCKED', sid, ph, path.join(S, 'decisions', `${sid}-blocked-${ph}.md`)]);
  } else if (state === 'awaiting_recheck') {
    out.push(['RECHECK', sid]);
  }
}
out.push(['ACTIVE', String(active)]);
process.stdout.write(out.map((r) => r.join('\t') + '\n').join(''));
JS
}

# archive <id> <phase> <handoff>: move a stale handoff aside under the next free number
archive() {
  n=1
  while [ -e "$STATE/handoffs/$1-$2.failed.$n.json" ]; do n=$((n + 1)); done
  mv -f "$3" "$STATE/handoffs/$1-$2.failed.$n.json" && log "ARCHIVE $1 $2 -> $1-$2.failed.$n.json"
}

# early_handoff <id> <phase> <secs> <reason>: make <id>-<phase>.json the failed
# handoff of an early engine exit (exit_reason engine_exited_early), keeping a
# lane-written one's fields; print its path
early_handoff() {
  PD_H="$STATE/handoffs/$1-$2.json" PD_SID="$1" PD_PH="$2" PD_SECS="$3" PD_WHY="$4" \
  ehp="$STATE/handoffs/$1-$2.json"
  ehw="$(jq -rs "$JQ_DEFS"' if length == 1 then .[0].phases[.[0].current].worker | ps else empty end' \
    "$STATE/stories/$1.json" 2>/dev/null)"
  ehh="$(jq -cs 'if length == 1 then .[0] else null end' "$ehp" 2>/dev/null)" || ehh=null
  [ -n "$ehh" ] || ehh=null
  printf '%s\n' "$ehh" | jq -c --arg sid "$1" --arg ph "$2" --arg secs "$3" --arg why "$4" --arg worker "$ehw" \
    "$JQ_DEFS"' (if type == "object" and .phase == $ph then . else {} end)
    | ($secs | tonumber | if . < 0 then -(-. | floor) else floor end) as $el
    | . + {schema: "hq-phase-handoff/v1", story_id: $sid, phase: $ph,
           worker_id: (if (.worker_id | t) then .worker_id else $worker end), status: "failed",
           exit_reason: "engine_exited_early", elapsed_s: $el}
    | if ((if has("summary") then .summary else "" end) | ps | startswith("engine_exited_early")) then .
      else .summary = "engine_exited_early after \($secs)s: \($why)" end
    | if has("files_changed") then . else .files_changed = [] end
    | if has("commits") then . else .commits = [] end
    | if has("back_pressure") then . else .back_pressure = {tests: "skip", lint: "skip", typecheck: "skip", build: "skip"} end
    | if has("context_for_next") then . else .context_for_next = "" end
    | if has("notes") then . else .notes = $why end' >"$ehp.tmp" && mv -f "$ehp.tmp" "$ehp" && printf '%s\n' "$ehp"
}

# stall_check: print "FIRE <since>" the first time the stall condition has held
# for --stall-window; keeps driver/stall.json and appends the event to
# <state>/events.jsonl when it fires
stall_check() {
  PD_STATE="$STATE" PD_WINDOW="$STALL" PD_HQ="$PC_HQ" node - <<'JS'
'use strict';
const fs = require('fs'), path = require('path');
const S = process.env.PD_STATE, W = parseInt(process.env.PD_WINDOW, 10), HQ = process.env.PD_HQ;
const SF = path.join(S, 'driver', 'stall.json');
const isObj = (v) => v !== null && typeof v === 'object' && !Array.isArray(v);
const truthy = (v) => !(v === null || v === undefined || v === false || v === 0 || v === '' ||
  (Array.isArray(v) && !v.length) || (isObj(v) && !Object.keys(v).length));
const get = (o, k, d) => (isObj(o) && Object.prototype.hasOwnProperty.call(o, k) ? o[k] : d);
const byteSort = (a) => a.sort((x, y) => Buffer.compare(Buffer.from(x), Buffer.from(y)));
const cmp = (x, y) => (x < y ? -1 : x > y ? 1 : 0);
function load(p) {
  try { return JSON.parse(fs.readFileSync(p, 'utf8')); } catch (e) { return null; }
}
function epoch(iso) {
  const m = /^(\d{4})-(\d{1,2})-(\d{1,2})T(\d{1,2}):(\d{1,2}):(\d{1,2})$/.exec(String(iso).slice(0, 19));
  if (!m) return null;
  const [y, mo, d, h, mi, s] = m.slice(1).map(Number);
  if (mo < 1 || mo > 12 || h > 23 || mi > 59 || s > 61) return null;
  if (d < 1 || new Date(Date.UTC(y, mo - 1, d)).getUTCDate() !== d) return null;
  return Math.floor(Date.UTC(y, mo - 1, d, h, mi, s) / 1000);
}
function files(d) {
  try { return fs.readdirSync(d).filter((n) => !n.startsWith('.')); } catch (e) { return []; }
}
const now = () => Date.now() / 1000;
const iso = (secs) => new Date(Math.floor(secs) * 1000).toISOString().slice(0, 19) + 'Z';
// Python json.dumps default output: ", " / ": " separators, non-ASCII escaped
function dumps(v) {
  if (v === null || v === undefined) return 'null';
  if (v === true) return 'true';
  if (v === false) return 'false';
  if (typeof v === 'number') {
    let s = String(v);
    const m = /^(-?)(\d)(?:\.(\d+))?e([+-])(\d+)$/.exec(s);
    if (m) s = m[1] + m[2] + (m[3] ? '.' + m[3] : '') + 'e' + m[4] + m[5].padStart(2, '0');
    return s;
  }
  if (typeof v === 'string') return JSON.stringify(v).replace(/[\u0080-￿]/g, (c) => '\\u' + c.charCodeAt(0).toString(16).padStart(4, '0'));
  if (Array.isArray(v)) return '[' + v.map(dumps).join(', ') + ']';
  return '{' + Object.keys(v).map((k) => dumps(k) + ': ' + dumps(v[k])).join(', ') + '}';
}
let rows = [];
try {
  const owned = load(path.join(S, 'lanes.json')) || {};
  const r = require('child_process').spawnSync(HQ, ['lanes', 'list', '--json'], { encoding: 'utf8', timeout: 30000 });
  const text = String(r.stdout || ''), starts = [text.indexOf('['), text.indexOf('{')].filter((n) => n >= 0);
  const parsed = JSON.parse(starts.length ? text.slice(Math.min(...starts)) : text);
  const listed = Array.isArray(parsed) ? parsed : (isObj(parsed) && Array.isArray(parsed.lanes) ? parsed.lanes : []);
  rows = listed.filter((row) => isObj(row) && Object.values(owned).includes(get(row, 'lane_id', null)));
} catch (e) { process.exit(0); }
const inflight = [];
const sd = path.join(S, 'stories');
for (const n of byteSort(fs.readdirSync(sd))) {
  const st = n.endsWith('.json') ? load(path.join(sd, n)) : null;
  if (!isObj(st) || st.state !== 'in_flight') continue;
  const phases = truthy(st.phases) ? st.phases : [];
  const cur = get(st, 'current', 0);
  if (!(Number.isInteger(cur) && cur >= 0 && cur < phases.length)) continue;
  let since = get(st, 'routed_at', null);
  if (typeof since !== 'number') {
    try { since = fs.statSync(path.join(S, 'envelopes', `${st.id}-${phases[cur].phase}.json`)).mtimeMs / 1000; } catch (e) { since = now(); }
  }
  inflight.push([st.id, phases[cur].worker, since]);
}
const live = rows.filter((r) => isObj(r) && isObj(r.loop));
let cond = false, stories = [], lanes = [], since = null;
if (inflight.length && live.length && live.every((r) => r.loop.state === 'waiting' && r.loop.queue_depth === 0)) {
  cond = true;
  stories = inflight.map((x) => x[0]); lanes = live.map((r) => get(r, 'lane_id', null)).sort(cmp);
  const changed = live.filter((r) => truthy(r.loop.updated_at)).map((r) => epoch(r.loop.updated_at));
  since = Math.max(Math.min(...inflight.map((x) => x[2])), ...changed.filter((c) => c !== null));
} else {
  // a routed phase sits in its lane queue and the lane has nothing active
  const owned = load(path.join(S, 'lanes.json')) || {};
  const byWorker = new Map();
  for (const r of live) for (const [worker, lane] of Object.entries(owned)) if (lane === get(r, 'lane_id', null)) byWorker.set(worker, r);
  for (const [sid, worker, s] of inflight) {
    const r = byWorker.get(worker);
    if (r && get(r.loop, 'queue_depth', 0) > 0 && !truthy(get(r.loop, 'active_envelope_id', null))) {
      cond = true; stories.push(sid); lanes.push(get(r, 'lane_id', worker));
      since = since === null ? s : Math.min(since, s);
    }
  }
}
const prev = load(SF);
if (!cond) {
  if (isObj(prev) && !truthy(prev.fired)) fs.unlinkSync(SF);
  process.exit(0);
}
if (isObj(prev)) {
  if (truthy(prev.fired)) process.exit(0);
  since = get(prev, 'since_epoch', since);
}
const sinceIso = iso(since);
const rec = { since_epoch: since, since: sinceIso, stories, lanes: [...new Set(lanes)].sort(cmp), fired: false };
if (now() - since >= W) {
  rec.fired = true;
  fs.appendFileSync(path.join(S, 'events.jsonl'), dumps({ event: 'stall', stories, lanes: rec.lanes, since: sinceIso,
    at: iso(now()) }) + '\n');
  process.stdout.write('FIRE ' + sinceIso + ' stories=' + stories.join(',') + ' lanes=' + rec.lanes.join(',') + '\n');
}
fs.writeFileSync(SF + '.tmp', dumps(rec));
fs.renameSync(SF + '.tmp', SF);
JS
}

# run_pc <args...>: run the conductor, leaving stdout in $OUT and rc in $RC
run_pc() {
  OUT="$("$PC" "$@" 2>"$D/.pc.err")"; RC=$?
  ERR="$(cat "$D/.pc.err" 2>/dev/null)"; rm -f "$D/.pc.err"
}

# go_list: the stories awaiting an explicit go, from a read-only scan
go_list() {
  scan | while IFS="$TAB" read -r a b c d; do
    [ "$a" = AWAITING_GO ] && printf '%s ' "$b"
  done | sed 's/ $//'
}

# run_tick: one conductor tick with every --worktree and --story-branches passed through
run_tick() {
  set -- tick --prd "$PRD" --state "$STATE"
  [ "$SB" = 1 ] && set -- "$@" --story-branches
  [ "$ALLOW_REPOS" = 1 ] && set -- "$@" --allow-repos-worktree
  [ -n "$TABLE" ] && set -- "$@" --table "$TABLE"
  if [ -n "$WT" ]; then
    oldifs="$IFS"; IFS="$NL"; set -f
    for w in $WT; do set -- "$@" --worktree "$w"; done
    set +f; IFS="$oldifs"
  fi
  run_pc "$@"
}

# ---- act on one scan; sets ACTED=1 when the state dir changed, PENDING_EXIT on a stop ----
act() {
  ACTED=0; ACTIVE=""; HELD_ITEM=""; GATE_DUE=0; BLOCKED_ITEMS=""; GO_ITEMS=""; INT_ITEMS=""
  while IFS="$TAB" read -r a b c d e; do
    case "$a" in
      ARCHIVE) archive "$b" "$c" "$d"; ACTED=1 ;;
      FAILCAP)
        log "FAILCAP $b $c ${e:-failed} in $d attempt(s)"
        run_pc failcap --state "$STATE" --story "$b"
        log "FAILCAP_HOLD $b $c rc=$RC: $OUT${ERR:+ | $ERR}"
        case "$RC:$OUT" in
          10:PHASE_FAILCAP*|10:ALREADY*) ;;
          *) finish 23 "failcap $b $c: unexpected (rc=$RC): $OUT $ERR" ;;
        esac
        [ "$e" = engine_exited_early ] && finish 21 "phase $b/$c: engine_exited_early in $d of $d attempt(s); the lane was restarted once in place and the engine exited early again; held for the owner (decision: ${OUT##* }); the parent decides whether to retry, change the story, or stop"
        fail_reason="$(jq -r '.blocked.text // "" | gsub("[\\r\\n\\t]+"; " ")' "$STATE/stories/$b.json" 2>/dev/null)"
        finish 21 "phase $b/$c returned handoff status failed in $d of $d attempt(s) (limit $MAX_FAILS); reason: $fail_reason; held for the owner (decision: ${OUT##* }); the parent decides whether to retry, change the story, or stop" ;;
      EARLY)
        log "TICK: EARLY_EXIT $b/$c after ${d}s: engine_exited_early ($e)"
        h="$(early_handoff "$b" "$c" "$d" "$e")" || finish 23 "could not write the early-exit handoff for $b/$c"
        rm -f "$D/stall.json"
        run_pc accept --state "$STATE" --story "$b" --handoff "$h"
        log "ACCEPT $b $c rc=$RC: $OUT${ERR:+ | $ERR}"
        case "$RC:$OUT" in
          1:PHASE_FAILED*) ACTED=1 ;;
          *) finish 23 "accept early exit $b $c: unexpected (rc=$RC): $OUT $ERR" ;;
        esac ;;
      ACCEPT)
        rm -f "$D/stall.json"
        log "ACCEPTING $b $c $d"
        run_pc accept --state "$STATE" --story "$b" --handoff "$d"
        log "ACCEPT $b $c rc=$RC: $OUT${ERR:+ | $ERR}"
        case "$RC:$OUT" in
          0:NEXT*|0:RECHECK*|1:PHASE_*|10:PHASE_BLOCKED*) ACTED=1 ;;
          *) finish 23 "accept $b $c: unexpected (rc=$RC): $OUT $ERR" ;;
        esac ;;
      RECHECK)
        log "RECHECKING $b"
        run_pc recheck --prd "$PRD" --state "$STATE" --story "$b"
        log "RECHECK $b rc=$RC: $(printf '%s' "$OUT" | tr '\n' ' ')${ERR:+ | $ERR}"
        case "$RC:$OUT" in
          0:VERIFIED*) ACTED=1; case "$OUT" in *RUN_GATE*) GATE_DUE=1 ;; esac ;;
          1:ROUTED_BACK*|1:FAILED*) ACTED=1 ;;
          *) finish 23 "recheck $b: unexpected (rc=$RC): $OUT $ERR" ;;
        esac ;;
      DEADLINE) finish 22 "phase $b/$c passed its deadline $d with no handoff" ;;
      HELD) HELD_ITEM="$b $c" ;;
      BLOCKED)
        blocked_reason="$(jq -r '.blocked.text // "" | gsub("[\\r\\n\\t]+"; " ")' "$STATE/stories/$b.json" 2>/dev/null)"
        BLOCKED_ITEMS="${BLOCKED_ITEMS:+$BLOCKED_ITEMS; }$b/$c${blocked_reason:+: $blocked_reason} (decision: $d)" ;;
      AWAITING_GO) GO_ITEMS="${GO_ITEMS:+$GO_ITEMS, }$b (decision: $c)" ;;
      INTERRUPTED) INT_ITEMS="${INT_ITEMS:+$INT_ITEMS, }$b at $c ($d)" ;;
      LANE_STOPPED)
        run_pc interrupt --state "$STATE" --story "$b" --note "the $c lane exited on a stop envelope"
        log "LANE_STOPPED $b $c rc=$RC: $OUT${ERR:+ | $ERR}"
        ACTED=1 ;;
      LANE_STALLED)
        company="$(jq -r '.company_slug // empty' "$STATE/run.json" 2>/dev/null)"
        lane="$(jq -r --arg w "$d" '.[$w] // empty' "$STATE/lanes.json" 2>/dev/null)"
        questions="$("$PC_HQ" lanes questions list --company "$company" --json 2>/dev/null | jq -c --arg lane "$lane" '.questions[]? | select(.lane_id == $lane and .status == "pending")' 2>/dev/null | head -1)"
        log "LANE_QUESTION story=$b phase=$c lane=$lane question=${questions:-missing}"
        finish 28 "loop lane $lane parked after repeated stalls for $b/$c; answer its pending question with hq lanes questions answer, then restart the driver: ${questions:-no pending question returned}" ;;
      INFLIGHT) ;;
      ACTIVE) ACTIVE="$b" ;;
      '') ;;
      *) finish 23 "scan printed an unknown line: $a" ;;
    esac
  done <<EOF
$(scan)
EOF
  [ -n "$ACTIVE" ] || finish 23 "could not read the state dir $STATE"
}

while :; do
  check_stop
  # Settle the state dir: archive, accept and recheck until a scan finds nothing to do.
  i=0
  while :; do
    act
    [ "$GATE_DUE" = 1 ] && finish 20 "regression gate due"
    [ "$ACTED" = 1 ] || break
    i=$((i + 1))
    [ "$i" -lt 100 ] || finish 23 "state did not settle after 100 scans"
  done
  [ -n "$HELD_ITEM" ] && finish 21 "story held for approval: $HELD_ITEM"
  FIRE="$(stall_check)"
  if [ -n "$FIRE" ]; then
    # FIRE <since> stories=<ids> lanes=<ids>
    set -- $FIRE
    log "STALL since $2 $3 $4: no phase accepted for the whole ${STALL}s stall window; event in $STATE/events.jsonl"
    finish 28 "stall: since $2, $3 $4, no phase accepted for ${STALL}s and no lane is working on them (event: $STATE/events.jsonl); check the lanes, then restart the driver"
  fi

  check_stop
  INT_NOW="$INT_ITEMS"
  run_tick
  GO_NOW="$(go_list)"
  if [ -n "$OUT" ] || [ "$GO_NOW" != "${GO_LAST:-}" ] || [ -n "$INT_NOW" ]; then
    log "TICK: $(printf '%s' "$OUT" | tr '\n' ' ')${GO_NOW:+| awaiting go: $GO_NOW}${INT_NOW:+| interrupted, routing first: $INT_NOW}"
  fi
  GO_LAST="$GO_NOW"
  case "$RC" in 0|3|11|12) ;; *) finish 23 "tick failed (rc=$RC): $ERR" ;; esac
  HELD_ITEM=""; GATE=""; LANE_DOWN=""; NO_LANE=""
  while IFS= read -r line; do
    case "$line" in
      ''|ROUTED\ *|RETRY\ *|PARKED_DEPENDENCY\ *|RELEASED_DEPENDENCY\ *) ;;
      CUT\ *|REUSED\ *|EXISTS\ *|MAX_STORIES\ *|BLOCKED_OWNER\ *|AWAITING_GO\ *) ;;
      HELD\ *) HELD_ITEM="${line#HELD }" ;;
      LANE_DOWN\ *) [ -n "$LANE_DOWN" ] || LANE_DOWN="${line#LANE_DOWN }" ;;
      NO_LANE\ *) [ -n "$NO_LANE" ] || NO_LANE="${line#NO_LANE }" ;;
      RUN_GATE) GATE=due ;;
      GATE_FAILED) GATE=failed ;;
      *) finish 23 "tick printed an unexpected line: $line" ;;
    esac
  done <<EOF
$OUT
EOF
  if [ -n "$LANE_DOWN" ]; then
    # LANE_DOWN <id> <phase> <worker> lanes-<code>
    set -- $LANE_DOWN
    log "LANE_DOWN lane $3 is down: $1/$2 stays queued; $4"
    finish 26 "lane down: $3 (story $1 phase $2 stays queued; $4); relaunch the $3 loop lane, then restart the driver"
  fi
  if [ -n "$NO_LANE" ]; then
    # NO_LANE <id> <phase> <worker> not in the worker table <file>
    set -- $NO_LANE
    log "NO_LANE $3 has no row in the worker table: $1/$2 stays queued"
    finish 27 "no lane: worker $3 has no row in the worker table (story $1 phase $2 stays queued); add the row, launch the $3 loop lane, then restart the driver"
  fi
  [ "$GATE" = due ] && finish 20 "regression gate due"
  [ "$GATE" = failed ] && finish 21 "regression gate failed; if one story caused it, record: pipeline-conductor.sh gate result fail --state $STATE --story <id> --note <text>, then restart the driver"
  [ -n "$HELD_ITEM" ] && finish 21 "story held for approval: $HELD_ITEM"

  if [ "$OUT" = "" ]; then
    act
    if [ "$ACTED" = 0 ] && [ "$ACTIVE" = 0 ]; then
      run_pc next --prd "$PRD" --state "$STATE"
      if [ "$RC" = 0 ] && [ -z "$OUT" ]; then
        run_pc report final --state "$STATE"
        log "REPORT $OUT"
        if [ -n "$BLOCKED_ITEMS$GO_ITEMS" ]; then
          why="${BLOCKED_ITEMS:+ blocked by its worker: $BLOCKED_ITEMS}"
          [ -n "$GO_ITEMS" ] && why="${why:+$why;} awaiting go: $GO_ITEMS; release with pipeline-conductor.sh go --state $STATE --story <id>"
          finish 21 "decision needed, nothing else can move:$why"
        fi
        stop_lanes || finish 23 "could not confirm every loop lane stopped; see LANE_STOP_TIMEOUT"
        finish 0 "all stories finished: $OUT"
      fi
    fi
  fi
  # wait, not a bare sleep: a TERM or INT trap runs at once instead of after the sleep
  sleep "$INTERVAL" &
  wait $! 2>/dev/null
done
