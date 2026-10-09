#!/usr/bin/env bash
# hq-core: public
# Regression tests for core/scripts/garden-policy-deep.py (/garden policies --deep).
set -euo pipefail
ROOT="${HQ_TEST_ROOT:-$(git rev-parse --show-toplevel)}"
S="$ROOT/core/scripts/garden-policy-deep.py"
FX="$(mktemp -d)"; trap 'rm -rf "$FX"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
run() { HQ_ROOT="$FX" python3 "$S" "$@"; }
mkdir -p "$FX/personal/policies" "$FX/core/policies" "$FX/companies/acme/policies" "$FX/workspace/orchestrator/policy-trigger-state"
pol() { printf -- '---\nid: %s\ntitle: %s\nenforcement: %s\nwhen: git\non: [SessionStart]\n---\n\n## Rule\n\n%s rule.\n' "$2" "$2" "$3" "$2" > "$1"; }
pol "$FX/personal/policies/keep-me.md" keep-me hard
pol "$FX/personal/policies/stale-one.md" stale-one soft
pol "$FX/personal/policies/dup-a.md" dup-a soft
pol "$FX/personal/policies/dup-b.md" dup-b hard
pol "$FX/companies/acme/policies/acme-rule.md" acme-rule soft
pol "$FX/core/policies/core-rule.md" core-rule hard
printf -- '---\ntitle: Broken: colon in title\nenforcement: soft\n---\n\n## Rule\n\nx\n' > "$FX/personal/policies/broken.md"
printf 'generated\n' > "$FX/personal/policies/_digest.md"
printf 'keep-me\nstale-one\n' > "$FX/workspace/orchestrator/policy-trigger-state/s1.txt"
RUN="$FX/workspace/run"

echo "[1] inventory refuses core/policies"
rc=0; run inventory --dir core/policies --out "$RUN" >/dev/null 2>&1 || rc=$?
[ "$rc" = 2 ] || fail "core/policies accepted (rc $rc)"

echo "[2] inventory covers personal + company, skips generated files, counts evidence, batches"
out="$(run inventory --dir personal/policies --dir companies/acme/policies --out "$RUN" --batch-size 3)"
grep -q '^policies: 6 ' <<<"$out" || fail "count: $out"
python3 - "$RUN/inventory.json" <<'PY' || fail "inventory content"
import json, sys
inv = {x['path']: x for x in json.load(open(sys.argv[1]))}
assert 'personal/policies/_digest.md' not in inv
assert inv['personal/policies/keep-me.md']['retrievals'] == 1
assert inv['personal/policies/dup-a.md']['retrievals'] == 0
assert 'companies/acme/policies/acme-rule.md' in inv
PY
[ -f "$RUN/batch-00.txt" ] && [ -f "$RUN/batch-01.txt" ] || fail "batches missing"
if command -v ruby >/dev/null 2>&1; then
  grep -q 'does not parse: 1' <<<"$out" || fail "broken frontmatter not reported: $out"
fi

echo "[3] merge rejects missing verdicts"
printf '[{"file":"keep-me.md","verdict":"keep","reason":"x"}]' > "$RUN/review-00.json"
rc=0; run merge --out "$RUN" >/dev/null 2>&1 || rc=$?
[ "$rc" = 2 ] || fail "incomplete reviews accepted (rc $rc)"

echo "[4] merge keeps a duplicate whose twin is also flagged"
cat > "$RUN/review-00.json" <<'JSON'
[{"file":"keep-me.md","verdict":"keep","reason":"x"},
 {"file":"stale-one.md","verdict":"delete-stale","reason":"script gone"},
 {"file":"dup-a.md","verdict":"delete-dup","target":"dup-b.md","reason":"same"},
 {"file":"dup-b.md","verdict":"delete-dup","target":"dup-a.md","reason":"same"},
 {"file":"broken.md","verdict":"core-fix","target":"core/scripts/x.sh","reason":"bug"},
 {"path":"companies/acme/policies/acme-rule.md","verdict":"delete-generic","reason":"generic"}]
JSON
run merge --out "$RUN" >/dev/null || fail "merge rc"
python3 - "$RUN/verdicts.json" <<'PY' || fail "dup chain not broken"
import json, sys
v = {r['path']: r['verdict'] for r in json.load(open(sys.argv[1]))}
kept = [p for p in ('personal/policies/dup-a.md', 'personal/policies/dup-b.md') if v[p] == 'keep']
assert len(kept) == 1, v
PY

echo "[5] apply is a dry run without --confirm"
out="$(run apply --out "$RUN" --verdict delete-stale --verdict delete-generic)"
grep -q 'would delete 2' <<<"$out" || fail "dry run: $out"
[ -f "$FX/personal/policies/stale-one.md" ] || fail "dry run deleted"

echo "[6] apply refuses keep verdicts"
rc=0; run apply --out "$RUN" --verdict keep --confirm >/dev/null 2>&1 || rc=$?
[ "$rc" = 2 ] || fail "keep accepted (rc $rc)"

echo "[7] apply --confirm backs up, deletes only the selection, respects --enforcement"
run apply --out "$RUN" --verdict delete-stale --verdict delete-generic --verdict core-fix --enforcement soft --confirm >/dev/null || fail "apply rc"
[ ! -f "$FX/personal/policies/stale-one.md" ] || fail "stale not deleted"
[ ! -f "$FX/companies/acme/policies/acme-rule.md" ] || fail "company rule not deleted"
[ -f "$FX/personal/policies/keep-me.md" ] || fail "keep deleted"
[ -f "$FX/core/policies/core-rule.md" ] || fail "core touched"
tarball="$(ls "$FX"/workspace/orchestrator/policy-lifecycle/backups/garden-deep-*.tar.gz)"
[ "$(tar -tzf "$tarball" | wc -l | tr -d ' ')" = 3 ] || fail "backup member count"
grep -q 'personal/policies/stale-one.md' "$RUN/applied.log" || fail "applied.log"

echo "[8] restore brings files back and refuses out-of-scope members"
run restore --backup "$tarball" >/dev/null || fail "restore rc"
[ -f "$FX/personal/policies/stale-one.md" ] || fail "not restored"
mkdir -p "$FX/evil/core/policies"; printf x > "$FX/evil/core/policies/c.md"
tar -czf "$FX/evil.tgz" -C "$FX/evil" core/policies/c.md
rc=0; run restore --backup "$FX/evil.tgz" >/dev/null 2>&1 || rc=$?
[ "$rc" = 2 ] || fail "out-of-scope restore accepted (rc $rc)"

echo "PASS garden-policy-deep"
