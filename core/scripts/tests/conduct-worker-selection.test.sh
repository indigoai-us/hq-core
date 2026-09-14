#!/usr/bin/env bash
# conduct-worker-selection.test.sh — guards the /conduct skill's contract with
# the worker registry and with worker.yaml.
#
# /conduct is prose, so nothing stops it describing a field that does not exist.
# It did: it told the agent to filter workers by `scope`, which the registry has
# never emitted, so the instruction was unfollowable and every worker passed the
# filter that was supposed to enforce tenancy. These checks pin the skill to the
# two schemas it actually reads.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SKILL="$ROOT/.claude/skills/conduct/SKILL.md"

PASS=0
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { PASS=$((PASS + 1)); echo "  ok — $1"; }

[ -f "$SKILL" ] || fail "missing $SKILL"

TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT

# There is deliberately no check that derives the registry schema from a
# registry.yaml on disk. That file is generated, is not tracked here, and when it
# is present in a core-only checkout it legitimately omits the optional `company`
# and `team` keys — so deriving the schema from it would either fail spuriously or
# assert nothing. The generator lives in the hq CLI; the checks below pin the
# skill to the field names and to worker.yaml, which this repo does ship.

echo "conduct: the skill does not filter on a field the registry lacks"
# `scope` is the specific one that was wrong. Guard it by name, and also guard
# the general case for anything the skill claims to read off a registry entry.
# shellcheck disable=SC2016  # a literal pattern, not a shell expansion
if grep -nE '^\s*-\s*`?scope`?\b|whose `?scope`?' "$SKILL" >/dev/null 2>&1; then
  fail "SKILL.md still filters registry entries on 'scope', which is not a registry field"
fi
ok "the stale 'scope' filter is gone"

echo "conduct: the filter names the two fields that actually gate selection"
# shellcheck disable=SC2016  # literal backticks from the markdown, not expansions
grep -qE '`status`|status. is' "$SKILL" || fail "Step 2 no longer filters on status"
# shellcheck disable=SC2016
grep -q '`company`' "$SKILL" || fail "Step 2 no longer filters on company"
ok "Step 2 filters on status and company"

echo "conduct: tenancy is stated as a hard boundary, not a preference"
grep -qiE 'different company|cross-company' "$SKILL" \
  || fail "Step 2 must say a worker from another company is out of scope"
ok "a worker from another company is explicitly refused"

echo "conduct: the worker definition is actually loaded, not just named"
grep -q 'worker\.yaml' "$SKILL" \
  || fail "SKILL.md never reads worker.yaml — the worker id would be a bare pool label again"
ok "the skill reads {path}/worker.yaml"

echo "conduct: every worker.yaml field the skill claims to use really exists"
# Grounding check. The skill names specific fields; at least one shipped worker
# must actually carry each, or the skill is describing a schema nobody writes.
worker_files="$(find "$ROOT/core/workers" -name worker.yaml 2>/dev/null)"
[ -n "$worker_files" ] || fail "no core worker.yaml files to check against"
check_field() {
  local label="$1" pattern="$2"
  printf '%s\n' "$worker_files" | xargs grep -lE "$pattern" >/dev/null 2>&1 \
    || fail "the skill uses '$label' but no shipped worker.yaml declares it"
}
check_field "execution.max_runtime" '^[[:space:]]+max_runtime:'
check_field "skills[].file"          '^[[:space:]]+file:[[:space:]]*skills/'
check_field "verification"           '^verification:'
check_field "context.base"           '^[[:space:]]+base:'
ok "max_runtime, skills[].file, verification and context.base are all real"

echo "conduct: the worker definition is read whole, not truncated"
# The longest shipped definitions run past 220 lines, and their tail is where the
# finalize checklists and approval requirements live — precisely the standing
# instructions this skill promises to carry verbatim. A capped read drops them
# silently, so the skill would contradict itself while looking correct.
longest=0
while IFS= read -r wf; do
  n="$(wc -l < "$wf")"
  [ "$n" -gt "$longest" ] && longest="$n"
done < <(find "$ROOT/core/workers" -name worker.yaml 2>/dev/null)
[ "$longest" -gt 0 ] || fail "no core worker.yaml files found"
if grep -nE "sed -n '1,[0-9]+p' \"?\{path\}/worker\.yaml|head -n? *[0-9]+ .*worker\.yaml" "$SKILL" >/dev/null 2>&1; then
  fail "SKILL.md caps the worker.yaml read; the longest shipped definition is $longest lines"
fi
grep -q 'Read it \*\*whole\*\*' "$SKILL" \
  || fail "SKILL.md must say the definition is read whole"
ok "the definition is read uncapped (longest shipped is $longest lines)"

echo "conduct: context.base paths are resolved before they reach the brief"
# These paths are not uniformly rooted — some are HQ-root relative, some relative
# to core/ — and many are stale. Passed through verbatim they point the lane at
# locations that do not exist.
grep -q 'resolve' "$SKILL" || fail "SKILL.md must resolve context.base before briefing"
grep -qE 'for candidate in' "$SKILL" \
  || fail "SKILL.md lost the context.base resolution loop"
grep -qiE 'resolves nowhere|drop an entry' "$SKILL" \
  || fail "SKILL.md must say an unresolvable context.base entry is dropped, not passed on"
ok "context.base is resolved, and dead entries are dropped"

echo "conduct: that resolution loop is valid shell"
resolver="$TMPD/resolve.sh"
sed -n '/^for p in {context.base entries}; do$/,/^done$/p' "$SKILL" \
  | sed -e 's/{context.base entries}/a b/' -e 's|{path}|/tmp|g' > "$resolver"
[ -s "$resolver" ] || fail "could not extract the context.base resolution loop"
bash -n "$resolver" || fail "the context.base resolution loop is not valid bash"
ok "the resolution loop parses"

echo "conduct: human checkpoints are treated as binding"
grep -qi 'human_checkpoints' "$SKILL" \
  || fail "the skill must carry verification.human_checkpoints into the brief"
grep -qi 'approval_required' "$SKILL" \
  || fail "the skill must honour verification.approval_required"
ok "approval_required and human_checkpoints are carried into the brief"

# The lane launch snippet moved to .claude/skills/_shared/lane-dispatch-protocol.md
# when /run-project started dispatching the same way. Its shell-validity checks
# moved with it, to orchestrator-skills-dispatch-lanes.test.sh — the launch block
# is validated where it now lives, once, rather than from whichever caller
# happens to quote it.

echo
echo "conduct-worker-selection.test.sh: $PASS checks passed"
