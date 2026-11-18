#!/usr/bin/env bash
# /run-project routes on conduct.runner (US-006).
# Default mode (subagent) runs each story through /execute-task on one
# in-session subagent and makes no hq runners call. Story lanes (Step 3L) and
# pipeline mode (Step 3P) sit under an advanced-mode heading and run only when
# conduct.runner is runner.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SKILL="$ROOT/.claude/skills/run-project/SKILL.md"
STATE_HELPER="$ROOT/core/scripts/run-project-state.sh"
fail=0
bad() { echo "FAIL: $*" >&2; fail=1; }
for f in "$SKILL" "$STATE_HELPER"; do [ -f "$f" ] || { echo "FAIL: missing $f" >&2; exit 1; }; done

FRONT="$(awk 'NR == 1 && /^---$/ { on = 1; next } on && /^---$/ { exit } on { print }' "$SKILL")"
ALLOWED="$(grep '^allowed-tools:' <<< "$FRONT")"
DESC="$(grep '^description:' <<< "$FRONT")"

# --- resolver ---
grep -Fq 'Bash(sh core/scripts/conduct-runner-resolve.sh:*)' <<< "$ALLOWED" \
  || bad "allowed-tools lacks the shared runner resolver"
STEP1="$(awk '/^## Step 1 /{ on = 1; print; next } on && /^#{1,2} /{ exit } on { print }' "$SKILL")"
[ -n "$STEP1" ] || bad "Step 1 section missing"
grep -Fq 'sh core/scripts/conduct-runner-resolve.sh --session-id {session-id}' <<< "$STEP1" \
  || bad "Step 1 must resolve the runner with the shared resolver"
grep -Fq 'Pipeline mode needs advanced mode: run /conduct-runners (conduct.runner runner) first.' <<< "$STEP1" \
  || bad "Step 1 must print the one-line pipeline message in default mode"

# --- frontmatter vocabulary ---
if grep -Fq 'through HQ worker lanes' <<< "$DESC"; then
  bad "description still says stories run through HQ worker lanes"
fi
grep -Fq 'subagents by default' <<< "$DESC" || bad "description must name subagents as the default"
grep -Fq '/conduct-runners' <<< "$DESC" || bad "description must name /conduct-runners for advanced mode"
grep -Fq 'Agent' <<< "$ALLOWED" || bad "allowed-tools must include the Agent tool"
grep -Fq 'Bash(hq runners create:*)' <<< "$ALLOWED" || bad "advanced mode still needs Bash(hq runners create:*)"

# --- default Step 3: no lanes ---
DEFAULT3="$(awk '
  $0 == "## Step 3 — Default Execution: Story Loop" { on = 1 }
  $0 == "# Advanced mode: runners" { exit }
  on { print }
' "$SKILL")"
[ -n "$DEFAULT3" ] || bad "default Step 3 (Story Loop) section missing"
if grep -Eq 'hq (runners|lanes)' <<< "$DEFAULT3"; then
  bad "default Step 3 names hq runners: $(grep -E 'hq (runners|lanes)' <<< "$DEFAULT3" | head -1)"
fi
grep -Fq '/execute-task {project}/{story-id}' <<< "$DEFAULT3" || bad "default story brief must run /execute-task"
grep -Fq 'name: "story-{story-id}"' <<< "$DEFAULT3" || bad "default story loop must dispatch a named Agent subagent"
grep -Fq 'spawn_agent' <<< "$DEFAULT3" || bad "default story loop must name the Codex spawn_agent path"
grep -Fq -- '--runner subagent' <<< "$DEFAULT3" || bad "default preflight must record --runner subagent"
grep -Fq 'conduct-subagents/{session-id}/runs.json' <<< "$DEFAULT3" || bad "default resume must read runs.json"
# Nested-subagent fallback: when the host forbids nested subagents, the
# parent runs /execute-task itself, one story at a time, and blocks with
# NEEDS_RUNNER only when it cannot start phase subagents either.
grep -Fq 'Nested-subagent fallback: if the host forbids nested subagents' <<< "$DEFAULT3" \
  || bad "default story loop must name the nested-subagent fallback"
FALLBACK="$(awk '/Nested-subagent fallback:/ { on = 1 } on && /^[0-9]+\. / && !/Nested/ { exit } on { print }' <<< "$DEFAULT3" | tr '\n' ' ' | tr -s ' ')"
grep -Fq 'the parent runs `/execute-task {project}/{story-id}` in default mode itself, one story at a time' <<< "$FALLBACK" \
  || bad "the fallback must run /execute-task from the parent, one story at a time"
