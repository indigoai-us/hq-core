#!/usr/bin/env bash
# PreCompact hook — fires immediately before autocompact runs.
#
# Surfaces a reminder so the agent can write a journal entry capturing the
# distilled findings/decisions from the current prefix BEFORE the raw
# tool-results disappear into the compacted summary.
#
# Claude Code can't override the autocompact prompt directly, but a PreCompact
# stdout banner becomes a system reminder in the post-compact context — Claude
# sees it and can act on it in the next turn.
#
# Companion to auto-checkpoint-precompact.sh (different focus: that one offers
# checkpoint/handoff/continue; this one asks for a journal entry).
#
# Suppress with HQ_DISABLED_HOOKS=journal-precompact.

set -uo pipefail

HQ_ROOT="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
JOURNAL_HELPER="$HQ_ROOT/core/scripts/session-journal.sh"

# Where is today's INDEX?
index_path=$("$JOURNAL_HELPER" index-path 2>/dev/null || echo "")

cat <<EOF
╔══════════════════════════════════════════════════════════════╗
║  Autocompact about to run — JOURNAL ENTRY RECOMMENDED        ║
╠══════════════════════════════════════════════════════════════╣
║  Raw tool-results in the prefix will be lossy-compressed.    ║
║  Write a journal entry NOW capturing:                        ║
║    • Goal of the current slice of work                       ║
║    • Findings worth recovering (non-obvious things learned)  ║
║    • Decisions made (with rejected alternatives if useful)   ║
║    • What the next slice will pick up                        ║
║                                                              ║
║    /journal "<title>"                                        ║
║                                                              ║
║  Post-compact, raw tool-results are gone — the journal entry ║
║  is what survives. Read it back via /journal --read <NNN>.   ║
╚══════════════════════════════════════════════════════════════╝
EOF

if [ -n "$index_path" ] && [ -f "$index_path" ]; then
  echo
  echo "Today's journal INDEX:"
  cat "$index_path"
fi

exit 0
