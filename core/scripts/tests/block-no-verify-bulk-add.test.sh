#!/usr/bin/env bash
# hq-core: public
#
# Regression test for core/hooks/PreToolUse/30-Bash--block-no-verify-bulk-add.sh.
# Runs every case in core/hook-tests/block-no-verify-bulk-add.yaml against the
# hook directly (the same fixture `hq doctor --deep-test` uses), plus a few
# command shapes that are awkward to put in YAML.
set -u
REAL="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
HOOK="$REAL/core/hooks/PreToolUse/30-Bash--block-no-verify-bulk-add.sh"
FIX="$REAL/core/hook-tests/block-no-verify-bulk-add.yaml"
[ -f "$HOOK" ] || { echo "FAIL: missing $HOOK"; exit 1; }
[ -f "$FIX" ] || { echo "FAIL: missing $FIX"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq is required"; exit 1; }

pass=0; fail=0
run() { # name command expect(block|allow)
  local rc=0 got
  jq -n --arg c "$2" '{tool_name:"Bash",tool_input:{command:$c}}' | env -u HQ_ALLOW_NO_VERIFY bash "$HOOK" >/dev/null 2>&1 || rc=$?
  case "$rc" in 2) got=block ;; 0) got=allow ;; *) got="exit$rc" ;; esac
  if [ "$got" = "$3" ]; then pass=$((pass+1)); echo "ok   $1"; else fail=$((fail+1)); echo "FAIL $1 (want $3, got $got): $2"; fi
}

# Fixture cases: name / command / expect, in file order.
names="$(grep -E '^  - name:' "$FIX" | sed 's/^  - name: *//')"
cmds="$(grep -E '^      command:' "$FIX" | sed 's/^      command: *//; s/^"//; s/"$//')"
exps="$(grep -E '^    expect:' "$FIX" | sed 's/^    expect: *//')"
n="$(printf '%s\n' "$names" | grep -c .)"
[ "$n" -eq "$(printf '%s\n' "$cmds" | grep -c .)" ] && [ "$n" -eq "$(printf '%s\n' "$exps" | grep -c .)" ] || { echo "FAIL: fixture fields out of step"; exit 1; }
i=1
while [ "$i" -le "$n" ]; do
  run "fixture: $(printf '%s\n' "$names" | sed -n "${i}p")" "$(printf '%s\n' "$cmds" | sed -n "${i}p")" "$(printf '%s\n' "$exps" | sed -n "${i}p")"
  i=$((i+1))
done

# The incident's own shape, from purge-one-p2.sh, as an agent would type it.
# shellcheck disable=SC2016 # the $w is part of the command under test
run "incident loop shape" 'for w in /a /b; do git -C "$w" add -A; git -C "$w" commit -q --no-verify -m wip; git -C "$w" push -u origin HEAD; done' block
run "add --all with push is allowed" 'git -C /r add --all && git -C /r commit -m x && git -C /r push' allow
run "add -A then push on next line is allowed" 'git -C /r add -A
git -C /r commit -m x
git -C /r push' allow
run "commit -n inside git -c options" 'git -C /r -c user.name=t commit -n -m x' block
run "push --no-verify after refspec" 'git -C /r push origin HEAD:refs/heads/x --no-verify' block
run "add specific path then push" 'git -C /r add src/a.ts && git -C /r commit -m x && git -C /r push' allow
run "commit then push, no add" 'git -C /r commit -am x && git -C /r push' allow
run "env escape inline" 'HQ_ALLOW_NO_VERIFY=1 git -C /r add -A && git -C /r push' allow
run "gh only" 'gh pr create -R o/r --title t --body b' allow
run "commit -n glued to separator" 'git -C /r commit -m x -n; echo done' block
run "commit -nm bundled with message flag is left alone" 'git -C /r commit -nm x' allow
run "stash push after add -A" 'git -C /r add -A && git -C /r stash push -u -m tag' allow
run "git log mentioning --no-verify" 'git -C /r log --grep=--no-verify' allow

echo "block-no-verify-bulk-add: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
