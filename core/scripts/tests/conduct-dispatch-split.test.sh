#!/usr/bin/env bash
# conduct-dispatch-split.test.sh — /conduct is split into the skill (triage,
# Step 1, Rules) and dispatch.md (lane mechanics). A question-only session
# reads nothing about lanes: the conductor core block, the intent hint, and the
# skill body outside its "needs a lane" section never point at the module, and
# the module itself holds every lane step. Engine resolution happens at first
# dispatch, silently when child_defaults match.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SKILL="$ROOT/.claude/skills/conduct/SKILL.md"
MODULE="$ROOT/.claude/skills/conduct/dispatch.md"
CORE="$ROOT/.claude/skills/conduct/conductor-core.md"
HINT="$ROOT/.claude/hooks/intent-hint.sh"
AUTO="$ROOT/.claude/hooks/auto-conduct.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "  ok — $1"; }
for f in "$SKILL" "$MODULE" "$CORE" "$HINT" "$AUTO"; do [ -f "$f" ] || fail "missing $f"; done

# Body of the skill after the frontmatter (allowed-tools legitimately names
# lane scripts; the prose must not).
body="$(awk 'NR==1 && $0=="---" {fm=1; next} fm && $0=="---" {fm=0; next} !fm' "$SKILL")"

echo "the skill is small and holds triage, Step 1, and Rules"
lines=$(wc -l < "$SKILL" | tr -d ' ')
[ "$lines" -le 160 ] || fail "SKILL.md is $lines lines; the lane mechanics must stay in dispatch.md"
grep -q '^## Step 1: Parse the argument' "$SKILL" || fail "Step 1 left the skill"
grep -q '^## When a task needs a lane' "$SKILL" || fail "the skill has no first-dispatch section"
grep -q '^## Rules' "$SKILL" || fail "Rules left the skill"
grep -q 'conductor-core.md' "$SKILL" || fail "the skill must point at the conductor core for triage"
ok "skill shape"

echo "lane mechanics live only in the module"
for h in '^## Step 2: Choose the worker' '^## Step 3: Assign a pool slot' '^## Step 4: Write the brief' '^## Step 5: Launch the lane, detached' '^## Step 5b: Send a message' '^## Step 6: Read the outcome' '^## Step 7: End every turn' '^## Engine roster' '^## How work leaves this session'; do
  grep -q "$h" "$MODULE" || fail "module lost section $h"
  grep -q "$h" "$SKILL" && fail "section $h is still in the skill"
done
for marker in 'hq-detach.sh' 'agent-1.result.json' 'conduct-inbox.sh send' 'conduct-lane-status.sh' 'lane-rows.html' 'conduct-pool.sh assign' 'worker.yaml'; do
  grep -qF "$marker" "$MODULE" || fail "module never mentions $marker"
  grep -qF "$marker" <<<"$body" && fail "skill prose still carries lane mechanics: $marker"
done
ok "every lane step is in dispatch.md and none in the skill prose"

echo "the module is reached only from the first-dispatch section"
section="$(awk '/^## When a task needs a lane/{on=1} /^## Rules/{on=0} on' "$SKILL")"
grep -q 'dispatch.md' <<<"$section" || fail "the first-dispatch section does not name dispatch.md"
grep -qi 'not loaded for questions, lookups, status' <<<"$section" || fail "the section must say when the module is not read"
outside="$(awk '/^## When a task needs a lane/{on=1} /^## Rules/{on=0} /^## See also/{on=1} !on' "$SKILL")"
grep -q 'dispatch.md' <<<"$outside" && fail "dispatch.md is referenced outside the first-dispatch section and See also"
ok "module reference is scoped"

echo "a question-only session never sees the module"
inject="$(awk '/<!-- inject:start -->/{on=1;next} /<!-- inject:end -->/{on=0} on' "$CORE")"
grep -q 'dispatch.md' <<<"$inject" && fail "the always-on conductor core block names dispatch.md"
grep -q 'dispatch.md' "$AUTO" && fail "auto-conduct.sh names dispatch.md"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/core/scripts" "$TMP/core/settings"
cp "$ROOT/core/scripts/hook-lib.sh" "$TMP/core/scripts/"
cp "$ROOT/core/settings/intent-index.yaml" "$TMP/core/settings/"
out="$(printf '{"session_id":"t","prompt":"what happened in the project where we aged out old policies"}' | HQ_ROOT="$TMP" bash "$HINT")"
grep -q 'dispatch.md' <<<"$out" && fail "intent hint for a question names dispatch.md"
grep -q 'dispatch.md' "$ROOT/core/settings/intent-index.yaml" && fail "the shipped intent index names dispatch.md"
ok "nothing on the question path points at lane mechanics"

echo "engine is resolved at first dispatch, child_defaults silently"
step1="$(awk '/^## Step 1/{on=1} /^## When a task needs a lane/{on=0} on' "$SKILL")"
grep -q 'AskUserQuestion' <<<"$step1" && fail "Step 1 still asks the engine question"
grep -qi 'resolved at first dispatch' <<<"$step1" || fail "Step 1 must defer the engine to first dispatch"
grep -q 'child_defaults' <<<"$section" || fail "first dispatch does not consult child_defaults"
grep -qi 'applied silently' <<<"$section" || fail "a child_defaults match must be applied silently"
grep -q 'AskUserQuestion' <<<"$section" || fail "no-match case must still ask once"
grep -q 'set conduct_engine' <<<"$section" || fail "the resolved engine must be persisted for the session"
ok "engine resolution"

echo "off and status are unchanged"
grep -q 'conduct-pool.sh clear' <<<"$step1" || fail "/conduct off lost its pool clear"
grep -q 'set conduct_engine ""' <<<"$step1" || fail "/conduct off lost its engine reset"
grep -q '`status` →' <<<"$step1" || fail "/conduct status left Step 1"
ok "off and status"

echo "conduct-dispatch-split: all checks passed"
