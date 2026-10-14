#!/usr/bin/env bash
# SessionStart hook — surfaces today's (and optionally yesterday's) journal INDEX
# as a system reminder. Lets a fresh continuation session pick up working memory
# without manually reading anything.
#
# Conservative: only surfaces INDEXes that exist; never reads the full entries.
# Agent decides whether to load specific entries via /journal --read <NNN>.
#
# Company scope: only entries tagged with the session's bound company
# (`[company: <slug>]`, written by session-journal.sh) are surfaced. The bound
# company comes from HQ_ACTIVE_COMPANY, else the session meta `company_slug`
# for the payload's session_id. An unbound session gets no entries, so one
# company's working memory never loads into another company's session.
#
# Suppress with HQ_DISABLED_HOOKS=load-journal-index-on-start.

set -uo pipefail

HQ_ROOT="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
JOURNAL_DIR="$HQ_ROOT/workspace/threads/journal"

input=""
[ -t 0 ] || input="$(cat 2>/dev/null || true)"

company="${HQ_ACTIVE_COMPANY:-}"
if [ -z "$company" ] && [ -n "$input" ] && command -v jq >/dev/null 2>&1; then
  session_id="$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null || true)"
  if [[ "$session_id" =~ ^[A-Za-z0-9._-]+$ ]]; then
    meta="$HQ_ROOT/workspace/sessions/$session_id/meta.yaml"
    [ -f "$meta" ] && company="$(sed -nE 's/^company_slug:[[:space:]]*"?([A-Za-z0-9_-]+)"?[[:space:]]*$/\1/p' "$meta" | head -1)"
  fi
fi
[[ "$company" =~ ^[A-Za-z0-9_-]+$ ]] || exit 0

# Prints the bound company's entry lines from an INDEX, nothing else.
company_entries() {
  # The tag is the INDEX line's suffix (session-journal.sh writes it last), so
  # match it only there; a title that mentions another company's tag stays out.
  grep -E -- "^- .*\[company: ${company}\][[:space:]]*$" "$1" 2>/dev/null || true
}

today=$(date -u +%Y-%m-%d)
yesterday=$(date -u -v-1d +%Y-%m-%d 2>/dev/null \
  || date -u -d '1 day ago' +%Y-%m-%d 2>/dev/null \
  || echo "")

today_idx="$JOURNAL_DIR/$today/INDEX.md"
yesterday_idx=""
[ -n "$yesterday" ] && yesterday_idx="$JOURNAL_DIR/$yesterday/INDEX.md"

today_entries=""
[ -f "$today_idx" ] && today_entries="$(company_entries "$today_idx")"
yesterday_entries=""
if [ -z "$today_entries" ] && [ -n "$yesterday_idx" ] && [ -f "$yesterday_idx" ]; then
  yesterday_entries="$(company_entries "$yesterday_idx")"
fi

# Nothing for this company: do nothing (silent).
[ -z "$today_entries" ] && [ -z "$yesterday_entries" ] && exit 0

echo "<journal-index>"
if [ -n "$today_entries" ]; then
  echo "## Today's session journal ($today, company: $company)"
  printf '%s\n' "$today_entries"
else
  # Only show yesterday if today has nothing for this company.
  echo "## Yesterday's session journal ($yesterday, company: $company)"
  printf '%s\n' "$yesterday_entries"
fi
echo
echo "Load specific entries via:  /journal --read <NNN>"
echo "Full spec:  core/knowledge/public/hq-core/journal-spec.md"
echo "</journal-index>"

exit 0
