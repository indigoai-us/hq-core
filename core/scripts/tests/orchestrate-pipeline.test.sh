#!/bin/bash
# E2E test for the /orchestrate pipeline script
# (.claude/skills/ideate/scripts/orchestrate-pipeline.mjs) run through
# core/scripts/workflow-runner.mjs with CANNED fake engine binaries — no real
# agents, no real HQ content.
#
# The fake engines answer each stage by prompt markers (capture / brainstorm /
# PRD / finalize) with schema-valid JSON, and the human gates are pre-answered
# as files (the durable-answer path), so the whole pipeline runs headless.
# Covered behaviors:
#   1. continuous default: no gates ever open — the recommended approach and
#      recommended open-question answers are taken and ledgered (decidedBy
#      "auto (recommended)"), no-recommendation questions defer to pre-flight
#      stories, a WEAK premise continues loudly (never auto-parks)
#   1c. gated mode (args.gated=true): capture -> brainstorm (STRONG) -> approach
#      gate -> PRD -> open-question gate -> finalize, returning prd_ready with
#      the gate choices threaded through (approach + decision reach the agents)
#   2. args contract: company/description required; a bad engine name fails
#   3. weak-premise path: verdict WEAK opens the premise gate; a "park" answer
#      ends the run with status parked and NO PRD/finalize agents ever spawn
#   4. open questions are capped: overflow past maxQuestionGates is
#      auto-deferred (finalize agent receives it), not gated
#   7b. a story agent that DIES (not merely blocks) no longer takes the run's
#      whole output with it: the line stops, but the planning and the stories
#      already delivered come back with status execution_failed, and the runner
#      prints the --resume id that replays the finished agents
#   5. engine threading: args.engine="grok" runs every stage on the grok bin
#      (codex bin never spawns)
#   9. company binding: every stage prompt opens with the hq-session bind (a
#      spawned stage is a fresh, unbound session and HQ denies its company
#      reads until it binds), and the personal scope is never told to bind
#   8. codex structured output: EVERY schema the pipeline hands agent() reaches
#      codex in the provider's STRICT dialect — additionalProperties:false on
#      every object node and a `required` listing every property — which is what
#      the run needs to survive its first agent (HTTP 400 invalid_json_schema
#      otherwise), plus the source-level invariant that each schema literal in
#      the pipeline states additionalProperties: false itself

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
RUNNER="$REPO_ROOT/core/scripts/workflow-runner.mjs"
PIPELINE="$REPO_ROOT/.claude/skills/orchestrate/scripts/orchestrate-pipeline.mjs"

pass=0
fail=0
check() { # check <name> <condition-exit-code>
  if [ "$2" -eq 0 ]; then
    printf 'ok   - %s\n' "$1"; pass=$((pass + 1))
  else
    printf 'FAIL - %s\n' "$1"; fail=$((fail + 1))
  fi
}

TMP="$(mktemp -d /tmp/orchestrate-pipeline-test.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
TMP="$(cd "$TMP" && pwd -P)"
mkdir -p "$TMP/bin"
HQROOT="$TMP/hqroot"
mkdir -p "$HQROOT/.claude"
printf '{}\n' > "$HQROOT/.claude/settings.json"

