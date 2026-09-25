#!/usr/bin/env bash
# Regression coverage for large policy-trigger inputs. The base revision passes
# the session ledger and facts through execve, which fails once either value
# crosses Linux MAX_ARG_STRLEN. The fixed path keeps the values in files and
# preserves the existing evaluator and dedupe behavior.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
HOOK="$ROOT/.claude/hooks/inject-policy-on-trigger.sh"
FACT_HELPER="$ROOT/core/scripts/derive-trigger-facts.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

[ -x "$HOOK" ] || fail "inject-policy-on-trigger.sh is not executable"
[ -x "$FACT_HELPER" ] || fail "derive-trigger-facts.sh is not executable"
BASE_FIXTURE="$ROOT/core/scripts/tests/fixtures/inject-policy-arg-size.base.sh"
[ -x "$BASE_FIXTURE" ] || fail "checked-in base fixture is not executable"

mkdir -p \
  "$TMP/core/policies" \
  "$TMP/core/scripts/lib" \
  "$TMP/.claude/hooks" \
  "$TMP/.codex/hooks" \
  "$TMP/.grok/hooks" \
  "$TMP/workspace/orchestrator/policy-trigger-state" \
  "$TMP/workspace/orchestrator/hook-state" \
  "$TMP/workspace/.hook-timeout-journal"

cp "$ROOT/.claude/hooks/hook-gate.sh" "$TMP/.claude/hooks/"
cp "$ROOT/.claude/hooks/inject-policy-on-trigger.sh" "$TMP/.claude/hooks/"
cp "$ROOT/.claude/hooks/hook-timeout-watchdog.sh" "$TMP/.claude/hooks/"
cp "$ROOT/.claude/hooks/hook-timeout-probe.sh" "$TMP/.claude/hooks/"
cp "$ROOT/.codex/hooks/hq-codex-hook-adapter.sh" "$TMP/.codex/hooks/"
cp "$ROOT/.grok/hooks/hq-grok-hook-adapter.sh" "$TMP/.grok/hooks/"
cp "$ROOT/core/scripts/hook-lib.sh" "$TMP/core/scripts/"
cp "$ROOT/core/scripts/lib/hook-adapter-core.sh" "$TMP/core/scripts/lib/"
cp "$ROOT/core/scripts/lib/trigger-fact-text.awk" "$TMP/core/scripts/lib/"
cp "$ROOT/core/scripts/derive-trigger-facts.sh" "$TMP/core/scripts/"
cp "$ROOT/core/scripts/eval-trigger.sh" "$TMP/core/scripts/"
chmod +x \
  "$TMP/.claude/hooks/hook-gate.sh" \
  "$TMP/.claude/hooks/inject-policy-on-trigger.sh" \
  "$TMP/.claude/hooks/hook-timeout-watchdog.sh" \
  "$TMP/.codex/hooks/hq-codex-hook-adapter.sh" \
  "$TMP/.grok/hooks/hq-grok-hook-adapter.sh" \
  "$TMP/core/scripts/derive-trigger-facts.sh" \
  "$TMP/core/scripts/eval-trigger.sh"

# Keep the adapter fixture focused on the registry-dispatched policy hook. The
# real adapters run registry hooks before settings/master hooks; an empty
# settings file keeps unrelated master fan-out out of this deadline test while
# preserving that ordering and the real hook-gate boundary.
cat > "$TMP/.claude/settings.json" <<'EOF'
{"hooks":{}}
EOF
cat > "$TMP/.claude/hooks/hook-registry.json" <<'EOF'
{
  "$schema": "hq-hook-registry@1",
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "id": "inject-policy-on-trigger",
            "script": ".claude/hooks/inject-policy-on-trigger.sh",
            "timeout": 60,
            "gated": true
          }
        ]
      }
    ]
  }
}
EOF

cat > "$TMP/core/policies/large-fact-policy.md" <<'EOF'
---
id: large-fact-policy
enforcement: soft
when: giant_fact_00001
on: [PreToolUse]
---

