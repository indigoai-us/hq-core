#!/usr/bin/env bash
# =============================================================================
# audit-log.sh — Structured audit log utility for HQ
#
# Schema fields: timestamp, event, company, project, story_id, worker, model,
#                action, files_touched, result, duration_ms, error, session_id
#
# Usage:
#   scripts/audit-log.sh append --event task_started --project my-project [fields...]
#   scripts/audit-log.sh query [--project X] [--company X] [--worker X] [--since X] [--event X]
#   scripts/audit-log.sh summary
#
# Events: task_started | phase_completed | task_completed | task_failed |
#         project_started | project_completed |
#         story_dispatched | story_completed | story_failed |
#         pipeline_started | pipeline_completed | pipeline_paused | pipeline_failed |
#         project_pr_created | project_reviewed | project_merged | project_deployed |
#         project_canary_pass | project_canary_fail |
#         gate_requested | gate_resolved
# Results: success | fail | skipped
# =============================================================================

set -euo pipefail

HQ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AUDIT_LOG="$HQ_ROOT/workspace/metrics/audit-log.jsonl"

VALID_EVENTS="task_started phase_completed task_completed task_failed project_started project_completed story_dispatched story_completed story_failed pipeline_started pipeline_completed pipeline_paused pipeline_failed project_pr_created project_reviewed project_merged project_deployed project_canary_pass project_canary_fail gate_requested gate_resolved"
VALID_RESULTS="success fail skipped"

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------

die() { echo "ERROR: $*" >&2; exit 1; }

require_jq() {
  command -v jq >/dev/null 2>&1 || die "jq is required but not installed (brew install jq)"
}

iso_now() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

contains() {
  local needle="$1" haystack="$2"
  [[ " $haystack " == *" $needle "* ]]
}

# ---------------------------------------------------------------------------
# append subcommand
# ---------------------------------------------------------------------------
# Usage:
#   audit-log.sh append \
#     --event task_started \
#     --project hq-observability \
#     [--company {company}] \
#     [--story-id US-001] \
#     [--worker backend-dev] \
#     [--model sonnet] \
#     [--action "Scaffold schema"] \
#     [--files "scripts/audit-log.sh,workspace/metrics/audit-log.jsonl"] \
#     [--result success] \
#     [--duration-ms 1234] \
#     [--error "message"] \
#     [--session-id abc123]
# ---------------------------------------------------------------------------
cmd_append() {
  require_jq

  local timestamp="" event="" company="" project="" story_id="" worker=""
  local model="" action="" files_touched="" result="" duration_ms="" error="" session_id=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --timestamp)     timestamp="$2";    shift 2 ;;
      --event)         event="$2";        shift 2 ;;
      --company)       company="$2";      shift 2 ;;
      --project)       project="$2";      shift 2 ;;
      --story-id)      story_id="$2";     shift 2 ;;
      --worker)        worker="$2";       shift 2 ;;
      --model)         model="$2";        shift 2 ;;
      --action)        action="$2";       shift 2 ;;
      --files)         files_touched="$2"; shift 2 ;;
      --result)        result="$2";       shift 2 ;;
      --duration-ms)   duration_ms="$2";  shift 2 ;;
      --error)         error="$2";        shift 2 ;;
      --session-id)    session_id="$2";   shift 2 ;;
      *) die "Unknown flag: $1" ;;
    esac
  done

  # --- required field validation ---
  [[ -n "$event" ]]   || die "Missing required field: --event"
  [[ -n "$project" ]] || die "Missing required field: --project"

  # validate event value
  contains "$event" "$VALID_EVENTS" || die "Invalid event '$event'. Must be one of: $VALID_EVENTS"

  # validate result if provided
  if [[ -n "$result" ]]; then
    contains "$result" "$VALID_RESULTS" || die "Invalid result '$result'. Must be one of: $VALID_RESULTS"
  fi

  # validate duration_ms is numeric if provided
  if [[ -n "$duration_ms" ]]; then
    [[ "$duration_ms" =~ ^[0-9]+$ ]] || die "--duration-ms must be a non-negative integer"
  fi

  # auto-fill timestamp
  [[ -n "$timestamp" ]] || timestamp="$(iso_now)"

  # --- build files_touched array ---
  # Input: comma-separated string → JSON array
  local files_json="[]"
  if [[ -n "$files_touched" ]]; then
    files_json="$(echo "$files_touched" | jq -Rc 'split(",")')"
  fi

  # --- build JSON line ---
  local entry
  entry="$(jq -cn \
    --arg ts        "$timestamp" \
    --arg event     "$event" \
    --arg company   "$company" \
    --arg project   "$project" \
    --arg story_id  "$story_id" \
    --arg worker    "$worker" \
    --arg model     "$model" \
    --arg action    "$action" \
    --argjson files "$files_json" \
    --arg result    "$result" \
    --arg dur       "$duration_ms" \
    --arg error     "$error" \
    --arg session   "$session_id" \
    '{
      timestamp:    $ts,
      event:        $event,
      company:      (if $company   != "" then $company   else null end),
      project:      $project,
      story_id:     (if $story_id  != "" then $story_id  else null end),
      worker:       (if $worker    != "" then $worker    else null end),
      model:        (if $model     != "" then $model     else null end),
      action:       (if $action    != "" then $action    else null end),
      files_touched: $files,
      result:       (if $result    != "" then $result    else null end),
      duration_ms:  (if $dur       != "" then ($dur | tonumber) else null end),
      error:        (if $error     != "" then $error     else null end),
      session_id:   (if $session   != "" then $session   else null end)
    } | with_entries(select(.value != null and .value != []))'
  )"

  echo "$entry" >> "$AUDIT_LOG"
  echo "Appended to $AUDIT_LOG"
}

