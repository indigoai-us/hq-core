#!/bin/sh
# hq-core: public
# pipeline-lane-rows.sh - the rows behind /run-project --pipeline Step 3P.6
# ("Relay, do not drive"): one JSON array with an item per loop lane in the
# session pool plus one item for the driver. The parent renders them at the end
# of every turn in which a pipeline lane is live; it never reads a transcript.
#
# Usage (from the HQ root):
#   sh core/scripts/pipeline-lane-rows.sh --state <pipeline state dir> [--session-id <id>]
#
# A loop lane is a pool slot whose run_dir has loop.json. Lane item fields:
#   kind             "lane"
#   worker           the slot's worker id
#   subagent_id      the slot's subagent id
#   status           the slot's pool status (running, waiting, idle, ...)
#   pid_alive        true when the slot's pid answers kill -0
#   story            the in_flight story whose current phase runs on this worker, or null
#   phase            that phase's name, or null
#   phase_label      "<story> · <worker> · <short verb>" (designing, building,
#                    testing, reviewing, ...), or null with no story in flight
#   phase_index      1-based index of the current phase, or null
#   phase_count      number of phases of the story, or null
#   phase_elapsed_s  seconds since the phase was routed (routed_at), or null
#   quiet_s          seconds since the newest agent-N.log last changed, or null
#   inbox_pending    envelopes waiting in run_dir/inbox/pending
#   last_line        newest non-blank agent-N.log line, whitespace squeezed, at most 160 chars, or null
#   exit             the value of the last CONDUCT_EXIT= line in lane.log, or null
#   pr               the last pull-request URL named in the newest handoff this worker wrote, or null
#   story_title      the story's title, or null
#   run_dir          the lane's run dir
# Driver item fields:
#   kind "driver", pid_alive, exit ("<code> <reason>" from driver/exit, or null),
#   verified, in_flight, queued, blocked, parked, skipped, interrupted,
#   awaiting_go (story counts; parked counts parked and parked_dependency,
#   blocked counts blocked_needs_owner, skipped reads skips.json),
#   last_line (the last driver.log line, or null)
#
# Env: PIPELINE_LANE_ROWS_POOL (default: $PC_POOL, else conduct-pool.sh next to
#   this script); HQ_SESSION_ID when --session-id is not given.
#
# POSIX sh plus jq (dash-clean, no bash arrays).

set -u

usage() { sed -n '3,/^# POSIX sh/p' "$0" >&2; exit 2; }

STATE=""; SID=""
while [ $# -gt 0 ]; do
  case "$1" in
    --state) [ $# -ge 2 ] || usage; STATE="$2"; shift 2 ;;
    --session-id) [ $# -ge 2 ] || usage; SID="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) echo "pipeline-lane-rows: unknown argument: $1" >&2; exit 2 ;;
  esac
done
[ -n "$STATE" ] || usage
[ -d "$STATE" ] || { echo "pipeline-lane-rows: no such state dir: $STATE" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "pipeline-lane-rows: jq required" >&2; exit 2; }

HERE="$(cd "$(dirname "$0")" && pwd)"
POOL="${PIPELINE_LANE_ROWS_POOL:-${PC_POOL:-$HERE/conduct-pool.sh}}"
[ -n "$SID" ] || SID="${HQ_SESSION_ID:-}"
[ -n "$SID" ] || SID="$(bash "$HERE/hq-session.sh" current 2>/dev/null || true)"
NOW="$(date +%s)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/plr.XXXXXX")" || exit 1
trap 'rm -rf "$TMP"' EXIT

mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null; }
alive() { [ -n "$1" ] && [ "$1" != null ] && kill -0 "$1" 2>/dev/null; }
clip() { tr -s '[:space:]' ' ' | sed 's/^ //; s/ $//' | cut -c1-160; }

# every story as one array
if ls "$STATE/stories/"*.json >/dev/null 2>&1; then
  jq -s '[.[] | select(type == "object" and .id != null)]' "$STATE/stories/"*.json >"$TMP/stories.json" 2>/dev/null \
    || echo '[]' >"$TMP/stories.json"
else
  echo '[]' >"$TMP/stories.json"
fi

if [ -n "$SID" ]; then
  "$POOL" --session-id "$SID" list >"$TMP/pool.json" 2>/dev/null || echo '[]' >"$TMP/pool.json"
else
  echo '[]' >"$TMP/pool.json"
fi
jq -e 'type == "array"' "$TMP/pool.json" >/dev/null 2>&1 || echo '[]' >"$TMP/pool.json"

: >"$TMP/items"
jq -r '.[] | [.worker_id, (.subagent_id // ""), (.status // ""), ((.pid // "") | tostring), (.run_dir // "")] | @tsv' \
  "$TMP/pool.json" >"$TMP/slots"
