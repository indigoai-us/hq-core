#!/usr/bin/env bash
# Regression: the /delegate skill must wire the eight tested helpers into a
# single confirmed flow — structural contract on SKILL.md, plus the shipped
# helper scripts it references must exist and be runnable.
#
# Guards:
#   1. Skill exists with scoped frontmatter (name, description,
#      allowed-tools including AskUserQuestion for the confirm/picker).
#   2. Every hq-delegate-*.sh helper is referenced AND exists on disk.
#   3. Ambiguous resolution (exit 3) is handled with a structured picker;
#      not-found stops; never sends blind.
#   4. Exactly-one-confirmation contract: the gated helpers are first run
#      WITHOUT --yes (plan mode), and the confirmation section precedes
#      execution with --yes.
#   5. Decline path: cancel deletes the bundle and mutates nothing.
#   6. Failure path: report the failing step, never claim partial success;
#      probe failure means no DM.
#   7. Dry-run documented as fully inert.
#   8. Humanize pass wired for the DM headline; success report is one plain
#      sentence.
#   9. Both hard policies are stated: no share-session URLs, no secret
#      values.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SKILL="$ROOT/.claude/skills/delegate/SKILL.md"

fail() { echo "FAIL: $*" >&2; exit 1; }

[ -f "$SKILL" ] || fail "missing delegate skill: $SKILL"

# 1. frontmatter
grep -q '^name: delegate$' "$SKILL" || fail "frontmatter must declare name: delegate"
grep -q '^description: ' "$SKILL" || fail "frontmatter must carry a description"
grep -q '^allowed-tools: .*AskUserQuestion' "$SKILL" \
  || fail "allowed-tools must include AskUserQuestion (picker + confirmation)"

# 2. every helper referenced and shipped
for helper in hq-delegate-resolve hq-delegate-bundle hq-delegate-grant \
  hq-delegate-repo hq-delegate-secrets hq-delegate-transfer \
  hq-delegate-verify hq-delegate-send; do
  grep -q "core/scripts/$helper.sh" "$SKILL" \
    || fail "skill must reference core/scripts/$helper.sh"
  [ -f "$ROOT/core/scripts/$helper.sh" ] \
    || fail "referenced helper missing from tree: core/scripts/$helper.sh"
  bash -n "$ROOT/core/scripts/$helper.sh" \
    || fail "helper does not parse: core/scripts/$helper.sh"
done

# 3. resolution outcomes
grep -q 'Exit 3' "$SKILL" || fail "skill must handle the ambiguous (exit 3) outcome"
grep -q 'Exit 4' "$SKILL" || fail "skill must handle the not-found (exit 4) outcome"
grep -qi 'never send blind' "$SKILL" || fail "skill must state it never sends blind"
grep -qi 'single-company' "$SKILL" || fail "skill must state resolution is single-company"

# 4. one-confirmation contract: plan (no --yes) before the gate, --yes after
grep -q 'WITHOUT `--yes`' "$SKILL" || fail "plan collection must run helpers without --yes"
grep -qi 'exactly one structured confirmation\|one structured confirmation (AskUserQuestion) before any mutation' "$SKILL" \
  || fail "skill must promise exactly one confirmation before mutation"
# ordering: the "collect the plan" section must appear before "--yes" execution
PLAN_LINE="$(grep -n 'Collect the plan' "$SKILL" | head -1 | cut -d: -f1)"
EXEC_LINE="$(grep -n -- '--manifest <manifest> --yes' "$SKILL" | head -1 | cut -d: -f1)"
[ -n "$PLAN_LINE" ] && [ -n "$EXEC_LINE" ] && [ "$PLAN_LINE" -lt "$EXEC_LINE" ] \
  || fail "plan collection must precede --yes execution"

# 5. decline path
grep -qi 'On cancel' "$SKILL" || fail "skill must document the cancel path"
grep -q 'delete `workspace/delegations/' "$SKILL" \
  || fail "cancel must delete the bundle"
grep -qi 'confirm nothing was granted' "$SKILL" \
  || fail "cancel must confirm nothing mutated"

# 6. failure semantics
grep -qi 'never claim partial success' "$SKILL" || fail "skill must never claim partial success"
grep -qi 'failed probe means no DM' "$SKILL" || fail "probe failure must block the DM"
grep -qi 'resumes instead of re-granting' "$SKILL" || fail "re-run must resume, not re-grant"

# 7. dry run inert
grep -q -- '--dry-run' "$SKILL" || fail "skill must document --dry-run"
grep -qi 'Nothing is pushed, granted' "$SKILL" \
  || fail "dry run must be documented as fully inert"

# 8. humanize + plain report
grep -q 'humanize-before-send.md' "$SKILL" || fail "DM headline must go through the humanize pass"
grep -qi 'One plain sentence' "$SKILL" || fail "success report must be one plain sentence"

# 9. hard policies
grep -q 'share-session' "$SKILL" || fail "skill must forbid share-session URLs"
grep -q 'hq-delegate-never-inlines-secrets-or-share-urls' "$SKILL" \
  || fail "skill must cite the delegation policy"
grep -qi 'Names only' "$SKILL" || fail "skill must state secret values never move"

echo "hq-delegate-skill: ok (frontmatter scoped, all 8 helpers shipped+referenced, picker/stop resolution, single confirm gate, inert dry-run, fail-closed semantics)"
