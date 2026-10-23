#!/usr/bin/env bash
# slug-scan.test.sh — regression tests for .leak-scan/slug-scan.py and
# .leak-scan/hash-slugs.sh, using made-up slugs only.
#
# Covers the ReviewDesk3 finding on hq-core-staging PR 1603: a private slug
# inside a longer token (cmp_<slug>, <slug>_prod, <slug>-prod) must be caught.
# Also: hyphenated slugs inside longer tokens, exact-case rule, public and
# allowlisted slugs never flagged, near-miss tokens ignored, and the scan
# refusing to run on an empty hash set.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
leak="$(cd "$here/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

# Made-up slugs; "zq-" prefix keeps them away from any real name.
printf '%s\n' zqalpha zq-beta-gamma zqdelta publicbrand > "$work/slugs.txt"
bash "$leak/hash-slugs.sh" --public publicbrand --salt 0123456789abcdef0123456789abcdef --out "$work/snap.yaml" < "$work/slugs.txt" >/dev/null
printf 'version: 1\nallowed:\n  - zqdelta   # allowlisted everywhere\n' > "$work/allow.yaml"

run_scan() { # $1 = probe file; prints exit code
  printf '%s\n' "$1" > "$work/files.txt"
  set +e
  python3 "$leak/slug-scan.py" --snapshot "$work/snap.yaml" --allowlist "$work/allow.yaml" --files "$work/files.txt" > "$work/out.txt" 2> "$work/err.txt"
  local rc=$?
  set -e
  echo "$rc"
}

hits() { grep -c '^::error file=' "$work/out.txt" || true; }

# 1. Bare slug on its own: hit.
printf 'tenant: zqalpha\n' > "$work/p1"
[[ "$(run_scan "$work/p1")" == 1 ]] || fail "bare slug not caught"

# 2. The three forms from the review, one per line: three hits, three lines.
printf 'a cmp_zqalpha b\nzqalpha_prod\nzqalpha-prod\n' > "$work/p2"
[[ "$(run_scan "$work/p2")" == 1 ]] || fail "embedded forms not caught"
[[ "$(hits)" == 3 ]] || fail "expected 3 embedded hits, got $(hits)"

# 3. Hyphenated slug inside longer tokens: cmp_<slug>, <slug>_prod, <slug>-prod, my-<slug>.
printf 'cmp_zq-beta-gamma\nzq-beta-gamma_prod\nzq-beta-gamma-prod\nmy-zq-beta-gamma\n' > "$work/p3"
[[ "$(run_scan "$work/p3")" == 1 ]] || fail "hyphenated embedded forms not caught"
[[ "$(hits)" == 4 ]] || fail "expected 4 hyphenated hits, got $(hits)"

# 4. Near misses and the exact-case rule: no hits.
printf 'zqalph zqalphax zq-beta zq-gamma ZQALPHA Zqalpha zq_beta_gamma\n' > "$work/p4"
[[ "$(run_scan "$work/p4")" == 0 ]] || fail "near miss or case variant flagged: $(cat "$work/out.txt")"

# 5. Public and allowlisted slugs are never flagged, even embedded.
printf 'publicbrand cmp_publicbrand zqdelta zqdelta_prod\n' > "$work/p5"
[[ "$(run_scan "$work/p5")" == 0 ]] || fail "public or allowlisted slug flagged"

# 6. Output never contains a slug.
printf 'cmp_zqalpha\n' > "$work/p6"
run_scan "$work/p6" >/dev/null
if grep -q 'zqalpha' "$work/out.txt" "$work/err.txt"; then fail "output names the slug"; fi

# 7. Empty hash set is an error (exit 2), not a clean pass.
printf '%s\n' publicbrand > "$work/only-public.txt"
bash "$leak/hash-slugs.sh" --public publicbrand --salt 0123456789abcdef0123456789abcdef --out "$work/snap-empty.yaml" < "$work/only-public.txt" >/dev/null
printf '%s\n' "$work/p1" > "$work/files.txt"
set +e
python3 "$leak/slug-scan.py" --snapshot "$work/snap-empty.yaml" --allowlist "$work/allow.yaml" --files "$work/files.txt" >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" == 2 ]] || fail "empty hash set should exit 2, got $rc"

# 8. The snapshot generator stores no private name.
if grep -qE 'zqalpha|zq-beta-gamma|zqdelta' "$work/snap.yaml"; then fail "snapshot contains a private slug"; fi
grep -q '^- publicbrand$' "$work/snap.yaml" || fail "snapshot lost the public slug"

echo "PASS: slug-scan (8 cases)"
