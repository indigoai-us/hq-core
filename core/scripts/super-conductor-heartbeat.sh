#!/usr/bin/env bash
# super-conductor-heartbeat.sh — the persistent wake source for /super-conductor.
#
# Run it under `hq monitor start --persistent` so every line it prints is
# delivered into the conductor session, including while the session is idle
# (the async Stop waiter wakes it). This replaces "the owner types sweep all":
# the sweep is due on a fixed cadence whether or not the last turn ended on a
# question, a compact, or an error.
#
# Each loop waits on the conduct link for up to <interval> seconds:
#   - a child report arrives  -> prints a REPORT line at once
#   - the interval elapses    -> prints a TICK line (sweep the channels)
# After a REPORT the next wait is a plain timer, so an undrained mailbox wakes
# the session at most twice per interval instead of spinning.
#
# Usage:
#   super-conductor-heartbeat.sh --interval <seconds|auto> [--link <id>]
#       [--channels <csv>] [--state <save-file>]
#       [--message-watch <watch-state> --company <csv>]
#       [--asks <asks-file> --company <csv> [--conductor <local_id>]... [--exclude <sid>]...]
#       [--once]
#
# --interval auto picks the cadence from the owner's work-day schedule on every
# loop (super-conductor-prefs.mjs interval): watch_interval.present inside
# work_hours, watch_interval.away outside them. Each wake line names the mode.
#
# --message-watch runs super-conductor-message-watch.mjs alongside the loop. It
# polls the HQ DM inbox and the channel change feed every ~30s in work hours
# (every 5 minutes outside them) and prints a SUPER-CONDUCTOR MESSAGE line only
# when an unseen inbound message arrives, at most once per
# $SC_MESSAGE_WATCH_MIN_GAP seconds (default 120), so
# the full sweep runs on the message instead of waiting for the next TICK. The
# watcher stops when the heartbeat exits. --company (the session's locked
# company set, `hq-session.sh get company_slugs`) is required with it and is
# passed through, so the watcher reads only that set's channels. If the watcher
# exits on its own, the heartbeat prints one MESSAGE-WATCH-EXITED line with the
# exit code and the first stderr line, and keeps ticking.
#
# With --message-watch and --state the heartbeat also runs the triage daemon
# and the decision answer watch (see the block before the loop): new ledger
# rows are classified in the background and the owner's answers from the
# /decision-desk session arrive as SUPER-CONDUCTOR ANSWER lines. Critical
# channels from the owner settings (prefs.mjs critical) are passed to the
# watcher, which prints a SUPER-CONDUCTOR CRITICAL line at once for them.
#
# --asks runs super-conductor-open-asks.mjs watch alongside the loop: every
# $SC_ASK_WATCH_INTERVAL seconds (default 60) it finds sessions of the locked
# company set whose turn ended on an unanswered picker or next-step card, and
# prints one SUPER-CONDUCTOR OPEN-ASK line per new ask naming the session and
# the question. Asks recorded in <asks-file> (open-asks.mjs mark) are skipped;
# announced asks are kept in <asks-file minus .json>-announced.json.
# --conductor (the conductor's local_ id, so its relays count as answers) and
# --exclude (its own transcript id) are passed through.
#
# A REPORT line names each child that reported since the last REPORT, its
# state, and the first line of its report (for a blocked child, its question),
# read from the link's pending queue without claiming it.
#
# SWEEP-INCOMPLETE prints once per missing set: the same line is not repeated
# until the save file changes or $SC_SWEEP_REPEAT_SECONDS (default 1800) pass,
# so a conductor that is mid-turn is not buried in identical lines.
#
# The watchers also get --parent-pid, so it stops if the heartbeat is killed
# hard. On Windows (Git Bash/MSYS) $$ is an MSYS pid that Node cannot see, so
# the heartbeat passes the Windows pid from /proc/$$/winpid instead. Where that
# file is missing (macOS, Linux) it passes $$.
#
# Without --channels, the channels come from the owner's settings file
# (personal/settings/super-conductor.yaml, or $SC_PREFS_FILE) through
# super-conductor-prefs.mjs, re-read on every line so a preference saved
# mid-run applies on the next wake. Falls back to sessions,hq_dms.
#
# With --state, every wake after the first runs super-conductor-sweep-check.mjs
# verify against the previous wake's time and prints a SWEEP-INCOMPLETE line
# for any selected channel, workspace, or account without sweep evidence.
#
# Exit: 0 when the link closes (the conductor is off), 1 after repeated waiter
# errors, 2 on bad arguments.
set -uo pipefail

