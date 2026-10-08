#!/usr/bin/env bash
# hq-core: public
# Tests for core/scripts/garden-policy-pass.sh — the /garden policies pass.
# Fixture corpus: six policies, two retire and four stay.
set -euo pipefail
ROOT="${HQ_TEST_ROOT:-$(git rev-parse --show-toplevel)}"
FX="$(mktemp -d)"; FX="$(cd "$FX" && pwd -P)"; trap 'rm -rf "$FX"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
unset HQ_SESSION_ID CLAUDE_PROJECT_DIR
P="$FX/personal/policies"; C="$FX/companies/acme/policies"
mkdir -p "$P" "$C" "$FX/core/policies" "$FX/workspace/orchestrator"
pol() {  # file id extra-frontmatter
  printf -- '---\nid: %s\ntitle: t\nenforcement: hard\nwhen: always\non: [SessionStart]\n%s---\n\n## Rule\n\n%s rule.\n' "$2" "$3" "$2" > "$1"
}
# Now = 2026-10-07. 90 days earlier = 2026-07-09.
NOW=1791331200
# 1 retire: old, never retrieved.
pol "$P/old-unused.md" old-unused $'created: 2026-01-01\n'
# 2 stay: old, retrieved recently.
pol "$P/old-used.md" old-used $'created: 2026-01-01\n'
# 3 stay: young, never retrieved.
pol "$P/young.md" young $'created: 2026-09-01\n'
# 4 retire: superseded, and its replacement is active.
pol "$C/replaced.md" replaced $'created: 2026-09-20\nstatus: superseded\n'
pol "$C/replacement.md" replacement $'created: 2026-09-20\nsupersedes: [replaced]\n'
# 5 stay: superseded, but the replacement is itself retired (not live).
pol "$C/orphan-superseded.md" orphan-superseded $'created: 2026-09-20\nstatus: superseded\n'
pol "$FX/core/policies/dead-replacement.md" dead-replacement $'created: 2026-09-20\nstatus: retired\nsupersedes: [orphan-superseded]\n'
# 6 stay: has retire_when; the script never judges it on its own.
pol "$C/workaround.md" workaround $'created: 2026-09-20\nretire_when: hq-cli 6.0 ships the native fix\n'
printf '{"policy":"old-used","session":"s1","ts":"2026-09-30T10:00:00Z","via":"read"}\n' > "$FX/workspace/orchestrator/policy-retrieval-ledger.jsonl"
run() { HQ_ROOT="$FX" GARDEN_NOW_EPOCH=$NOW bash "$ROOT/core/scripts/garden-policy-pass.sh" --dir "$P" --dir "$C" "$@"; }

echo "[1] dry run lists exactly the two candidates and writes nothing to policies"
before="$(cat "$P"/*.md "$C"/*.md | shasum)"
out="$(run --dry-run)"
[ "$(grep -c '^would-retire	' <<<"$out")" = 2 ] || fail "want 2 candidates: $out"
grep -q '^would-retire	old-unused	' <<<"$out" || fail "old-unused not selected: $out"
grep -q '^would-retire	replaced	' <<<"$out" || fail "replaced not selected: $out"
grep -q '^judge	workaround	' <<<"$out" || fail "workaround not listed for judgment: $out"
for keep in old-used young orphan-superseded replacement; do
  grep -q "^would-retire	$keep	" <<<"$out" && fail "$keep selected"
done
[ "$(cat "$P"/*.md "$C"/*.md | shasum)" = "$before" ] || fail "dry run modified policies"
grep -q 'Dry run: evaluated 7 policies; 2 would be retired' <<<"$out" || fail "dry summary: $out"
[ -f "$FX/workspace/reports/garden/policies-2026-10-07.md" ] || fail "no dry-run report"

echo "[2] live run retires the two through policy-retire.sh, keeps files in place"
out="$(run)"
grep -q 'Evaluated 7 policies; retired 2; 0 failed' <<<"$out" || fail "live summary: $out"
f="$P/old-unused.md"
grep -q '^status: retired' "$f" && grep -q '^retired_at:' "$f" && grep -q '^retired_by: garden-policy-pass' "$f" \
  && grep -q '^retired_reason: "garden: no retrievals in 90 days' "$f" || fail "old-unused fields: $(head -14 "$f")"
grep -q '^status: retired' "$C/replaced.md" && grep -q 'retired_reason: "garden: superseded by a live policy' "$C/replaced.md" || fail "replaced fields"
for keep in "$P/old-used.md" "$P/young.md" "$C/orphan-superseded.md" "$C/workaround.md" "$C/replacement.md"; do
  grep -q '^status: retired' "$keep" && fail "$keep retired"
done
[ "$(find "$P" "$C" -name '*.md' | wc -l | tr -d ' ')" = 7 ] || fail "files moved or deleted"
grep -q 'retired | old-unused' "$FX/workspace/reports/garden/policies-2026-10-07.md" || fail "report table"

echo "[3] --retire-when-met retires a judged condition with the reasoning recorded"
run --retire-when-met "workaround=hq-cli 6.0 is installed" >/dev/null
grep -q 'retired_reason: "garden: retire_when met (hq-cli 6.0 ships the native fix): hq-cli 6.0 is installed"' "$C/workaround.md" || fail "judged reason: $(head -14 "$C/workaround.md")"

echo "[4] core/policies is never retired, even when it qualifies"
pol "$FX/core/policies/core-old.md" core-old $'created: 2026-01-01\n'
out="$(HQ_ROOT="$FX" GARDEN_NOW_EPOCH=$NOW bash "$ROOT/core/scripts/garden-policy-pass.sh" --dir "$FX/core/policies")"
grep -q '^skip	core-old	core/policies/core-old.md	core policy' <<<"$out" || fail "core skip: $out"
grep -q '^status: retired' "$FX/core/policies/core-old.md" && fail "core policy retired"
echo "garden-policy-pass: ok"
