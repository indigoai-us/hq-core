#!/usr/bin/env bash
# hq-core: public
#
# Regression contract: /learn writes the `company:` frontmatter field for a
# client-scoped rule saved outside a company's own policies directory, so the
# policy reminder (inject-policy-on-trigger.sh, feedback_9eda6433) can skip it
# in sessions locked to other companies. A general rule carries no field, the
# company is never inferred from the policy name or wording, the template line
# copied as is never hides a rule, and the field never hides a hard rule.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SKILL="$ROOT/.claude/skills/learn/SKILL.md"
SPEC="$ROOT/core/knowledge/public/hq-core/policies-spec.md"
HOOK="$ROOT/.claude/hooks/inject-policy-on-trigger.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
has() { grep -qF -- "$2" "$1" || fail "$3: missing '$2' in ${1#"$ROOT"/}"; }

[ -f "$SKILL" ] || fail "learn skill is missing"
[ -f "$SPEC" ] || fail "policies spec is missing"

# The policy template carries the optional field, commented out.
template="$(awk '/^\*\*Policy file format\*\*/{f=1} f&&/^## Rule$/{exit} f' "$SKILL")"
[ -n "$template" ] || fail "learn policy template block not found"
tline="$(grep -E '^# company: <slug>' <<<"$template" || true)"
[ -n "$tline" ] || fail "learn policy template has no commented company: line"
if grep -qE '^compan(y|ies):' <<<"$template"; then
  fail "template has an uncommented company: line"
fi

# Rules for when to write it.
has "$SKILL" '### Company field (client-scoped rules outside a company policies directory)' 'learn documents the company field step'
has "$SKILL" 'Never infer a company from the policy name, slug, or wording' 'learn forbids inferring a company'
has "$SKILL" 'Never write a `company:` line unless Step 3 resolved a company scope' 'learn emits the field only after a resolved scope'
has "$SKILL" 'Omit the field for a general rule' 'learn omits the field for general rules'
has "$SKILL" 'Do not add it to a file in a company policies directory' 'learn skips the field for company policy dirs'
has "$SKILL" 'Never use this field to move a company rule out of' 'learn keeps Step 3 company routing'
has "$SKILL" 'never skips a `hard` or `gate` rule' 'learn keeps hard rules visible'
has "$SKILL" 'exists in `companies/manifest.yaml`' 'learn verifies the slug against the manifest'
has "$SPEC" '`/learn` writes this field' 'policies spec says /learn writes the field'

# Behaviour: run the real reminder hook on policies written per the template.
command -v jq >/dev/null || fail "jq required"
FACT_LIB="$ROOT/core/scripts/lib/trigger-fact-text.awk"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"
cat > "$TMP/bin/hq" <<'HQEOF'
set -euo pipefail
if [ "${1:-}" = "--version" ]; then printf '%s\n' 'hq 5.342.5'; exit 0; fi
text="$(jq -r '.prompt // ""')"
printf '%s\n' "always $(printf '%s\n' "$text" | awk -v mode=all -f "$FAKE_FACT_LIB" | tr '\n' ' ')"
HQEOF
chmod +x "$TMP/bin/hq"

R="$TMP/hq"
P="$R/personal/policies"
CO="$R/companies"
mkdir -p "$R/core/policies" "$P" "$R/core/scripts/lib" "$CO/acme/policies" "$CO/verdanote/policies" \
  "$R/workspace/orchestrator/policy-trigger-state" "$R/.codex/hooks" "$R/workspace/sessions/s1"
cp "$ROOT/core/scripts/lib/session-scope-capability.sh" "$R/core/scripts/lib/"
cp "$ROOT/core/scripts/hqd-hook-flag-cache-lib.sh" "$R/core/scripts/"
printf '%s\n' 'process.stdout.write("true")' > "$R/.codex/hooks/codex-explicit-path-flag.cjs"
printf 'session_id: s1\ncompany_slug: acme\n' > "$R/workspace/sessions/s1/meta.yaml"
printf '{"session_id":"s1","company_slug":"acme","company_slugs":["acme"]}\n' \
  > "$R/workspace/sessions/s1/scope-capability.json"

mk() { # <id> <enforcement> <company line> <marker>
  printf -- '---\nid: %s\nwhen: backfill\non: [UserPromptSubmit]\nenforcement: %s\n%s\n---\n\n## Rule\n\n%s.\n' \
    "$1" "$2" "$3" "$4" > "$P/$1.md"
}
mk general soft "$tline" MARK_GENERAL
mk client-other soft 'company: verdanote' MARK_OTHER
mk client-mine soft 'company: acme' MARK_MINE
mk client-hard hard 'company: verdanote' MARK_HARD

OUT="$(jq -cn '{session_id:"s1",hook_event_name:"UserPromptSubmit",cwd:"/",prompt:"run the backfill"}' \
  | env PATH="$TMP/bin:$PATH" FAKE_FACT_LIB="$FACT_LIB" HQ_ROOT="$R" CLAUDE_PROJECT_DIR="$R" \
      HQ_POLICY_RELEVANCE_CAP=0 HQ_INJECT_PERSONAL_SOFT=1 bash "$HOOK" 2>/dev/null || true)"
case "$OUT" in *MARK_GENERAL*) ;; *) fail "general rule written from the template was hidden: $OUT" ;; esac
case "$OUT" in *MARK_MINE*) ;; *) fail "rule tagged with the locked company was hidden" ;; esac
case "$OUT" in *MARK_HARD*) ;; *) fail "hard rule tagged with another company was hidden" ;; esac
case "$OUT" in *MARK_OTHER*) fail "soft rule tagged with another company surfaced" ;; esac

echo "PASS: learn-company-field"