interval=""
link=""
channels=""
state=""
watch_state=""
companies=""
asks_file=""
conductors=()
excludes=()
once=0
HQ_BIN="${HQ_BIN:-hq}"
MAX_ERRORS="${SC_HEARTBEAT_MAX_ERRORS:-5}"
ERROR_BACKOFF="${SC_HEARTBEAT_ERROR_BACKOFF:-30}"
MIN_INTERVAL="${SC_HEARTBEAT_MIN_INTERVAL:-30}"

usage() {
  echo "usage: super-conductor-heartbeat.sh --interval <seconds|auto> [--link <id>] [--channels <csv>] [--state <save-file>] [--message-watch <watch-state> --company <csv>] [--asks <asks-file> --company <csv> [--conductor <id>]... [--exclude <sid>]...] [--once]" >&2
  exit 2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --interval) interval="${2:-}"; shift 2 ;;
    --link) link="${2:-}"; shift 2 ;;
    --channels) channels="${2:-}"; shift 2 ;;
    --state) state="${2:-}"; shift 2 ;;
    --message-watch) watch_state="${2:-}"; shift 2 ;;
    --company) companies="${companies:+$companies,}${2:-}"; shift 2 ;;
    --asks) asks_file="${2:-}"; shift 2 ;;
    --conductor) conductors+=("${2:-}"); shift 2 ;;
    --exclude) excludes+=("${2:-}"); shift 2 ;;
    --once) once=1; shift ;;
    -h|--help) usage ;;
    *) echo "super-conductor-heartbeat: unknown argument $1" >&2; usage ;;
  esac
done

if ! [[ "$interval" =~ ^[0-9]+$ || "$interval" == auto ]]; then
  echo "super-conductor-heartbeat: --interval must be whole seconds or auto" >&2
  exit 2
fi
if [[ -n "$watch_state" && "$watch_state" == -* ]]; then
  echo "super-conductor-heartbeat: --message-watch needs a state file path" >&2
  exit 2
fi
if [[ -n "$asks_file" && ( "$asks_file" == -* || -z "$companies" ) ]]; then
  echo "super-conductor-heartbeat: --asks needs a file path and --company (hq-session.sh get company_slugs)" >&2
  exit 2
fi
if [[ -n "$watch_state" && -z "$companies" ]]; then
  echo "super-conductor-heartbeat: --message-watch needs --company (hq-session.sh get company_slugs)" >&2
  exit 2
fi

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREFS_JS="$HERE/super-conductor-prefs.mjs"
fixed_interval="$interval"
mode="fixed"

# Same clamp as the skill's watch_interval rule.
clamp() { # seconds
  local s="$1"
  (( s < MIN_INTERVAL )) && s=$MIN_INTERVAL
  (( s > 3600 )) && s=3600
  printf '%s' "$s"
}

