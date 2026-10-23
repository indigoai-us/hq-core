#!/usr/bin/env bash
# Regression: the host-native (agent) /run-project path must keep state.json in
# the standard shape after every story, the way .claude/scripts/run-project.sh
# does. The vyg-attribution-2030 run wrote its state once, with no prd_path and
# no progress block, and never updated it, so the progress band showed 0/0.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
HELPER="$ROOT/core/scripts/run-project-state.sh"
SKILL="$ROOT/.claude/skills/run-project/SKILL.md"

fail() { echo "FAIL: $*" >&2; exit 1; }

[[ -x "$HELPER" ]] || fail "core/scripts/run-project-state.sh is missing or not executable"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/companies/acme/projects/demo-proj"
cat > "$TMP/companies/acme/projects/demo-proj/prd.json" <<'JSON'
{"name":"demo-proj","userStories":[
  {"id":"US-001","title":"Schema","passes":true},
  {"id":"US-002","title":"API","passes":false},
  {"id":"US-003","title":"CLI","passes":false}
]}
JSON
PRD="$TMP/companies/acme/projects/demo-proj/prd.json"
STATE="$TMP/workspace/orchestrator/demo-proj/state.json"
run() { HQ_ROOT="$TMP" bash "$HELPER" "$@" >/dev/null; }
check() { jq -e "$1" "$STATE" >/dev/null || fail "$2 (state: $(jq -c . "$STATE"))"; }
pass_story() {
  jq --arg id "$1" '.userStories |= map(if .id == $id then .passes = true else . end)' "$PRD" > "$PRD.tmp"
  mv "$PRD.tmp" "$PRD"
}

# init: standard shape with prd_path and a progress block the band can read.
run init demo-proj --company acme --session-id s-1 --provider claude --model m --effort low
check '.prd_path == "companies/acme/projects/demo-proj/prd.json"' "init must record prd_path"
check '.company == "acme" and .status == "in_progress" and .session_id == "s-1"' "init must record company, status, session"
check '.progress == {total: 3, completed: 1, failed: 0, in_progress: 0}' "init progress must count PRD stories (1/3)"
check '(.current_tasks | type) == "array" and (.completed_tasks | type) == "array" and (.failed_tasks | type) == "array"' "init must create the task arrays"

# start: the running story shows up in current_tasks.
run start demo-proj US-002
check '.current_tasks == [.current_tasks[0]] and .current_tasks[0].id == "US-002" and .current_tasks[0].title == "API" and (.current_tasks[0].started_at | type) == "string"' "start must add the story to current_tasks"
check '.progress.in_progress == 1' "start must count the running story"

# complete: progress advances after the story, not only at the end.
pass_story US-002
run complete demo-proj US-002 --commit abc1234
check '.progress.completed == 2 and .progress.total == 3 and .progress.in_progress == 0' "complete must advance progress to 2/3"
check '[.completed_tasks[].id] == ["US-002"] and .completed_tasks[0].commit_sha == "abc1234" and (.completed_tasks[0].completed_at | type) == "string"' "complete must record the story in completed_tasks"
check '.current_tasks == [] and .status == "in_progress"' "complete must clear current_tasks and keep the run open"

# fail / blocked: counted the way the band reads failed_tasks.
run start demo-proj US-003
run fail demo-proj US-003 --error "TIMEOUT" --blocked
check '.failed_tasks[0].id == "US-003" and .failed_tasks[0].blocked == true and .progress.failed == 1 and .current_tasks == []' "fail --blocked must record a blocked failure"

# Retry then complete the last story: the run closes itself.
run start demo-proj US-003
check '.failed_tasks == [] and .progress.failed == 0' "start must clear a story's earlier failure"
pass_story US-003
run complete demo-proj US-003
check '.progress == {total: 3, completed: 3, failed: 0, in_progress: 0} and .status == "completed"' "last complete must mark the run completed (3/3)"

