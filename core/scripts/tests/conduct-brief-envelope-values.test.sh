#!/usr/bin/env bash
# Every conduct brief must carry the exact hq-lane-envelope.v1 line: the full
# allowed-key list, the allowed decision and story_status values, the questions
# item shape, and the rules for when questions, blocked_reason,
# story_complete_reason and outcome appear. A brief that listed only the field
# names led subagent-runner workers to write decision "complete", and every
# lane ended envelope_invalid.
#
# The line mirrors hq-cli's lane envelope validator, parseLaneEnvelope in
# src/lib/lanes/types.ts, and parseLaneOutcome in src/lib/lanes/outcome.ts.
# Set HQ_CLI_SRC to an hq-cli checkout root to also compare the key list and
# the decision and story_status values with that checkout's types.ts. Without
# one, only that comparison is skipped, with a note.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
CORE="$ROOT/.claude/skills/_shared/conduct-dispatch-core.md"
ROLES="$ROOT/.claude/skills/conduct/roles"
CONDUCT_DISPATCH="$ROOT/.claude/skills/conduct/dispatch.md"
RUNNERS_DISPATCH="$ROOT/.claude/skills/conduct-runners/dispatch.md"
EXECUTE_TASK="$ROOT/.claude/skills/execute-task/SKILL.md"
RUN_PROJECT="$ROOT/.claude/skills/run-project/SKILL.md"
fail() { echo "FAIL: $*" >&2; exit 1; }

PREFIX='Envelope (hq-lane-envelope.v1): write one JSON object using only these keys: '
KEYS='schema_version, decision, summary, story_status, artifacts, story_complete, story_complete_reason, questions, blocked_reason, next_check_at, fingerprint, outcome'
DECISION_VALUES='"done", "ask", "blocked"'
STATUS_VALUES='"queued", "in_progress", "review", "done"'
DECISIONS="decision is one of $DECISION_VALUES; any other value, such as \"complete\", fails as envelope_invalid."
STATUSES="story_status is one of $STATUS_VALUES."
EXAMPLE='{"id":"q1","question":"Which branch should the fix target?","context":"main and release both carry the bug.","options":["main","release"],"recommended":"main"}'

# Each sentence the line must hold, word for word.
REQUIRED=(
  'schema_version is "hq-lane-envelope.v1".'
  "$DECISIONS"
  "$STATUSES"
  'summary is a non-empty string.'
  'artifacts is an array.'
  'questions is required and non-empty when decision is "ask", and absent otherwise.'
  "Each questions item is an object with question (a non-empty string), context (a non-empty string) and options (an array of strings), plus optional id and recommended (non-empty strings), and no other keys, for example $EXAMPLE."
  'blocked_reason is required and non-empty when decision is "blocked", and absent otherwise.'
  'story_complete is optional and is a boolean; story_complete_reason is required and non-empty when story_complete is present, and absent otherwise.'
  'story_complete true requires story_status "done" and a story_complete_reason that says what was delivered and how it was verified; story_complete false requires another story_status and a reason that says what is still missing.'
  'next_check_at is optional and is an ISO date-time.'
  'fingerprint is optional and is a non-empty string or null.'
  'outcome is optional; include it when the brief or the Executive standing rules (item 9) ask for it, as an object with only state ("done", "needs_decision" or "partial"), outcome (a non-empty string), gathered (an array of {"label","text"} objects with an optional "ref", all non-empty strings), next_steps (an array of non-empty strings, at least one when state is "partial") and an optional decision_id; state "needs_decision" requires decision_id or a non-empty questions array, and state "done" cannot accompany decision "blocked".'
)

[ -f "$CORE" ] || fail "missing $CORE"
count="$(grep -c '^Envelope (hq-lane-envelope.v1): ' "$CORE" || true)"
[ "$count" = 1 ] || fail "shared core must hold exactly one envelope line, found $count"
LINE="$(grep '^Envelope (hq-lane-envelope.v1): ' "$CORE")"

# The key list is exact: no key missing, none added (for example prs).
case "$LINE" in "$PREFIX"*) : ;; *) fail "shared core envelope line does not start with the key-list prefix" ;; esac
rest="${LINE#"$PREFIX"}"
listed="${rest%%. *}"
[ "$listed" = "$KEYS" ] || fail "shared core envelope key list is \"$listed\", expected \"$KEYS\""

for s in "${REQUIRED[@]}"; do
  case "$LINE" in *"$s"*) : ;; *) fail "shared core envelope line is missing: $s" ;; esac
done

# Nothing beyond the pinned sentences: rebuilding the line from them must
# give the line back.
expected="$PREFIX$KEYS."
for s in "${REQUIRED[@]}"; do expected="$expected $s"; done
[ "$LINE" = "$expected" ] || fail "shared core envelope line holds text beyond the pinned sentences"

# The example question is valid JSON with exactly the allowed item keys.
if command -v jq >/dev/null 2>&1; then
  printf '%s' "$EXAMPLE" | jq -e '
    (keys - ["id","question","context","options","recommended"]) == []
    and (.question | type == "string" and length > 0)
    and (.context | type == "string" and length > 0)
    and (.options | type == "array" and all(type == "string"))
    and (.id | type == "string" and length > 0)
    and (.recommended | type == "string" and length > 0)' >/dev/null \
    || fail "example question is not a valid questions item"