# Sets $interval and $mode for the next wait. With auto, re-read the schedule
# every loop so crossing into or out of work hours changes the cadence without
# a restart. A prefs failure (for example a bad work_hours value) keeps the last
# good cadence (900s on the first) and prints one CADENCE-ERROR line naming the
# problem, once per failure streak, so it is never silent.
cadence_error_reported=0
resolve_interval() {
  if [[ "$fixed_interval" != auto ]]; then
    interval="$(clamp "$fixed_interval")"
    return
  fi
  local out err secs m
  err="$(mktemp)"
  out="$(node "$PREFS_JS" interval 2>"$err" || true)"
  read -r secs m <<<"$out"
  if [[ "$secs" =~ ^[0-9]+$ && -n "$m" ]]; then
    interval="$(clamp "$secs")"
    mode="$m"
    cadence_error_reported=0
  else
    if ! [[ "$interval" =~ ^[0-9]+$ ]]; then
      interval=900
      mode="unknown"
    fi
    if [[ "$cadence_error_reported" -eq 0 ]]; then
      cadence_error_reported=1
      printf 'SUPER-CONDUCTOR CADENCE-ERROR %s | %s | Using %ss until the work-day settings read cleanly. Fix work_hours or watch_interval in the owner settings.\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(head -c 300 "$err" | tr '\n' ' ')" "$interval"
    fi
  fi
  rm -f "$err"
}
resolve_interval

current_channels() {
  if [[ -n "$channels" ]]; then
    printf '%s' "$channels"
    return
  fi
  local c=""
  if command -v node >/dev/null 2>&1 && [[ -f "$PREFS_JS" ]]; then
    c="$(node "$PREFS_JS" channels 2>/dev/null || true)"
  fi
  if [[ -n "$c" ]]; then
    printf '%s (from settings)' "$c"
  else
    printf 'sessions,hq_dms'
  fi
}

resume_hint="Run the /super-conductor wakeup (Step 7)"
[[ -n "$state" ]] && resume_hint="Read $state, then run the /super-conductor wakeup (Step 7)"

SWEEP_JS="$HERE/super-conductor-sweep-check.mjs"
WATCH_JS="$HERE/super-conductor-message-watch.mjs"
ASKS_JS="$HERE/super-conductor-open-asks.mjs"
HQ_ROOT_DIR="${HQ_ROOT:-$(cd "$HERE/../.." && pwd)}"
SWEEP_REPEAT="${SC_SWEEP_REPEAT_SECONDS:-1800}"
prev_wake=""
last_sweep_line=""
last_sweep_at=0
sweep_mark="$(mktemp "${TMPDIR:-/tmp}/sc-sweep-mark.XXXXXX")"
last_report_at=""

# Before each wake line, verify the save file's sweep evidence against the
# previous wake. A short sweep prints SWEEP-INCOMPLETE naming what was missed.
check_sweep() {
  [[ -n "$state" && -n "$prev_wake" ]] || return 0
  command -v node >/dev/null 2>&1 && [[ -f "$SWEEP_JS" ]] || return 0
  local args=(verify --state "$state" --since "$prev_wake") line
  [[ -n "$channels" ]] && args+=(--channels "$channels")
  if ! line="$(node "$SWEEP_JS" "${args[@]}" 2>&1)"; then
    # Same missing set, save file untouched since the last line, and inside
    # the repeat window: the conductor is mid-turn; do not bury it again.
    # The key is the set of missing target names: the reasons carry --since,
    # which moves on every wake.
    local now_s key
    now_s="$(date +%s)"
    key="$(sed -n 's/.*NOT SWEPT: //p' <<<"$line" | sed -E 's/ \(([^()]|\([^()]*\))*\)//g')"
    if [[ -n "$key" && "$key" == "$last_sweep_line" && ! "$state" -nt "$sweep_mark" ]] && (( now_s - last_sweep_at < SWEEP_REPEAT )); then
      return 0
    fi
    last_sweep_line="$key"
    last_sweep_at="$now_s"
    touch "$sweep_mark"
    printf 'SUPER-CONDUCTOR SWEEP-INCOMPLETE %s | %s | The last wakeup did not sweep every selected channel. Sweep the missing ones now and record evidence; never report "nothing new" for an unswept channel.\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${line:0:600}"
  fi
}

