#!/usr/bin/env bash
# hq-core: public
# conduct-standing.sh — /conduct routing and standing worker lanes.
#
# Workers stay open: the conductor coordinates and does no project work
# itself. Small bounded tasks go to background subagents; an ongoing area of
# work goes to a standing worker that takes the follow-up tasks in that area.
# Under the default runner (subagent) that worker is a standing Agent subagent
# recorded in runs.json, and this helper creates and messages no runner lane.
# Opening and messaging runner lanes (send) belongs to /conduct-runners, the
# advanced mode. close ends runner lanes this session already opened under
# any runner.
#
# Usage:
#   bash core/scripts/conduct-standing.sh route --kind <answer|status|lookup|small|ongoing> \
#        [--worker <id>] [--company <slug>] [--outlives] [--engine <e>] \
#        [--host claude|codex] [--runner subagent|runner] [--session-id <id>]
#     Prints {route, runner, worker, lane, standing, reason}. route is one of:
#       inline             answer from context already loaded, or one status read
#       subagent           a one-off subagent: no matching worker
#       standing-subagent  (subagent) a standing subagent for the worker; reuse
#                          its runs.json lane with SendMessage or start one
#       child-session      (subagent) work that outlives this session: a conduct
#                          child session, or /conduct-runners for a runner
#       needs-runners      (subagent) an engine other than the host's: offer
#                          /conduct-runners. --host (default claude) names the
#                          session's own engine; a Codex host runs Codex
#                          subagents with spawn_agent in default mode.
#       lane-reuse         (runner) a standing lane for this worker and company is open
#       lane-open          (runner) open a lane; standing:true when a worker matches
#     The runner comes from core/scripts/conduct-runner-resolve.sh, given
#     --runner and the session id; this script does not read the settings.
#
#   bash core/scripts/conduct-standing.sh agent-type --worker <id> [--company <slug>]
#     Prints {worker, subagent_type, worker_yaml, skill_files}. subagent_type is
#     the worker id when a Claude agent definition of that name exists in
#     .claude/agents/ or the user's agents dir; otherwise general-purpose, and
#     the brief names skill_files.
#
#   bash core/scripts/conduct-standing.sh send --worker <id> --company <slug> \
#        --brief-file <path> [--project <p>] [--story <s> | --no-story <reason>] \
#        [--runner <r>] [--session-id <id>] [-- <extra hq runners create flags>]
#     /conduct-runners only. Routes one task to the worker's standing runner
#     lane: `hq runners message --text-file` when the recorded lane is open,
#     otherwise `hq runners create --keep-alive` plus `hq runners keep-alive --on
#     --standing`. Prints {action, lane, worker, company}; action is "reused" or
#     "opened". A create refusal prints the create JSON and exits 3. Under the
#     subagent runner it calls no hq command and exits 4.
#
#   bash core/scripts/conduct-standing.sh list [--session-id <id>]
#   bash core/scripts/conduct-standing.sh find --worker <id> --company <slug> [--session-id <id>]
#   bash core/scripts/conduct-standing.sh forget --lane <id> [--session-id <id>]
#
#   bash core/scripts/conduct-standing.sh close [--dry-run] [--runner <r>] [--session-id <id>]
#     /conduct off, /conduct-runners off, or /handoff: turns keep-alive off and
#     interrupts every standing runner lane recorded for this session
#     (resumable), then clears the record. It runs under any runner, so lanes
#     an earlier /conduct-runners turn or an older core opened still close
#     after the session moves to subagent. It never opens or messages a lane;
#     with no record it calls no hq command. Standing subagents end when the
#     conductor stops resuming them and marks their runs.json rows closed.
#
# State: workspace/sessions/<session-id>/conduct-standing-lanes.json
# Set HQ_BIN to override the hq binary (tests).

set -euo pipefail

ROOT="${HQ_ROOT:-${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}}"
HQ_BIN="${HQ_BIN:-hq}"

