#!/bin/bash
# brainstorm-gate.test.sh — verifies the /brainstorm plan gate.
#
# Checks:
#   - the Plan gate section of brainstorm/SKILL.md lists exactly three options:
#     Plan it now, Upgrade to deep-plan, Stop here
#   - only Step 8 (the plan phase) writes prd.json, and the Rules text says so
#   - the brainstorm question set parses and branches on the Q-mode fact
#   - with the fixture answering Stop here, replaying the gate branch leaves
#     prd.json absent and the board status at brainstormed
#
# Fixture: core/scripts/tests/fixtures/brainstorm-gate/stop-here/

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
SKILL="$REPO_ROOT/.claude/skills/brainstorm/SKILL.md"
QSET="$REPO_ROOT/.claude/skills/_shared/questions/brainstorm.md"
HELPER="$REPO_ROOT/.claude/skills/grilling/frontier.sh"
FIXTURE="$SCRIPT_DIR/fixtures/brainstorm-gate/stop-here"

pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "  PASS: $1"; }
bad() { fail=$((fail + 1)); echo "  FAIL: $1"; }
expect_eq() {
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected '$3', got '$2')"; fi
}

echo "brainstorm-gate.test.sh"

for f in "$SKILL" "$QSET" "$HELPER" "$FIXTURE/gate-answer.txt" "$FIXTURE/brainstorm.md" "$FIXTURE/board.json"; do
  [ -f "$f" ] || { echo "  FAIL: missing $f"; exit 1; }
done

# 1. Gate text: the numbered options under "### Plan gate", up to "Handle the answer".
gate=$(awk '/^### Plan gate/{on=1; next} on && /^Handle the answer/{exit} on' "$SKILL")
[ -n "$gate" ] && ok "Plan gate section present" || bad "Plan gate section present"
options=$(printf '%s\n' "$gate" | grep -E '^[0-9]+\. `' | sed -E 's/^[0-9]+\. `([^`]*)`.*/\1/')
count=$(printf '%s\n' "$options" | grep -c .)
expect_eq "gate has three options" "$count" "3"
expect_eq "gate options in order" "$(printf '%s|' $options | tr -d '\n')" "$(printf '%s|' Plan it now Upgrade to deep-plan Stop here | tr -d '\n')"
grep -q 'one `AskUserQuestion`' <<< "$gate" && ok "gate is one AskUserQuestion" || bad "gate is one AskUserQuestion"

# 2. Each gate answer has a branch; Stop here and Upgrade never write prd.json.
branches=$(awk '/^Handle the answer/{on=1; next} on && /^## /{exit} on' "$SKILL")
for opt in "Plan it now" "Upgrade to deep-plan" "Stop here"; do
  grep -q "^- \*\*$opt\*\*:" <<< "$branches" && ok "branch for $opt" || bad "branch for $opt"
done
stop_line=$(printf '%s\n' "$branches" | grep '^- \*\*Stop here\*\*:')
grep -q 'prd.json is not written' <<< "$stop_line" && ok "Stop here writes no prd.json" || bad "Stop here writes no prd.json"
grep -q '`brainstormed`' <<< "$stop_line" && ok "Stop here keeps board at brainstormed" || bad "Stop here keeps board at brainstormed"
upgrade_line=$(grep '^- \*\*Upgrade to deep-plan\*\*:' <<< "$branches")
grep -q 'Do not write prd.json' <<< "$upgrade_line" \
  && ok "Upgrade writes no prd.json" || bad "Upgrade writes no prd.json"

# 3. Only Step 8 writes prd.json; Rules text updated.
writers=$(grep -n 'Write `{project_dir}/prd.json`' "$SKILL" | cut -d: -f1)
step8=$(grep -n '^## Step 8: Plan Phase' "$SKILL" | cut -d: -f1)
next_h=$(awk -v s="$step8" 'NR>s && /^## /{print NR; exit}' "$SKILL")
in_step8=1
for w in $writers; do { [ "$w" -gt "$step8" ] && [ "$w" -lt "$next_h" ]; } || in_step8=0; done
[ -n "$writers" ] && [ "$in_step8" = 1 ] && ok "prd.json written only in Step 8" || bad "prd.json written only in Step 8"
grep -q "Phases A through C never write prd.json; only the plan phase does, after the gate" "$SKILL" \
  && ok "Rules text updated" || bad "Rules text updated"
grep -q '^- \*\*No prd.json\*\*' "$SKILL" && bad "old No prd.json rule removed" || ok "old No prd.json rule removed"

# 4. Question set parses and branches on Q-mode.
bash "$HELPER" count "$QSET" >/dev/null 2>&1 && ok "question set parses" || bad "question set parses"
grep -q '^## Q-mode' "$QSET" && ok "Q-mode fact present" || bad "Q-mode fact present"
grep -q '^- applies_to: startup' "$QSET" && grep -q '^- applies_to: builder' "$QSET" \
  && ok "STARTUP and BUILDER branches present" || bad "STARTUP and BUILDER branches present"

# 5. Replay the fixture: apply the gate branch the SKILL text prescribes.
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
cp "$FIXTURE/brainstorm.md" "$FIXTURE/board.json" "$tmp/"
answer=$(tr -d '\n' < "$FIXTURE/gate-answer.txt")
expect_eq "fixture answers Stop here" "$answer" "Stop here"
branch=$(printf '%s\n' "$branches" | grep "^- \*\*$answer\*\*:")
if grep -q 'continue to Step 8' <<< "$branch"; then
  echo '{}' > "$tmp/prd.json"
fi
[ ! -e "$tmp/prd.json" ] && ok "prd.json absent after Stop here" || bad "prd.json absent after Stop here"
status=$(sed -E 's/.*"status": "([^"]*)".*/\1/' "$tmp/board.json")
expect_eq "board status after Stop here" "$status" "brainstormed"
grep -q '^status: exploring' "$tmp/brainstorm.md" && ok "brainstorm not promoted" || bad "brainstorm not promoted"

echo "  $pass passed, $fail failed"
[ "$fail" -eq 0 ]