# Who reported since the last REPORT line, from the link's pending queue (read
# only; the conductor still drains it with `hq lanes link read`). Prints
# "<last at>\t<name> (state): first line; ..." or nothing. Report text is shown
# only for children whose joined company (children/<name>/meta.json) is in
# the --company set; others, and every child when no --company was given, are
# counted without their text or name. "|" in child text becomes "/" and
# control characters are dropped, so it cannot pose as a field of the wake
# line. A blocked child whose session has an OPEN-ASK that is still open (not
# relayed) and was announced within 15 minutes before the report is shown as
# that ask instead of its question, so one decision reaches /decision-queue
# once; any other blocked report shows its own question.
report_summary() {
  [[ -n "$link" ]] || return 0
  local dir="$HQ_ROOT_DIR/workspace/lanes-links/$link"
  [[ -f "$dir/up/inbox/pending/inbox.jsonl" ]] || return 0
  node -e '
    const fs = require("fs");
    const path = require("path");
    const [dir, after, csv, asksFile] = process.argv.slice(1);
    const allowed = new Set(String(csv || "").split(",").map((x) => x.trim()).filter(Boolean));
    const clip = (t, n) => { t = t.replace(/[\u0000-\u001f\u007f]+/g, " ").replace(/\s+/g, " ").replace(/\|/g, "/").trim(); return t.length > n ? t.slice(0, n - 1) + "…" : t; };
    const readJson = (f) => { try { return JSON.parse(fs.readFileSync(f, "utf8")); } catch { return {}; } };
    const recorded = asksFile ? (readJson(asksFile).asks || {}) : {};
    const announced = asksFile ? (readJson(asksFile.replace(/\.json$/, "") + "-announced.json").announced || {}) : {};
    const WINDOW_MS = 15 * 60 * 1000;
    const metaOf = (name) => (/^[A-Za-z0-9._-]+$/.test(name) ? readJson(path.join(dir, "children", name, "meta.json")) : {});
    // The ask this blocked report duplicates: same session, not yet relayed,
    // announced (or queued) within WINDOW_MS before the report.
    const openAskOf = (sid, at) => {
      if (!sid) return "";
      const reportMs = Date.parse(at) || Date.now();
      let best = "", bestMs = 0;
      const times = { ...announced };
      for (const [k, v] of Object.entries(recorded)) if (v && v.status === "queued") times[k] = times[k] || v.at;
      for (const [k, t] of Object.entries(times)) {
        if (!k.startsWith(sid + ":")) continue;
        if (recorded[k] && recorded[k].status === "relayed") continue;
        const ms = Date.parse(t);
        if (!(ms <= reportMs + 60000 && reportMs - ms <= WINDOW_MS)) continue;
        if (ms > bestMs) { best = k.slice(sid.length + 1); bestMs = ms; }
      }
      return best;
    };
    const out = []; let hidden = 0; let last = "";
    for (const line of fs.readFileSync(path.join(dir, "up", "inbox", "pending", "inbox.jsonl"), "utf8").split("\n")) {
      let m; try { m = JSON.parse(line); } catch { continue; }
      if (!m || typeof m.text !== "string" || (after && !(m.at > after))) continue;
      last = m.at > last ? m.at : last;
      const head = /^\[from ([^\]·]+?)\s*·\s*([a-z]+)\]\s*\n?/.exec(m.text);
      if (!head) continue; // link notices (joined, left) carry no decision
      const meta = metaOf(head[1]);
      const cos = String(meta.company || "").split(",").map((x) => x.trim()).filter(Boolean);
      if (!allowed.size || !cos.length || !cos.every((c) => allowed.has(c))) { hidden++; continue; }
      const ask = head[2] === "blocked" ? openAskOf(String(meta.session_id || ""), m.at) : "";
      if (ask) { out.push(`${clip(head[1], 40)} (blocked): already an OPEN-ASK, ask_id ${clip(ask, 80)}; queue that ask once`); continue; }
      const body = m.text.slice(head[0].length).split("\n").map((l) => l.trim()).filter(Boolean);
      const pick = head[2] === "blocked" ? (body.find((l) => /\?\s*$/.test(l)) || body.find((l) => l.includes("?")) || body[0] || "") : (body[0] || "");
      out.push(`${clip(head[1], 40)} (${head[2]}): ${clip(pick, 200)}`);
    }
    if (hidden) out.push(`${hidden} report${hidden > 1 ? "s" : ""} from sessions outside this company set or with no company (read them with hq lanes link read)`);
    if (out.length) process.stdout.write(`${last}\t${out.slice(0, 5).join("; ")}${out.length > 5 ? `; +${out.length - 5} more` : ""}`);
  ' "$dir" "$last_report_at" "$companies" "$asks_file" 2>/dev/null || true
}

