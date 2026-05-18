#!/usr/bin/env bash
# SessionStart hook — surfaces today's (and optionally yesterday's) journal INDEX
# as a system reminder. Lets a fresh continuation session pick up working memory
# without manually reading anything.
#
# Conservative: only surfaces INDEXes that exist; never reads the full entries.
# Agent decides whether to load specific entries via /journal --read <NNN>.
#
# Suppress with HQ_DISABLED_HOOKS=load-journal-index-on-start.

set -uo pipefail

HQ_ROOT="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
JOURNAL_DIR="$HQ_ROOT/workspace/threads/journal"

today=$(date -u +%Y-%m-%d)
yesterday=$(date -u -v-1d +%Y-%m-%d 2>/dev/null \
  || date -u -d '1 day ago' +%Y-%m-%d 2>/dev/null \
  || echo "")

today_idx="$JOURNAL_DIR/$today/INDEX.md"
yesterday_idx=""
[ -n "$yesterday" ] && yesterday_idx="$JOURNAL_DIR/$yesterday/INDEX.md"

# If neither exists, do nothing (silent).
[ ! -f "$today_idx" ] && [ ! -f "$yesterday_idx" ] && exit 0

echo "<journal-index>"
if [ -f "$today_idx" ]; then
  echo "## Today's session journal ($today)"
  cat "$today_idx"
fi
if [ -f "$yesterday_idx" ] && [ ! -f "$today_idx" ]; then
  # Only show yesterday if today's is empty — keep noise down.
  echo "## Yesterday's session journal ($yesterday)"
  cat "$yesterday_idx"
fi
echo
echo "Load specific entries via:  /journal --read <NNN>"
echo "Full spec:  core/knowledge/public/hq-core/journal-spec.md"
echo "</journal-index>"

exit 0
