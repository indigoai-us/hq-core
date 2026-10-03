#!/usr/bin/env bash
# og-inject.test.sh — regression coverage for og-inject.sh.
# Asserts: tags injected, existing-image preference, author-owned pages skipped,
# subdir URL resolution, hq-deploy card image when a base URL is set,
# placeholder PNG validity when it is not, idempotency, and the in-place
# rewrite of a legacy card.png tag to card.jpg.
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
[ "$(echo "$RES" | jq -r '.image')" = "card" ] && pass "image uses hq-deploy card" || fail "expected image=card"
[ "$(echo "$RES" | jq -r '.changed')" = "true" ] && pass "changed=true" || fail "expected changed=true"

have 'property="og:title" content="Quarterly Report"' "$TMP/index.html" && pass "og:title from <title>" || fail "og:title missing"
have 'property="og:description" content="Numbers for the quarter."' "$TMP/index.html" && pass "og:description from meta" || fail "og:description missing"
have 'property="og:image" content="https://api.indigo-hq.com/api/public/apps/demo/card.jpg"' "$TMP/index.html" && pass "og:image is the generated card" || fail "og:image wrong"
have 'name="twitter:image" content="https://api.indigo-hq.com/api/public/apps/demo/card.jpg"' "$TMP/index.html" && pass "twitter:image is the generated card" || fail "twitter:image wrong"
[ ! -e "$TMP/_hq-og.png" ] && pass "no placeholder PNG written when base url set" || fail "placeholder PNG written despite base url"
have 'name="twitter:card" content="summary_large_image"' "$TMP/index.html" && pass "twitter large card" || fail "twitter:card wrong"
have 'property="og:url" content="https://demo.indigo-hq.com/"' "$TMP/index.html" && pass "root url normalized" || fail "root og:url wrong"

have 'property="og:url" content="https://demo.indigo-hq.com/sub/about.html"' "$TMP/sub/about.html" && pass "subdir url" || fail "subdir og:url wrong"
have 'content="Paragraph fallback description."' "$TMP/sub/about.html" && pass "paragraph fallback desc" || fail "fallback desc missing"

[ "$(grep -c 'hq-deploy: social preview' "$TMP/owned.html")" = "0" ] && pass "author-owned page untouched" || fail "owned.html was modified"

# No-base-url path: placeholder fallback, relative image
TMP2="$(mktemp -d)"; cat > "$TMP2/index.html" <<'H'
<!doctype html><html><head><title>NoBase</title></head><body></body></html>
H
RES3="$("$OG" "$TMP2" "" "NoBase")"
[ "$(echo "$RES3" | jq -r '.image')" = "generated" ] && pass "placeholder generated when no base url" || fail "expected image=generated without base url"
have 'property="og:image" content="/_hq-og.png"' "$TMP2/index.html" && pass "relative image when no base url" || fail "relative image path wrong"

# Valid 1200x630 PNG
python3 - "$TMP2/_hq-og.png" <<'PY' && pass "valid 1200x630 PNG" || fail "PNG invalid"
import struct,sys
d=open(sys.argv[1],'rb').read()
ok = d[:8]==bytes([137,80,78,71,13,10,26,10])
w,h=struct.unpack('>II',d[16:24])
sys.exit(0 if (ok and w==1200 and h==630) else 1)
PY

# Idempotency: a second run injects nothing new
RES2="$("$OG" "$TMP" "https://demo.indigo-hq.com" "Report App")"
[ "$(echo "$RES2" | jq -r '.injected')" = "0" ] && pass "idempotent (re-run injects 0)" || fail "second run re-injected"

rm -rf "$TMP2"

# Legacy page already carrying a card.png tag: re-run rewrites it to card.jpg
# in place and does not add a second tag.
TMP4="$(mktemp -d)"; cat > "$TMP4/index.html" <<'H'
<!doctype html><html><head>
  <!-- hq-deploy: social preview tags -->
  <meta property="og:title" content="Legacy">
  <meta property="og:image" content="https://api.indigo-hq.com/api/public/apps/demo/card.png">
  <meta name="twitter:image" content="https://api.indigo-hq.com/api/public/apps/demo/card.png">
<title>Legacy</title></head><body><img src="/api/public/apps/demo/card.png"></body></html>
H
RES5="$("$OG" "$TMP4" "https://demo.indigo-hq.com" "Legacy")"
[ "$(echo "$RES5" | jq -r '.rewritten')" = "1" ] && [ "$(echo "$RES5" | jq -r '.injected')" = "0" ] && pass "legacy page rewritten, not re-injected" || fail "legacy rewrite result wrong: $RES5"
[ "$(grep -c 'property="og:image" content="https://api.indigo-hq.com/api/public/apps/demo/card.jpg"' "$TMP4/index.html")" = "1" ] && pass "legacy og:image now card.jpg (one tag)" || fail "legacy og:image not rewritten to a single card.jpg tag"
[ "$(grep -c 'name="twitter:image" content="https://api.indigo-hq.com/api/public/apps/demo/card.jpg"' "$TMP4/index.html")" = "1" ] && pass "legacy twitter:image now card.jpg (one tag)" || fail "legacy twitter:image not rewritten to a single card.jpg tag"
[ "$(grep -c 'og:title' "$TMP4/index.html")" = "1" ] && pass "no second tag block added" || fail "second og block added"
have '<img src="/api/public/apps/demo/card.png">' "$TMP4/index.html" && pass "non-meta card.png reference left alone" || fail "body img was rewritten"
RES6="$("$OG" "$TMP4" "https://demo.indigo-hq.com" "Legacy")"
[ "$(echo "$RES6" | jq -r '.rewritten')" = "0" ] && [ "$(echo "$RES6" | jq -r '.changed')" = "false" ] && pass "legacy rewrite idempotent" || fail "legacy rewrite not idempotent: $RES6"
rm -rf "$TMP4"

# Existing preview image still wins over the card
TMP3="$(mktemp -d)"; cat > "$TMP3/index.html" <<'H'
<!doctype html><html><head><title>Img</title></head><body></body></html>
H
cp /dev/null "$TMP3/og.png"
RES4="$("$OG" "$TMP3" "https://demo.indigo-hq.com" "Img")"
[ "$(echo "$RES4" | jq -r '.image')" = "existing" ] && have 'content="https://demo.indigo-hq.com/og.png"' "$TMP3/index.html" && pass "existing og image preferred over card" || fail "existing image not preferred"
rm -rf "$TMP3"

if [ "$FAIL" = "0" ]; then echo "ALL PASS"; exit 0; else echo "FAILURES"; exit 1; fi
