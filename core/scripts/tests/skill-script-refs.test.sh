#!/usr/bin/env bash
# Regression coverage for local files referenced by shipped skills. Skills must
# not document scripts removed with a retired workflow or link to policy files
# outside the release tree. The checker must reject broken fixtures, then pass
# against every shipped skill.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
LINT="$ROOT/core/scripts/lint-skill-script-refs.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
run_lint_in() { ( cd "$1" && bash "$LINT" "$2" ); }

[[ -f "$LINT" ]] || fail "linter missing: $LINT"

FX="$TMP/scaffold"
mkdir -p "$FX/.claude/skills/demo" "$FX/core/scripts"
printf '# demo\nRun `bash core/scripts/live.sh`.\n' > "$FX/.claude/skills/demo/SKILL.md"
printf '#!/usr/bin/env bash\nexit 0\n' > "$FX/core/scripts/live.sh"

out="$(run_lint_in "$FX" demo 2>&1)" || fail "Case A: valid local script references should pass; got:\n${out}"
printf '%s\n' "$out" | grep -q '^OK:' || fail "Case A: expected OK output; got:\n${out}"

printf '# demo\nRun `bash core/scripts/retired.sh`.\n' > "$FX/.claude/skills/demo/SKILL.md"
if out="$(run_lint_in "$FX" demo 2>&1)"; then
  fail "Case B: missing documented script should fail, but passed:\n${out}"
fi
printf '%s\n' "$out" | grep -q 'core/scripts/retired.sh' \
  || fail "Case B: failure must name the missing script; got:\n${out}"

out="$( ( cd "$ROOT" && bash "$LINT" learn ) 2>&1 )" \
  || fail "Case C: live learn skill contains a stale local script reference:\n${out}"

if grep -qF 'validate-policy-tags.sh' "$ROOT/.claude/skills/learn/SKILL.md"; then
  fail "Case D: learn skill still names the retired policy-tag validator"
fi

# Case E: EVERY shipped skill — not just `learn` — must reference only scripts
# that resolve in a fresh install. This is the gate that would have caught the
# resolve-company.sh regression (a skill guidance referencing a script that
# lived only on an unmerged promote branch) instead of letting four skills ship
# a dead invocation.
e_broken=""
for skill_dir in "$ROOT/.claude/skills"/*/; do
  skill="$(basename "$skill_dir")"
  [[ "$skill" =~ ^[a-z][a-z0-9-]*$ ]] || continue
  [[ -f "$skill_dir/SKILL.md" ]] || continue
  if ! out="$( ( cd "$ROOT" && bash "$LINT" "$skill" ) 2>&1 )"; then
    e_broken+=$'\n'"${out}"
  fi
done
if [[ -n "$e_broken" ]]; then
  fail "Case E: shipped skill(s) reference a missing local script:${e_broken}"
fi

# Case F: the allowlist genuinely exempts a known-pending backbone. A fixture
# skill that references a missing script fails, then passes once that exact ref
# is allowlisted — so the exemption mechanism cannot silently rot into a
# blanket bypass.
FX2="$TMP/allow"
mkdir -p "$FX2/.claude/skills/demo" "$FX2/core/scripts"
printf '# demo\nRun `bash core/scripts/pending.sh`.\n' > "$FX2/.claude/skills/demo/SKILL.md"
if out="$(run_lint_in "$FX2" demo 2>&1)"; then
  fail "Case F: a missing allowlist-candidate should fail before it is listed:\n${out}"
fi
printf 'core/scripts/pending.sh\n' > "$FX2/core/scripts/lint-skill-script-refs.allow"
out="$(run_lint_in "$FX2" demo 2>&1)" || fail "Case F: an allowlisted ref should pass; got:\n${out}"
printf '%s\n' "$out" | grep -q '^OK:' || fail "Case F: expected OK once allowlisted; got:\n${out}"

# Case G: local Markdown policy links are release guidance too. A link to a
# shipped policy passes, while a dangling target fails and names the bad href.
FX3="$TMP/policy-links"
mkdir -p "$FX3/.claude/skills/demo" "$FX3/core/policies"
printf '# policy\n' > "$FX3/core/policies/safety.md"
cat > "$FX3/.claude/skills/demo/SKILL.md" <<'GOODPOLICYF'
# demo
Follow the [safety policy](../../../core/policies/safety.md).
GOODPOLICYF
out="$(run_lint_in "$FX3" demo 2>&1)" \
  || fail "Case G: an existing local policy link should pass; got:\n${out}"

cat > "$FX3/.claude/skills/demo/SKILL.md" <<'BADPOLICYF'
# demo
Follow the [missing policy](../../../core/policies/missing.md).
BADPOLICYF
if out="$(run_lint_in "$FX3" demo 2>&1)"; then
  fail "Case G: a missing local policy link should fail, but passed:\n${out}"
fi
grep -q '../../../core/policies/missing.md' <<<"$out" \
  || fail "Case G: failure must name the missing policy href; got:\n${out}"

echo "PASS: skill-script-refs (scripts + local policy links + all-skills clean + allowlist + WC-17 regression)"
