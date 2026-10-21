#!/usr/bin/env bash
# Regression for list-apps.sh: GET /api/apps is paginated (nextCursor). Callers
# that read only page one miss apps in orgs with more than one page of apps
# (2026-10-18: two project-summary pages left public). The helper must read
# every page, stop early on a name match, and fail closed on any bad page.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIST="$SCRIPT_DIR/list-apps.sh"
FAIL=0
pass() { printf '  ok   %s\n' "$1"; }
fail() { printf '  FAIL %s\n' "$1"; FAIL=1; }
command -v jq >/dev/null 2>&1 || { echo "FAIL: needs jq"; exit 1; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# Fake request script with deploy-api-request.sh's contract: prints the body
# on 2xx + --expect match, exits 1 otherwise. Pages come from $PAGES/<cursor>.json.
cat > "$TMP/request.sh" <<'EOF'
#!/usr/bin/env bash
url=""; expect=""; extra=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --url) url="$2"; shift 2 ;;
    --expect) expect="$2"; shift 2 ;;
    --stage|--method) shift 2 ;;
    *) extra="$extra $1"; shift ;;
  esac
done
printf '%s|%s\n' "$url" "$extra" >> "$PAGES/requests"
cursor=first
case "$url" in *"&cursor="*) cursor="${url##*&cursor=}" ;; esac
[ -f "$PAGES/$cursor.json" ] || { echo "[deploy] stage=app-list status=500" >&2; exit 1; }
jq -e "$expect" "$PAGES/$cursor.json" >/dev/null 2>&1 || { echo "[deploy] invalid" >&2; exit 1; }
cat "$PAGES/$cursor.json"
EOF
chmod +x "$TMP/request.sh"

setup() {
  PAGES="$TMP/$1"; mkdir -p "$PAGES"; : > "$PAGES/requests"
  export PAGES
}
run() { HQ_DEPLOY_REQUEST_SCRIPT="$TMP/request.sh" HQ_DEPLOY_JWT=t bash "$LIST" --api http://api.test/ "$@"; }

# Three pages; the target is on page 3.
setup three
jq -nc '{apps: [range(0;100) | {name: "a\(.)", id: "a\(.)"}], nextCursor: "c2"}' > "$PAGES/first.json"
jq -nc '{apps: [range(0;100) | {name: "b\(.)", id: "b\(.)"}], nextCursor: "c3"}' > "$PAGES/c2.json"
printf '%s\n' '{"apps":[{"name":"target","id":"app-9","subdomain":"target"}],"nextCursor":null}' > "$PAGES/c3.json"

out="$(run --name target --header 'X-Org-Slug: acme')"; code=$?
[ "$code" = 0 ] && [ "$(printf '%s' "$out" | jq -r .id)" = app-9 ] \
  && pass "finds an app on page 3" || fail "page-3 lookup: code=$code out=$out"
grep -q 'limit=100&cursor=c3' "$PAGES/requests" && pass "follows nextCursor" || fail "did not request cursor c3"
grep -q 'X-Org-Slug: acme' "$PAGES/requests" && pass "passes context headers through on every page" \
  || fail "context header dropped"
grep -q '^http://api.test/api/apps' "$PAGES/requests" && pass "normalizes a trailing slash in --api" || fail "bad base url"

: > "$PAGES/requests"
out="$(run --name a5)"
[ "$(printf '%s' "$out" | jq -r .id)" = a5 ] && [ "$(wc -l < "$PAGES/requests" | tr -d ' ')" = 1 ] \
  && pass "stops paging at the first match" || fail "early stop: $(cat "$PAGES/requests")"

out="$(run --name missing)"; code=$?
[ "$code" = 0 ] && [ -z "$out" ] && pass "missing app: empty output, exit 0" || fail "missing: code=$code out=$out"

out="$(run)"
[ "$(printf '%s' "$out" | jq '.apps | length')" = 201 ] && pass "no --name: merges every page into {apps:[...]}" \
  || fail "merge count: $(printf '%s' "$out" | jq '.apps | length')"

# A failing page must fail the whole call, never read as "not found".
setup broken
printf '%s\n' '{"apps":[],"nextCursor":"gone"}' > "$PAGES/first.json"
out="$(run --name target 2>/dev/null)"; code=$?
[ "$code" != 0 ] && [ -z "$out" ] && pass "failed page 2 fails closed" || fail "broken page: code=$code out=$out"

setup malformed
printf '%s\n' '{"items":[]}' > "$PAGES/first.json"
run --name target >/dev/null 2>&1 && fail "malformed page accepted" || pass "malformed page fails closed"

setup loop
printf '%s\n' '{"apps":[],"nextCursor":"c2"}' > "$PAGES/first.json"
printf '%s\n' '{"apps":[],"nextCursor":"c2"}' > "$PAGES/c2.json"
run --name target >/dev/null 2>&1 && fail "repeated cursor looped or passed" || pass "repeated cursor fails closed"

setup cap
printf '%s\n' '{"apps":[],"nextCursor":"c2"}' > "$PAGES/first.json"
printf '%s\n' '{"apps":[],"nextCursor":"c3"}' > "$PAGES/c2.json"
printf '%s\n' '{"apps":[],"nextCursor":null}' > "$PAGES/c3.json"
HQ_DEPLOY_APP_LIST_MAX_PAGES=2 run --name target >/dev/null 2>&1 && fail "page cap ignored" || pass "page cap fails closed"

setup badcursor
printf '%s\n' '{"apps":[],"nextCursor":"a&b=c"}' > "$PAGES/first.json"
run --name target >/dev/null 2>&1 && fail "unsafe cursor sent" || pass "non-base64url cursor fails closed"

if [ "$FAIL" = 0 ]; then echo "ALL PASS: list-apps"; exit 0; else echo "FAILURES"; exit 1; fi