## Rule
The large-fact policy was evaluated.
EOF

SESSION="large-policy-session"
LEDGER="$TMP/workspace/orchestrator/policy-trigger-state/$SESSION.txt"
JOURNAL="$TMP/workspace/.hook-timeout-journal/session.tsv"
printf 'bash_env_set=unset\ntiming_precision=ms\n' > "$JOURNAL.meta"

write_large_ledger() {
  local ledger_file="${1:-$LEDGER}"
  local i=0
  : > "$ledger_file"
  while [ "$i" -lt 18000 ]; do
    printf 'duplicate-ledger-slug\n' >> "$ledger_file"
    i=$((i + 1))
  done
}

write_large_payload() {
  local i=0
  {
    printf '%s' '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"'
    while [ "$i" -lt 14000 ]; do
      printf 'giant_fact_%05d ' "$i"
      i=$((i + 1))
    done
    printf '%s' '"},"session_id":"large-policy-session"}'
  } > "$TMP/payload.json"
}

write_large_ledger
write_large_payload

ledger_bytes="$(wc -c < "$LEDGER")"
ledger_bytes="${ledger_bytes//[!0-9]/}"
[ "$ledger_bytes" -ge 200000 ] || fail "ledger fixture is only ${ledger_bytes} bytes"

FACTS_FILE="$TMP/facts.txt"
HQ_ROOT="$TMP" CLAUDE_PROJECT_DIR="$TMP" \
  bash "$FACT_HELPER" PreToolUse < "$TMP/payload.json" > "$FACTS_FILE"
facts_bytes="$(LC_ALL=C wc -c < "$FACTS_FILE")"
facts_bytes="${facts_bytes//[!0-9]/}"
[ "$facts_bytes" -ge 200000 ] || fail "facts fixture is only ${facts_bytes} bytes"

run_hook() {
  local hook_file="$1" stdout_file="$2" stderr_file="$3" rc
  set +e
  HQ_ROOT="$TMP" \
    CLAUDE_PROJECT_DIR="$TMP" \
    HQ_HOOK_TIMEOUT_JOURNAL_FILE="$JOURNAL" \
    bash "$hook_file" < "$TMP/payload.json" > "$stdout_file" 2> "$stderr_file"
  rc=$?
  set -e
  return "$rc"
}

# Base-red proof: the checked-in frozen fixture reproduces the retired argv
# handoff without selecting origin/main or HEAD^. It must fail before emitting
# the matching policy once the facts and ledger cross the exec argument limit.
if "$BASE_FIXTURE" "$FACTS_FILE" "$LEDGER" > "$TMP/base.out" 2> "$TMP/base.err"; then
  base_rc=0
else
  base_rc=$?
fi
grep -Fq 'Argument list too long' "$TMP/base.err" \
  || fail "base fixture did not expose the E2BIG failure (rc=$base_rc)"
if grep -Fq 'large-fact-policy' "$TMP/base.out"; then
  fail "base fixture emitted the policy despite E2BIG"
fi

# Candidate proof starts from the same oversized ledger, so a passing result
# exercises both file-backed facts and ledger compaction.
write_large_ledger
if ! run_hook "$HOOK" "$TMP/candidate.out" "$TMP/candidate.err"; then
  fail "candidate hook failed: $(tail -n 5 "$TMP/candidate.err")"
fi
grep -Fq 'large-fact-policy' "$TMP/candidate.out" \
  || fail "candidate did not evaluate the oversized facts and ledger"
if grep -Fq 'Argument list too long' "$TMP/candidate.err"; then
  fail "candidate still hit E2BIG"
fi

compacted_bytes="$(wc -c < "$LEDGER")"
compacted_bytes="${compacted_bytes//[!0-9]/}"
[ "$compacted_bytes" -lt 65536 ] \
  || fail "ledger was not compacted below 64K (size=${compacted_bytes})"