# ---------------------------------------------------------------------------
# query subcommand
# ---------------------------------------------------------------------------
# Usage:
#   audit-log.sh query [--project X] [--company X] [--worker X] [--since YYYY-MM-DD] [--event X]
# ---------------------------------------------------------------------------
cmd_query() {
  require_jq

  local filter_project="" filter_company="" filter_worker="" filter_since="" filter_event=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --project) filter_project="$2"; shift 2 ;;
      --company) filter_company="$2"; shift 2 ;;
      --worker)  filter_worker="$2";  shift 2 ;;
      --since)   filter_since="$2";   shift 2 ;;
      --event)   filter_event="$2";   shift 2 ;;
      *) die "Unknown flag: $1" ;;
    esac
  done

  if [[ ! -f "$AUDIT_LOG" ]]; then
    echo "No audit log found at $AUDIT_LOG" >&2
    exit 0
  fi

  # Build jq args + filter chain (parameterized to prevent filter injection)
  local jq_args=()
  local jq_filter="."

  if [[ -n "$filter_project" ]]; then
    jq_args+=(--arg fp "$filter_project")
    jq_filter+=' | select(.project == $fp)'
  fi
  if [[ -n "$filter_company" ]]; then
    jq_args+=(--arg fc "$filter_company")
    jq_filter+=' | select(.company == $fc)'
  fi
  if [[ -n "$filter_worker" ]]; then
    jq_args+=(--arg fw "$filter_worker")
    jq_filter+=' | select(.worker == $fw)'
  fi
  if [[ -n "$filter_event" ]]; then
    jq_args+=(--arg fe "$filter_event")
    jq_filter+=' | select(.event == $fe)'
  fi
  if [[ -n "$filter_since" ]]; then
    jq_args+=(--arg fs "$filter_since")
    jq_filter+=' | select(.timestamp >= $fs)'
  fi

  local count
  count=$(jq -r "${jq_args[@]}" "$jq_filter" "$AUDIT_LOG" 2>/dev/null | jq -s 'length')

  jq -r "${jq_args[@]}" "$jq_filter" "$AUDIT_LOG" 2>/dev/null | jq -s '.'
  echo "--- $count record(s) matched ---" >&2
}