# canned stage responses, shared by both fake engines
cat > "$TMP/bin/canned.sh" <<'CANNED'
canned_response() { # canned_response <prompt> <verdict>
  local prompt="$1" verdict="$2"
  # order matters: the finalize prompt also mentions the PRD skill, so match
  # the most specific marker first
  case "$prompt" in
    *"decision-mode write-back"*)
      printf '{"decisionsApplied":1,"investigationStories":2,"storiesTotal":7,"stories":[{"id":"US-001","title":"First deliverable"},{"id":"US-002","title":"Second deliverable"}]}\n' ;;
    *"Execute story US-"*)
      sid="$(printf '%s' "$prompt" | sed -n 's/.*Execute story \(US-[0-9]*\).*/\1/p')"
      if [ -n "${FAKE_BLOCK_STORY:-}" ] && [ "$sid" = "$FAKE_BLOCK_STORY" ]; then
        printf '{"storyId":"%s","status":"blocked","artifacts":[],"note":"canned blocker"}\n' "$sid"
      else
        printf '{"storyId":"%s","status":"passed","artifacts":["projects/demo-slug/artifact-%s.txt"],"note":"done"}\n' "$sid" "$sid"
      fi ;;
    *"skills/idea/SKILL.md"*)
      printf '{"boardId":"xx-proj-001","title":"Demo Title"}\n' ;;
    *"skills/brainstorm/SKILL.md"*)
      printf '{"slug":"demo-slug","premiseVerdict":"%s","premiseSummary":"Premise summary here.","approaches":[{"name":"option-a","effort":"M","summary":"the safe one","whenToChoose":"default"},{"name":"option-b","effort":"L","summary":"the big one","whenToChoose":"scale"}],"recommended":"option-a","biggestRisk":"scope creep"}\n' "$verdict" ;;
    *"Read the PRD skill at"*)
      printf '{"name":"demo-slug","prdPath":"projects/demo-slug/prd.json","stories":5,"openQuestions":[{"question":"Auth provider?","options":["existing","new"],"recommended":"existing","whyItMatters":"touches every story"},{"question":"Overflow question A?","options":[],"recommended":"","whyItMatters":"minor"},{"question":"Overflow question B?","options":[],"recommended":"","whyItMatters":"minor"}]}\n' ;;
    *)
      printf 'echo:%s\n' "$prompt" ;;
  esac
}
CANNED

cat > "$TMP/bin/codex" <<'FAKE'
#!/usr/bin/env bash
rec="${FAKE_REC_DIR:?}"
. "$(dirname "$0")/canned.sh"
last=""; prompt=""
while [ $# -gt 0 ]; do
  case "$1" in
    --output-last-message) last="$2"; shift 2 ;;
    --output-schema) mkdir -p "$rec/schemas"; cp "$2" "$rec/schemas/schema.$$-$RANDOM.json"; shift 2 ;;
    -C|-c|-m|--color) shift 2 ;;
    exec) shift ;;
    --*) shift ;;
    *) prompt="$1"; shift ;;
  esac
done
printf '%s\n' "$prompt" >> "$rec/codex-prompts"
if [ -n "${FAKE_KILL_STORY:-}" ]; then
  case "$prompt" in
    *"Execute story $FAKE_KILL_STORY "*)
      echo "fake codex: story agent died" >&2; exit 3 ;;
  esac
fi
canned_response "$prompt" "${FAKE_VERDICT:-STRONG}" > "$last"
exit 0
FAKE
chmod +x "$TMP/bin/codex"

cat > "$TMP/bin/grok" <<'FAKE'
#!/usr/bin/env bash
# grok returns a JSON envelope {text, stopReason, ...}; the canned stage reply
# rides in .text (JSON-escaped), matching the real CLI.
rec="${FAKE_REC_DIR:?}"
. "$(dirname "$0")/canned.sh"
prompt=""
while [ $# -gt 0 ]; do
  case "$1" in
    --single) prompt="$2"; shift 2 ;;
    -m|--reasoning-effort|--output-format|--permission-mode) shift 2 ;;
    *) shift ;;
  esac
done
printf '%s\n' "$prompt" >> "$rec/grok-prompts"
canned_response "$prompt" "${FAKE_VERDICT:-STRONG}" \
  | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>process.stdout.write(JSON.stringify({text:s.trim(),stopReason:"EndTurn",sessionId:"s1"})+"\n"))'
exit 0
FAKE
chmod +x "$TMP/bin/grok"

pre_answer() { # pre_answer <gates-dir> <id> <choice>
  node -e '
    const fs = require("fs");
    const [, dir, id, choice] = process.argv;
    fs.mkdirSync(`${dir}/answered`, { recursive: true });
    fs.writeFileSync(`${dir}/answered/${id}.json`,
      JSON.stringify({ id, choice, answered_at: new Date().toISOString() }));
  ' "$1" "$2" "$3"
}

run_pipeline() { # run_pipeline <gates-dir> <rec-dir> <args-json> [env pairs...] -> $OUT, $RC
  local gates="$1" rec="$2" argsjson="$3"; shift 3
  mkdir -p "$rec"
  RUNDIR="$TMP/run-$RANDOM"
  OUT="$(env "$@" HQ_WORKFLOW_CODEX_BIN="$TMP/bin/codex" HQ_WORKFLOW_GROK_BIN="$TMP/bin/grok" \
    FAKE_REC_DIR="$rec" HQ_WORKFLOW_CPU_CHECK=0 HQ_ROOT="$HQROOT" \
    HQ_WORKFLOW_GATES_DIR="$gates" HQ_WORKFLOW_GATE_POLL_SECS=1 \
    node "$RUNNER" "$PIPELINE" --quiet --args "$argsjson" \
    --run-dir "$RUNDIR" 2>"$TMP/stderr.last")"
  RC=$?
}