grep -Fxq 'large-fact-policy' "$LEDGER" \
  || fail "candidate did not record the injected policy"

# Dedupe must survive compaction: the same policy does not fire again.
run_hook "$HOOK" "$TMP/second.out" "$TMP/second.err" \
  || fail "second candidate invocation failed: $(tail -n 5 "$TMP/second.err")"
if grep -Fq 'large-fact-policy' "$TMP/second.out"; then
  fail "policy re-injected after ledger compaction"
fi

# Two hooks sharing an oversized session ledger must retain both slugs. Each
# invocation compacts before it records; without one shared lock, the later
# compaction rename can overwrite the other hook's append.
cat > "$TMP/core/policies/race-policy-a.md" <<'EOF'
---
id: race-policy-a
enforcement: soft
when: race_fact_a
on: [PreToolUse]
---

## Rule
The first concurrent ledger policy was evaluated.
EOF
cat > "$TMP/core/policies/race-policy-b.md" <<'EOF'
---
id: race-policy-b
enforcement: soft
when: race_fact_b
on: [PreToolUse]
---

## Rule
The second concurrent ledger policy was evaluated.
EOF
RACE_SESSION="large-policy-race-session"
RACE_LEDGER="$TMP/workspace/orchestrator/policy-trigger-state/$RACE_SESSION.txt"
RACE_PAYLOAD_A="$TMP/race-a.json"
RACE_PAYLOAD_B="$TMP/race-b.json"
jq -n --arg sid "$RACE_SESSION" \
  '{hook_event_name:"PreToolUse",tool_name:"Bash",tool_input:{command:"race_fact_a"},session_id:$sid}' \
  > "$RACE_PAYLOAD_A"
jq -n --arg sid "$RACE_SESSION" \
  '{hook_event_name:"PreToolUse",tool_name:"Bash",tool_input:{command:"race_fact_b"},session_id:$sid}' \
  > "$RACE_PAYLOAD_B"
write_large_ledger "$RACE_LEDGER"
set +e
HQ_ROOT="$TMP" CLAUDE_PROJECT_DIR="$TMP" HQ_HOOK_TIMEOUT_SENTRY=0 \
  HQ_HOOK_TIMEOUT_JOURNAL_FILE="$JOURNAL" timeout 30 bash "$HOOK" \
  < "$RACE_PAYLOAD_A" > "$TMP/race-a.out" 2> "$TMP/race-a.err" &
race_pid_a=$!
HQ_ROOT="$TMP" CLAUDE_PROJECT_DIR="$TMP" HQ_HOOK_TIMEOUT_SENTRY=0 \
  HQ_HOOK_TIMEOUT_JOURNAL_FILE="$JOURNAL" timeout 30 bash "$HOOK" \
  < "$RACE_PAYLOAD_B" > "$TMP/race-b.out" 2> "$TMP/race-b.err" &
race_pid_b=$!
wait "$race_pid_a"
race_rc_a=$?
wait "$race_pid_b"
race_rc_b=$?
set -e
[ "$race_rc_a" -eq 0 ] || fail "first concurrent ledger hook failed (rc=$race_rc_a): $(tail -n 5 "$TMP/race-a.err")"
[ "$race_rc_b" -eq 0 ] || fail "second concurrent ledger hook failed (rc=$race_rc_b): $(tail -n 5 "$TMP/race-b.err")"
grep -Fxq 'race-policy-a' "$RACE_LEDGER" \
  || fail "concurrent compaction/append lost race-policy-a"
grep -Fxq 'race-policy-b' "$RACE_LEDGER" \
  || fail "concurrent compaction/append lost race-policy-b"

