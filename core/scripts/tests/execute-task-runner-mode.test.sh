#!/usr/bin/env bash
# /execute-task routes each phase on conduct.runner (US-007).
# Default mode (subagent) runs every phase on a named Agent subagent, appends
# each handoff to handoffs.jsonl, and makes no hq runners call. Lanes (6c-lanes)
# sit under an advanced-mode heading and run only when conduct.runner is runner.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SKILL="$ROOT/.claude/skills/execute-task/SKILL.md"
fail=0
bad() { echo "FAIL: $*" >&2; fail=1; }
[ -f "$SKILL" ] || { echo "FAIL: missing $SKILL" >&2; exit 1; }

FRONT="$(awk 'NR == 1 && /^---$/ { on = 1; next } on && /^---$/ { exit } on { print }' "$SKILL")"
ALLOWED="$(grep '^allowed-tools:' <<< "$FRONT")"
for tool in 'Agent' 'SendMessage' 'spawn_agent' 'wait_agent' \
  'Bash(sh core/scripts/conduct-runner-resolve.sh:*)' 'Bash(hq runners create:*)'; do
  grep -Fq "$tool" <<< "$ALLOWED" || bad "allowed-tools lacks $tool"
done

# section <exact heading line>: print the section up to the next heading of the same or higher level
section() {
  awk -v h="$1" '
    $0 == h { on = 1; split(h, p, " "); lvl = length(p[1]); print; next }
    on && /^#+ / { split($0, q, " "); if (length(q[1]) <= lvl) exit }
    on { print }
  ' "$SKILL"
}

# --- step 5: resolve and record the runner ---
STEP5="$(section '### 5. Initialize Execution State')"
[ -n "$STEP5" ] || bad "step 5 missing"
grep -Fq 'sh core/scripts/conduct-runner-resolve.sh --session-id {session-id}' <<< "$STEP5" \
  || bad "step 5 must resolve the runner with the shared resolver"
grep -Fq '"runner": "subagent|runner"' <<< "$STEP5" || bad "step 5 execution state must record runner"

# --- runtime adapter ---
ADAPTER="$(section '## Runtime Adapter: Phase Runner')"
[ -n "$ADAPTER" ] || bad "Runtime Adapter: Phase Runner section missing"
grep -Fq '**Default (`subagent`):**' <<< "$ADAPTER" || bad "adapter must name the subagent default"
grep -Fq 'In advanced mode, do not substitute `Task`, `spawn_agent`' <<< "$ADAPTER" \
  || bad "the Task/spawn_agent ban must be advanced-only"
grep -Fq 'the parent never runs a phase itself' <<< "$ADAPTER" || bad "adapter must keep the parent-never-runs-a-phase rule"
grep -Fq 'NEEDS_RUNNER' <<< "$ADAPTER" || bad "adapter must block NEEDS_RUNNER"
if grep -q '^## Runtime Adapter: HQ Worker Lanes' "$SKILL"; then bad "old lanes-only adapter heading still present"; fi

# --- 6c split: default before advanced ---
H_DEF='#### 6c-default. Run the Phase on an Agent Subagent'
H_LANES="#### 6c-lanes. Advanced Mode: Create or Continue the Worker's Lane, Then Dispatch"
n_def="$(grep -nxF "$H_DEF" "$SKILL" | head -1 | cut -d: -f1)"
n_lanes="$(grep -nxF "$H_LANES" "$SKILL" | head -1 | cut -d: -f1)"
n_hand="$(grep -nxF '#### 6c (both modes). Record the Handoff' "$SKILL" | head -1 | cut -d: -f1)"
[ -n "$n_def" ] && [ -n "$n_lanes" ] && [ -n "$n_hand" ] || bad "missing 6c-default, 6c-lanes, or handoff heading"
if [ -n "$n_def" ] && [ -n "$n_lanes" ] && [ -n "$n_hand" ]; then
  [ "$n_def" -lt "$n_lanes" ] || bad "6c-default must precede 6c-lanes"
  [ "$n_lanes" -lt "$n_hand" ] || bad "6c-lanes must precede the shared handoff step"
fi

