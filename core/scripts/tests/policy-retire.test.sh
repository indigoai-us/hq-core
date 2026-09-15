#!/usr/bin/env bash
# hq-core: public
# Regression tests for core/scripts/policy-retire.sh (2026-09-07).
set -euo pipefail
ROOT="${HQ_TEST_ROOT:-$(git rev-parse --show-toplevel)}"; S="$ROOT/core/scripts/policy-retire.sh"
FX="$(mktemp -d)"; trap 'rm -rf "$FX"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
mkdir -p "$FX/personal/policies" "$FX/core/policies" "$FX/companies/acme/policies"
pol() { printf -- '---\nid: %s\ntitle: t\nenforcement: hard\nversion: 2\nwhen: always\non: [SessionStart]\n---\n\n## Rule\n\n%s rule.\n' "$2" "$2" > "$1"; }
pol "$FX/personal/policies/p1.md" p1; pol "$FX/core/policies/c1.md" c1; pol "$FX/companies/acme/policies/a1.md" a1
echo "[1] retire by slug writes status + reason, keeps body"
HQ_ROOT="$FX" HQ_SESSION_ID=sess-r bash "$S" p1 --reason "never fired in 120 days" >/dev/null || fail "retire rc"
grep -q '^status: retired' "$FX/personal/policies/p1.md" || fail "status missing"
grep -q '^retired_reason: "never fired in 120 days"' "$FX/personal/policies/p1.md" || fail "reason missing"
grep -q '^retired_by: sess-r' "$FX/personal/policies/p1.md" || fail "by missing"
grep -q '^p1 rule.' "$FX/personal/policies/p1.md" || fail "body lost"
[ "$(grep -c '^version: 2' "$FX/personal/policies/p1.md")" = 1 ] || fail "other frontmatter lost"
echo "[2] company slug resolves; --reason required; unknown slug -> 3"
HQ_ROOT="$FX" bash "$S" a1 --reason x >/dev/null || fail "company retire"
rc=0; HQ_ROOT="$FX" bash "$S" c1 >/dev/null 2>&1 || rc=$?; [ "$rc" = 2 ] || fail "reason required rc $rc"
rc=0; HQ_ROOT="$FX" bash "$S" nope --reason x >/dev/null 2>&1 || rc=$?; [ "$rc" = 3 ] || fail "unknown rc $rc"
echo "[3] --restore removes the retired fields"
HQ_ROOT="$FX" bash "$S" p1 --restore >/dev/null || fail "restore rc"
grep -q '^status:\|^retired_' "$FX/personal/policies/p1.md" && fail "retired fields remain"
grep -q '^p1 rule.' "$FX/personal/policies/p1.md" || fail "body lost on restore"
echo "[3b] canonical policy validation refuses malformed and duplicate triggers before a retirement write"
printf -- '---\nid: malformed\ntitle: t\nenforcement: hard\nwhen: git push\non: [SessionStart]\n---\n\n## Rule\n\nMalformed rule.\n' > "$FX/personal/policies/malformed.md"
rc=0; HQ_ROOT="$FX" bash "$S" malformed --reason test >/dev/null 2>&1 || rc=$?
[ "$rc" != 0 ] || fail "malformed trigger was retired"
grep -q '^status: retired' "$FX/personal/policies/malformed.md" && fail "malformed policy was modified"
printf -- '---\nid: duplicate-when\ntitle: t\nenforcement: hard\nwhen: git\nwhen: git push\non: [SessionStart]\n---\n\n## Rule\n\nDuplicate when rule.\n' > "$FX/personal/policies/duplicate-when.md"
rc=0; HQ_ROOT="$FX" bash "$S" duplicate-when --reason test >/dev/null 2>&1 || rc=$?
[ "$rc" != 0 ] || fail "duplicate when trigger was retired"
grep -q '^status: retired' "$FX/personal/policies/duplicate-when.md" && fail "duplicate-when policy was modified"
echo "[4] --from-report batch: dry run then --yes"
printf '[{"id":"c1","path":"core/policies/c1.md","candidate_classes":["never-fired"]},{"id":"malformed","path":"personal/policies/malformed.md","candidate_classes":["never-fired"]},{"id":"p1","path":"personal/policies/p1.md","candidate_classes":["dormant"]}]' > "$FX/r.json"
out="$(HQ_ROOT="$FX" bash "$S" --from-report "$FX/r.json" --class never-fired --reason "aged out")"
grep -q 'would retire: c1' <<<"$out" && ! grep -q 'p1' <<<"$out" || fail "dry run: $out"
grep -q '^status: retired' "$FX/core/policies/c1.md" && fail "dry run wrote"
rc=0; out="$(HQ_ROOT="$FX" bash "$S" --from-report "$FX/r.json" --class never-fired --reason "aged out" --yes 2>&1)" || rc=$?
[ "$rc" != 0 ] || fail "batch must fail when a selected policy fails canonical validation: $out"
grep -q '1 retired \[never-fired\]; 1 failed' <<<"$out" || fail "batch reported wrong counts: $out"
grep -q '^retired_reason: "aged out \[never-fired\]"' "$FX/core/policies/c1.md" || fail "batch reason"
grep -q '^status: retired' "$FX/personal/policies/malformed.md" && fail "batch modified malformed policy"
grep -q '^status: retired' "$FX/personal/policies/p1.md" && fail "wrong class retired"
echo "[5] consumers skip retired: bind digest and age report"
mkdir -p "$FX/workspace/sessions/s1" "$FX/workspace/orchestrator/policy-trigger-state"; printf 's1\n' > "$FX/workspace/sessions/.current"
printf 'companies:\n  acme:\n    name: Acme\n' > "$FX/companies/manifest.yaml"
HS="$ROOT/core/scripts/hq-session.sh"; cp -R "$ROOT/core/scripts/lib" "$FX/core/scripts/" 2>/dev/null || true
dig="$(HQ_ROOT="$FX" HQ_HQ_SESSION_NO_CLI=1 bash "$HS" --session-id s1 set company_slug acme 2>/dev/null || true)"
grep -q 'a1' <<<"$dig" && fail "bind digest surfaced a retired policy: $dig"
rep="$(HQ_ROOT="$FX" HQ_POLICY_REPORT_NOW_EPOCH=1800000000 bash "$ROOT/core/scripts/policy-age-report.sh" --json)"
jq -e '[.[].id] | index("c1") == null' <<<"$rep" >/dev/null || fail "age report listed a retired policy"
echo "policy-retire: ok"

