#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# run-project-state.sh — write workspace/orchestrator/{project}/state.json for
# the host-native /run-project paths (story lanes, Agent-tool or spawn_agent
# fallback, interactive, ralph).
#
# .claude/scripts/run-project.sh keeps state.json current on its own. The
# host-native paths are driven by the parent session, which used to write the
# file by hand in whatever shape it chose: no prd_path, no progress block, and
# no update after each story. The run-project progress band reads the standard
# shape (schema: core/settings/orchestrator.yaml), so those runs showed 0/0.
# This helper writes the same shape the script path writes, and every command
# recomputes the progress block from prd.json.
#
# Usage:
#   run-project-state.sh init     <project> --company <co> [--prd <rel>] [--session-id <id>]
#                                 [--provider <p>] [--model <m>] [--effort <e>] [--orchestrator <name>]
#   run-project-state.sh start    <project> <story-id>
#   run-project-state.sh complete <project> <story-id> [--commit <sha>]
#   run-project-state.sh fail     <project> <story-id> --error <text> [--blocked]
#   run-project-state.sh finish   <project>
#   run-project-state.sh sync     <project>
#
# Call `complete` only after the story is verified and `passes: true` is
# written. `complete` marks the run completed once every story passes.
# HQ_ROOT may be set to point at another HQ checkout (tests do this).
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HQ_ROOT="${HQ_ROOT:-$(cd "${SCRIPT_DIR}/../.." && pwd)}"

die() { echo "run-project-state: $*" >&2; exit 1; }
ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }

command -v jq >/dev/null 2>&1 || die "jq is required"

