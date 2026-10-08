#!/usr/bin/env bash
# learn-lifecycle-fixtures.test.sh — /learn lifecycle stamping (policy-lifecycle US-004).
#
# /learn is a model-executed skill, so this test pins its authoring contract in
# two halves:
#   1. SKILL.md (and its Codex mirror under .agents/skills) states the rules:
#      status: active, public by scope + portability check, retire_when and
#      last_confirmed for workarounds, provenance under ## Provenance.
#   2. A reference renderer that applies exactly those rules turns each fixture
#      learning under fixtures/learn-lifecycle/<case>/learning.json into a policy
#      file, which must equal the committed expected.md byte for byte and pass
#      the validate-policy-frontmatter write hook.
#
# Usage: bash core/scripts/tests/learn-lifecycle-fixtures.test.sh

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
SKILL="$ROOT/.claude/skills/learn/SKILL.md"
MIRROR="$ROOT/.agents/skills/learn/SKILL.md"
FIX="$HERE/fixtures/learn-lifecycle"
VALIDATOR="$ROOT/.claude/hooks/validate-policy-frontmatter.sh"

pass=0; fail=0
ok()  { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; }
has() { if grep -qF -- "$2" "$SKILL"; then ok "$1"; else bad "$1 (missing: $2)"; fi; }

command -v python3 >/dev/null 2>&1 || { echo "python3 is required" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "jq is required" >&2; exit 2; }

# --- 1. SKILL.md states the contract -----------------------------------------
has "template stamps status active" "status: active"
has "template carries retire_when" "retire_when: {workaround rules only"
has "template carries last_confirmed" "last_confirmed: {workaround rules only"
has "template has a Provenance section" "## Provenance"
has "company and repo scopes are never public" "Company- and repo-scoped policies: always \`public: false\`"
has "global public requires the portability check" "hq-public-policy-rule-body-generic"
has "public false records the reason in notes" "with the failing check in \`notes:\`"
has "no confirmation prompt for lifecycle fields" "hq-learn-auto-no-confirmation"
has "rationale keeps only mechanism and trade-offs" "\`## Rationale\` keeps only the mechanism and the"

if grep -qF "and provenance under \`## Rationale\`" "$SKILL"; then
  bad "old provenance-under-Rationale routing removed"
else
  ok "old provenance-under-Rationale routing removed"
fi
n="$(grep -c '^## Provenance$' "$SKILL")"
[ "$n" = "1" ] && ok "Provenance section appears once in the template" || bad "Provenance section count is $n, want 1"

# The lifecycle block adds no AskUserQuestion: the count stays at the pre-US-004 value.
aq="$(grep -c 'AskUserQuestion' "$SKILL")"
[ "$aq" = "0" ] && ok "no AskUserQuestion in the learn skill" || bad "learn skill mentions AskUserQuestion $aq times"

if [ -f "$MIRROR" ] && cmp -s "$SKILL" "$MIRROR"; then
  ok "Codex mirror .agents/skills/learn matches"
else
  bad "Codex mirror .agents/skills/learn differs or is missing"
fi