fi

grep -F 'verbatim' "$CORE" >/dev/null || fail 'shared core does not require the line verbatim'

n=0
for t in "$ROLES"/*.md; do
  [ -f "$t" ] || continue
  n=$((n + 1))
  c="$(grep -c '^Envelope (hq-lane-envelope.v1): ' "$t" || true)"
  [ "$c" = 1 ] || fail "$(basename "$t") must hold exactly one envelope line, found $c"
  grep -Fx -- "$LINE" "$t" >/dev/null || fail "$(basename "$t") does not carry the shared envelope line verbatim"
done
[ "$n" -ge 6 ] || fail "expected at least 6 role brief templates, found $n"

grep -F 'Copy the envelope line from Step 4 into the brief' "$CONDUCT_DISPATCH" >/dev/null \
  || fail 'conduct/dispatch.md subagent dispatch does not copy the envelope line into the brief'
grep -F 'envelope line from Step 4 of the shared core, copied verbatim' "$RUNNERS_DISPATCH" >/dev/null \
  || fail 'conduct-runners/dispatch.md runner briefs do not carry the envelope line'

# The /execute-task 6c-lanes and /run-project 3L lane briefs carry the same line.
for f in "$EXECUTE_TASK" "$RUN_PROJECT"; do
  [ -f "$f" ] || fail "missing $f"
  c="$(grep -c '^ *Envelope (hq-lane-envelope.v1): ' "$f" || true)"
  [ "$c" = 1 ] || fail "$(basename "$(dirname "$f")")/SKILL.md must hold exactly one envelope line, found $c"
  got="$(grep '^ *Envelope (hq-lane-envelope.v1): ' "$f" | sed 's/^ *//')"
  [ "$got" = "$LINE" ] || fail "$(basename "$(dirname "$f")")/SKILL.md lane brief does not carry the shared envelope line verbatim"
done
awk '/^#### 6c-lanes\./{s=1} s&&/^##/&&!/6c-lanes/{exit} s' "$EXECUTE_TASK" \
  | grep -F -- "$LINE" >/dev/null || fail 'execute-task 6c-lanes does not carry the envelope line'
awk '/^### 3L\.b\./{s=1} s&&/^##/&&!/3L\.b\./{exit} s' "$RUN_PROJECT" \
  | grep -F -- "$LINE" >/dev/null || fail 'run-project 3L.b does not carry the envelope line'

# Compare with hq-cli's validator when a checkout is available.
quoted_set() { { grep -o '"[a-z_]*"' || true; } | tr -d '"' | LC_ALL=C sort; }
TYPES="${HQ_CLI_SRC:-}/src/lib/lanes/types.ts"
if [ -n "${HQ_CLI_SRC:-}" ] && [ -f "$TYPES" ]; then
  src_keys="$(awk '/export function parseLaneEnvelope\(/{f=1} f&&/Object\.keys\(raw\)\.filter\(/{g=1} g{print} g&&/\.includes\(key\)/{exit}' "$TYPES" | quoted_set)"
  src_decisions="$(awk '/export const ENVELOPE_DECISIONS = \[/{g=1} g{print} g&&/\] as const;/{exit}' "$TYPES" | quoted_set)"
  src_statuses="$(awk '/export const STORY_STATUSES = \[/{g=1} g{print} g&&/\] as const;/{exit}' "$TYPES" | quoted_set)"
  [ -n "$src_keys" ] || fail "could not read the allowed-key list from parseLaneEnvelope in $TYPES"
  [ -n "$src_decisions" ] || fail "could not read ENVELOPE_DECISIONS from $TYPES"
  [ -n "$src_statuses" ] || fail "could not read STORY_STATUSES from $TYPES"
  line_keys="$(printf '%s' "$KEYS" | tr ',' '\n' | tr -d ' ' | LC_ALL=C sort)"
  line_decisions="$(printf '%s' "$DECISION_VALUES" | quoted_set)"
  line_statuses="$(printf '%s' "$STATUS_VALUES" | quoted_set)"
  [ "$src_keys" = "$line_keys" ] || fail "envelope keys differ from parseLaneEnvelope in $TYPES: hq-cli [$(echo $src_keys)] line [$(echo $line_keys)]"
  [ "$src_decisions" = "$line_decisions" ] || fail "decision values differ from ENVELOPE_DECISIONS in $TYPES: hq-cli [$(echo $src_decisions)] line [$(echo $line_decisions)]"
  [ "$src_statuses" = "$line_statuses" ] || fail "story_status values differ from STORY_STATUSES in $TYPES: hq-cli [$(echo $src_statuses)] line [$(echo $line_statuses)]"
  echo "hq-cli comparison: keys, decision and story_status values match $TYPES"
else
  echo "NOTE: HQ_CLI_SRC is unset or has no src/lib/lanes/types.ts; skipped only the hq-cli types.ts comparison"
fi

echo "PASS: conduct-brief-envelope-values ($n templates)"
