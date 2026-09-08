#!/usr/bin/env bash
# Regression: selecting a create option must supply the title required by organize.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT
mkdir -p "$SANDBOX/.hq/work-context/sessions"
export WORK_MESH_HOME="$SANDBOX" WORK_MESH_SPOOL="$SANDBOX/spool.jsonl"
export WORK_MESH_SEQ_DIR="$SANDBOX/seq" HQ_ROOT="$ROOT"
unset HQ_SESSION_ID CLAUDE_CODE_SESSION_ID CLAUDE_SESSION_ID CODEX_SESSION_ID CODEX_THREAD_ID || true
unset HQ_WORK_MESH_DISABLED HQ_DISABLED_HOOKS || true
for harness in claude codex grok; do
  sid="create-guidance-$harness"
  cat >"$SANDBOX/.hq/work-context/sessions/$sid.json" <<JSON
{"sessionId":"$sid","decision":{"decisionId":"dec_create","askAfter":true,"options":[{"optionId":"opt_create_project","label":"Create project"},{"optionId":"opt_create_task","label":"Create task"}]}}
JSON
  output="$(HQ_WORK_MESH_HARNESS="$harness" HQ_HARNESS="$harness" bash "$ROOT/core/hooks/UserPromptSubmit/35-work-mesh-turn-start.sh" <<<"{\"session_id\":\"$sid\",\"prompt\":\"please create the approved project\"}")"
  for flag in --create-project --create-task; do
    printf '%s' "$output" | jq -e --arg flag "$flag" \
      '.hookSpecificOutput.additionalContext | contains($flag + " ") and contains("<approved ") and contains("before &&")' >/dev/null
    echo "PASS: $harness emits $flag title guidance"
  done
  printf '%s' "$output" | jq -e \
    '.hookSpecificOutput.additionalContext | contains("canonical project already exists") and contains("exact id")' >/dev/null
  echo "PASS: $harness preserves canonical project identity"
done