DEF="$(section "$H_DEF")"
if grep -Eq 'hq (runners|lanes)' <<< "$DEF"; then bad "6c-default names hq runners: $(grep -E 'hq (runners|lanes)' <<< "$DEF" | head -1)"; fi
grep -Fq '`Agent` tool' <<< "$DEF" || bad "6c-default must dispatch with the Agent tool"
grep -Fq 'name: "{task.id}-{worker.id}"' <<< "$DEF" || bad "6c-default must name the subagent"
grep -Fq '`spawn_agent` then `wait_agent`' <<< "$DEF" || bad "6c-default must name the Codex path"
grep -Fq '`SendMessage` to its agent id' <<< "$DEF" || bad "6c-default must resume the worker subagent"
grep -Fq '.handoff.json' <<< "$DEF" || bad "6c-default must wait for the handoff file"
grep -Fq 'conduct-subagents/{session-id}/runs.json' <<< "$DEF" || bad "6c-default must record runs.json"
grep -Fq 'NEEDS_RUNNER' <<< "$DEF" || bad "6c-default must block NEEDS_RUNNER"
grep -Fq 'parent can run `/execute-task` from its own session' <<< "$DEF" \
  || bad "6c-default NEEDS_RUNNER must let a /run-project parent run /execute-task itself"

LANES="$(section "$H_LANES")"
for want in 'hq runners create' 'hq runners message' 'hq runners wait' 'last_envelope.ref' '--senior "session:{session-id}"'; do
  grep -Fq -- "$want" <<< "$LANES" || bad "6c-lanes lacks $want"
done
grep -Fq '`runner`' <<< "$LANES" || bad "6c-lanes must say it runs only for conduct.runner runner"

HAND="$(section '#### 6c (both modes). Record the Handoff')"
grep -Fq 'handoffs.jsonl' <<< "$HAND" || bad "shared step must append handoffs.jsonl in both modes"
grep -Eq 'from_worker.*to_worker' <<< "$(tr '\n' ' ' <<< "$HAND")" || bad "shared step must keep the handoff format"

# --- 6c.5 unchanged, 6c.7 uses the split runner ---
grep -Fq 'codex review --uncommitted' "$SKILL" || bad "6c.5 inline codex review must stay"
grep -Fq '4. **Dispatch on the phase runner**' "$SKILL" || bad "6c.7 must dispatch on the split runner"
if grep -Fq 'Dispatch through the worker lane' "$SKILL"; then bad "6c.7 still dispatches through the lane only"; fi

# --- 6d ---
D6="$(section '#### 6d. Process Worker Output')"
grep -Fq "In default mode, read the phase handoff from the subagent's handoff file" <<< "$D6" \
  || bad "6d default must read the handoff file"
grep -Fq "In advanced mode, read the completed lane's latest envelope" <<< "$D6" || bad "6d must keep the envelope read under advanced mode"
grep -Fq 'a `codex-debugger` subagent (6c-default) by default' <<< "$D6" || bad "6d debugger fallback must use the split runner"
grep -Fq 'In advanced mode, HQ lanes records the lane state' <<< "$D6" || bad "6d lane-state bullet must be advanced-only"

# --- 6e.7 ---
grep -qxF '#### 6e.7 Verify the worker committed its work' "$SKILL" || bad "6e.7 must be renamed"
E7="$(section '#### 6e.7 Verify the worker committed its work')"
grep -Fq 'The orchestrator does not commit work for you.' <<< "$E7" || bad "6e.7 must say the orchestrator does not commit"
grep -Fq '`SendMessage` to its subagent' <<< "$E7" || bad "6e.7 must return the commit requirement to the subagent"

# --- Ralph Principle and Rules ---
RALPH="$(section '## Ralph Principle')"
grep -Fq 'One named subagent per worker, resumed across phases' <<< "$RALPH" || bad "Ralph Principle must name the subagent default"
grep -Fq 'In advanced mode' <<< "$RALPH" || bad "Ralph Principle must put lanes under advanced mode"
RULES="$(section '## Rules')"
grep -Fq '**One named subagent per worker, resumed across phases**' <<< "$RULES" || bad "Rules must name the subagent default"
grep -Fq '**In advanced mode, one lane per worker and senior**' <<< "$RULES" || bad "Rules must put the lane rule under advanced mode"

[ "$fail" -eq 0 ] || exit 1
echo "execute-task runner mode: ok"