echo "[6] --auto retires every candidate with a reason and writes a dated report; --dry-run writes nothing"
mkdir -p "$FX/workspace/orchestrator/policy-trigger-state" "$FX/core/scripts"
cp "$ROOT/core/scripts/policy-age-report.sh" "$FX/core/scripts/"
printf -- '---\nid: stale-one\ntitle: t\nenforcement: hard\ncreated: 2026-01-01\nversion: 3\nwhen: always\non: [SessionStart]\n---\n\n## Rule\n\nRun `core/scripts/does-not-exist.sh`.\n' > "$FX/personal/policies/stale-one.md"
printf -- '---\nid: fresh\ntitle: t\nenforcement: hard\ncreated: 2026-01-01\nversion: 3\nwhen: always\non: [SessionStart]\n---\n\n## Rule\n\nfine.\n' > "$FX/personal/policies/fresh.md"
printf 'fresh\n' > "$FX/workspace/orchestrator/policy-trigger-state/z1.txt"
out="$(HQ_ROOT="$FX" bash "$S" --auto --dir "$FX/personal/policies" --dry-run)"
grep -q 'would retire: stale-one' <<<"$out" || fail "dry run: $out"; grep -q '^status: retired' "$FX/personal/policies/stale-one.md" && fail "dry run wrote"
ls "$FX/workspace/reports" 2>/dev/null | grep -q . && fail "dry run wrote a report"
out="$(HQ_ROOT="$FX" bash "$S" --auto --dir "$FX/personal/policies")"
grep -q 'retired: stale-one' <<<"$out" || fail "auto: $out"
grep -q '^retired_reason: "auto: every path the rule depends on is gone' "$FX/personal/policies/stale-one.md" || fail "auto reason: $(head -12 "$FX/personal/policies/stale-one.md")"
# a partly-stale rule is reported as needs-fix, never retired
printf -- '---\nid: partly\ntitle: t\nenforcement: hard\ncreated: 2026-01-01\nversion: 3\nwhen: always\non: [SessionStart]\n---\n\n## Rule\n\nRun `core/scripts/exists.sh` then `core/scripts/gone.sh`.\n' > "$FX/personal/policies/partly.md"
: > "$FX/core/scripts/exists.sh"; printf 'partly\n' >> "$FX/workspace/orchestrator/policy-trigger-state/z1.txt"
HQ_ROOT="$FX" bash "$S" --auto --dir "$FX/personal/policies" >/dev/null || true
grep -q '^status: retired' "$FX/personal/policies/partly.md" && fail "partly-stale rule must not be retired"
grep -rq 'needs-fix (not retired) \*\*partly\*\*' "$FX/workspace/reports/" || fail "partly-stale rule not reported as needs-fix"
grep -q '^status: retired' "$FX/personal/policies/fresh.md" && fail "fresh policy retired"
rep="$(ls "$FX/workspace/reports"/policy-retirement-*.md | head -1)"; [ -n "$rep" ] || fail "no report"
grep -q 'stale-one' "$rep" && grep -q 'human on the loop' "$rep" || fail "report content"
echo "policy-retire --auto: ok"

