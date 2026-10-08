#!/usr/bin/env bash
# build-intent-index.test.sh — the generated intent index lists every shipped
# skill once, skips personal symlinks and company bridge skills in shipped
# scope, includes them in local scope, is idempotent, and --check detects drift.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GEN="$HERE/../build-intent-index.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FIX="$TMP/hq"
mkdir -p "$FIX/.claude/skills" "$FIX/core/settings" "$FIX/companies" "$FIX/personal/skills/mine" "$FIX/.hq/usable-integrations"

mk_skill() { # dir description [extra frontmatter lines...]
  local d="$1" desc="$2"; shift 2
  mkdir -p "$d"
  { printf -- '---\nname: %s\ndescription: %s\n' "$(basename "$d")" "$desc"
    for l in "$@"; do printf '%s\n' "$l"; done
    printf -- '---\n\nBody text that must not be indexed.\ndescription: not this one\n'; } > "$d/SKILL.md"
}

mk_skill "$FIX/.claude/skills/deploy" "Deploy or share generated HQ artifacts." 'argument-hint: "<path> [--public]"'
mk_skill "$FIX/.claude/skills/conduct" '"Orchestrator mode. Triggers: \"/conduct\", \"run it in the background\"."' 'triggers: [conduct, background]'
mk_skill "$FIX/.claude/skills/acme:crm" "Company bridge skill for acme."
mk_skill "$FIX/personal/skills/mine" "A personal skill."
ln -s "$FIX/personal/skills/mine" "$FIX/.claude/skills/mine"
mkdir -p "$FIX/.claude/skills/_shared"; printf 'shared helper\n' > "$FIX/.claude/skills/_shared/notes.md"
mkdir -p "$FIX/.claude/skills/no-skill-md"
printf '{"company":"acme","apps":[{"name":"Slack","selector":"--integration slack"}]}\n' > "$FIX/.hq/usable-integrations/acme.json"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass=0

# 1. shipped scope: content rules
out="$(bash "$GEN" --root "$FIX")"
IDX="$FIX/core/settings/intent-index.yaml"
[ -f "$IDX" ] || fail "shipped index not written"
case "$out" in *"wrote"*) ;; *) fail "first run should report wrote: $out" ;; esac
[ "$(grep -c '^  - name: "/deploy"' "$IDX")" -eq 1 ] || fail "deploy listed once"
[ "$(grep -c '^  - name: "/conduct"' "$IDX")" -eq 1 ] || fail "conduct listed once"
grep -q '^  - name: "/mine"' "$IDX" && fail "personal symlink skill leaked into shipped scope"
grep -q 'acme' "$IDX" && fail "company slug leaked into shipped scope"
grep -q '_shared' "$IDX" && fail "_shared pseudo-dir indexed"
grep -q 'no-skill-md' "$IDX" && fail "dir without SKILL.md indexed"
grep -q 'not this one' "$IDX" && fail "body text indexed as description"
grep -q '^    args: "<path> \[--public\]"' "$IDX" || fail "argument-hint missing"
grep -q '^    triggers: "\[conduct, background\]"' "$IDX" || fail "triggers missing"
grep -q '^    use: "Orchestrator mode. Triggers: \\"/conduct\\", \\"run it in the background\\"."' "$IDX" || fail "quoted description not normalised: $(grep -A1 conduct "$IDX" | tail -1)"
grep -q '^builtins:' "$IDX" && grep -q '^  - name: "integrations"' "$IDX" || fail "builtins section missing"
pass=$((pass+1)); echo "ok 1 shipped scope content"

# 2. idempotent and --check current
before="$(cat "$IDX")"
out2="$(bash "$GEN" --root "$FIX")"
case "$out2" in *"unchanged"*) ;; *) fail "second run should be unchanged: $out2" ;; esac
[ "$before" = "$(cat "$IDX")" ] || fail "second run changed bytes"
bash "$GEN" --root "$FIX" --check >/dev/null || fail "--check should pass when current"
pass=$((pass+1)); echo "ok 2 idempotent"

# 3. --check detects drift after a skill changes
mk_skill "$FIX/.claude/skills/deploy" "Deploy artifacts, now different."
if bash "$GEN" --root "$FIX" --check >/dev/null 2>&1; then fail "--check should fail on drift"; fi
bash "$GEN" --root "$FIX" >/dev/null
grep -q 'now different' "$IDX" || fail "rebuild did not pick up new description"
pass=$((pass+1)); echo "ok 3 check detects drift"

# 4. local scope includes personal + bridge skills and cached integrations
LOCAL="$FIX/workspace/orchestrator/intent-index.yaml"
bash "$GEN" --root "$FIX" --scope local --company acme >/dev/null
[ -f "$LOCAL" ] || fail "local index not written"
grep -q '^  - name: "/mine"' "$LOCAL" || fail "local scope missing personal skill"
grep -q '^  - name: "/acme:crm"' "$LOCAL" || fail "local scope missing bridge skill"
grep -q '^integrations:' "$LOCAL" || fail "local scope missing integrations section"
grep -q '^  - name: "Slack"' "$LOCAL" || fail "cached integration not listed"
grep -q -- '--integration slack' "$LOCAL" || fail "integration selector missing"
bash "$GEN" --root "$FIX" --scope local --company nocache --out "$TMP/nc.yaml" >/dev/null
grep -q 'no cached list' "$TMP/nc.yaml" || fail "missing cache should leave a pointer, not fail"
pass=$((pass+1)); echo "ok 4 local scope"

# 5. bad args
bash "$GEN" --root "$FIX" --scope nope >/dev/null 2>&1 && fail "bad scope accepted"
bash "$GEN" --root "$TMP/empty" >/dev/null 2>&1 && fail "missing skills dir accepted"
pass=$((pass+1)); echo "ok 5 argument errors"

echo "build-intent-index.test.sh: $pass/5 passed"