# ---- 1: continuous default — no gates, recommended answers taken -------------
G0="$TMP/g0"; R0="$TMP/r0"
run_pipeline "$G0" "$R0" '{"company":"demo","description":"a demo idea worth building","direction":"quality"}'
check "continuous pipeline exits 0" "$RC"
printf '%s\n' "$OUT" | node -e '
  const r = JSON.parse(require("fs").readFileSync(0, "utf8"));
  process.exit(r.status === "delivered" && r.mode === "continuous"
    && r.chosenApproach === "option-a" && r.autoDecided >= 1
    && r.storiesTotal === 7 && r.storiesExecuted === 2
    && r.deliverables.length === 2 && r.blockedStory === null ? 0 : 1);
'
check "continuous: full arc delivered — approach taken, 2 stories executed, deliverables listed" "$?"
grep -q 'Execute story US-001' "$R0/codex-prompts" && grep -q 'Execute story US-002' "$R0/codex-prompts"
check "continuous: an execute agent ran per story" "$?"
[ ! -d "$G0/pending" ] && [ ! -d "$G0/answered" ]
check "continuous: no gate files ever created" "$?"
grep -q '"decidedBy":"auto (recommended)"' "$R0/codex-prompts"
check "continuous: auto decisions carry decidedBy auto (recommended)" "$?"
grep -q '"answer":"existing"' "$R0/codex-prompts"
check "continuous: recommended open-question answer became a ledgered decision" "$?"
grep -q 'Overflow question A?' "$R0/codex-prompts" && grep -q 'Overflow question B?' "$R0/codex-prompts"
check "continuous: no-recommendation questions deferred to pre-flight stories" "$?"

# ---- 1b: continuous + WEAK premise — never auto-parks -------------------------
G0W="$TMP/g0w"; R0W="$TMP/r0w"
run_pipeline "$G0W" "$R0W" '{"company":"demo","description":"a shaky idea"}' FAKE_VERDICT=WEAK
check "continuous weak-premise pipeline exits 0" "$RC"
printf '%s\n' "$OUT" | node -e '
  const r = JSON.parse(require("fs").readFileSync(0, "utf8"));
  process.exit((r.status === "delivered") && r.premiseVerdict === "WEAK" ? 0 : 1);
'
check "continuous: WEAK premise continues to delivered (no auto-park)" "$?"
grep -q 'PREMISE WEAK (continuing' "$RUNDIR/journal.jsonl"
check "continuous: WEAK premise logged loudly (journal)" "$?"

# ---- 1c: gated happy path (gates still work behind the flag) ------------------
G1="$TMP/g1"; R1="$TMP/r1"
pre_answer "$G1" demo-slug-approach option-b
pre_answer "$G1" demo-slug-q1 existing
run_pipeline "$G1" "$R1" '{"company":"demo","description":"a demo idea worth building","direction":"quality","gated":true,"planOnly":true,"maxQuestionGates":1}'
check "gated pipeline exits 0" "$RC"
printf '%s\n' "$OUT" | grep -v 'GATE ' | node -e '
  const r = JSON.parse(require("fs").readFileSync(0, "utf8"));
  process.exit(r.status === "prd_ready" && r.mode === "gated"
    && r.boardId === "xx-proj-001" && r.slug === "demo-slug"
    && r.chosenApproach === "option-b" && r.autoDecided === 0
    && r.storiesTotal === 7 && r.decisionsApplied === 1
    && r.investigationStories === 2 ? 0 : 1);
'
check "gated: final JSON prd_ready with gate choices threaded through" "$?"
grep -q 'option-b' "$R1/codex-prompts"
check "gated: chosen approach (gate answer) reached the PRD agent prompt" "$?"
grep -q '"answer":"existing"' "$R1/codex-prompts"
check "gated: resolved decision reached the finalize agent" "$?"

