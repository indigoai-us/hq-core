#!/usr/bin/env bash
# Regression coverage for aggregate tracker reconciliation in run-project.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SCRIPT="$ROOT/.claude/scripts/run-project.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

awk '
  /^reconcile_trackers\(\) \{/ { found=1 }
  found {
    print
    if ($0 ~ /^}$/) exit
  }
' "$SCRIPT" > "$TMP/reconcile-trackers.sh"

# shellcheck source=/dev/null
source "$TMP/reconcile-trackers.sh"

HQ_ROOT="$TMP/hq"
PROJECT="tracker-fixture"
PRD_REL="companies/test/projects/tracker-fixture/prd.json"
PRD_PATH="$TMP/prd.json"
COMPLETED=3
TOTAL=5

mkdir -p "$HQ_ROOT/workspace/orchestrator"
printf '%s\n' '{"metadata":{}}' > "$PRD_PATH"
printf '%s\n' '{"projects":[{"name":"tracker-fixture","prdPath":"old/path.json","state":"queued","storiesComplete":0,"storiesTotal":1,"checkedOutFiles":["keep-me"]}]}' \
  > "$HQ_ROOT/workspace/orchestrator/state.json"

ts() { printf '2026-07-16T12:00:00Z\n'; }

reconcile_trackers "in_progress"

state_file="$HQ_ROOT/workspace/orchestrator/state.json"
[[ "$(jq -r '.projects[0].storiesComplete' "$state_file")" == "3" ]] \
  || fail "storiesComplete was not reconciled"
[[ "$(jq -r '.projects[0].storiesTotal' "$state_file")" == "5" ]] \
  || fail "storiesTotal was not reconciled"
[[ "$(jq -r '.projects[0].state' "$state_file")" == "in_progress" ]] \
  || fail "state was not reconciled"
[[ "$(jq -r '.projects[0].updatedAt' "$state_file")" == "2026-07-16T12:00:00Z" ]] \
  || fail "updatedAt was not reconciled"
[[ "$(jq -r '.projects[0].checkedOutFiles[0]' "$state_file")" == "keep-me" ]] \
  || fail "existing aggregate tracker fields were not preserved"

echo "run-project tracker reconciliation test passed"
