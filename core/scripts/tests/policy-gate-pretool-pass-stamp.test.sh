#!/usr/bin/env bash
# hq-core: public
# policy-gate-pretool-pass-stamp.test.sh — on a Bash PreToolUse, master-hook
# runs policy-enforcement-gate.sh from the registry and inject-policy-on-
# trigger.sh used to run it a second time on every call. The registry run now
# leaves a pass stamp (exact payload + byte copies of the match TSV and state
# JSON) when the call is not outbound and matches no gate-fact policy, and the
# selector skips its re-run only when that stamp still matches byte for byte.
#
# Adversarial cases: the second run must still happen, and still block, when
# anything the decision reads could differ.
#   [a] non-outbound call, unchanged inputs: stamp written, re-run skipped
#   [b] the TSV gains a row after the first run: re-run happens
#   [c] the state JSON changes after the first run: re-run happens
#   [d] same tool_use_id but a different command: re-run happens
#   [e] payload without tool_use_id: no stamp, re-run happens
#   [f] outbound command: no stamp; missing receipts still block (exit 2)
#   [g] a gate-fact row in the TSV: no stamp
#   [h] a forged stamp for an outbound payload cannot skip the block:
#       the selector re-runs the gate and the block lands
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
pass=0
fail=0
ok() { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; }

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq unavailable" >&2; exit 0; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/gate-pass-stamp.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
TMP="$(cd "$TMP" && pwd -P)"
FIX="$TMP/hq"
mkdir -p "$FIX/.claude/hooks" "$FIX/core" "$FIX/workspace/orchestrator/policy-enforcement" "$FIX/companies"
cp -R "$ROOT/.claude/hooks/." "$FIX/.claude/hooks/"
cp -R "$ROOT/core/scripts" "$FIX/core/scripts"
mkdir -p "$FIX/core/policies"
printf 'companies: {}\n' > "$FIX/companies/manifest.yaml"

# Count gate invocations: the fixture's gate is a wrapper around the real one.
GATE_LOG="$TMP/gate.log"
mv "$FIX/.claude/hooks/policy-enforcement-gate.sh" "$FIX/.claude/hooks/policy-enforcement-gate.real.sh"
cat > "$FIX/.claude/hooks/policy-enforcement-gate.sh" <<EOF
#!/usr/bin/env bash
printf 'run\n' >> "$GATE_LOG"
exec bash "$FIX/.claude/hooks/policy-enforcement-gate.real.sh" "\$@"
EOF

DIR="$FIX/workspace/orchestrator/policy-enforcement"
SID="stamp-test-session"
EMPTY_STATE='{"prompt":"","requiredSkills":[],"briefs":[],"receipts":{"skills":[],"briefs":[]},"conflicts":[]}'

reset_state() { # <state-json>
  rm -f "$DIR/$SID".* "$GATE_LOG"
  printf '%s\n' "$1" > "$DIR/$SID.json"
  : > "$GATE_LOG"
}
payload() { # <command> [tool_use_id]
  if [ -n "${2:-}" ]; then
    jq -nc --arg sid "$SID" --arg cwd "$FIX" --arg cmd "$1" --arg id "$2" \
      '{session_id:$sid,cwd:$cwd,hook_event_name:"PreToolUse",tool_use_id:$id,tool_name:"Bash",tool_input:{command:$cmd}}'
  else
    jq -nc --arg sid "$SID" --arg cwd "$FIX" --arg cmd "$1" \
      '{session_id:$sid,cwd:$cwd,hook_event_name:"PreToolUse",tool_name:"Bash",tool_input:{command:$cmd}}'
  fi
}
gate() { # <payload> -> rc; output in $TMP/gate.out
  printf '%s' "$1" | env CLAUDE_PROJECT_DIR="$FIX" HQ_ROOT="$FIX" \
    bash "$FIX/.claude/hooks/policy-enforcement-gate.sh" PreToolUse > "$TMP/gate.out" 2>/dev/null
}
selector() { # <payload> -> rc; output in $TMP/sel.out
  printf '%s' "$1" | env CLAUDE_PROJECT_DIR="$FIX" HQ_ROOT="$FIX" HOME="$TMP/home" \
    bash "$FIX/.claude/hooks/inject-policy-on-trigger.sh" > "$TMP/sel.out" 2>/dev/null
}
runs() { grep -c . "$GATE_LOG" 2>/dev/null || printf '0'; }
mkdir -p "$TMP/home"

