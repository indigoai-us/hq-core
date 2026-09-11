#!/usr/bin/env bash
# ralph-orchestrator-policy.test.sh — pins the orchestrator context-discipline
# policy across the move to persistent workers.
#
# This policy is enforcement: hard, so its body is injected verbatim into every
# session it fires in. Two failure directions matter and they pull opposite ways.
# Relaxing it to allow long-lived workers must not quietly drop the JSON return
# contract that is the actual reason it exists; and the spawn-per-story rules it
# replaced must not creep back in, because they contradict the pool the skills
# now depend on.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
POLICY="$ROOT/core/policies/ralph-orchestrator-context-discipline.md"
README="$ROOT/core/knowledge/public/workers/README.md"

PASS=0
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { PASS=$((PASS + 1)); echo "  ok — $1"; }

[ -f "$POLICY" ] || fail "missing $POLICY"

echo "ralph policy: still hard, and still within the injected-body budget"
grep -q '^enforcement: hard' "$POLICY" || fail "policy must stay enforcement: hard"
# Only the text above the first archival heading is injected and counted.
body="$(awk '/^## Rationale|^## Background|^## Change history|^## Examples|^## References/{exit}{print}' "$POLICY" | wc -c)"
cap="${HQ_POLICY_HARD_RULE_MAX_BYTES:-6144}"
[ "$body" -le "$cap" ] || fail "injected body is $body bytes, over the $cap-byte hard-policy cap"
ok "hard enforcement retained, body is $body/$cap bytes"

echo "ralph policy: the JSON return contract is intact"
# These are the load-bearing rules. Loosening the worker-lifetime rules must not
# take them with it.
for needle in \
  'RETURN CONTRACT: json' \
  'jq -e' \
  'INVALID_RETURN_FORMAT' \
  'Retry exactly once' \
  'Narrate one line per story' \
  'Never simulate' \
  'Keep parent log reads bounded' \
  'budget-aware regression gates'
do
  grep -qi -- "$needle" "$POLICY" || fail "the policy lost its '$needle' requirement"
done
ok "return contract, retry, narration, no-simulation and bounded reads all survive"

echo "ralph policy: spawn-per-story is gone and cannot creep back"
if grep -qiE 'one story worker per story' "$POLICY"; then
  fail "policy still mandates one story worker per story — contradicts the session pool"
fi
grep -qi 'one live slot per HQ worker id' "$POLICY" \
  || fail "rule 6 must state one live slot per worker id"
grep -qi 'serialize on that slot' "$POLICY" \
  || fail "rule 8 must say same-worker stories serialize rather than opening a second slot"
ok "rules 6 and 8 describe reused slots, not a child per story"

echo "ralph policy: extra slots still need a trigger or explicit opt-in"
grep -qiE 'high-risk trigger' "$POLICY" \
  || fail "the opt-in gate for extra slots was dropped"
grep -qiE 'stating the token/runtime cost' "$POLICY" \
  || fail "extra slots must still require stating the cost first"
ok "extra capacity is still gated, not free"

echo "ralph policy: the cap is named, not implied"
grep -q 'conduct-pool.sh' "$POLICY" || fail "the policy must name the helper that owns the cap"
grep -q 'CONDUCT_POOL_CAP' "$POLICY" || fail "the policy must name the cap variable"
ok "conduct-pool.sh and CONDUCT_POOL_CAP are both named"

echo "ralph policy: the trigger covers every orchestrator that uses the pool"
when_line="$(grep -m1 '^when:' "$POLICY")"
for t in '/run-project' '/run-pipeline' '/conduct' '/execute-task'; do
  case "$when_line" in *"$t"*) : ;; *) fail "when: does not cover $t — $when_line" ;; esac
done
ok "when: covers run-project, run-pipeline, conduct and execute-task"

echo "ralph policy: the rationale no longer sells fresh-context-per-story"
grep -qi 'no longer the mechanism' "$POLICY" \
  || fail "the rationale must say fresh-context-per-story is no longer the mechanism"
grep -qi 'prompt cache' "$POLICY" \
  || fail "the rationale must name prompt-cache reuse as the point of resuming"
ok "the rationale names parent thinness, JSON returns and the cap instead"

echo "workers README: records the divergence rather than contradicting the policy"
[ -f "$README" ] || fail "missing $README"
grep -q 'Fresh context per task' "$README" \
  || fail "the README no longer states the Ralph principle it is qualifying"
grep -qi 'see the exception below' "$README" \
  || fail "the Ralph bullet must point at the exception instead of reading as absolute"
grep -qi 'workers persist in the session pool' "$README" \
  || fail "the README must record that HQ workers persist"
grep -q 'ralph-orchestrator-context-discipline' "$README" \
  || fail "the README must link the policy that governs this"
grep -qi 'interactive' "$README" \
  || fail "the README must note --interactive is unaffected"
ok "the README qualifies the principle and links the governing policy"

echo
echo "ralph-orchestrator-policy.test.sh: $PASS checks passed"
