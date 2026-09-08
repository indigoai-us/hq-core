#!/usr/bin/env bash
# record-policy-retrieval.sh — PostToolUse hook for Read and Bash.
#
# Records when a session actually PULLED a policy's full text: a Read of a
# policy file, or a `qmd get <slug>` / `cat`/`sed` of a policy path in Bash.
# One line per slug per session under
#   workspace/orchestrator/policy-retrieval-state/<session>.txt
#
# Why (2026-09-07): the trigger ledger says a policy was *emitted*; above the
# host's output ceiling that meant nothing. With index-mode injection, the
# agent pulls a rule when it matters — that pull is the usage signal the age
# report and retirement rely on. Non-fatal by design; always exits 0.
set -uo pipefail
{
  INPUT="$(cat 2>/dev/null || echo '{}')"
  command -v jq >/dev/null 2>&1 || exit 0
  TOOL="$(printf '%s' "$INPUT" | jq -r '.tool_name // empty')"
  SID="$(printf '%s' "$INPUT" | jq -r '.session_id // empty' | tr -d '\n' | tr -c 'A-Za-z0-9._-' '_')"
  [ -n "$SID" ] || exit 0
  HQ_ROOT="${HQ_ROOT:-${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}}"
  refs=""
  case "$TOOL" in
    Read)
      p="$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // empty')"
      case "$p" in *"/policies/"*.md) refs="$p" ;; esac ;;
    Bash)
      cmd="$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty')"
      refs="$(printf '%s' "$cmd" | grep -oE '[A-Za-z0-9_./-]*/policies/[A-Za-z0-9_.-]+\.md' || true)
$(printf '%s' "$cmd" | grep -oE 'qmd[[:space:]]+get[[:space:]]+(-c[[:space:]]+[a-z0-9_-]+[[:space:]]+)?[a-z0-9][a-z0-9-]*' | awk '{print $NF}' || true)" ;;
    *) exit 0 ;;
  esac
  [ -n "$(printf '%s' "$refs" | tr -d '[:space:]')" ] || exit 0
  DIR="$HQ_ROOT/workspace/orchestrator/policy-retrieval-state"; mkdir -p "$DIR" 2>/dev/null || exit 0
  LEDGER="$DIR/$SID.txt"; touch "$LEDGER"
  printf '%s\n' "$refs" | while IFS= read -r r; do
    [ -n "$r" ] || continue
    slug="$(basename "$r" .md)"
    case "$slug" in *" "*|*.conflict-*|README|example-policy|_digest*) continue ;; esac
    grep -qx "$slug" "$LEDGER" 2>/dev/null || printf '%s\n' "$slug" >> "$LEDGER"
  done
} 2>/dev/null || true
exit 0