TAB="$(printf '\t')"
while IFS="$TAB" read -r w sub st pid rd; do
  [ -n "$rd" ] && [ -f "$rd/loop.json" ] || continue
  pa=false; alive "$pid" && pa=true
  pend=0
  [ -d "$rd/inbox/pending" ] && pend="$(find "$rd/inbox/pending" -type f ! -name '.*' | wc -l | tr -d ' ')"
  n="$(ls "$rd" 2>/dev/null | sed -n 's/^agent-\([0-9][0-9]*\)\.log$/\1/p' | sort -n | tail -1)"
  last=""; quiet=null
  if [ -n "$n" ]; then
    lg="$rd/agent-$n.log"
    last="$(grep -v '^[[:space:]]*$' "$lg" 2>/dev/null | tail -1 | clip)"
    m="$(mtime "$lg")"; [ -n "$m" ] && quiet=$((NOW - m)); [ "$quiet" != null ] && [ "$quiet" -lt 0 ] && quiet=0
  fi
  ex="$(grep 'CONDUCT_EXIT=' "$rd/lane.log" 2>/dev/null | tail -1 | sed 's/.*CONDUCT_EXIT=//' | clip)"
  # the newest handoff this worker wrote, for its PR
  pr=""
  hf="$(ls -t "$STATE/handoffs/"*.json 2>/dev/null | while IFS= read -r f; do
          jq -e --arg w "$w" '.worker_id == $w' "$f" >/dev/null 2>&1 && { printf '%s\n' "$f"; break; }
        done)"
  [ -n "$hf" ] && pr="$(grep -o 'https://github\.com/[^"[:space:]]*/pull/[0-9][0-9]*' "$hf" | tail -1)"
  jq -n --arg w "$w" --arg sub "$sub" --arg st "$st" --argjson pa "$pa" --argjson pend "$pend" \
    --arg last "$last" --argjson quiet "$quiet" --arg ex "$ex" --arg pr "$pr" --arg rd "$rd" \
    --argjson now "$NOW" --slurpfile S "$TMP/stories.json" '
    def verb: {architect: "designing", backend: "building", frontend: "building", database: "migrating",
               fullstack: "building", motion: "animating", content: "writing", docs: "writing",
               qa: "testing", test: "testing", review: "reviewing", "code-review": "reviewing",
               security: "auditing"}[.] // .;
    ([$S[0][] | select(.state == "in_flight" and ((.phases // [])[.current // 0].worker == $w))] | first) as $s
    | (if $s then ($s.phases[$s.current].phase // null) else null end) as $ph
    | {kind: "lane", worker: $w, subagent_id: $sub, status: $st, pid_alive: $pa,
       story: ($s.id // null), phase: $ph,
       phase_label: (if $s then "\($s.id) · \($w) · \($ph | verb)" else null end),
       phase_index: (if $s then ($s.current + 1) else null end),
       phase_count: (if $s then ($s.phases | length) else null end),
       phase_elapsed_s: (if ($s.routed_at | type) == "number" then ([0, $now - $s.routed_at] | max | floor) else null end),
       quiet_s: $quiet, inbox_pending: $pend,
       last_line: (if $last == "" then null else $last end),
       exit: (if $ex == "" then null else $ex end),
       pr: (if $pr == "" then null else $pr end),
       story_title: ($s.title // null), run_dir: $rd}' >>"$TMP/items"
done <"$TMP/slots"

dpid="$(cat "$STATE/driver/driver.pid" 2>/dev/null)"
dpa=false; alive "$dpid" && dpa=true
dex="$(cat "$STATE/driver/exit" 2>/dev/null | head -1 | clip)"
dlast="$(tail -1 "$STATE/driver/driver.log" 2>/dev/null | clip)"
skipped=0
[ -f "$STATE/skips.json" ] && skipped="$(jq 'if type == "object" then length else 0 end' "$STATE/skips.json" 2>/dev/null || echo 0)"
jq -n --argjson pa "$dpa" --arg ex "$dex" --arg last "$dlast" --argjson sk "$skipped" --slurpfile S "$TMP/stories.json" '
  def n(f): [$S[0][] | select(f)] | length;
  {kind: "driver", pid_alive: $pa, exit: (if $ex == "" then null else $ex end),
   verified: n(.state == "verified"), in_flight: n(.state == "in_flight"), queued: n(.state == "queued"),
   blocked: n(.state == "blocked_needs_owner"), parked: n(.state == "parked" or .state == "parked_dependency"),
   skipped: $sk, interrupted: n(.state == "interrupted"), awaiting_go: n(.state == "awaiting_go"),
   last_line: (if $last == "" then null else $last end)}' >>"$TMP/items"

jq -s '.' "$TMP/items"