emit() { # kind detail
  # Only a TICK is a full sweep. A REPORT, MESSAGE, TRIAGE or ANSWER wake in
  # between asks the conductor for that one thing, so sweep evidence is
  # judged tick to tick, never against the last wake of any kind.
  case "$1" in
    TICK) check_sweep; prev_wake="$(date -u +%Y-%m-%dT%H:%M:%SZ)" ;;
  esac
  local cadence=""
  [[ "$fixed_interval" == auto ]] && cadence=" | cadence: $mode ${interval}s"
  printf 'SUPER-CONDUCTOR %s %s | channels: %s%s | %s.\n' \
    "$1" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(current_channels)" "$cadence" "$2"
}

watch_pid=""
asks_pid=""
triage_pid=""
answers_pid=""
child_pid=""
wait_out=""
# Git Bash has no process-tree kill tool, so the watcher subshell stops its
# own node on TERM, and a pending sleep or link wait is the one tracked child.
cleanup() {
  [[ -n "$child_pid" ]] && kill "$child_pid" 2>/dev/null
  [[ -n "$watch_pid" ]] && kill "$watch_pid" 2>/dev/null
  [[ -n "$asks_pid" ]] && kill "$asks_pid" 2>/dev/null
  [[ -n "$triage_pid" ]] && kill "$triage_pid" 2>/dev/null
  [[ -n "$answers_pid" ]] && kill "$answers_pid" 2>/dev/null
  [[ -n "$wait_out" ]] && rm -f "$wait_out"
  rm -f "$sweep_mark"
}
trap cleanup EXIT
trap 'exit 143' TERM INT

# The pid Node can probe, for every background watcher. Under MSYS $$ is not a
# Windows pid; see the header. Computed once and shared, so no watcher can
# get the MSYS pid by mistake and exit on its first tick.
parent_pid=$$
proc_root="${SC_PROC_ROOT:-/proc}"
if [[ -r "$proc_root/$$/winpid" ]]; then
  winpid="$(tr -dc '0-9' <"$proc_root/$$/winpid")"
  [[ -n "$winpid" ]] && parent_pid="$winpid"
fi

if [[ -n "$watch_state" && "$once" -eq 0 ]]; then
  # With a save file the watcher also keeps the request ledger next to it
  # (<link>-requests.jsonl) and records sweep evidence for what it read.
  watch_extra=()
  if [[ -n "$state" ]]; then
    watch_extra=(--ledger "${state%-state.json}-requests.jsonl" --save "$state")
  fi
  # Critical channels and the team list from the owner settings
  # (prefs.mjs critical): "<channels>\t<team>\t<max_delay>". The poll
  # interval is clamped so a critical item is seen within max_delay.
  crit_args=()
  watch_interval="${SC_MESSAGE_WATCH_INTERVAL:-30}"
  if command -v node >/dev/null 2>&1 && [[ -f "$PREFS_JS" ]]; then
    crit_line="$(node "$PREFS_JS" critical 2>/dev/null || true)"
    # cut, not `read`: an empty team field must not shift max_delay left.
    crit_channels="$(printf '%s' "$crit_line" | cut -f1)"
    crit_team="$(printf '%s' "$crit_line" | cut -f2)"
    crit_delay="$(printf '%s' "$crit_line" | cut -f3)"
    if [[ -n "${crit_channels:-}" ]]; then
      crit_args=(--critical "$crit_channels")
      [[ -n "${crit_team:-}" ]] && crit_args+=(--team "$crit_team")
      if [[ "${crit_delay:-}" =~ ^[0-9]+$ ]] && (( watch_interval * 2 > crit_delay )); then
        watch_interval=$(( crit_delay / 2 ))
        (( watch_interval < 5 )) && watch_interval=5
      fi
    fi
  fi
  watch_err="$(mktemp)"
  # The subshell reports a watcher that stops on its own. On the heartbeat's
  # own stop it gets TERM, stops node, and prints nothing.
  (
    node "$WATCH_JS" --state "$watch_state" --company "$companies" \
      ${watch_extra[@]+"${watch_extra[@]}"} \
      ${crit_args[@]+"${crit_args[@]}"} \
      --interval "$watch_interval" \
      --min-wake-gap "${SC_MESSAGE_WATCH_MIN_GAP:-120}" \
      --hint "$resume_hint" --parent-pid "$parent_pid" 2>"$watch_err" &
    node_pid=$!
    trap 'kill "$node_pid" 2>/dev/null; rm -f "$watch_err"; exit 143' TERM INT
    wait "$node_pid"
    rc=$?
    if [[ $rc -ne 143 ]]; then
      printf 'SUPER-CONDUCTOR MESSAGE-WATCH-EXITED %s | the message watcher stopped (exit %s): %s | Messages now wake the conductor only on the timer sweep. Re-arm the heartbeat (Step 2b) to restore the message wake.\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$rc" "$(head -n1 "$watch_err" | cut -c1-300)"
    fi
    rm -f "$watch_err"
  ) &
  watch_pid=$!
