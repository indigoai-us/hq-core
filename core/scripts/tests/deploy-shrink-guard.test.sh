#!/usr/bin/env bash
# Regression (feedback 09bf5e25 / 94c43419): /deploy replaced a live static app
# with a stripped older 52 KB copy of its page and said nothing. The skill now
# runs shrink-check.sh before uploading to an existing app. Fixture-based: no
# live deploys, no network.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
CHECK="$ROOT/.claude/skills/deploy/scripts/shrink-check.sh"
SKILL="$ROOT/.claude/skills/deploy/SKILL.md"
FAIL=0
pass() { echo "  ok: $*"; }
fail() { echo "FAIL: $*" >&2; FAIL=1; }

[ -x "$CHECK" ] || { echo "FAIL: shrink-check.sh missing or not executable" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq is required" >&2; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/deploy-shrink-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
mk() { head -c "$2" /dev/zero | tr '\0' 'a' > "$1"; }   # mk <file> <bytes>

LIVE="$TMP/live"; mkdir -p "$LIVE/assets"
mk "$LIVE/index.html" 300000
mk "$LIVE/assets/app.js" 100000
mk "$LIVE/data.json" 2000
mk "$LIVE/about.html" 5000

run() { OUT=$("$CHECK" "$@"); RC=$?; }

# 1. The reported case: index.html shrinks from 300 KB to 52 KB.
N1="$TMP/n1"; mkdir -p "$N1/assets"; mk "$N1/index.html" 52000; mk "$N1/assets/app.js" 100000; mk "$N1/data.json" 2000; mk "$N1/about.html" 5000
run --new-dir "$N1" --live-dir "$LIVE"
[ "$RC" = 3 ] && pass "index shrink blocks (exit 3)" || fail "index shrink exit was $RC"
jq -e '.shrink == true and .confirmed == false and (.reasons | index("index_shrunk"))' <<<"$OUT" >/dev/null \
  && pass "index_shrunk reported" || fail "index_shrunk missing: $OUT"
jq -r .message <<<"$OUT" | grep '293 KB live to 51 KB' >/dev/null \
  && pass "message names both sizes" || fail "message lacks sizes: $OUT"

# 2. Confirmed shrink goes through.
run --new-dir "$N1" --live-dir "$LIVE" --confirm-shrink
[ "$RC" = 0 ] && jq -e '.shrink == true and .confirmed == true' <<<"$OUT" >/dev/null \
  && pass "--confirm-shrink lets it through" || fail "confirm: rc=$RC $OUT"

# 3. A stripped build: index.html kept, the other top-level pages/data and assets gone.
N3="$TMP/n3"; mkdir -p "$N3"; mk "$N3/index.html" 300000
run --new-dir "$N3" --live-dir "$LIVE"
[ "$RC" = 3 ] && jq -e '.reasons | index("files_missing")' <<<"$OUT" >/dev/null \
  && pass "stripped build (top-level files missing) blocks" || fail "missing file: rc=$RC $OUT"

# 3b. Ordinary SPA redeploy: hashed bundle names change, nothing else does.
HL="$TMP/hl"; mkdir -p "$HL/assets"; mk "$HL/index.html" 300000
mk "$HL/assets/index-abc12345.js" 100000; mk "$HL/assets/style-9f8e7d6c.css" 20000; mk "$HL/data.json" 2000
HN="$TMP/hn"; mkdir -p "$HN/assets"; mk "$HN/index.html" 301000
mk "$HN/assets/index-def67890.js" 101000; mk "$HN/assets/style-1a2b3c4d.css" 20000; mk "$HN/data.json" 2000
run --new-dir "$HN" --live-dir "$HL"
[ "$RC" = 0 ] && jq -e '.shrink == false' <<<"$OUT" >/dev/null \
  && pass "hashed-asset redeploy passes" || fail "hashed redeploy: rc=$RC $OUT"

# 4. Total shrinks by more than half while index.html stays.
N4="$TMP/n4"; mkdir -p "$N4/assets"; mk "$N4/index.html" 150001; mk "$N4/assets/app.js" 1
run --new-dir "$N4" --live-dir "$LIVE"
[ "$RC" = 3 ] && jq -e '.reasons | index("total_shrunk")' <<<"$OUT" >/dev/null \
  && pass "total shrink blocks" || fail "total shrink: rc=$RC $OUT"

# 5. Same or larger build, and a modest shrink, pass.
N5="$TMP/n5"; mkdir -p "$N5/assets"; mk "$N5/index.html" 400000; mk "$N5/assets/app.js" 100000; mk "$N5/data.json" 2000; mk "$N5/about.html" 5000
run --new-dir "$N5" --live-dir "$LIVE"
[ "$RC" = 0 ] && jq -e '.shrink == false' <<<"$OUT" >/dev/null && pass "larger build passes" || fail "larger: rc=$RC $OUT"
N6="$TMP/n6"; mkdir -p "$N6/assets"; mk "$N6/index.html" 200000; mk "$N6/assets/app.js" 100000; mk "$N6/data.json" 2000; mk "$N6/about.html" 5000
run --new-dir "$N6" --live-dir "$LIVE"
[ "$RC" = 0 ] && pass "shrink under half passes" || fail "modest shrink: rc=$RC $OUT"

# 6. No snapshot: compare the downloaded live index.html only.
run --new-dir "$N1" --live-index-file "$LIVE/index.html"
[ "$RC" = 3 ] && pass "index-only comparison blocks" || fail "index-only: rc=$RC"
run --new-dir "$N5" --live-index-file "$LIVE/index.html"
[ "$RC" = 0 ] && pass "index-only comparison passes" || fail "index-only pass: rc=$RC"

# 7. Bad args.
run --new-dir "$N1"
[ "$RC" = 64 ] && pass "missing live source is a usage error" || fail "bad args rc=$RC"

# 8. SKILL.md wiring and the localStorage note.
grep -q '^#### Shrink guard' "$SKILL" && pass "skill has the shrink guard section" || fail "no guard section"
G=$(grep -n '^#### Shrink guard' "$SKILL" | head -1 | cut -d: -f1)
U=$(grep -n '^#### Static upload' "$SKILL" | head -1 | cut -d: -f1)
[ -n "$G" ] && [ -n "$U" ] && [ "$G" -lt "$U" ] && pass "guard comes before the static upload" || fail "guard not before upload"
grep -q -- '--confirm-shrink' "$SKILL" && pass "skill documents --confirm-shrink" || fail "no --confirm-shrink"
grep -q 'shrink-check.sh:\*' "$SKILL" && pass "allowed-tools lists shrink-check.sh" || fail "allowed-tools entry missing"
grep -q 'localStorage is per host' "$SKILL" && grep -q 'indigo-hq.com' "$SKILL" && pass "localStorage per-host note present" || fail "localStorage note missing"

[ "$FAIL" = 0 ] && echo "deploy-shrink-guard: all checks passed" || { echo "deploy-shrink-guard: FAILED" >&2; exit 1; }