CMD="${1:-}"
PROJECT="${2:-}"
[[ -n "$CMD" && -n "$PROJECT" ]] || die "usage: run-project-state.sh <init|start|complete|fail|finish|sync> <project> ..."
[[ "$PROJECT" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "invalid project name: $PROJECT"
shift 2

STATE_DIR="$HQ_ROOT/workspace/orchestrator/$PROJECT"
STATE_FILE="$STATE_DIR/state.json"
PROGRESS_FILE="$STATE_DIR/progress.txt"
LOCK_FILE="$STATE_DIR/.state.lock"

# One writer at a time: every command reads, changes and rewrites state.json,
# and parallel story lanes call it concurrently. The lock is a kernel flock(2)
# on fd 9, held until this process exits; the kernel drops it when the holder
# dies, so there is no stale-lock takeover to race. macOS ships no flock(1),
# so perl takes the lock on the shared fd there (the lock belongs to the open
# file description, which this shell keeps open after perl exits).
acquire_lock() {
  mkdir -p "$STATE_DIR"
  exec 9>>"$LOCK_FILE"
  if command -v flock >/dev/null 2>&1; then
    flock -w 30 9 || die "timed out waiting for $LOCK_FILE"
  else
    command -v perl >/dev/null 2>&1 || die "flock or perl is required"
    perl -MFcntl=:flock -e 'open(my $f, ">&=", 9) or die "fd 9: $!\n";
      $SIG{ALRM} = sub { exit 3 }; alarm 30; flock($f, LOCK_EX) or die "flock: $!\n";' \
      || die "timed out waiting for $LOCK_FILE"
  fi
}

# Atomic write: jq filter over state.json with the PRD slurped as $prd.
write_state() {
  local prd_rel="$1"; shift
  local tmp="$STATE_FILE.tmp.$$"
  jq --slurpfile prd "$HQ_ROOT/$prd_rel" "$@" "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
}

# Progress block recomputed from the PRD: a story counts as completed when
# prd.json says passes:true or completed_tasks lists it.
# shellcheck disable=SC2016  # jq program; $prd and $s are jq variables
REFRESH='
  ($prd[0].userStories // []) as $s
  | (.completed_tasks // []) as $ct
  | ([$s[] | select(.passes == true) | .id] + [$ct[].id] | unique) as $done
  | .failed_tasks = (.failed_tasks // [])
  | .current_tasks = (.current_tasks // [])
  | .completed_tasks = $ct
  | .retry_queue = (.retry_queue // [])
  | .regression_gates = (.regression_gates // [])
  | .progress = {
      total: ($s | length),
      completed: ([$s[] | select(.id as $i | $done | index($i))] | length),
      failed: (.failed_tasks | length),
      in_progress: (.current_tasks | length)
    }
'

require_state() {
  acquire_lock
  [[ -f "$STATE_FILE" ]] || die "no state.json for $PROJECT; run: run-project-state.sh init $PROJECT --company <co>"
  PRD_REL="$(jq -r '.prd_path // empty' "$STATE_FILE")"
  [[ -n "$PRD_REL" && -f "$HQ_ROOT/$PRD_REL" ]] || die "state.json prd_path is missing or unreadable: ${PRD_REL:-<unset>}"
}

title_of() {
  jq -r --arg id "$1" '(.userStories // [])[] | select(.id == $id) | .title // ""' "$HQ_ROOT/$PRD_REL"
}

log_progress() {
  echo "[$(ts)] $*" >> "$PROGRESS_FILE"
}

print_progress() {
  jq -c '.progress' "$STATE_FILE"
}

case "$CMD" in
  init)
    COMPANY="" PRD_REL="" SESSION_ID="" PROVIDER="" MODEL="" EFFORT="" ORCH="host-native-agent"
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --company) COMPANY="${2:-}"; shift 2 ;;
        --prd) PRD_REL="${2:-}"; shift 2 ;;
        --session-id) SESSION_ID="${2:-}"; shift 2 ;;
        --provider) PROVIDER="${2:-}"; shift 2 ;;
        --model) MODEL="${2:-}"; shift 2 ;;
        --effort) EFFORT="${2:-}"; shift 2 ;;
        --orchestrator) ORCH="${2:-}"; shift 2 ;;
        *) die "init: unknown argument $1" ;;
      esac
    done
    [[ -n "$COMPANY" ]] || die "init: --company is required (never inferred from cwd)"
    [[ -n "$PRD_REL" ]] || PRD_REL="companies/$COMPANY/projects/$PROJECT/prd.json"
    [[ "$PRD_REL" != /* && "/$PRD_REL/" != */../* ]] || die "init: --prd must be a path inside the HQ root"
    [[ -f "$HQ_ROOT/$PRD_REL" ]] || die "init: PRD not found: $PRD_REL"
    acquire_lock
    NOW="$(ts)"
    if [[ -f "$STATE_FILE" ]] && jq -e 'type == "object"' "$STATE_FILE" >/dev/null 2>&1; then
      RESUME=true
      PREV_COMPANY="$(jq -r '.company // empty' "$STATE_FILE")"
      [[ -z "$PREV_COMPANY" || "$PREV_COMPANY" == "$COMPANY" ]] \
        || die "init: state.json belongs to company '$PREV_COMPANY', not '$COMPANY'; refusing to switch it"
    else
      RESUME=false
      echo '{}' > "$STATE_FILE"
    fi
    # Resume keeps started_at, session_id and recorded tasks; a fresh or
    # earlier completed run is set back to in_progress for the band. Running
    # entries from the earlier session are dropped: the resuming session
    # re-records each story whose lane is still live with `start`.
    write_state "$PRD_REL" \
      --arg project "$PROJECT" --arg company "$COMPANY" --arg prd_path "$PRD_REL" \
      --arg session "$SESSION_ID" --arg provider "$PROVIDER" --arg model "$MODEL" \
      --arg effort "$EFFORT" --arg orch "$ORCH" --arg ts "$NOW" "
      .project = \$project
      | .company = \$company
      | .prd_path = \$prd_path
      | .status = \"in_progress\"
      | .started_at = (.started_at // \$ts)
      | .updated_at = \$ts
      | .orchestrator = \$orch
      | .current_tasks = []
      | (if \$session != \"\" then .session_id = (.session_id // \$session) else . end)
      | (if \$provider != \"\" then .provider = \$provider else . end)
      | (if \$model != \"\" then .model = \$model else . end)
      | (if \$effort != \"\" then .effort = \$effort else . end)
      | $REFRESH"
    TOTAL="$(jq -r '.progress.total' "$STATE_FILE")"
    DONE="$(jq -r '.progress.completed' "$STATE_FILE")"
    if [[ "$RESUME" == true ]]; then
      log_progress "Project resumed: $PROJECT ($TOTAL stories, $DONE already completed)"
    else
      log_progress "Project started: $PROJECT ($TOTAL stories, $DONE already completed)"
    fi
    print_progress
    ;;

  start)
    STORY="${1:-}"; [[ -n "$STORY" ]] || die "start: story id required"
    require_state
    TITLE="$(title_of "$STORY")"
    write_state "$PRD_REL" --arg id "$STORY" --arg title "$TITLE" --arg ts "$(ts)" "
      .current_tasks = ([(.current_tasks // [])[] | select(.id != \$id)]
                        + [{id: \$id, title: \$title, status: \"in_progress\", started_at: \$ts}])
      | .failed_tasks = [(.failed_tasks // [])[] | select(.id != \$id)]
      | .retry_queue = [(.retry_queue // [])[] | select(. != \$id)]
      | .status = \"in_progress\"
      | .updated_at = \$ts
      | $REFRESH"
    log_progress "Started $STORY: $TITLE"
    print_progress
    ;;

  complete)
    STORY="${1:-}"; [[ -n "$STORY" ]] || die "complete: story id required"
    shift
    SHA=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --commit) SHA="${2:-}"; shift 2 ;;
        *) die "complete: unknown argument $1" ;;
      esac
    done
    require_state
    TITLE="$(title_of "$STORY")"
    write_state "$PRD_REL" --arg id "$STORY" --arg title "$TITLE" --arg sha "$SHA" --arg ts "$(ts)" "
      .completed_tasks = ([(.completed_tasks // [])[] | select(.id != \$id)]
                          + [{id: \$id, title: \$title, status: \"completed\", completed_at: \$ts}
                             + (if \$sha != \"\" then {commit_sha: \$sha} else {} end)])
      | .current_tasks = [(.current_tasks // [])[] | select(.id != \$id)]
      | .failed_tasks = [(.failed_tasks // [])[] | select(.id != \$id)]
      | .retry_queue = [(.retry_queue // [])[] | select(. != \$id)]
      | .updated_at = \$ts
      | $REFRESH
      | (if .progress.total > 0 and .progress.completed == .progress.total and (.current_tasks | length) == 0
         then .status = \"completed\" | .completed_at = \$ts else . end)"
    log_progress "Completed $STORY: $TITLE${SHA:+ ($SHA)}"
    print_progress
    ;;

  fail)
    STORY="${1:-}"; [[ -n "$STORY" ]] || die "fail: story id required"
    shift
    ERROR="" BLOCKED=false
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --error) ERROR="${2:-}"; shift 2 ;;
        --blocked) BLOCKED=true; shift ;;
        *) die "fail: unknown argument $1" ;;
      esac
    done
    [[ -n "$ERROR" ]] || die "fail: --error is required"
    require_state
    write_state "$PRD_REL" --arg id "$STORY" --arg err "$ERROR" --argjson blocked "$BLOCKED" --arg ts "$(ts)" "
      .failed_tasks = ([(.failed_tasks // [])[] | select(.id != \$id)]
                       + [{id: \$id, error: \$err, timestamp: \$ts} + (if \$blocked then {blocked: true} else {} end)])
      | .retry_queue = ([(.retry_queue // [])[] | select(. != \$id)] + (if \$blocked then [] else [\$id] end))
      | .current_tasks = [(.current_tasks // [])[] | select(.id != \$id)]
      | .updated_at = \$ts
      | $REFRESH"
    if [[ "$BLOCKED" == true ]]; then log_progress "Blocked $STORY: $ERROR"; else log_progress "Failed $STORY: $ERROR"; fi
    print_progress
    ;;

  finish)
    require_state
    write_state "$PRD_REL" --arg ts "$(ts)" "
      .current_tasks = []
      | .updated_at = \$ts
      | $REFRESH
      | .status = (if .progress.completed == .progress.total then \"completed\" else \"paused\" end)
      | (if .status == \"completed\" then .completed_at = \$ts else . end)"
    log_progress "Run $(jq -r .status "$STATE_FILE"): $PROJECT $(jq -r '"\(.progress.completed)/\(.progress.total)"' "$STATE_FILE")"
    print_progress
    ;;

  sync)
    require_state
    write_state "$PRD_REL" --arg ts "$(ts)" ".updated_at = \$ts | $REFRESH"
    print_progress
    ;;

  *)
    die "unknown command: $CMD (init|start|complete|fail|finish|sync)"
    ;;
esac
