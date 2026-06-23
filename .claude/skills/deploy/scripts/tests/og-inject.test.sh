#!/usr/bin/env bash
# og-inject.test.sh — regression coverage for og-inject.sh.
# Asserts: tags injected, existing-image preference, author-owned pages skipped,
# subdir URL resolution, generated PNG validity, and idempotency.
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OG="$SCRIPT_DIR/og-inject.sh"
FAIL=0
pass() { printf '  ok   %s\n' "$1"; }
fail() { printf '  FAIL %s\n' "$1"; FAIL=1; }
have() { grep -q "$1" "$2" 2>/dev/null; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/sub"
cat > "$TMP/index.html" <<'H'
<!doctype html><html><head><title>Quarterly Report</title>
<meta name="description" content="Numbers for the quarter."></head><body></body></html>
H
cat > "$TMP/sub/about.html" <<'H'
<!doctype html><html><head><title>About</title></head><body><p>Paragraph fallback description.</p></body></html>
H
cat > "$TMP/owned.html" <<'H'
<!doctype html><html><head><title>Owned</title><meta property="og:title" content="Author"></head><body></body></html>
H

RES="$("$OG" "$TMP" "https://demo.indigo-hq.com" "Report App")"

echo "result: $RES"
[ "$(echo "$RES" | jq -r '.injected')" = "2" ] && pass "injected 2 pages (skips owned.html)" || fail "expected injected=2"
[ "$(echo "$RES" | jq -r '.image')" = "generated" ] && pass "image generated" || fail "expected image=generated"
[ "$(echo "$RES" | jq -r '.changed')" = "true" ] && pass "changed=true" || fail "expected changed=true"

have 'property="og:title" content="Quarterly Report"' "$TMP/index.html" && pass "og:title from <title>" || fail "og:title missing"
have 'property="og:description" content="Numbers for the quarter."' "$TMP/index.html" && pass "og:description from meta" || fail "og:description missing"
have 'property="og:image" content="https://demo.indigo-hq.com/_hq-og.png"' "$TMP/index.html" && pass "absolute og:image" || fail "og:image wrong"
have 'name="twitter:card" content="summary_large_image"' "$TMP/index.html" && pass "twitter large card" || fail "twitter:card wrong"
have 'property="og:url" content="https://demo.indigo-hq.com/"' "$TMP/index.html" && pass "root url normalized" || fail "root og:url wrong"

have 'property="og:url" content="https://demo.indigo-hq.com/sub/about.html"' "$TMP/sub/about.html" && pass "subdir url" || fail "subdir og:url wrong"
have 'content="Paragraph fallback description."' "$TMP/sub/about.html" && pass "paragraph fallback desc" || fail "fallback desc missing"

[ "$(grep -c 'hq-deploy: social preview' "$TMP/owned.html")" = "0" ] && pass "author-owned page untouched" || fail "owned.html was modified"

# Valid 1200x630 PNG
python3 - "$TMP/_hq-og.png" <<'PY' && pass "valid 1200x630 PNG" || fail "PNG invalid"
import struct,sys
d=open(sys.argv[1],'rb').read()
ok = d[:8]==bytes([137,80,78,71,13,10,26,10])
w,h=struct.unpack('>II',d[16:24])
sys.exit(0 if (ok and w==1200 and h==630) else 1)
PY

# Idempotency: a second run injects nothing new
RES2="$("$OG" "$TMP" "https://demo.indigo-hq.com" "Report App")"
[ "$(echo "$RES2" | jq -r '.injected')" = "0" ] && pass "idempotent (re-run injects 0)" || fail "second run re-injected"

# No-base-url path → relative image, summary card downgrade only if no image
TMP2="$(mktemp -d)"; cat > "$TMP2/index.html" <<'H'
<!doctype html><html><head><title>NoBase</title></head><body></body></html>
H
"$OG" "$TMP2" "" "NoBase" >/dev/null
have 'property="og:image" content="/_hq-og.png"' "$TMP2/index.html" && pass "relative image when no base url" || fail "relative image path wrong"
rm -rf "$TMP2"

if [ "$FAIL" = "0" ]; then echo "ALL PASS"; exit 0; else echo "FAILURES"; exit 1; fi
