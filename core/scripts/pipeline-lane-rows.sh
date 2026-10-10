#!/bin/sh
# hq-core: public
# pipeline-lane-rows.sh - the rows behind /run-project --pipeline Step 3P.6
# ("Relay, do not drive"): one JSON array with an item per loop lane in the
# mapped loop lanes plus one item for the driver. The parent renders them at the end
# of every turn in which a pipeline lane is live; it never reads a transcript.
#
# Usage (from the HQ root):
#   sh core/scripts/pipeline-lane-rows.sh --state <pipeline state dir> [--session-id <id>]
#
# A loop lane is loaded from hq lanes list --json and the run's lanes.json. Lane item fields:
#   kind             "lane"
#   worker           the slot's worker id
#   subagent_id      the slot's subagent id
#   status           the loop state (running, waiting, stopped, ...)
#   pid_alive        true when the loop controller reports a pid
#   story            the in_flight story whose current phase runs on this worker, or null
#   phase            that phase's name, or null
#   phase_label      "<story> · <worker> · <short verb>" (designing, building,
#                    testing, reviewing, ...), or null with no story in flight
#   phase_index      1-based index of the current phase, or null
#   phase_count      number of phases of the story, or null
#   phase_elapsed_s  seconds since the phase was routed (routed_at), or null
#   quiet_s          null (not reported by hq lanes)
#   inbox_pending    hq lanes inbox count when available
#   last_line        latest lane status line from hq lanes, or null
#   exit             null (not reported by hq lanes)
#   pr               latest pull-request URL from hq lanes, or null
#   story_title      the story's title, or null
#   run_dir          null (loop lane internals are not read)
# Driver item fields:
#   kind "driver", pid_alive, exit ("<code> <reason>" from driver/exit, or null),
#   verified, in_flight, queued, blocked, parked, skipped, interrupted,
#   awaiting_go (story counts; parked counts parked and parked_dependency,
#   blocked counts blocked_needs_owner, skipped reads skips.json),
#   last_line (the last driver.log line, or null)
#
# Env: PC_HQ (default: hq); HQ_SESSION_ID when --session-id is not given.
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
PC_HQ="${PC_HQ:-hq}"
[ -n "$SID" ] || SID="${HQ_SESSION_ID:-}"
[ -n "$SID" ] || SID="$(bash "$HERE/hq-session.sh" current 2>/dev/null || true)"
NOW="$(date +%s)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/plr.XXXXXX")" || exit 1
trap 'rm -rf "$TMP"' EXIT

clip() { tr -s '[:space:]' ' ' | sed 's/^ //; s/ $//' | cut -c1-160; }
alive() { [ -n "$1" ] && [ "$1" != null ] && kill -0 "$1" 2>/dev/null; }

# every story as one array
if ls "$STATE/stories/"*.json >/dev/null 2>&1; then
  jq -s '[.[] | select(type == "object" and .id != null)]' "$STATE/stories/"*.json >"$TMP/stories.json" 2>/dev/null \
    || echo '[]' >"$TMP/stories.json"
else
  echo '[]' >"$TMP/stories.json"
fi

"$PC_HQ" lanes list --json >"$TMP/lanes.json" 2>/dev/null || echo '[]' >"$TMP/lanes.json"
jq -e 'type == "array"' "$TMP/lanes.json" >/dev/null 2>&1 || echo '[]' >"$TMP/lanes.json"
[ -f "$STATE/lanes.json" ] || echo '{}' >"$STATE/lanes.json"
jq -n --argjson now "$NOW" --slurpfile S "$TMP/stories.json" --slurpfile L "$TMP/lanes.json" --slurpfile M "$STATE/lanes.json" '
  def verb: {architect:"designing",backend:"building",frontend:"building",database:"migrating",fullstack:"building",motion:"animating",content:"writing",docs:"writing",qa:"testing",test:"testing",review:"reviewing","code-review":"reviewing",security:"auditing"}[.] // .;
  $M[0] | to_entries[] as $map | ($L[0] | map(select(.lane_id == $map.value)) | first) as $lane |
    select($lane != null) | ($lane.loop // {}) as $loop |
    ([$S[0][] | select(.state == "in_flight" and ((.phases // [])[.current // 0].worker == $map.key))] | first) as $s |
    (($s.phases // [])[($s.current // 0)].phase // null) as $ph |
    {kind:"lane",worker:$map.key,subagent_id:$map.value,status:($loop.state // "unknown"),pid_alive:(($loop.pid // 0) > 0),
     story:($s.id // null),phase:$ph,phase_label:(if $s then "\($s.id) · \($map.key) · \($ph|verb)" else null end),
     phase_index:(if $s then ($s.current + 1) else null end),phase_count:(if $s then ($s.phases|length) else null end),
     phase_elapsed_s:(if ($s.routed_at|type)=="number" then ([0,$now-$s.routed_at]|max|floor) else $lane.elapsed_s // null end),
     quiet_s:null,inbox_pending:($lane.inbox_pending // 0),last_line:($lane.last_line // null),exit:null,pr:($lane.pr // null),
     story_title:($s.title // null),run_dir:null}' >"$TMP/items"

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