grep -Fq 'the parent never runs a phase' <<< "$FALLBACK" || bad "the fallback must keep phases on subagents"
grep -Fq 'NEEDS_RUNNER` only when the parent cannot start phase subagents either' <<< "$FALLBACK" \
  || bad "the fallback must block NEEDS_RUNNER only when the parent cannot start phases either"
if grep -Fq 'tell the user to rerun it with `/conduct-runners` set' <<< "$DEFAULT3"; then
  bad "default story loop still sends a nested-subagent block to /conduct-runners"
fi
grep -Fq 'The nested-subagent fallback never runs' <<< "$DEFAULT3" || bad "the fallback must not run stories concurrently"
grep -Fq 'handoffs.jsonl' <<< "$DEFAULT3" || bad "default story loop must cross-check handoffs.jsonl"
D3D="$(awk '$0 == "### 3d. Budget and Recovery" { on = 1; next } on && /^#{1,3} / { exit } on { print }' <<< "$DEFAULT3")"
[ -n "$D3D" ] || bad "default 3d section missing"
grep -Fq 'Do not simulate `/execute-task` by spawning worker-phase agents from the' <<< "$D3D" \
  || bad "default 3d must keep the do-not-simulate rule"

# --- advanced heading order ---
adv="$(grep -n '^# Advanced mode: runners$' "$SKILL" | head -1 | cut -d: -f1)"
s3l="$(grep -n '^## Step 3L — Story Lanes$' "$SKILL" | head -1 | cut -d: -f1)"
s3p="$(grep -n '^## Step 3P ' "$SKILL" | head -1 | cut -d: -f1)"
s3="$(grep -n '^## Step 3 — Default Execution: Story Loop$' "$SKILL" | head -1 | cut -d: -f1)"
[ -n "$adv" ] && [ -n "$s3l" ] && [ -n "$s3p" ] && [ -n "$s3" ] || bad "missing a Step 3 / advanced / 3L / 3P heading"
if [ -n "$adv" ] && [ -n "$s3l" ] && [ -n "$s3p" ] && [ -n "$s3" ]; then
  [ "$s3" -lt "$adv" ] || bad "default Step 3 must precede the advanced heading"
  [ "$adv" -lt "$s3l" ] || bad "# Advanced mode: runners must precede Step 3L"
  [ "$adv" -lt "$s3p" ] || bad "# Advanced mode: runners must precede Step 3P"
fi
S3L="$(awk '$0 == "## Step 3L — Story Lanes" { on = 1 } /^## Step 3P / { exit } on { print }' "$SKILL")"
grep -Fq 'hq runners create' <<< "$S3L" || bad "Step 3L must keep hq runners create"
grep -Fq -- '--runner runner' <<< "$S3L" || bad "Step 3L preflight must record --runner runner"
# Advanced mode is unchanged: with no provider CLI it keeps the in-session
# spawn_agent/wait_agent fallback and says which path is in use.
grep -Fq 'If no provider CLI is available, retain the existing' <<< "$S3L" || bad "Step 3L lost the no-provider-CLI fallback"
grep -Fq 'in-session `spawn_agent`/`wait_agent` fallback' <<< "$S3L" || bad "Step 3L must keep the in-session spawn_agent/wait_agent fallback"
grep -Fq 'say which path is in use' <<< "$S3L" || bad "Step 3L must say which path is in use"
grep -Fq 'use the existing' <<< "$S3L" && grep -Fq 'in-session fallback or pause with the current blocker' <<< "$S3L" || bad "Step 3L must keep the in-session fallback when a story lane cannot run /execute-task"
if grep -Fq 'do not substitute' <<< "$S3L"; then bad "Step 3L must not refuse the in-session fallback"; fi

# --- Codex: default mode runs on spawn_agent ---
STEP4="$(awk '/^## Step 4 /{ on = 1; print; next } on && /^#{1,2} /{ exit } on { print }' "$SKILL")"
[ -n "$STEP4" ] || bad "Step 4 section missing"
grep -Fq 'route to the default story loop' <<< "$STEP4" \
  || bad "Codex interactive mode must route worker-backed runs to the default story loop"

# --- state helper ---
grep -Fq -- '--runner subagent|runner' "$STATE_HELPER" || bad "run-project-state.sh usage must document --runner"
grep -Fq -- '--runner) RUNNER=' "$STATE_HELPER" || bad "run-project-state.sh init must parse --runner"

# --- Rules ---
RULES="$(awk '/^## Rules$/ { on = 1; next } on && /^#{1,2} / { exit } on { print }' "$SKILL")"
grep -Fq 'Default stories run through `/execute-task` on a subagent' <<< "$RULES" \
  || bad "Rules must name the subagent default"
grep -Fq 'In advanced mode' <<< "$RULES" || bad "Rules must mark the lane path as advanced"

[ "$fail" -eq 0 ] || exit 1
echo "run-project runner mode: ok"
