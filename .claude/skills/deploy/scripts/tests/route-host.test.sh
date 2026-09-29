#!/usr/bin/env bash
# pass() never fails, so `cond && pass || fail` is a safe if/else here.
# shellcheck disable=SC2015
# route-host.test.sh — regression coverage for route-host.sh (reuse an existing
# static deploy by adding a route). Asserts: merge keeps every host page and
# places the artifact under the route; conflicts, unsafe routes, and
# root-absolute asset paths are refused; record snapshots the live site and the
# registry lists it per org.
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RH="$SCRIPT_DIR/route-host.sh"
FAIL=0
pass() { printf '  ok   %s\n' "$1"; }
fail() { printf '  FAIL %s\n' "$1"; FAIL=1; }
field() { printf '%s' "$1" | jq -r "$2"; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/route-host-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
export HQ_DEPLOY_ROUTES_FILE="$TMP/state/deploy-routes.json"
export HQ_DEPLOY_HOSTS_DIR="$TMP/state/deploy-hosts"

# Host site: root page plus one existing route.
mkdir -p "$TMP/host/2026-09-28" "$TMP/art/img"
printf '<html><body>home</body></html>\n' > "$TMP/host/index.html"
printf '<html><body>old report</body></html>\n' > "$TMP/host/2026-09-28/index.html"
printf 'body{}\n' > "$TMP/host/site.css"
# New artifact with relative assets only.
printf '<html><head><link href="style.css" rel="stylesheet"></head><body><img src="img/a.png">new</body></html>\n' > "$TMP/art/index.html"
printf 'p{}\n' > "$TMP/art/style.css"
printf 'png\n' > "$TMP/art/img/a.png"

# --- merge: happy path -------------------------------------------------------
RES="$("$RH" merge "$TMP/host" "$TMP/art" "/2026-09-29/" "$TMP/out1")"
[ "$(field "$RES" .ok)" = "true" ] && pass "merge ok" || fail "merge failed: $RES"
[ "$(field "$RES" .route)" = "/2026-09-29/" ] && pass "route normalized to /2026-09-29/" || fail "route wrong: $RES"
[ "$(field "$RES" .replaced)" = "false" ] && pass "new route not marked replaced" || fail "replaced should be false"
[ "$(field "$RES" '.routes | join(",")')" = "/,/2026-09-28/,/2026-09-29/" ] && pass "routes list host pages plus new route" || fail "routes wrong: $RES"
[ "$(field "$RES" .file_count)" = "6" ] && pass "file_count counts merged tree" || fail "file_count wrong: $RES"
grep -q home "$TMP/out1/index.html" && pass "host root page kept" || fail "host root lost"
grep -q 'old report' "$TMP/out1/2026-09-28/index.html" && pass "existing route kept" || fail "existing route lost"
[ -f "$TMP/out1/site.css" ] && pass "host asset kept" || fail "host asset lost"
[ -f "$TMP/out1/2026-09-29/img/a.png" ] && grep -q new "$TMP/out1/2026-09-29/index.html" && pass "artifact placed under route" || fail "artifact not placed"
grep -q 'old report' "$TMP/host/2026-09-28/index.html" && [ ! -e "$TMP/host/2026-09-29" ] && pass "host snapshot untouched" || fail "merge mutated host dir"

# --- merge: nested route -----------------------------------------------------
RES="$("$RH" merge "$TMP/host" "$TMP/art" "reports/q3" "$TMP/out-nested")"
[ "$(field "$RES" .ok)" = "true" ] && [ -f "$TMP/out-nested/reports/q3/index.html" ] && pass "nested route merges" || fail "nested route failed: $RES"

# --- merge: conflicts --------------------------------------------------------
RES="$("$RH" merge "$TMP/host" "$TMP/art" "2026-09-28" "$TMP/out2")"
[ "$(field "$RES" .reason)" = "route_exists" ] && pass "existing route refused without --replace" || fail "expected route_exists: $RES"
[ ! -e "$TMP/out2" ] && pass "refused merge writes nothing" || fail "out dir created on refusal"

RES="$("$RH" merge "$TMP/host" "$TMP/art" "2026-09-28" "$TMP/out3" --replace)"
[ "$(field "$RES" .ok)" = "true" ] && [ "$(field "$RES" .replaced)" = "true" ] && pass "--replace swaps the route" || fail "--replace failed: $RES"
grep -q new "$TMP/out3/2026-09-28/index.html" && [ ! -e "$TMP/out3/2026-09-28/old" ] && pass "replaced route holds only the new artifact" || fail "replace left old content"
grep -q home "$TMP/out3/index.html" && pass "--replace keeps other pages" || fail "--replace dropped other pages"

RES="$("$RH" merge "$TMP/host" "$TMP/art" "site.css/x" "$TMP/out4")"
[ "$(field "$RES" .reason)" = "route_blocked" ] && pass "file in route path refused" || fail "expected route_blocked: $RES"

mkdir -p "$TMP/busy" && printf x > "$TMP/busy/f"
RES="$("$RH" merge "$TMP/host" "$TMP/art" "new" "$TMP/busy")"
[ "$(field "$RES" .reason)" = "out_not_empty" ] && pass "non-empty out dir refused" || fail "expected out_not_empty: $RES"

# --- merge: unsafe routes ----------------------------------------------------
for bad in "" "/" "../etc" "a/../b" "_versions" "a/_staging" "api/x" "Upper" "a b" "a//b"; do
  RES="$("$RH" merge "$TMP/host" "$TMP/art" "$bad" "$TMP/out-bad")"
  if [ "$(field "$RES" .reason)" = "invalid_route" ]; then pass "invalid route refused: '$bad'"; else fail "route '$bad' accepted: $RES"; fi
done
[ ! -e "$TMP/out-bad" ] && pass "invalid routes write nothing" || fail "invalid route wrote output"

# --- merge: artifact checks --------------------------------------------------
mkdir -p "$TMP/noidx" && printf x > "$TMP/noidx/page.html"
RES="$("$RH" merge "$TMP/host" "$TMP/noidx" "r" "$TMP/out5")"
[ "$(field "$RES" .reason)" = "no_index" ] && pass "artifact without index.html refused" || fail "expected no_index: $RES"

mkdir -p "$TMP/abs"
printf '<html><script src="/assets/app.js"></script></html>\n' > "$TMP/abs/index.html"
RES="$("$RH" merge "$TMP/host" "$TMP/abs" "r" "$TMP/out6")"
[ "$(field "$RES" .reason)" = "root_absolute_paths" ] && pass "root-absolute src refused" || fail "expected root_absolute_paths: $RES"

mkdir -p "$TMP/abscss"
printf '<html></html>\n' > "$TMP/abscss/index.html"
printf 'body{background:url(/bg.png)}\n' > "$TMP/abscss/s.css"
RES="$("$RH" merge "$TMP/host" "$TMP/abscss" "r" "$TMP/out7")"
[ "$(field "$RES" .reason)" = "root_absolute_paths" ] && pass "root-absolute css url refused" || fail "expected root_absolute_paths for css: $RES"

# Formatted and uppercase variants must be caught too.
i=0
for form in '<img src = "/a.png">' '<SCRIPT SRC="/app.js"></SCRIPT>' "<link href= '/s.css'>" '<img src=/a.png>' '<a HREF =  "/x/">x</a>'; do
  i=$((i + 1))
  mkdir -p "$TMP/absv$i"
  printf '<html>%s</html>\n' "$form" > "$TMP/absv$i/index.html"
  RES="$("$RH" merge "$TMP/host" "$TMP/absv$i" "r" "$TMP/outv$i")"
  if [ "$(field "$RES" .reason)" = "root_absolute_paths" ]; then pass "root-absolute form refused: $form"; else fail "root-absolute form accepted: $form -> $RES"; fi
done
for css in 'body{background:url( /bg.png)}' 'body{background:URL( "/bg.png" )}'; do
  i=$((i + 1))
  mkdir -p "$TMP/absv$i"
  printf '<html></html>\n' > "$TMP/absv$i/index.html"
  printf '%s\n' "$css" > "$TMP/absv$i/s.css"
  RES="$("$RH" merge "$TMP/host" "$TMP/absv$i" "r" "$TMP/outv$i")"
  if [ "$(field "$RES" .reason)" = "root_absolute_paths" ]; then pass "root-absolute css form refused: $css"; else fail "root-absolute css form accepted: $css -> $RES"; fi
done
mkdir -p "$TMP/relok"
printf '<html><a href="/">home</a><img src = "img/a.png"><a HREF="#top">t</a></html>\n' > "$TMP/relok/index.html"
RES="$("$RH" merge "$TMP/host" "$TMP/relok" "r" "$TMP/out-relok")"
[ "$(field "$RES" .ok)" = "true" ] && pass "relative paths and bare / link allowed" || fail "relative paths wrongly refused: $RES"

mkdir -p "$TMP/cdn"
printf '<html><script src="//cdn.example.com/x.js"></script><a href="https://example.com/">x</a></html>\n' > "$TMP/cdn/index.html"
RES="$("$RH" merge "$TMP/host" "$TMP/cdn" "r" "$TMP/out8")"
[ "$(field "$RES" .ok)" = "true" ] && pass "protocol-relative and absolute URLs allowed" || fail "external URLs wrongly refused: $RES"

RES="$("$RH" merge "$TMP/missing" "$TMP/art" "r" "$TMP/out9")"
[ "$(field "$RES" .reason)" = "host_missing" ] && pass "missing host refused" || fail "expected host_missing: $RES"

# --- record + hosts ----------------------------------------------------------
RES="$("$RH" hosts)"
[ "$(field "$RES" '.hosts | length')" = "0" ] && pass "empty registry lists no hosts" || fail "expected empty hosts: $RES"

RES="$("$RH" record --org acme --subdomain standup --app-id app_1 --access-mode company --deploy-id dep_1 --site "$TMP/out1")"
[ "$(field "$RES" .ok)" = "true" ] && [ "$(field "$RES" .key)" = "acme/standup" ] && pass "record ok with org/subdomain key" || fail "record failed: $RES"
SNAP="$(field "$RES" .site)"
[ -f "$SNAP/2026-09-29/index.html" ] && [ -f "$SNAP/2026-09-28/index.html" ] && pass "snapshot holds the full live site" || fail "snapshot incomplete"
rm -rf "$TMP/out1"
[ -f "$SNAP/index.html" ] && pass "snapshot survives source removal" || fail "snapshot tied to source dir"

"$RH" record --org - --subdomain mine --app-id app_2 --access-mode public --deploy-id dep_2 --site "$TMP/host" >/dev/null

RES="$("$RH" hosts --org acme)"
[ "$(field "$RES" '.hosts | length')" = "1" ] && pass "hosts filters by org" || fail "org filter wrong: $RES"
[ "$(field "$RES" '.hosts[0].appId')" = "app_1" ] && [ "$(field "$RES" '.hosts[0].deployId')" = "dep_1" ] && [ "$(field "$RES" '.hosts[0].accessMode')" = "company" ] && pass "host carries appId, deployId, accessMode" || fail "host fields wrong: $RES"
[ "$(field "$RES" '.hosts[0].siteExists')" = "true" ] && pass "siteExists true for live snapshot" || fail "siteExists wrong: $RES"
[ "$(field "$RES" '.hosts[0].routes | join(",")')" = "/,/2026-09-28/,/2026-09-29/" ] && pass "registry routes recorded" || fail "registry routes wrong: $RES"

# --tarball records exactly what was uploaded.
mkdir -p "$TMP/tarsrc/docs" && printf '<html>t</html>\n' > "$TMP/tarsrc/index.html" && printf '<html>d</html>\n' > "$TMP/tarsrc/docs/index.html"
tar -czf "$TMP/up.tar.gz" -C "$TMP/tarsrc" .
RES="$("$RH" record --org acme --subdomain fromtar --app-id app_9 --access-mode public --deploy-id dep_9 --tarball "$TMP/up.tar.gz")"
[ "$(field "$RES" .ok)" = "true" ] && [ "$(field "$RES" '.routes | join(",")')" = "/,/docs/" ] && [ -f "$(field "$RES" .site)/docs/index.html" ] && pass "record --tarball snapshots the uploaded archive" || fail "record --tarball failed: $RES"
RES="$("$RH" record --org acme --subdomain x --app-id a --tarball "$TMP/nope.tar.gz")"
[ "$(field "$RES" .reason)" = "host_missing" ] && pass "missing tarball refused" || fail "expected host_missing for tarball: $RES"
RES="$("$RH" record --org acme --subdomain x --app-id a)"
[ "$(field "$RES" .reason)" = "bad_argument" ] && pass "record without site or tarball refused" || fail "expected bad_argument: $RES"

RES="$("$RH" hosts --org -)"
[ "$(field "$RES" '.hosts[0].key')" = "_personal/mine" ] && pass "personal scope keyed as _personal" || fail "personal key wrong: $RES"

# Re-record replaces the snapshot wholesale (a removed page must not linger).
mkdir -p "$TMP/smaller" && printf '<html>v2</html>\n' > "$TMP/smaller/index.html"
"$RH" record --org acme --subdomain standup --app-id app_1 --access-mode company --deploy-id dep_3 --site "$TMP/smaller" >/dev/null
[ ! -e "$SNAP/2026-09-28" ] && grep -q v2 "$SNAP/index.html" && pass "re-record replaces snapshot" || fail "stale snapshot content kept"
RES="$("$RH" hosts --org acme)"
[ "$(field "$RES" '.hosts[] | select(.key == "acme/standup") | .deployId')" = "dep_3" ] && pass "re-record updates deployId" || fail "deployId not updated: $RES"

rm -rf "$SNAP"
RES="$("$RH" hosts --org acme)"
[ "$(field "$RES" '.hosts[] | select(.key == "acme/standup") | .siteExists')" = "false" ] && pass "siteExists false when snapshot is gone" || fail "siteExists should be false: $RES"

RES="$("$RH" record --org 'a/../b' --subdomain x --app-id a --site "$TMP/host")"
[ "$(field "$RES" .reason)" = "bad_argument" ] && pass "unsafe org refused by record" || fail "unsafe org accepted: $RES"

MODE="$(stat -c %a "$HQ_DEPLOY_ROUTES_FILE" 2>/dev/null || stat -f %Lp "$HQ_DEPLOY_ROUTES_FILE")"
[ "$MODE" = "600" ] && pass "registry is mode 0600" || fail "registry mode $MODE"

# --- locking -----------------------------------------------------------------
# Concurrent records must not drop each other's registry entries.
pids=""
for n in 1 2 3 4 5 6 7 8; do
  "$RH" record --org race --subdomain "site$n" --app-id "app_$n" --deploy-id "dep_$n" --site "$TMP/host" >/dev/null &
  pids="$pids $!"
done
for pid in $pids; do wait "$pid"; done
RES="$("$RH" hosts --org race)"
[ "$(field "$RES" '.hosts | length')" = "8" ] && pass "8 concurrent records all kept" || fail "concurrent records lost entries: $(field "$RES" '.hosts | length')"
[ ! -e "$HQ_DEPLOY_ROUTES_FILE.lock" ] && pass "lock released after record" || fail "lock left behind"

# A lock held by a dead process is broken.
mkdir "$HQ_DEPLOY_ROUTES_FILE.lock"
sh -c 'exit 0' &
dead=$!
wait "$dead"
printf '%s\n' "$dead" > "$HQ_DEPLOY_ROUTES_FILE.lock/pid"
RES="$("$RH" record --org race --subdomain stale --app-id a --deploy-id d --site "$TMP/host")"
[ "$(field "$RES" .ok)" = "true" ] && pass "stale lock from dead pid is broken" || fail "stale lock not broken: $RES"

# A lock held by a live process makes record wait, then time out without writing.
mkdir "$HQ_DEPLOY_ROUTES_FILE.lock"
printf '%s\n' "$$" > "$HQ_DEPLOY_ROUTES_FILE.lock/pid"
RES="$(HQ_DEPLOY_ROUTES_LOCK_WAIT_TENTHS=3 "$RH" record --org race --subdomain blocked --app-id a --deploy-id d --site "$TMP/host")"
[ "$(field "$RES" .reason)" = "lock_timeout" ] && pass "live lock times out" || fail "expected lock_timeout: $RES"
[ -d "$HQ_DEPLOY_ROUTES_FILE.lock" ] && pass "timed-out caller leaves the owner's lock alone" || fail "timed-out caller removed a live lock"
RES="$(HQ_DEPLOY_ROUTES_LOCK_WAIT_TENTHS=3 "$RH" merge "$TMP/host" "$TMP/art" "locked" "$TMP/out-locked")"
[ "$(field "$RES" .reason)" = "lock_timeout" ] && pass "merge waits on the lock too" || fail "merge ignored the lock: $RES"
rm -rf "$HQ_DEPLOY_ROUTES_FILE.lock"
RES="$("$RH" hosts --org race)"
[ "$(field "$RES" '[.hosts[].subdomain] | index("blocked")')" = "null" ] && pass "timed-out record wrote nothing" || fail "timed-out record wrote an entry"

if [ "$FAIL" -ne 0 ]; then
  echo "route-host.test.sh: FAILED"
  exit 1
fi
echo "route-host.test.sh: all passed"