usage() { sed -n '3,60p' "$0" | sed 's/^# \{0,1\}//'; }
die() { echo "conduct-standing: $*" >&2; exit 1; }
need_val() { [ $# -ge 2 ] && [ -n "$2" ] || die "$1 needs a value"; }
valid_id() { case "$1" in ''|[!A-Za-z0-9]*|*[!A-Za-z0-9._-]*) return 1 ;; esac; }

SID=""
resolve_sid() {
  [ -n "$SID" ] || SID="${HQ_SESSION_ID:-}"
  [ -n "$SID" ] || SID="$(bash "$ROOT/core/scripts/hq-session.sh" current 2>/dev/null || true)"
  [ -n "$SID" ] || die "no session id: pass --session-id or start an HQ session"
  valid_id "$SID" || die "invalid session id: $SID"
}
state_file() { printf '%s/workspace/sessions/%s/conduct-standing-lanes.json' "$ROOT" "$SID"; }
read_state() {
  local f; f="$(state_file)"
  if [ -f "$f" ] && jq -e '.lanes|type=="array"' "$f" >/dev/null 2>&1; then
    cat "$f"
  else
    printf '{"schema":"conduct-standing-lanes.v1","lanes":[]}'
  fi
}
write_state() {
  local f; f="$(state_file)"
  mkdir -p "$(dirname "$f")"
  cat > "$f.tmp"
  mv "$f.tmp" "$f"
}
find_lane() { read_state | jq -r --arg w "$1" --arg c "$2" \
  '[.lanes[]|select(.worker==$w and .company==$c)][0].lane // empty'; }

# A lane in one of these states cannot take a message; create resumes its
# worker thread instead.
lane_closed() {
  local show state
  show="$("$HQ_BIN" runners show "$1" --json 2>/dev/null)" || return 0
  state="$(printf '%s' "$show" | jq -r '.lane.state // .state // "unknown"' 2>/dev/null)" || return 0
  case "$state" in
    stopped|cancelled|canceled|failed|retired|superseded|unknown|null|"") return 0 ;;
  esac
  return 1
}

# The runner comes from core/scripts/conduct-runner-resolve.sh, the one
# resolver shared with lanes-workers.sh and the Stop gate.
resolve_runner() {
  local r args=(--root "$ROOT")
  [ -z "$1" ] || args+=(--runner "$1")
  [ -z "$SID" ] || args+=(--session-id "$SID")
  r="$(sh "$ROOT/core/scripts/conduct-runner-resolve.sh" "${args[@]}")" || die "could not resolve the conduct runner (subagent or runner)"
  printf '%s' "$r"
}

# Default /conduct (runner subagent) opens and messages no runner lane: that
# belongs to /conduct-runners.
SUBAGENT_NO_LANES="the session runner is subagent: default /conduct keeps standing workers on Agent subagents (runs.json) and opens no runner lane; use /conduct-runners for runner lanes"