fi

if [[ -n "$asks_file" && "$once" -eq 0 ]]; then
  asks_args=(watch --company "$companies" --state "$asks_file" --seen "${asks_file%.json}-announced.json"
    --interval "${SC_ASK_WATCH_INTERVAL:-60}" --parent-pid "$parent_pid")
  for c in ${conductors[@]+"${conductors[@]}"}; do asks_args+=(--conductor "$c"); done
  for x in ${excludes[@]+"${excludes[@]}"}; do asks_args+=(--exclude "$x"); done
  asks_err="$(mktemp)"
  (
    node "$ASKS_JS" "${asks_args[@]}" 2>"$asks_err" &
    node_pid=$!
    trap 'kill "$node_pid" 2>/dev/null; rm -f "$asks_err"; exit 143' TERM INT
    wait "$node_pid"
    rc=$?
    if [[ $rc -ne 143 ]]; then
      printf 'SUPER-CONDUCTOR ASK-WATCH-EXITED %s | the open-ask watcher stopped (exit %s): %s | Waiting sessions are now found only when the wakeup runs open-asks. Re-arm the heartbeat (Step 2b).\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$rc" "$(head -n1 "$asks_err" | cut -c1-300)"
    fi
    rm -f "$asks_err"
  ) &
  asks_pid=$!
fi