# ---- 4: gated overflow questions auto-deferred (maxQuestionGates=1) ----------
grep -q 'Overflow question A?' "$R1/codex-prompts" && grep -q 'Overflow question B?' "$R1/codex-prompts"
check "gated: overflow questions passed to finalize as deferred" "$?"
[ ! -f "$G1/pending/demo-slug-q2.json" ] && [ ! -f "$G1/answered/demo-slug-q2.json" ]
check "gated: no gate opened for overflow questions" "$?"

# ---- 2: args contract --------------------------------------------------------
G2="$TMP/g2"; R2="$TMP/r2"
run_pipeline "$G2" "$R2" '{"description":"missing company"}'
[ "$RC" -ne 0 ] && grep -q 'needs args {company, description}' "$TMP/stderr.last"
check "missing company fails fast with a clear error" "$?"
run_pipeline "$G2" "$R2" '{"company":"demo","description":"x","engine":"gemini"}'
[ "$RC" -ne 0 ] && grep -q 'args.engine must be' "$TMP/stderr.last"
check "unknown engine name fails fast" "$?"

# ---- 3: gated weak premise -> park -------------------------------------------
G3="$TMP/g3"; R3="$TMP/r3"
pre_answer "$G3" demo-slug-premise park
run_pipeline "$G3" "$R3" '{"company":"demo","description":"a shaky idea","gated":true}' FAKE_VERDICT=WEAK
check "gated weak-premise pipeline exits 0" "$RC"
printf '%s\n' "$OUT" | grep -v 'GATE ' | node -e '
  const r = JSON.parse(require("fs").readFileSync(0, "utf8"));
  process.exit(r.status === "parked" && r.slug === "demo-slug" ? 0 : 1);
'
check "gated: park answer ends the run with status parked" "$?"
grep -q 'Read the PRD skill at' "$R3/codex-prompts" && prd_ran=1 || prd_ran=0
check "gated: no PRD/finalize agents ran after park" "$prd_ran"

# ---- 5: engine threading — grok runs every stage (continuous) ----------------
G5="$TMP/g5"; R5="$TMP/r5"
run_pipeline "$G5" "$R5" '{"company":"demo","description":"a demo idea worth building","engine":"grok"}'
check "grok-engine pipeline exits 0" "$RC"
printf '%s\n' "$OUT" | grep -v 'GATE ' | node -e '
  const r = JSON.parse(require("fs").readFileSync(0, "utf8"));
  process.exit(r.status === "delivered" && r.chosenApproach === "option-a" ? 0 : 1);
'
check "grok-engine run reached delivered" "$?"
[ -f "$R5/grok-prompts" ] && [ ! -f "$R5/codex-prompts" ]
check "every stage ran on the grok bin (codex bin never spawned)" "$?"

# ---- 6: plan-only stops at the PRD --------------------------------------------
G6="$TMP/g6"; R6="$TMP/r6"
run_pipeline "$G6" "$R6" '{"company":"demo","description":"a demo idea worth building","planOnly":true}'
check "plan-only pipeline exits 0" "$RC"
printf '%s\n' "$OUT" | node -e '
  const r = JSON.parse(require("fs").readFileSync(0, "utf8"));
  process.exit(r.status === "prd_ready" && r.storiesExecuted === undefined ? 0 : 1);
'
check "plan-only: stops at prd_ready, no execution fields" "$?"
grep -q 'Execute story' "$R6/codex-prompts" && po_exec=1 || po_exec=0
check "plan-only: no execute agents ran" "$po_exec"

# ---- 7: blocked story stops the line ------------------------------------------
G7="$TMP/g7"; R7="$TMP/r7"
run_pipeline "$G7" "$R7" '{"company":"demo","description":"a demo idea worth building"}' FAKE_BLOCK_STORY=US-002
check "blocked-story pipeline exits 0" "$RC"
printf '%s\n' "$OUT" | node -e '
  const r = JSON.parse(require("fs").readFileSync(0, "utf8"));
  process.exit(r.status === "execution_blocked" && r.storiesExecuted === 2
    && r.blockedStory && r.blockedStory.id === "US-002"
    && r.deliverables.length === 1 ? 0 : 1);
'
check "blocked story stops the line with honest status + partial deliverables" "$?"