cmd_route() {
  local kind="" worker="" company="" outlives=0 engine="" host=claude lane="" runner=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --kind) need_val "$@"; kind="$2"; shift 2 ;;
      --worker) need_val "$@"; worker="$2"; shift 2 ;;
      --company) need_val "$@"; company="$2"; shift 2 ;;
      --engine) need_val "$@"; engine="$2"; shift 2 ;;
      --host) need_val "$@"; host="$2"; shift 2 ;;
      --runner) need_val "$@"; runner="$2"; shift 2 ;;
      --outlives) outlives=1; shift ;;
      --session-id) need_val "$@"; SID="$2"; shift 2 ;;
      *) die "route: unknown option: $1" ;;
    esac
  done
  case "$kind" in answer|status|lookup|small|ongoing) ;; *) die "route: --kind must be answer, status, lookup, small or ongoing" ;; esac
  [ -z "$worker" ] || valid_id "$worker" || die "route: invalid --worker: $worker"
  case "$host" in claude|codex) ;; *) die "route: --host must be claude or codex" ;; esac
  out() { jq -cn --arg r "$1" --arg w "$worker" --arg l "$2" --argjson s "$3" --arg why "$4" --arg run "$runner" \
    '{route:$r, runner:(if $run=="" then null else $run end), worker:(if $w=="" then null else $w end), lane:(if $l=="" then null else $l end), standing:$s, reason:$why}'; }
  case "$kind" in
    answer) out inline "" false "answer from context already loaded"; return ;;
    status) out inline "" false "one status read"; return ;;
  esac
  resolve_sid
  runner="$(resolve_runner "$runner")"
  [ -z "$worker" ] || [ -n "$company" ] || die "route: --company is required with --worker"
  if [ "$runner" = subagent ]; then
    if [ -n "$engine" ] && [ "$engine" != "$host" ]; then
      out needs-runners "" false "an engine other than the host's ($host) needs a runner: offer /conduct-runners; default /conduct opens no runner lane"; return
    fi
    if [ "$outlives" = 1 ]; then
      out child-session "" false "work outlives this session: use a conduct child session, or /conduct-runners for a runner; default /conduct opens no runner lane"; return
    fi
    if [ -n "$worker" ]; then
      out standing-subagent "" true "standing subagent for the $worker worker in $company: resume its runs.json lane with SendMessage, or start one"; return
    fi
    out subagent "" false "small bounded task with no matching worker: one-off subagent"; return
  fi
  if [ -n "$worker" ]; then
    lane="$(find_lane "$worker" "$company")"
    if [ -n "$lane" ]; then out lane-reuse "$lane" true "standing $worker lane is open"; return; fi
    out lane-open "" true "task matches the $worker worker"; return
  fi
  if [ "$outlives" = 1 ] || { [ -n "$engine" ] && [ "$engine" != claude ]; }; then
    out lane-open "" false "work outlives the session or runs on a non-Claude engine"; return
  fi
  out subagent "" false "small bounded task with no standing lane"
}