# Resume keeps started_at and session_id, reopens the run, and drops the
# earlier session's running entries (they would otherwise stay "running").
STARTED="$(jq -r .started_at "$STATE")"
jq '.current_tasks = [{id: "US-003", title: "CLI", status: "in_progress", started_at: "2026-01-01T00:00:00Z"}]' "$STATE" > "$STATE.tmp" && mv "$STATE.tmp" "$STATE"
run init demo-proj --company acme --session-id s-2
check ".started_at == \"$STARTED\" and .session_id == \"s-1\" and .status == \"in_progress\"" "re-init must keep started_at and the original session_id"
check '.current_tasks == [] and .progress.in_progress == 0' "re-init must drop the earlier session's running entries"

# init refuses to switch the run to another company.
if HQ_ROOT="$TMP" bash "$HELPER" init demo-proj --company other --prd companies/acme/projects/demo-proj/prd.json >/dev/null 2>&1; then
  fail "init must refuse a company different from the recorded one"
fi
check '.company == "acme"' "a refused company switch must leave state.json unchanged"

# Concurrent writers are serialised: 80 parallel starts all land, over
# several rounds (a lock that can be stolen loses a few writes per round).
mkdir -p "$TMP/companies/acme/projects/par"
jq -n '{userStories: [range(1; 81) | {id: "S-\(.)", title: "s\(.)", passes: false}]}' > "$TMP/companies/acme/projects/par/prd.json"
PAR="$TMP/workspace/orchestrator/par/state.json"
for round in 1 2 3; do
  rm -rf "$TMP/workspace/orchestrator/par"
  run init par --company acme
  for i in $(seq 1 80); do HQ_ROOT="$TMP" bash "$HELPER" start par "S-$i" >/dev/null & done
  wait
  [[ "$(jq '.current_tasks | length' "$PAR")" == 80 && "$(jq '.progress.in_progress' "$PAR")" == 80 ]] \
    || fail "round $round: parallel starts lost writes: $(jq '.current_tasks | length' "$PAR")/80 entries"
done

# A holder killed mid-command does not leave the lock held: the kernel drops it.
HQ_ROOT="$TMP" bash -c 'exec 9>>"$1"; if command -v flock >/dev/null; then flock 9; else perl -MFcntl=:flock -e "open(my \$f, \">&=\", 9); flock(\$f, LOCK_EX)"; fi; exec sleep 30' _ \
  "$TMP/workspace/orchestrator/par/.state.lock" &
HOLDER=$!
sleep 0.5
kill -9 "$HOLDER"; wait "$HOLDER" 2>/dev/null || true
run sync par

# A hand-written state like the vyg run's (no prd_path, no progress) is repaired by init.
echo '{"project":"demo-proj","path":"host-native-agent","stories":{}}' > "$STATE"
run init demo-proj --company acme
check '.prd_path != null and .progress.total == 3 and .progress.completed == 3' "init must repair a hand-written state.json"

[[ -s "$TMP/workspace/orchestrator/demo-proj/progress.txt" ]] || fail "helper must append to progress.txt"

# Unsafe or missing inputs are refused.
if HQ_ROOT="$TMP" bash "$HELPER" init demo-proj >/dev/null 2>&1; then fail "init without --company must fail"; fi
if HQ_ROOT="$TMP" bash "$HELPER" init ../x --company acme >/dev/null 2>&1; then fail "init must reject an unsafe project name"; fi

# The agent path in SKILL.md must call the helper at run start and after every story.
grep -Fq 'core/scripts/run-project-state.sh init {project} --company {company}' "$SKILL" \
  || fail "run-project SKILL.md must initialise state.json with run-project-state.sh init"
grep -Fq 'core/scripts/run-project-state.sh start {project} {story-id}' "$SKILL" \
  || fail "run-project SKILL.md story loop must record the running story with run-project-state.sh start"
grep -Fq 'core/scripts/run-project-state.sh complete {project} {story-id}' "$SKILL" \
  || fail "run-project SKILL.md story loop must update state.json after each verified story"
grep -Fq 'core/scripts/run-project-state.sh fail {project} {story-id}' "$SKILL" \
  || fail "run-project SKILL.md story loop must record failed and blocked stories"
sed -n '/^allowed-tools:/p' "$SKILL" | grep -Fq 'Bash(bash core/scripts/run-project-state.sh:*)' \
  || fail "run-project SKILL.md allowed-tools must allow the state helper"

echo "PASS: host-native run-project path keeps state.json progress current after every story"
