#!/usr/bin/env bash
# Pins the structured return contract and HQ lanes mapping for story orchestration.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
POLICY="$ROOT/core/policies/ralph-orchestrator-context-discipline.md"
README="$ROOT/core/knowledge/public/workers/README.md"
PASS=0
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { PASS=$((PASS + 1)); echo "  ok — $1"; }
[ -f "$POLICY" ] || fail "missing $POLICY"
[ -f "$README" ] || fail "missing $README"
echo "ralph policy: hard policy remains within injected-body budget"
grep -q '^enforcement: hard' "$POLICY" || fail "policy must stay enforcement: hard"
body="$(awk '/^## Rationale|^## Background|^## Change history|^## Examples|^## References/{exit}{print}' "$POLICY" | wc -c)"
cap="${HQ_POLICY_HARD_RULE_MAX_BYTES:-6144}"
[ "$body" -le "$cap" ] || fail "injected body is $body bytes, over the $cap-byte hard-policy cap"
ok "hard enforcement retained, body is $body/$cap bytes"
echo "ralph policy: structured return and bounded-read requirements survive"
for needle in 'RETURN CONTRACT: json' 'jq -e' 'INVALID_RETURN_FORMAT' 'Retry exactly once' 'Narrate one line per story' 'Never simulate' 'Keep parent log reads bounded' 'budget-aware regression gates'; do
  grep -qi -- "$needle" "$POLICY" || fail "policy lost '$needle'"
done
ok "return contract, retry, narration, no-simulation and bounded reads survive"
echo "ralph policy: rule 6 gives each host its own resume path"
rule6="$(awk '/^6\. /{on=1} on && /^7\. /{exit} on' "$POLICY")"
rule7="$(awk '/^7\. /{on=1} on && /^8\. /{exit} on' "$POLICY")"
grep -q 'In Claude Code, start it with `Agent` and resume it with `SendMessage`' <<<"$rule6" || fail 'rule 6 must scope SendMessage to Claude Code'
grep -q 'Codex has no `SendMessage`' <<<"$rule6" || fail 'rule 6 must say Codex has no SendMessage'
grep -q 'spawn_agent`, passing the worker.s earlier handoff file, and collect it with `wait_agent`' <<<"$rule6" || fail 'rule 6 must give Codex its spawn_agent/wait_agent equivalent'
if grep -q 'Codex `spawn_agent`), and resume that same subagent with `SendMessage`' <<<"$rule6"; then fail 'rule 6 still tells Codex to use SendMessage'; fi
ok "rule 6 resumes with SendMessage in Claude Code and spawn_agent/wait_agent in Codex"
echo "ralph policy: rule 7 carves out the run-project nested-subagent fallback"
grep -q 'when the host forbids nested subagents, the `/run-project` parent runs `/execute-task` itself, one story at a time' <<<"$rule7" || fail 'rule 7 must carve out the run-project parent fallback'
grep -q 'still runs each phase on its worker subagents' <<<"$rule7" || fail 'rule 7 carve-out must keep phases on worker subagents'
ok "rule 7 allows the parent to run /execute-task when nested subagents are off"
echo "ralph policy: lanes are the worker and result source"
grep -qi 'hq runners create' "$POLICY" || fail "rule 6 must create worker lanes"
grep -qi 'hq runners message' "$POLICY" || fail "rule 6 must route live follow-ups through lanes message"
grep -qi 'lane envelopes' "$POLICY" || fail "rule 6 must use lane envelopes for results"
grep -qi 'admission or capacity refusals' "$POLICY" || fail "rule 6 must honor HQ lanes admission"
grep -qi 'serialize on that worker lane' "$POLICY" || fail "same-worker stories must not create a competing live lane"
if grep -qE 'conduct-(pool|inbox|link|reap|lane-status|lane-launch|lane-wait)\.sh|CONDUCT_POOL_CAP' "$POLICY" "$README"; then
  fail "owned policy or worker knowledge still describes conduct pool mechanics"
fi
ok "HQ lanes owns creation, continuation, admission, and result records"
echo "ralph policy: contract still covers all four orchestrators"
when_line="$(grep -m1 '^when:' "$POLICY")"
for t in '/run-project' '/run-pipeline' '/conduct' '/execute-task'; do
  case "$when_line" in *"$t"*) : ;; *) fail "when: does not cover $t — $when_line" ;; esac
done
ok "when: covers run-project, run-pipeline, conduct and execute-task"
echo "workers README: documents HQ lanes and interactive behavior"
grep -qi 'workers persist in HQ lanes' "$README" || fail "README must describe persistent HQ worker lanes"
grep -q 'hq runners message' "$README" || fail "README must describe live-lane follow-ups"
grep -qi 'interactive' "$README" || fail "README must note interactive mode remains parent-driven"
grep -q 'ralph-orchestrator-context-discipline' "$README" || fail "README must link the governing policy"
ok "worker knowledge reflects lane behavior"
echo
printf 'ralph-orchestrator-policy.test.sh: %s checks passed\n' "$PASS"
bash "$(dirname "${BASH_SOURCE[0]}")/hq-load-company-hard-policies-on-mid-session-bind.test.sh"
