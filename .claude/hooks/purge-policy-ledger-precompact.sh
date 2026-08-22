#!/bin/bash
# purge-policy-ledger-precompact.sh — PreCompact.
#
# Autocompact condenses older turns, and the injected <policy-reminder> text
# lives in those turns — so after a compaction the policy bodies are gone from
# context. But the per-session dedup ledger still lists every injected slug as
# "already fired", so inject-policy-on-trigger.sh never re-surfaces them: the
# agent silently loses its guardrails for the rest of the session.
#
# This hook removes THIS session's policy-trigger ledgers (both the per-session
# `once` ledger and the per-turn `always` ledger) just before the compaction.
# With an empty ledger, the next event (the first prompt or Bash after compact)
# re-injects the full SessionStart baseline and every once-per-session policy,
# exactly as at session start.
#
# Scope safety: this ONLY ever deletes the ledgers keyed to the session id in
# the hook payload. If the session id cannot be resolved it deletes nothing —
# it never wipes the whole ledger directory (that would purge other live
# sessions' state). Advisory: always exits 0.
#
# Wired in .claude/settings.json PreCompact, gated by hook-gate.sh under
# "purge-policy-ledger-precompact" (standard + strict profiles).

set -uo pipefail

STDIN_JSON="$(cat 2>/dev/null || echo '{}')"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HQ_ROOT="${HQ_ROOT:-${CLAUDE_PROJECT_DIR:-$(cd "$SCRIPT_DIR/../.." && pwd)}}"

# Resolve session_id from the payload with the same helper the injector uses,
# falling back to jq, then a minimal grep — so the purge still targets the right
# session even on hosts without jq.
SESSION_ID=""
if [ -f "$HQ_ROOT/core/scripts/hook-lib.sh" ]; then
  # shellcheck disable=SC1091
  . "$HQ_ROOT/core/scripts/hook-lib.sh" 2>/dev/null || true
fi
if command -v hq_json_get >/dev/null 2>&1; then
  SESSION_ID="$(printf '%s' "$STDIN_JSON" | hq_json_get session_id 2>/dev/null || true)"
fi
if [ -z "$SESSION_ID" ] && command -v jq >/dev/null 2>&1; then
  SESSION_ID="$(printf '%s' "$STDIN_JSON" | jq -r '.session_id // empty' 2>/dev/null || true)"
fi
if [ -z "$SESSION_ID" ]; then
  SESSION_ID="$(printf '%s' "$STDIN_JSON" \
    | sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
fi

# No session id → target nothing. Never purge the whole directory.
[ -n "$SESSION_ID" ] || exit 0

DIR="$HQ_ROOT/workspace/orchestrator/policy-trigger-state"
rm -f "$DIR/$SESSION_ID.txt" "$DIR/$SESSION_ID.turn.txt" 2>/dev/null || true

exit 0
