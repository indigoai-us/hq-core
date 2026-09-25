#!/usr/bin/env bash
# hq-core: public
# Missing shared fact text must fail with a named error at both call boundaries.
set -euo pipefail

HQ_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
FIXTURE="$(mktemp -d)"
trap 'rm -rf "$FIXTURE"' EXIT
ROOT="$FIXTURE/hq"
mkdir -p "$ROOT/core/scripts/lib" "$ROOT/.claude/hooks" \
  "$ROOT/core/policies" "$ROOT/workspace/orchestrator/policy-trigger-state" \
  "$ROOT/workspace/orchestrator/hook-state"

cp "$HQ_SRC/core/scripts/hook-lib.sh" "$ROOT/core/scripts/"
cp "$HQ_SRC/core/scripts/derive-trigger-facts.sh" "$ROOT/core/scripts/"
cp "$HQ_SRC/core/scripts/eval-trigger.sh" "$ROOT/core/scripts/"
cp "$HQ_SRC/core/scripts/lib/trigger-fact-text.awk" "$ROOT/core/scripts/lib/"
cp "$HQ_SRC/.claude/hooks/inject-policy-on-trigger.sh" "$ROOT/.claude/hooks/"
rm "$ROOT/core/scripts/lib/trigger-fact-text.awk"

payload="$FIXTURE/payload.json"
jq -cn --arg sid "missing-trigger-fact-library-$$" --arg cwd "$ROOT" \
  '{hook_event_name:"UserPromptSubmit",session_id:$sid,cwd:$cwd,prompt:"gh pr create",tool_input:{}}' > "$payload"

expected='ERROR: derive-trigger-facts: missing core/scripts/lib/trigger-fact-text.awk'
direct_stdout="$FIXTURE/direct.stdout"
direct_stderr="$FIXTURE/direct.stderr"
direct_status=0
bash "$ROOT/core/scripts/derive-trigger-facts.sh" UserPromptSubmit \
  < "$payload" > "$direct_stdout" 2> "$direct_stderr" || direct_status=$?
[ "$direct_status" -ne 0 ] || { echo "FAIL: derive-trigger-facts succeeded without its shared AWK helper" >&2; exit 1; }
grep -Fxq "$expected" "$direct_stderr" || { echo "FAIL: derive-trigger-facts omitted the named missing-helper error" >&2; exit 1; }

inject_stdout="$FIXTURE/inject.stdout"
inject_stderr="$FIXTURE/inject.stderr"
inject_status=0
env HQ_ROOT="$ROOT" CLAUDE_PROJECT_DIR="$ROOT" \
  bash "$ROOT/.claude/hooks/inject-policy-on-trigger.sh" \
  < "$payload" > "$inject_stdout" 2> "$inject_stderr" || inject_status=$?
[ "$inject_status" -eq 0 ] || { echo "FAIL: advisory injector changed its exit status ($inject_status)" >&2; exit 1; }
grep -Fxq "$expected" "$inject_stderr" || { echo "FAIL: injector swallowed the missing-helper error" >&2; exit 1; }

echo "derive-trigger-facts-library-fail-closed: ok"