# With a save file and a message watch, two more background workers run:
#   - the triage daemon (super-conductor-triage.mjs watch) classifies every new
#     ledger row within $SC_TRIAGE_INTERVAL seconds (default 15): fyi rows are
#     closed, decisions go to the link's decision queue
#     (<link>-decisions.jsonl, asked by the /decision-desk session), work rows
#     are marked for the conductor to route. It prints one TRIAGE line per
#     pass that changed something.
#   - the answer watch (super-conductor-decisions.mjs watch --for conductor)
#     prints one SUPER-CONDUCTOR ANSWER line per decision the owner answered
#     on the desk, so this session relays it at once.
# SC_TRIAGE=0 turns both off.
TRIAGE_JS="$HERE/super-conductor-triage.mjs"
DECISIONS_JS="$HERE/super-conductor-decisions.mjs"
if [[ -n "$watch_state" && -n "$state" && "$once" -eq 0 && "${SC_TRIAGE:-1}" != 0 && -f "$TRIAGE_JS" && -f "$DECISIONS_JS" ]]; then
  ledger_file="${state%-state.json}-requests.jsonl"
  decisions_file="${state%-state.json}-decisions.jsonl"
  triage_err="$(mktemp)"
  (
    node "$TRIAGE_JS" watch --ledger "$ledger_file" --decisions "$decisions_file" --company "$companies" \
      --interval "${SC_TRIAGE_INTERVAL:-15}" --parent-pid "$parent_pid" 2>"$triage_err" &
    node_pid=$!
    trap 'kill "$node_pid" 2>/dev/null; rm -f "$triage_err"; exit 143' TERM INT
    wait "$node_pid"
    rc=$?
    if [[ $rc -ne 143 ]]; then
      printf 'SUPER-CONDUCTOR TRIAGE-EXITED %s | the triage daemon stopped (exit %s): %s | New ledger rows are no longer classified in the background; triage them in the wakeup and re-arm the heartbeat (Step 2b).\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$rc" "$(head -n1 "$triage_err" | cut -c1-300)"
    fi
    rm -f "$triage_err"
  ) &
  triage_pid=$!
  answers_err="$(mktemp)"
  (
    node "$DECISIONS_JS" watch --file "$decisions_file" --for conductor --interval "${SC_ANSWER_WATCH_INTERVAL:-5}" --parent-pid "$parent_pid" 2>"$answers_err" &
    node_pid=$!
    trap 'kill "$node_pid" 2>/dev/null; rm -f "$answers_err"; exit 143' TERM INT
    wait "$node_pid"
    rc=$?
    if [[ $rc -ne 143 ]]; then
      printf 'SUPER-CONDUCTOR ANSWER-WATCH-EXITED %s | the decision answer watch stopped (exit %s): %s | Answered decisions now reach this session only on the timer sweep (decisions.mjs list --status answered); re-arm the heartbeat (Step 2b).\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$rc" "$(head -n1 "$answers_err" | cut -c1-300)"
    fi
    rm -f "$answers_err"
  ) &
  answers_pid=$!
fi

# Every wait runs in the background and is waited on, so a stop signal is
# handled at once instead of after the interval, the link timeout, or the
# backoff (bash defers traps until a foreground child exits).
wait_out="$(mktemp "${TMPDIR:-/tmp}/sc-heartbeat.XXXXXX")"
bg_wait() { # command... ; output in $wait_out, returns its status
  "$@" >"$wait_out" 2>&1 &
  child_pid=$!
  wait "$child_pid"
  local rc=$?
  child_pid=""
  return "$rc"
}

errors=0
timer_next=0
while :; do
  resolve_interval
  if [[ -z "$link" || "$timer_next" -eq 1 ]]; then
    bg_wait sleep "$interval" || true
    timer_next=0
    emit TICK "Sweep due. $resume_hint"
  else
    bg_wait "$HQ_BIN" lanes link wait --link "$link" --timeout "$interval"
    rc=$?
    out="$(cat "$wait_out")"
    case "$rc" in
      0)
        errors=0
        timer_next=1
        summary="$(report_summary)"
        if [[ -n "$summary" ]]; then
          last_report_at="${summary%%$'\t'*}"
          emit REPORT "From ${summary#*$'\t'}. Drain the link, then sweep. $resume_hint"
        else
          emit REPORT "A conducted session reported. Drain the link, then sweep. $resume_hint"
        fi
        ;;
      3)
        errors=0
        emit TICK "Sweep due. $resume_hint"
        ;;
      *)
        if grep -qiE 'link_not_found|link_closed|no such link' <<<"$out"; then
          emit LINK-CLOSED "The conduct link is gone; the heartbeat is stopping. Confirm the conductor is off or reopen the link"
          exit 0
        fi
        errors=$((errors + 1))
        first_line="$(head -n1 <<<"$out")"
        emit WAITER-ERROR "Link wait failed (exit $rc, attempt $errors/$MAX_ERRORS): ${first_line:0:160}. Sweep anyway. $resume_hint"
        if (( errors >= MAX_ERRORS )); then
          emit STOPPED "Heartbeat gave up after $MAX_ERRORS waiter errors. Re-arm it per Step 2b"
          exit 1
        fi
        bg_wait sleep "$ERROR_BACKOFF" || true
        ;;
    esac
  fi
  [[ "$once" -eq 1 ]] && exit 0
done