# ---------------------------------------------------------------------------
# summary subcommand
# ---------------------------------------------------------------------------
# Outputs table: project | stories | phases | failures | last_activity
# ---------------------------------------------------------------------------
cmd_summary() {
  require_jq

  if [[ ! -f "$AUDIT_LOG" ]]; then
    echo "No audit log found at $AUDIT_LOG" >&2
    exit 0
  fi

  local line_count
  line_count=$(wc -l < "$AUDIT_LOG" | tr -d ' ')

  if [[ "$line_count" -eq 0 ]]; then
    echo "Audit log is empty — no records to summarize."
    exit 0
  fi

  echo ""
  echo "=== Audit Log Summary ==="
  echo ""

  # Per-project breakdown
  echo "--- By Project ---"
  printf "%-40s  %8s  %8s  %8s  %8s  %-26s\n" \
    "PROJECT" "STORIES" "PHASES" "FAILURES" "SKIPPED" "LAST_ACTIVITY"
  printf "%-40s  %8s  %8s  %8s  %8s  %-26s\n" \
    "$(printf '%0.s-' {1..40})" "--------" "--------" "--------" "--------" "$(printf '%0.s-' {1..26})"

  jq -rs '
    group_by(.project) |
    .[] |
    {
      project:       .[0].project,
      stories:       (map(select(.event == "task_completed" or .event == "task_failed")) | length),
      phases:        (map(select(.event == "phase_completed")) | length),
      failures:      (map(select(.result == "fail" or .event == "task_failed")) | length),
      skipped:       (map(select(.result == "skipped")) | length),
      last_activity: (sort_by(.timestamp) | last | .timestamp)
    }
  ' "$AUDIT_LOG" | jq -r '
    "\(.project // "unknown")\t\(.stories)\t\(.phases)\t\(.failures)\t\(.skipped)\t\(.last_activity // "-")"
  ' | while IFS=$'\t' read -r proj stories phases failures skipped last; do
    printf "%-40s  %8s  %8s  %8s  %8s  %-26s\n" \
      "$proj" "$stories" "$phases" "$failures" "$skipped" "$last"
  done

  echo ""

  # Per-worker breakdown
  echo "--- By Worker ---"
  printf "%-30s  %8s  %8s  %-10s\n" "WORKER" "TASKS" "FAILURES" "SUCCESS_RATE"
  printf "%-30s  %8s  %8s  %-10s\n" \
    "$(printf '%0.s-' {1..30})" "--------" "--------" "----------"

  jq -rs '
    map(select(.worker != null)) |
    group_by(.worker) |
    .[] |
    {
      worker:   .[0].worker,
      tasks:    (map(select(.event == "task_completed" or .event == "task_failed")) | length),
      failures: (map(select(.result == "fail" or .event == "task_failed")) | length)
    } |
    . + {
      rate: (if .tasks > 0 then (((.tasks - .failures) / .tasks * 100) | round | tostring) + "%" else "n/a" end)
    }
  ' "$AUDIT_LOG" | jq -r '
    "\(.worker)\t\(.tasks)\t\(.failures)\t\(.rate)"
  ' | while IFS=$'\t' read -r worker tasks failures rate; do
    printf "%-30s  %8s  %8s  %-10s\n" "$worker" "$tasks" "$failures" "$rate"
  done

  echo ""

  # Overall stats
  local total_events total_tasks total_failures
  total_events=$(wc -l < "$AUDIT_LOG" | tr -d ' ')
  total_tasks=$(jq -rs 'map(select(.event == "task_completed" or .event == "task_failed")) | length' "$AUDIT_LOG")
  total_failures=$(jq -rs 'map(select(.result == "fail" or .event == "task_failed")) | length' "$AUDIT_LOG")

  echo "--- Totals ---"
  echo "  Total events:   $total_events"
  echo "  Total tasks:    $total_tasks"
  echo "  Total failures: $total_failures"
  echo ""
}

# ---------------------------------------------------------------------------
# help
# ---------------------------------------------------------------------------
cmd_help() {
  cat <<'EOF'
audit-log.sh — HQ audit log utility

SUBCOMMANDS:
  append    Write one JSONL record to the audit log
  query     Filter and display records
  summary   Show aggregated table (project | worker | status)

APPEND FLAGS (--event and --project are required):
  --timestamp    ISO8601 (auto-filled if omitted)
  --event        task_started | phase_completed | task_completed | task_failed |
                 project_started | project_completed |
                 story_dispatched | story_completed | story_failed |
                 pipeline_started | pipeline_completed | pipeline_paused |
                 pipeline_failed | project_pr_created | project_reviewed |
                 project_merged | project_deployed | project_canary_pass |
                 project_canary_fail | gate_requested | gate_resolved
  --company      Company slug (e.g. {company})
  --project      Project slug (e.g. hq-observability)
  --story-id     Story ID (e.g. US-001)
  --worker       Worker name (e.g. backend-dev)
  --model        Model name (e.g. sonnet)
  --action       Short description of what happened
  --files        Comma-separated file paths touched
  --result       success | fail | skipped
  --duration-ms  Wall-clock time in milliseconds (integer)
  --error        Error message if result=fail
  --session-id   Claude session/thread ID

QUERY FLAGS:
  --project      Filter by project slug
  --company      Filter by company slug
  --worker       Filter by worker name
  --since        Filter by timestamp >= YYYY-MM-DD (or full ISO8601)
  --event        Filter by event type

EXAMPLES:
  # Append a task_started event
  scripts/audit-log.sh append \
    --event task_started \
    --project hq-observability \
    --company {company} \
    --story-id US-001 \
    --worker backend-dev \
    --model sonnet

  # Query all failures for a project
  scripts/audit-log.sh query --project hq-observability --event task_failed

  # Query since a date
  scripts/audit-log.sh query --since 2026-03-01

  # Show summary table
  scripts/audit-log.sh summary

LOG FILE:
  workspace/metrics/audit-log.jsonl
EOF
}

# ---------------------------------------------------------------------------
# dispatch
# ---------------------------------------------------------------------------
SUBCOMMAND="${1:-help}"
shift || true

case "$SUBCOMMAND" in
  append)  cmd_append  "$@" ;;
  query)   cmd_query   "$@" ;;
  summary) cmd_summary "$@" ;;
  help|--help|-h) cmd_help ;;
  *) die "Unknown subcommand '$SUBCOMMAND'. Use: append | query | summary | help" ;;
esac