# [a]
reset_state "$EMPTY_STATE"
P="$(payload 'git status --short' toolu_a1)"
gate "$P"; rc=$?
[ "$rc" -eq 0 ] && [ -f "$DIR/$SID.pretool-pass" ] && ok "[a] registry run passes and writes a stamp" \
  || bad "[a] registry run rc=$rc stamp=$([ -f "$DIR/$SID.pretool-pass" ] && echo yes || echo no)"
selector "$P"
[ "$(runs)" -eq 1 ] && ok "[a] selector skips the identical re-run" || bad "[a] gate ran $(runs) times, want 1"

# [b]
reset_state "$EMPTY_STATE"
P="$(payload 'git status --short' toolu_b1)"
gate "$P"
printf 'late-policy\tcore\t%s/core/policies/late-policy.md\tsoft\trule\treactive\n' "$FIX" >> "$DIR/$SID.policies.tsv"
selector "$P"
[ "$(runs)" -eq 2 ] && ok "[b] a new TSV row forces the re-run" || bad "[b] gate ran $(runs) times, want 2"

# [c]
reset_state "$EMPTY_STATE"
P="$(payload 'git status --short' toolu_c1)"
gate "$P"
printf '%s\n' '{"prompt":"","requiredSkills":["work-broadcast"],"briefs":[],"receipts":{"skills":[],"briefs":[]},"conflicts":[]}' > "$DIR/$SID.json"
selector "$P"
[ "$(runs)" -eq 2 ] && ok "[c] a changed state JSON forces the re-run" || bad "[c] gate ran $(runs) times, want 2"

# [d]
reset_state "$EMPTY_STATE"
gate "$(payload 'git status --short' toolu_d1)"
selector "$(payload 'git log -1' toolu_d1)"
[ "$(runs)" -eq 2 ] && ok "[d] same tool_use_id with another command forces the re-run" || bad "[d] gate ran $(runs) times, want 2"

# [e]
reset_state "$EMPTY_STATE"
P="$(payload 'git status --short')"
gate "$P"
[ ! -f "$DIR/$SID.pretool-pass" ] && ok "[e] no tool_use_id writes no stamp" || bad "[e] stamp written without tool_use_id"
selector "$P"
[ "$(runs)" -eq 2 ] && ok "[e] no tool_use_id keeps the re-run" || bad "[e] gate ran $(runs) times, want 2"

# [f]
reset_state '{"prompt":"","requiredSkills":["work-broadcast"],"briefs":[],"receipts":{"skills":[],"briefs":[]},"conflicts":[]}'
P="$(payload 'hq dm send --channel chn_x hello' toolu_f1)"
gate "$P"; rc=$?
[ "$rc" -eq 2 ] && grep -q 'lacks required receipts' "$TMP/gate.out" \
  && ok "[f] outbound call without receipts still blocks" || bad "[f] outbound rc=$rc"
[ ! -f "$DIR/$SID.pretool-pass" ] && ok "[f] a blocked outbound call writes no stamp" || bad "[f] stamp written on block"

# [g]
reset_state "$EMPTY_STATE"
printf 'fact-policy\tcore\t%s/core/policies/fact-policy.md\tgate\trule\treactive\n' "$FIX" > "$DIR/$SID.policies.tsv"
cat > "$FIX/core/policies/fact-policy.md" <<'MD'
---
id: fact-policy
enforcement: gate
---
## Rule
Fixture.
MD
gate "$(payload 'git status --short' toolu_g1)"
[ ! -f "$DIR/$SID.pretool-pass" ] && ok "[g] a gate-fact policy writes no stamp" || bad "[g] stamp written with a gate-fact row"
rm -f "$FIX/core/policies/fact-policy.md"

# [h]
reset_state '{"prompt":"","requiredSkills":["work-broadcast"],"briefs":[],"receipts":{"skills":[],"briefs":[]},"conflicts":[]}'
P="$(payload 'hq dm send --channel chn_x hello' toolu_h1)"
# Forge a stamp for a non-outbound payload under the same id.
gate "$(payload 'git status --short' toolu_h1)"
: > "$GATE_LOG"
selector "$P"; rc=$?
[ "$(runs)" -eq 1 ] && [ "$rc" -eq 2 ] && ok "[h] a stamp for another payload cannot skip the outbound block" \
  || bad "[h] selector rc=$rc gate runs=$(runs), want rc=2 runs=1"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