echo "[6b] --auto reports only successful writes and fails when validation rejects a selected policy"
mkdir -p "$FX/auto-invalid/policies"
printf -- '---\nid: auto-invalid\ntitle: t\nenforcement: hard\ncreated: 2026-01-01\nversion: 3\nwhen: git push\non: [SessionStart]\n---\n\n## Rule\n\nRun `core/scripts/auto-missing.sh`.\n' > "$FX/auto-invalid/policies/auto-invalid.md"
rc=0; out="$(HQ_ROOT="$FX" bash "$S" --auto --dir "$FX/auto-invalid/policies" --report-dir "$FX/auto-invalid/reports" 2>&1)" || rc=$?
[ "$rc" != 0 ] || fail "auto batch must fail when canonical validation rejects a selected policy: $out"
grep -q 'failed: auto-invalid' <<<"$out" || fail "auto batch did not name the failed policy: $out"
grep -q '^status: retired' "$FX/auto-invalid/policies/auto-invalid.md" && fail "auto batch modified malformed policy"
grep -q '0 retired, 1 failed' <<<"$out" || fail "auto batch reported wrong write counts: $out"

echo "[7] a renamed reference (foo.sh -> foo.mjs) is needs-fix, never retired"
printf -- '---\nid: renamed-ref\ntitle: t\nenforcement: hard\ncreated: 2026-01-01\nversion: 2\nwhen: always\non: [SessionStart]\n---\n\n## Rule\n\nRun `core/scripts/mesh.sh`.\n' > "$FX/personal/policies/renamed-ref.md"
: > "$FX/core/scripts/mesh.mjs"; printf 'renamed-ref\n' >> "$FX/workspace/orchestrator/policy-trigger-state/z1.txt"
HQ_ROOT="$FX" bash "$S" --auto --dir "$FX/personal/policies" >/dev/null || true
grep -q '^status: retired' "$FX/personal/policies/renamed-ref.md" && fail "renamed reference retired the rule"
grep -rq 'needs-fix (not retired) \*\*renamed-ref\*\*.*renamed' "$FX/workspace/reports/" || fail "renamed ref not reported as needs-fix"
echo "policy-retire rename detection: ok"

echo "[8] a rule that says NOT to call a deleted script is not stale"
printf -- '---\nid: negated-ref\ntitle: t\nenforcement: hard\ncreated: 2026-01-01\nversion: 2\nwhen: always\non: [SessionStart]\n---\n\n## Rule\n\nAgents MUST NOT call the deleted `core/scripts/old-thing.sh`; use `hq mesh` instead.\n' > "$FX/personal/policies/negated-ref.md"
printf 'negated-ref\n' >> "$FX/workspace/orchestrator/policy-trigger-state/z1.txt"
HQ_ROOT="$FX" bash "$S" --auto --dir "$FX/personal/policies" >/dev/null || true
grep -q '^status: retired' "$FX/personal/policies/negated-ref.md" && fail "negated reference retired the rule"
grep -rq 'negated-ref' "$FX/workspace/reports/" && fail "negated reference reported at all"
echo "policy-retire negation: ok"