# ---- 7b: a story agent that DIES returns partial results, not nothing --------
# A blocked story was already handled; a story agent that crashes outright was
# not. The exception escaped the script, so the runner returned NO result at
# all — the finished planning and the stories already delivered went unreported
# even though they were on disk. Observed live on 2026-08-19: 13 agents and
# 5h44m of finished work vanished from the run's output when agent 14 died.
G7B="$TMP/g7b"; R7B="$TMP/r7b"
run_pipeline "$G7B" "$R7B" '{"company":"demo","description":"a demo idea worth building"}' FAKE_KILL_STORY=US-002
check "a dead story agent no longer takes the whole run's output with it" "$RC"
printf '%s\n' "$OUT" | node -e '
  const r = JSON.parse(require("fs").readFileSync(0, "utf8"));
  process.exit(r.status === "execution_failed"
    && r.failedStory && r.failedStory.id === "US-002" && r.failedStory.error
    && r.storiesExecuted === 1 && r.deliverables.length === 1
    && r.prdPath === "projects/demo-slug/prd.json" && r.boardId === "xx-proj-001"
    ? 0 : 1);
'
check "the partial result names the dead story and keeps the planning + delivered work" "$?"
grep -q -- '--resume ' "$TMP/stderr.last"
check "the run still prints how to resume the finished agents" "$?"

# ---- 8: every schema the pipeline hands agent() reaches codex strict-valid ---
# The codex engine forwards --output-schema to its provider as a STRICT
# structured-output schema. An object node without additionalProperties:false,
# or with a `required` that misses a property, is rejected with HTTP 400
# invalid_json_schema before the agent does any work — which is exactly how this
# pipeline died on its very first agent (capture-idea) on 2026-08-19. Run 1
# above exercised every stage, so its recorded schemas are the full set.
schemas_seen="$(ls "$R0/schemas"/*.json 2>/dev/null | wc -l | tr -d ' ')"
[ "${schemas_seen:-0}" -ge 6 ]
check "every pipeline stage handed codex a schema (${schemas_seen:-0} recorded, >= 6)" "$?"

node "$REPO_ROOT/core/scripts/tests/assert-strict-output-schema.mjs" "$R0/schemas"/*.json 2>"$TMP/strict.err"
check "every schema handed to agent() is strict-valid at every object node" "$?"

# Source-level invariant: the fix belongs in the pipeline literals too, so a new
# stage written by copying an existing one carries the flag rather than relying
# on the runner's defensive rewrite alone.
pipeline_code="$(grep -v '^[[:space:]]*//' "$PIPELINE")"   # prose about the rule is not the rule
obj_nodes="$(printf '%s\n' "$pipeline_code" | grep -c "type: 'object'")"
declared="$(printf '%s\n' "$pipeline_code" | grep -c 'additionalProperties: false')"
[ "$obj_nodes" -gt 0 ] && [ "$obj_nodes" -eq "$declared" ]
check "every object schema literal in the pipeline declares additionalProperties: false ($declared/$obj_nodes)" "$?"

# ---- 9: every stage is told to bind the company before reading it -----------
# A spawned stage is a FRESH session, and a fresh session is unbound: HQ's scope
# authorizer denies every read under companies/{co}/ until `hq-session.sh set
# company_slug` runs, and nothing runs it for a spawned agent. Observed
# 2026-08-19: a capture stage lost its first two turns to that denial.
grep -q 'hq-session.sh set company_slug demo' "$R0/codex-prompts"
check "each stage prompt carries the company-bind command" "$?"
bind_stages="$(grep -c 'hq-session.sh set company_slug demo' "$R0/codex-prompts")"
[ "${bind_stages:-0}" -ge 6 ]
check "the bind instruction reaches every stage (${bind_stages:-0} prompts, >= 6)" "$?"
grep -q 'ONE denial worth retrying' "$R0/codex-prompts"
check "the bind denial is carved out of the never-retry rule" "$?"

# personal scope has no company to bind — the instruction must not appear.
G9="$TMP/g9"; R9="$TMP/r9"
run_pipeline "$G9" "$R9" '{"company":"personal","description":"a personal idea","planOnly":true}'
check "personal-scope pipeline exits 0" "$RC"
grep -q 'set company_slug' "$R9/codex-prompts" && personal_bind=1 || personal_bind=0
check "personal scope is never told to bind a company" "$personal_bind"

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
