#!/usr/bin/env bash
# List per-check results for a grouped pr-checks job.
#
# The linux-checks-N jobs run several former standalone jobs as step runs.
# Each test step id is t_<former_job>__<n> (dashes in the job name become
# underscores). This script reads the `steps` context as JSON from
# STEPS_JSON, folds the step outcomes per former job, and writes a table to
# GITHUB_STEP_SUMMARY (stdout when unset). A former job is "failure" when any
# of its steps failed, "skipped" when every step was skipped, else "success".
#
# It only reports. The job result already comes from the failing step.
set -euo pipefail

steps_json="${STEPS_JSON:-}"
if [[ -z "$steps_json" ]]; then
  echo "grouped-check-summary: STEPS_JSON is empty" >&2
  exit 0
fi

table="$(jq -r '
  to_entries
  | map(select(.key | test("^t_.+__[0-9]+$")))
  | map({job: (.key | sub("__[0-9]+$"; "") | sub("^t_"; "") | gsub("_"; "-")),
         n: (.key | capture("__(?<n>[0-9]+)$").n | tonumber),
         outcome: (.value.outcome // "skipped")})
  | group_by(.job)
  | map({job: .[0].job,
         steps: length,
         result: (if any(.[]; .outcome == "failure") then "failure"
                  elif all(.[]; .outcome == "skipped") then "skipped"
                  elif any(.[]; .outcome == "cancelled") then "cancelled"
                  else "success" end),
         first_failed: (map(select(.outcome == "failure")) | sort_by(.n) | first | .n // null)})
  | sort_by(.job)
  | (["| Former job | Steps | Result | First failed step |", "|---|---|---|---|"]
     + map("| \(.job) | \(.steps) | \(.result) | \(.first_failed // "-") |"))
  | .[]
' <<< "$steps_json")"

out="${GITHUB_STEP_SUMMARY:-/dev/stdout}"
{
  echo "### Per-check results"
  echo
  echo "$table"
} >> "$out"

failed="$(jq -r '
  to_entries
  | map(select((.key | test("^t_.+__[0-9]+$")) and .value.outcome == "failure"))
  | map(.key | sub("__[0-9]+$"; "") | sub("^t_"; "") | gsub("_"; "-"))
  | unique | .[]
' <<< "$steps_json")"
if [[ -n "$failed" ]]; then
  while IFS= read -r job; do
    echo "::error title=grouped check failed::$job"
  done <<< "$failed"
fi
exit 0
