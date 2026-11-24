#!/usr/bin/env bash
# Structural contract for the native /delegate route and its outcome handling.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SKILL="$ROOT/.claude/skills/delegate/SKILL.md"

fail() { echo "FAIL: $*" >&2; exit 1; }

[ -f "$SKILL" ] || fail "missing delegate skill: $SKILL"
grep -q '^name: delegate$' "$SKILL" || fail "frontmatter must declare name: delegate"
grep -q '^description: ' "$SKILL" || fail "frontmatter must carry a description"
grep -q '^allowed-tools: .*AskUserQuestion' "$SKILL" \
  || fail "allowed-tools must include AskUserQuestion (resolution picker)"

# shellcheck source=../lib/hq-cli-floor.sh
. "$ROOT/core/scripts/lib/hq-cli-floor.sh"
required="$(hq_cli_floor_required "$ROOT")" || fail "staging must declare its CLI floor"
case "$required" in
  '>='*) hq_cli_version_ge "${required#>=}" 5.345.234 \
    || fail "staging must require hq-cli 5.345.234 or newer" ;;
  *) fail "staging CLI floor must use a minimum-version constraint" ;;
esac
# 5.345.241 is the first hq-cli whose native secrets step checks every name
# exists before sharing, reads prd.json metadata.secrets before the repo
# schema, and shares agent and person uids through grantPrincipal (US-029).
grep -Fq 'hq_cli_floor_check delegate 5.345.241' "$SKILL" \
  || fail "the skill must check the 5.345.241 CLI floor before delegation"
grep -Fq 'Upgrade hq-cli to 5.345.241 or newer' "$SKILL" \
  || fail "older installs need an upgrade message"
grep -Fq 'hq core delegate run --company <co> --project <project> --to "<recipient>" [--share] [--no-secrets] [--dry-run]' "$SKILL" \
  || fail "the one-process delegate flow must preserve company, principal and user flags"
FLOOR_LINE="$(grep -nF 'hq_cli_floor_check delegate 5.345.241' "$SKILL" | cut -d: -f1)"
RUN_LINE="$(grep -nF 'hq core delegate run --company' "$SKILL" | cut -d: -f1)"
[ "$FLOOR_LINE" -lt "$RUN_LINE" ] || fail "the version check must precede delegation"
if grep -Eq 'hq-delegate-.*\.sh|Legacy fallback|identified old-CLI failure' "$SKILL"; then
  fail "the skill must have only the native route"
fi

# Kept helpers still serve existing callers and keep their syntax coverage.
for helper in hq-delegate-resolve hq-delegate-bundle hq-delegate-grant \
  hq-delegate-repo hq-delegate-secrets hq-delegate-transfer \
  hq-delegate-verify hq-delegate-send hq-delegate-pickup; do
  [ -f "$ROOT/core/scripts/$helper.sh" ] || fail "retained helper missing: $helper"
  bash -n "$ROOT/core/scripts/$helper.sh" || fail "helper does not parse: $helper"
done

grep -Fq 'Exit 3 with `status: ambiguous`' "$SKILL" || fail "handle ambiguous resolution"
grep -Fq 'with the chosen exact principal' "$SKILL" || fail "rerun only for the selected identity"
grep -Fq 'Exit 4 with `failedStep: resolve`' "$SKILL" || fail "scope not-found handling to resolution"
grep -qi 'never send blind' "$SKILL" || fail "skill must state it never sends blind"
grep -qi 'single-company' "$SKILL" || fail "skill must state resolution is single-company"

grep -Fq 'Exit 0 with `status: sent` or `status: already-sent`' "$SKILL" \
  || fail "new and resumed sends must both reach pickup"
for action in '--ack' '--check' '--status'; do
  grep -Fq -- "hq core delegate pickup --manifest <manifest> $action" "$SKILL" \
    || fail "native pickup must retain $action"
done
grep -Fq 'hq core delegate send --manifest <manifest> --reconcile <eventId>' "$SKILL" \
  || fail "uncertain sends need a native reconciliation path"
grep -qi 'failed probe means no DM' "$SKILL" || fail "probe failure must block the DM"
grep -qi 'never claim partial success' "$SKILL" || fail "skill must report partial failure accurately"
grep -qi 'Never delete' "$SKILL" || fail "skill must keep the bundle on failure"
grep -qi 'resumes instead of re-granting' "$SKILL" || fail "a partial run must resume"

grep -Fq 'Exit 0 with `status: dry-run`' "$SKILL" || fail "handle a successful dry run"
grep -qi 'Nothing is pushed, granted' "$SKILL" || fail "dry run must be inert"
grep -qi 'is the authorization' "$SKILL" || fail "invocation must authorize the native workflow"
grep -qi 'Never ask for permission' "$SKILL" || fail "rules must forbid asking for permission"
if grep -qi 'Proceed\*\* / \*\*Cancel\|Proceed without secrets\|Offer \*\*Proceed\|one structured confirmation' "$SKILL"; then
  fail "skill must not offer a second approval gate"
fi

grep -q 'humanize-before-send.md' "$SKILL" || fail "a custom DM headline still needs the humanize pass"
grep -qi 'One plain sentence' "$SKILL" || fail "success report must be one plain sentence"
grep -q 'hq-delegate-never-inlines-secrets-or-share-urls' "$SKILL" || fail "skill must cite the delegation policy"
grep -qi 'Names only' "$SKILL" || fail "secret values must never move"
grep -qi 'Always hand over the required secrets' "$SKILL" || fail "the default must grant required secret names"

echo "hq-delegate-skill: ok (native flow, CLI floor, scoped resolution, resume, pickup and inert dry run)"