# --- 2. Fixture runs ----------------------------------------------------------
render() {
  python3 -I - "$1" <<'PY'
import json, re, sys
L = json.load(open(sys.argv[1]))
scope = L["scope"]
kind = scope.split(":", 1)[0]
co = scope.split(":", 1)[1] if ":" in scope else ""

# Portability check from hq-public-policy-rule-body-generic: no HQ-internal
# paths, slugs, or infra names in the Rule body.
INTERNAL_PATH = re.compile(r"(^|[\s`(])(~/|/|\.claude/|(companies|personal|workspace|repos|core)/)")
INFRA = re.compile(r"\b(arn:aws|\d{12}|[a-z0-9-]+\.s3\.|[a-z0-9-]+\.internal)\b")
def portability_reason(rule):
    if INTERNAL_PATH.search(rule):
        return "public false because the Rule names an HQ-internal path"
    if INFRA.search(rule):
        return "public false because the Rule names internal infrastructure"
    return ""

# Workaround classification: a named tool with a version, or defect words.
WORKAROUND = re.compile(r"(\b\d+\.\d+(\.\d+)?\b|\bbug\b|\bdefect\b|\bregression\b|\bworkaround\b|\bupstream issue\b)", re.I)
text = L["title"] + " " + L["rule"]
is_workaround = bool(WORKAROUND.search(text))

prefix = {"global": "hq", "command": "hq-cmd"}.get(kind, co)
enforcement = "hard" if L["source"] == "user-correction" else "soft"
notes = ""
if kind in ("global", "command"):
    notes = portability_reason(L["rule"])
    public = "false" if notes else "true"
else:
    public = "false"

fm = [
    "id: %s-%s" % (prefix, L["slug"]),
    "title: %s" % L["title"],
    "when: %s" % L["when"],
    "on: [PreToolUse, PostToolUse, UserPromptSubmit, AssistantIntent]",
    "enforcement: %s" % enforcement,
    "public: %s" % public,
    "status: active",
    "version: 1",
    "created: %s" % L["today"],
    "updated: %s" % L["today"],
    "source: %s" % L["source"],
]
if notes:
    fm.append("notes: %s" % notes)
if is_workaround:
    fm.append("retire_when: %s" % L["fix_condition"] if "fix_condition" in L else "retire_when: %s" % L["workaround"]["fix_condition"])
    fm.append("last_confirmed: %s" % L["today"])
out = "---\n" + "\n".join(fm) + "\n---\n\n## Rule\n\n" + L["rule"] + "\n\n## Rationale\n\n" + L["mechanism"] + "\n"
if L.get("context"):
    out += "\n## Provenance\n\n" + L["context"] + "\n"
sys.stdout.write(out)
PY
}

cases=0
for dir in "$FIX"/*/; do
  name="$(basename "$dir")"
  cases=$((cases + 1))
  got="$(render "$dir/learning.json")" || { bad "$name: renderer failed"; continue; }
  want="$(cat "$dir/expected.md")"
  if [ "$got" = "$want" ]; then
    ok "$name: rendered policy matches expected.md"
  else
    bad "$name: rendered policy differs from expected.md"
    diff <(printf '%s\n' "$want") <(printf '%s\n' "$got") | sed 's/^/     /'
  fi
  # Rationale must not carry provenance-only detail (dates, ticket/PR numbers).
  rat="$(awk '/^## Rationale$/{f=1;next} /^## /{f=0} f' "$dir/expected.md")"
  if printf '%s\n' "$rat" | grep -Eq '[0-9]{4}-[0-9]{2}-[0-9]{2}|#[0-9]+|[A-Z]+-[0-9]+'; then
    bad "$name: Rationale carries provenance detail"
  else
    ok "$name: Rationale holds mechanism only"
  fi
  # The expected policy must pass the write-time validator as a company/personal policy.
  target="$ROOT/personal/policies/$name.md"
  case "$(jq -r .scope "$dir/learning.json")" in
    company:*) target="$ROOT/companies/acme/policies/$name.md" ;;
  esac
  err="$(jq -n --arg fp "$target" --rawfile c "$dir/expected.md" '{tool_name:"Write",tool_input:{file_path:$fp, content:$c}}' \
    | HQ_ROOT="$ROOT" bash "$VALIDATOR" 2>&1 >/dev/null)"
  if [ $? -eq 0 ]; then ok "$name: expected.md passes validate-policy-frontmatter"; else bad "$name: validator rejected expected.md: $err"; fi
done
[ "$cases" -eq 3 ] && ok "three fixture cases present" || bad "found $cases fixture cases, want 3"

# Spot checks that tie each case to its acceptance criterion.
grep -q '^public: true$' "$FIX/global-portable/expected.md" && ok "global portable -> public: true" || bad "global portable is not public"
grep -q '^public: false$' "$FIX/global-internal-path/expected.md" && grep -q '^notes: ' "$FIX/global-internal-path/expected.md" \
  && ok "global internal path -> public: false with notes" || bad "global internal path not private with notes"
grep -q '^public: false$' "$FIX/company-workaround/expected.md" && grep -q '^retire_when: ' "$FIX/company-workaround/expected.md" \
  && grep -q '^last_confirmed: 2026-10-07$' "$FIX/company-workaround/expected.md" \
  && ok "company workaround -> public false, retire_when, last_confirmed" || bad "company workaround lifecycle fields missing"
if grep -q '^retire_when:' "$FIX/global-portable/expected.md"; then bad "non-workaround carries retire_when"; else ok "non-workaround omits retire_when"; fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
