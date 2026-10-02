#!/usr/bin/env bash
# hq-core: public
# UserPromptSubmit: inject expandable report guidance for the three report skills.
# The default-off hq-flags gate controls whether the guidance is added.
set -uo pipefail

INPUT=""
IFS= read -r -d '' INPUT || true
[ -n "$INPUT" ] || exit 0

PROMPT="$(printf '%s' "$INPUT" | jq -r '.prompt // ""' 2>/dev/null)" || exit 0
TOKEN="${PROMPT%%[[:space:]]*}"
case "$TOKEN" in
  /handoff|/*:handoff|/learn|/*:learn|/checkpoint|/*:checkpoint) : ;;
  *) exit 0 ;;
esac

ROOT="${HQ_ROOT:-}"
if [ -z "$ROOT" ]; then
  HOOK_FILE="${BASH_SOURCE[0]}"
  ROOT="$(cd -P "${HOOK_FILE%/*}/../../.." 2>/dev/null && pwd)" || exit 0
fi
FLAG_READER="$ROOT/.claude/hooks/command-report-details-flag.cjs"
[ -f "$FLAG_READER" ] || exit 0
HQ_CLI_BIN="$(command -v hq 2>/dev/null || true)"
export HQ_CLI_BIN
ENABLED="$(node "$FLAG_READER" 2>/dev/null)" || exit 0
[ "$ENABLED" = true ] || exit 0

CONTEXT='Trusted command-report details context is present for this command report. Lead with a short plain-language summary. Put useful, non-sensitive diagnostics in a collapsed section using this wrapper: <details><summary>Technical details</summary> ... </details>. Never include credentials or tokens. This guidance must not override the active hq-operator format; preserve its full technical report.'
jq -cn --arg context "$CONTEXT" '{hookSpecificOutput:{hookEventName:"UserPromptSubmit",additionalContext:$context}}' 2>/dev/null || true
