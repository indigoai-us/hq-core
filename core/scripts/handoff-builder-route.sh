#!/usr/bin/env bash
# hq-core: public
# handoff-builder-route.sh — decide whether /handoff takes the builder route
# (draft hq-core fixes as a staging PR) or the public route (file feedback),
# and on the builder route write the brief for the visible fix agent.
#
# Usage: handoff-builder-route.sh [--root <hq-root>] [--thread <thread.json>]
#                                 [--brief-out <path>]
#
# Builder test: <root>/repos/private/hq-core-staging is a git repo and
# `git push --dry-run origin HEAD:refs/heads/handoff-fix/route-probe` succeeds.
# Anything else is the public route.
#
# Output (stdout, exit 0 unless arguments are bad):
#   route: builder
#   route: public (<reason>)
# With --thread on the builder route, one more line:
#   brief: <path>                    (hq-core items present; brief written)
#   brief: none (<reason>)
#
# HQ_HANDOFF_BUILDER_ROUTE=0 forces the public route.
# bash 3.2 safe.
set -euo pipefail

ROOT=""
THREAD=""
BRIEF_OUT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --root) ROOT="${2:-}"; shift 2 ;;
    --thread) THREAD="${2:-}"; shift 2 ;;
    --brief-out) BRIEF_OUT="${2:-}"; shift 2 ;;
    *) echo "handoff-builder-route: unknown argument: $1" >&2; exit 2 ;;
  esac
done
if [ -z "$ROOT" ]; then
  ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
fi
if [ -n "$THREAD" ] && [ ! -f "$THREAD" ]; then
  echo "handoff-builder-route: thread not found: $THREAD" >&2
  exit 2
fi

STAGING="$ROOT/repos/private/hq-core-staging"

route_reason=""
if [ "${HQ_HANDOFF_BUILDER_ROUTE:-1}" = "0" ]; then
  route_reason="builder route disabled (HQ_HANDOFF_BUILDER_ROUTE=0)"
elif [ ! -d "$STAGING" ]; then
  route_reason="no hq-core-staging repo"
elif ! git -C "$STAGING" rev-parse --git-dir >/dev/null 2>&1; then
  route_reason="hq-core-staging is not a git repo"
# Never prompt for credentials: a prompt would hang /handoff. --force keeps a
# stale probe branch on the remote from failing the test as non-fast-forward.
elif ! GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND="${GIT_SSH_COMMAND:-ssh} -o BatchMode=yes" \
       git -C "$STAGING" push --dry-run --force --quiet origin \
       HEAD:refs/heads/handoff-fix/route-probe </dev/null >/dev/null 2>&1; then
  route_reason="git push --dry-run to hq-core-staging failed"
fi

if [ -n "$route_reason" ]; then
  echo "route: public ($route_reason)"
  exit 0
fi
echo "route: builder"

[ -n "$THREAD" ] || exit 0

ITEMS="$(jq -c '[(.deficiencies // [])[] | select(.kind == "hq-core")]' "$THREAD")"
if [ "$(jq 'length' <<<"$ITEMS")" -eq 0 ]; then
  echo "brief: none (no hq-core deficiencies)"
  exit 0
fi

THREAD_ID="$(jq -r '.thread_id // empty' "$THREAD")"
[ -n "$THREAD_ID" ] || THREAD_ID="$(basename "$THREAD" .json)"
# Short id: the trailing segment after the last dash, else the first 12 chars.
SHORT_ID="${THREAD_ID##*-}"
[ -n "$SHORT_ID" ] && [ "$SHORT_ID" != "$THREAD_ID" ] || SHORT_ID="$(printf '%s' "$THREAD_ID" | cut -c1-12)"
SHORT_ID="$(printf '%s' "$SHORT_ID" | tr -c 'A-Za-z0-9._-' '-')"
BRANCH="handoff-fix/$SHORT_ID"

if [ -z "$BRIEF_OUT" ]; then
  BRIEF_OUT="$ROOT/workspace/handoff-builder/$SHORT_ID.md"
fi
mkdir -p "$(dirname "$BRIEF_OUT")"

{
  echo "# Handoff builder fix brief"
  echo
  echo "Thread: $THREAD_ID"
  echo "Repo: repos/private/hq-core-staging (GitHub indigoai-us/hq-core-staging)"
  echo "Branch: $BRANCH (create off origin/main)"
  echo
  echo "## Rules"
  echo
  echo "1. Fetch origin, then create $BRANCH off origin/main. Anchor every git command with git -C repos/private/hq-core-staging and every gh command with -R indigoai-us/hq-core-staging."
  echo "2. Apply the fixes below grouped by lever, one commit per lever. Only touch files inside hq-core-staging."
  echo "3. Leave an item out and list it under 'Not applied' with the reason when it has no evidence, the fix is outside hq-core, or its tests fail after the change (revert that item's commit)."
  echo "4. Run the tests named in or next to every touched area (core/scripts/tests/*.test.sh that cover the touched scripts, and the checks .github/workflows/pr-checks.yml runs for those paths), plus the leak scan the repo CI runs. Never skip, loosen, or delete a test."
  echo "5. Push the branch and open exactly one PR against main. The PR body lists each applied deficiency with its lever, summary, and evidence, links thread $THREAD_ID, and has a 'Not applied' section (write 'None' when empty)."
  echo "6. When the diff touches .claude/skills or .claude/commands, add the manual-copy label, then push one more commit so CI reruns with the label."
  echo "7. Never merge, never run gh pr merge, never use --admin, never push to main."
  echo "8. Finish with one line: 'pr: <url>' or 'pr: none (<reason>)'."
  echo
  echo "## Deficiencies"
  echo
  jq -r '
    group_by(.lever // "unknown")[] |
    "### Lever: \(.[0].lever // "unknown")\n" +
    ([.[] |
      "- Summary: \(.summary // "")\n  Severity: \(.severity // "unknown")\n" +
      "  Evidence: \(if ((.evidence // "") | tostring | length) > 0 then (.evidence | tostring) else "NONE (do not apply; list under Not applied)" end)\n" +
      "  Proposed fix: \(.proposed_fix // "")"
    ] | join("\n")) + "\n"
  ' <<<"$ITEMS"
} > "$BRIEF_OUT"

echo "brief: $BRIEF_OUT"