registry_path() {
  local worker="$1" company="$2" reg p
  for reg in ${company:+"$ROOT/companies/$company/workers/registry.yaml"} "$ROOT/core/workers/registry.yaml"; do
    [ -f "$reg" ] || continue
    p="$(awk -v id="$worker" '
      /^  - id:/ { gsub(/["'\'']/, "", $3); cur=$3; next }
      cur==id && /^    path:/ { v=$2; gsub(/["'\'']/, "", v); print v; exit }' "$reg")"
    [ -n "$p" ] && { printf '%s' "${p%/}"; return 0; }
  done
  return 0
}

cmd_agent_type() {
  local worker="" company="" type=general-purpose dir path yaml="" skills="[]"
  while [ $# -gt 0 ]; do
    case "$1" in
      --worker) need_val "$@"; worker="$2"; shift 2 ;;
      --company) need_val "$@"; company="$2"; shift 2 ;;
      *) die "agent-type: unknown option: $1" ;;
    esac
  done
  valid_id "$worker" || die "agent-type: invalid --worker: $worker"
  [ -z "$company" ] || valid_id "$company" || die "agent-type: invalid --company: $company"
  for dir in "$ROOT/.claude/agents" "${HQ_CLAUDE_AGENTS_DIR:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/agents}"; do
    if [ -f "$dir/$worker.md" ]; then type="$worker"; break; fi
  done
  path="$(registry_path "$worker" "$company")"
  if [ -n "$path" ] && [ -f "$ROOT/$path/worker.yaml" ]; then
    yaml="$path/worker.yaml"
    skills="$(awk -v base="$path" '
        /^skills:/ { on=1; next }
        on && /^[^ #]/ { on=0 }
        on && /^ +file:/ { f=$2; gsub(/["'\'']/, "", f); print base "/" f }' "$ROOT/$yaml" \
      | jq -R . | jq -cs .)"
    if [ "$skills" = "[]" ] && [ -d "$ROOT/$path/skills" ]; then
      skills="$(cd "$ROOT" && find "$path/skills" -maxdepth 1 -name '*.md' | sort | jq -R . | jq -cs .)"
    fi
  fi
  jq -cn --arg w "$worker" --arg t "$type" --arg y "$yaml" --argjson s "$skills" \
    '{worker:$w, subagent_type:$t, worker_yaml:(if $y=="" then null else $y end), skill_files:$s}'
}

cmd_send() {
  local worker="" company="" brief="" project="" story="" nostory="" lane resp runner=""
  local -a extra=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --worker) need_val "$@"; worker="$2"; shift 2 ;;
      --company) need_val "$@"; company="$2"; shift 2 ;;
      --brief-file) need_val "$@"; brief="$2"; shift 2 ;;
      --project) need_val "$@"; project="$2"; shift 2 ;;
      --story) need_val "$@"; story="$2"; shift 2 ;;
      --no-story) need_val "$@"; nostory="$2"; shift 2 ;;
      --runner) need_val "$@"; runner="$2"; shift 2 ;;
      --session-id) need_val "$@"; SID="$2"; shift 2 ;;
      --) shift; extra=("$@"); break ;;
      *) die "send: unknown option: $1" ;;
    esac
  done
  valid_id "$worker" || die "send: invalid --worker: $worker"
  # hq-background-jobs-require-bound-company: every lane names its company.
  valid_id "$company" || die "send: --company is required (a lane must be bound to its company)"
  [ -f "$brief" ] || die "send: --brief-file not found: $brief"
  [ -z "$story" ] || [ -z "$nostory" ] || die "send: --story and --no-story are exclusive"
  [ -n "$story" ] || [ -n "$nostory" ] || nostory="conduct standing $worker lane"
  resolve_sid
  runner="$(resolve_runner "$runner")"
  if [ "$runner" = subagent ]; then
    echo "conduct-standing: send refused: $SUBAGENT_NO_LANES" >&2
    return 4
  fi

  lane="$(find_lane "$worker" "$company")"
  if [ -n "$lane" ] && ! lane_closed "$lane"; then
    local -a mflags=()
    [ -z "$project" ] || mflags+=(--project "$project")
    [ -z "$story" ] || mflags+=(--story "$story")
    "$HQ_BIN" runners message "$lane" --text-file "$brief" ${mflags[@]+"${mflags[@]}"} --json >/dev/null \
      || die "send: hq runners message $lane failed"
    jq -cn --arg l "$lane" --arg w "$worker" --arg c "$company" '{action:"reused", lane:$l, worker:$w, company:$c}'
    return
  fi
  [ -z "$lane" ] || read_state | jq --arg l "$lane" '.lanes |= map(select(.lane != $l))' | write_state

  local -a cflags=(--company "$company" --worker "$worker" --brief-file "$brief"
                   --senior "session:$SID" --keep-alive --json)
  [ -z "$project" ] || cflags+=(--project "$project")
  if [ -n "$story" ]; then cflags+=(--story "$story"); else cflags+=(--no-story "$nostory"); fi
  resp="$("$HQ_BIN" runners create "${cflags[@]}" ${extra[@]+"${extra[@]}"})" || true
  lane="$(printf '%s' "$resp" | jq -r 'select(.ok != false) | .lane_id // .lane.id // empty' 2>/dev/null || true)"
  if [ -z "$lane" ]; then
    [ -n "$resp" ] || resp='{"ok":false,"error":"no response from hq runners create"}'
    printf '%s\n' "$resp"
    return 3
  fi
  "$HQ_BIN" runners keep-alive "$lane" --on --standing --json >/dev/null \
    || echo "conduct-standing: keep-alive --standing failed for $lane; the lane is open but will not wait for follow-up work" >&2
  read_state | jq --arg w "$worker" --arg c "$company" --arg l "$lane" --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '.lanes = ([.lanes[]|select(.worker != $w or .company != $c)] + [{worker:$w, company:$c, lane:$l, opened_at:$now}])' \
    | write_state
  jq -cn --arg l "$lane" --arg w "$worker" --arg c "$company" '{action:"opened", lane:$l, worker:$w, company:$c}'
}