run_adapter() {
  local runtime="$1" adapter="$2" sid="$3" size_mode="${4:-large}"
  local payload ledger journal_hash journal_file out err rc
  payload="$TMP/${sid}.json"
  ledger="$TMP/workspace/orchestrator/policy-trigger-state/${sid}.txt"
  out="$TMP/${sid}.out"
  err="$TMP/${sid}.err"
  if [ "$size_mode" = "large" ]; then
    jq --arg sid "$sid" '.session_id = $sid' "$TMP/payload.json" > "$payload"
  else
    jq --arg sid "$sid" --arg cmd "giant_fact_00001" \
      '.session_id = $sid | .tool_input.command = $cmd' \
      "$TMP/payload.json" > "$payload"
  fi
  write_large_ledger "$ledger"
  journal_hash="$(printf '%s\0' "$sid" | sha256sum | awk '{print $1}')"
  journal_file="$TMP/workspace/.hook-timeout-journal/${journal_hash}.tsv"
  printf 'bash_env_set=unset\ntiming_precision=ms\n' > "${journal_file}.meta"
  set +e
  timeout 30 env \
    HQ_ROOT="$TMP" \
    CLAUDE_PROJECT_DIR="$TMP" \
    HQ_HOOK_TIMEOUT_SENTRY=0 \
    HQ_GROK_POLICY_DEBOUNCE_SECS=0 \
    bash "$adapter" < "$payload" > "$out" 2> "$err"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "$runtime adapter exceeded the 30s deadline or failed (rc=$rc): $(tail -n 5 "$err")"
  grep -Fxq 'large-fact-policy' "$ledger" \
    || fail "$runtime adapter did not evaluate and record the large-fact policy"
  grep -Eq $'\tPreToolUse\t[1-9][0-9]*\t1$' \
    "$TMP/workspace/orchestrator/policy-emit-stats/${sid}.txt" \
    || fail "$runtime adapter did not produce policy output before its protocol boundary"
  if grep -Fq 'Argument list too long' "$out" "$err"; then
    fail "$runtime adapter still hit E2BIG"
  fi
  grep -Fxq 'policy_trigger_script=inject-policy-on-trigger.sh' "${journal_file}.meta" \
    || fail "$runtime adapter did not derive its timeout journal path"
  if [ "$size_mode" = "large" ]; then
    grep -Fxq 'facts_bytes_bucket=>128K' "${journal_file}.meta" \
      || fail "$runtime adapter journal missed the oversized facts bucket"
  else
    grep -Fxq 'facts_bytes_bucket=<16K' "${journal_file}.meta" \
      || fail "$runtime adapter journal missed the small facts bucket"
  fi
}

# The registry hook runs through the same adapter/gate path that previously
# preceded master-hook's journal export. Distinct sessions keep each runtime's
# dedupe ledger independent while preserving the 200 KB payload and ledger.
run_adapter codex "$TMP/.codex/hooks/hq-codex-hook-adapter.sh" large-policy-codex-session large
run_adapter grok "$TMP/.grok/hooks/hq-grok-hook-adapter.sh" large-policy-grok-session small

# c015's existing hook-timeout journal metadata receives the size buckets that
# explain a later timeout warning for this policy hook.
grep -Fxq 'policy_trigger_script=inject-policy-on-trigger.sh' "$JOURNAL.meta" \
  || fail "hook-timeout metadata did not name the policy hook"
grep -Fxq 'policy_trigger_event=PreToolUse' "$JOURNAL.meta" \
  || fail "hook-timeout metadata did not record the event"
grep -Fxq 'ledger_bytes_bucket=>128K' "$JOURNAL.meta" \
  || fail "hook-timeout metadata missed the oversized ledger bucket"
grep -Fxq 'facts_bytes_bucket=>128K' "$JOURNAL.meta" \
  || fail "hook-timeout metadata missed the oversized facts bucket"

for fact_file in \
  "$TMP/workspace/orchestrator/hook-state"/.policy-trigger-facts.* \
  "$TMP/workspace/orchestrator/hook-state"/.policy-trigger-input.* \
  "$TMP/workspace/orchestrator/hook-state"/.policy-trigger-pair.*; do
  [ ! -e "$fact_file" ] || fail "spilled policy input file was not cleaned up: $fact_file"
done

echo "ALL PASS: inject-policy-arg-size"