cmd_list() {
  while [ $# -gt 0 ]; do
    case "$1" in --session-id) need_val "$@"; SID="$2"; shift 2 ;; *) die "list: unknown option: $1" ;; esac
  done
  resolve_sid
  read_state | jq -c '.lanes'
}

cmd_find() {
  local worker="" company=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --worker) need_val "$@"; worker="$2"; shift 2 ;;
      --company) need_val "$@"; company="$2"; shift 2 ;;
      --session-id) need_val "$@"; SID="$2"; shift 2 ;;
      *) die "find: unknown option: $1" ;;
    esac
  done
  [ -n "$worker" ] && [ -n "$company" ] || die "find: --worker and --company are required"
  resolve_sid
  local lane; lane="$(find_lane "$worker" "$company")"
  [ -n "$lane" ] || return 1
  echo "$lane"
}

cmd_forget() {
  local lane=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --lane) need_val "$@"; lane="$2"; shift 2 ;;
      --session-id) need_val "$@"; SID="$2"; shift 2 ;;
      *) die "forget: unknown option: $1" ;;
    esac
  done
  resolve_sid
  read_state | jq --arg l "$lane" '.lanes |= map(select(.lane != $l))' | write_state
}

cmd_close() {
  local dry=0 lane failed=0 runner="" n
  while [ $# -gt 0 ]; do
    case "$1" in
      --dry-run) dry=1; shift ;;
      --runner) need_val "$@"; runner="$2"; shift 2 ;;
      --session-id) need_val "$@"; SID="$2"; shift 2 ;;
      *) die "close: unknown option: $1" ;;
    esac
  done
  resolve_sid
  runner="$(resolve_runner "$runner")"
  n="$(read_state | jq '.lanes|length')"
  if [ "$runner" = subagent ]; then
    if [ "$n" = 0 ]; then
      echo "no runner lanes closed: $SUBAGENT_NO_LANES. Standing subagents end when you stop resuming them and mark their runs.json rows closed."
      return 0
    fi
    # Cleanup, not dispatch: these lanes were opened by an earlier
    # /conduct-runners turn or an older core, and still name this session as
    # their senior. Close them; never open or message one.
    echo "closing $n runner lane(s) this session opened before it moved to the subagent runner."
  fi
  for lane in $(read_state | jq -r '.lanes[].lane'); do
    if [ "$dry" = 1 ]; then
      echo "would close $lane: hq runners keep-alive $lane --off; hq runners interrupt $lane"
      continue
    fi
    "$HQ_BIN" runners keep-alive "$lane" --off --json >/dev/null 2>&1 || { echo "conduct-standing: keep-alive --off failed for $lane" >&2; failed=1; continue; }
    if ! lane_closed "$lane"; then
      "$HQ_BIN" runners interrupt "$lane" --reason "conduct closed its standing lanes" --json >/dev/null 2>&1 || true
    fi
    read_state | jq --arg l "$lane" '.lanes |= map(select(.lane != $l))' | write_state
    echo "closed $lane"
  done
  return "$failed"
}

sub="${1:-}"
[ $# -gt 0 ] && shift
case "$sub" in
  route) cmd_route "$@" ;;
  agent-type) cmd_agent_type "$@" ;;
  send) cmd_send "$@" ;;
  list) cmd_list "$@" ;;
  find) cmd_find "$@" ;;
  forget) cmd_forget "$@" ;;
  close) cmd_close "$@" ;;
  ""|-h|--help|help) usage ;;
  *) echo "conduct-standing: unknown subcommand: $sub" >&2; usage >&2; exit 1 ;;
esac
