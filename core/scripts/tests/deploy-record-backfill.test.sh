#!/usr/bin/env bash
# pass() never fails, so `cond && pass || fail` is a safe if/else here.
# shellcheck disable=SC2015
# deploy-record-backfill.test.sh — regression coverage for /deploy
# record-existing (US-006 of hq-reuse-discovery). A stubbed app list and a
# local HTTP server stand in for hq-deploy and the live sites, so nothing
# leaves the machine. Covers: dry-run writes nothing, own apps only,
# skip-existing, local sources (project and workspace), the public fetch path,
# a sign-in redirect and a gated app becoming needs-source, cursor resume,
# --app/--source replacing a needs-source record, captions, the request gap,
# and how SKILL.md exposes the command.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
CMD="$ROOT/.claude/skills/deploy/scripts/deploy-record-backfill.sh"
SKILL="$ROOT/.claude/skills/deploy/SKILL.md"
FAIL=0
pass() { printf '  ok   %s\n' "$1"; }
fail() { printf '  FAIL %s\n' "$1"; FAIL=1; }

[ -x "$CMD" ] || { echo "FAIL deploy-record-backfill.sh missing or not executable"; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "FAIL python3 is required to run this test"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "FAIL jq is required to run this test"; exit 1; }

field() { jq -r --arg k "$2" 'if has($k) and .[$k] != null then .[$k] else "" end | if type == "array" then (map(tostring) | join(",")) else tostring end' <<<"$1" 2>/dev/null; }
fm() { sed -n "s/^$2: //p" "$1" | head -1 | sed 's/^"//; s/"$//'; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/deploy-record-backfill-test.XXXXXX")"
SERVER_PID=""
cleanup() {
  if [ -n "$SERVER_PID" ]; then kill "$SERVER_PID" 2>/dev/null; wait "$SERVER_PID" 2>/dev/null; fi
  rm -rf "$TMP"
}
trap cleanup EXIT
T="$(cd "$TMP" && pwd -P)"
export HOME="$T/home"
mkdir -p "$HOME"

# Live sites: /pub serves a page, /signin redirects like a gated app.
cat > "$T/server.py" <<'EOF'
import http.server, sys
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path.startswith("/pub"):
            body = (b"<!doctype html><title>Pricing page</title><body><h1>Pricing</h1><p>"
                    + b"Three plans for teams with monthly and yearly billing and a free trial. " * 12 + b"</p></body>")
            self.send_response(200); self.send_header("Content-Type", "text/html"); self.end_headers(); self.wfile.write(body)
        elif self.path.startswith("/signin"):
            self.send_response(302); self.send_header("Location", "/login"); self.end_headers()
        elif self.path.startswith("/login"):
            body = b"<!doctype html><title>Sign in</title><p>Sign in to continue.</p>"
            self.send_response(200); self.send_header("Content-Type", "text/html"); self.end_headers(); self.wfile.write(body)
        else:
            self.send_response(404); self.end_headers()
    def log_message(self, *a):
        pass
srv = http.server.HTTPServer(("127.0.0.1", 0), H)
open(sys.argv[1], "w").write(str(srv.server_address[1]))
srv.serve_forever()
EOF
python3 -I "$T/server.py" "$T/port" & SERVER_PID=$!
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do [ -s "$T/port" ] && break; sleep 0.1; done
PORT="$(cat "$T/port" 2>/dev/null)"
[ -n "$PORT" ] || { echo "FAIL test server did not start"; exit 1; }

# A throwaway HQ.
build_hq() {
  local H="$1"
  rm -rf "$H"
  mkdir -p "$H/companies/bravo/projects/web/deploys" "$H/companies/bravo/projects/web/site-a" \
           "$H/companies/other/projects/x" "$H/workspace/drafts/promo-deck"
  printf 'companies:\n  bravo:\n    name: Bravo\n  other:\n    name: Other\n' > "$H/companies/manifest.yaml"
  printf -- '---\nrecord: "hq-deploy"\nrecord_version: 1\nsubdomain: "old-app"\ntags: ["deploy"]\n---\n\n# old-app\n\nAlready recorded.\n' \
    > "$H/companies/bravo/projects/web/deploys/old-app.md"
  printf '<!doctype html><title>Site A</title><p>Site A explains the onboarding checklist for new customers in five steps.</p>\n' \
    > "$H/companies/bravo/projects/web/site-a/index.html"
  printf '<!doctype html><title>Promo deck</title><p>Quarterly promo deck for the sales team.</p>\n' \
    > "$H/workspace/drafts/promo-deck/index.html"
  # A session bound to project web: a backfill must not file every app there.
  mkdir -p "$H/workspace/sessions/sid-1"
  printf 'session_id: sid-1\ncompany_slug: bravo\nproject: web\n' > "$H/workspace/sessions/sid-1/meta.yaml"
}
APPS="$T/apps.json"
cat > "$APPS" <<EOF
{"apps":[
 {"id":"a1","name":"old-app","subdomain":"old-app","url":"https://old-app.example.test","type":"static","accessMode":"public","ownerId":"me"},
 {"id":"a2","name":"site-a","subdomain":"site-a","url":"https://site-a.example.test","type":"static","accessMode":"company","ownerId":"me"},
 {"id":"a3","name":"Promo deck","subdomain":"promo-deck","url":"https://promo-deck.example.test","type":"static","accessMode":"company","ownerId":"me"},
 {"id":"a4","name":"pub-page","subdomain":"pub-page","url":"http://127.0.0.1:$PORT/pub","type":"static","accessMode":"public","ownerId":"me"},
 {"id":"a5","name":"signin-page","subdomain":"signin-page","url":"http://127.0.0.1:$PORT/signin","type":"static","accessMode":"public","ownerId":"me"},
 {"id":"a6","name":"board-notes","subdomain":"board-notes","url":"https://board-notes.example.test","type":"static","accessMode":"password","passwordProtected":true,"ownerId":"me"},
 {"id":"a7","name":"someone-else","subdomain":"someone-else","url":"https://someone-else.example.test","type":"static","accessMode":"public","ownerId":"them"}
]}
EOF
H="$T/hq"
build_hq "$H"
run() { (cd "$H" && HQ_ROOT="" HQ_DEPLOY_BACKFILL_APPS_FILE="$APPS" HQ_DEPLOY_BACKFILL_OWNER=me "$CMD" "$@"); }
last() { tail -1 <<<"$1"; }
snapshot() { (cd "$H" && find . -type f | sort | xargs shasum 2>/dev/null); }

echo "--- dry run is the default and writes nothing"
BEFORE="$(snapshot)"
START="$(python3 -I -c 'import time; print(int(time.time()*1000))')"
OUT="$(run --company bravo)"; RC=$?
END="$(python3 -I -c 'import time; print(int(time.time()*1000))')"
RES="$(last "$OUT")"
[ "$RC" = 0 ] && [ "$(field "$RES" mode)" = "dry-run" ] && [ "$BEFORE" = "$(snapshot)" ] && [ ! -e "$H/workspace/deploy-record-backfill" ] \
  && pass "no --apply: plan printed, no file written, no cursor" || fail "dry run (rc=$RC): $RES"
[ "$(field "$RES" written_from_local)" = 2 ] && [ "$(field "$RES" written_from_fetch)" = 1 ] && [ "$(field "$RES" needs_source)" = 2 ] \
  && [ "$(field "$RES" skipped)" = 1 ] && [ "$(field "$RES" failed)" = 0 ] && pass "dry run counts: 2 local, 1 fetch, 2 needs-source, 1 skipped" || fail "dry counts: $RES"
grep -q '^site-a  access=company  source=local:companies/bravo/projects/web/site-a  type=landing  home=companies/bravo/projects/web/deploys  -> would write$' <<<"$OUT" \
  && grep -q '^promo-deck .*home=companies/bravo/deploys ' <<<"$OUT" && grep -q '^board-notes .*(needs-source)$' <<<"$OUT" \
  && pass "each app line names its source, access mode, type and home" || fail "plan lines: $OUT"
grep -q '^record-existing bravo (dry-run): written-from-local=2 written-from-fetch=1 needs-source=2 skipped=1 failed=0$' <<<"$OUT" \
  && pass "summary line" || fail "summary line: $OUT"
[ "$(field "$RES" requests)" = 2 ] && [ $((END - START)) -ge 500 ] && pass "two fetches are spaced at least 0.5 s apart ($((END - START)) ms)" || fail "rate: $((END - START)) ms, $RES"

echo "--- only your own apps"
! grep -q 'someone-else' <<<"$OUT" && [ "$(field "$RES" yours)" = 6 ] && [ "$(field "$RES" apps_listed)" = 7 ] \
  && pass "an app created by someone else is not listed or recorded" || fail "own apps: $RES"
RES="$(last "$(run --company bravo --app someone-else)")"
[ "$(field "$RES" reason)" = "app_not_yours" ] && pass "--app cannot name someone else's app" || fail "app_not_yours: $RES"

echo "--- apply"
OLD_SUM="$(shasum "$H/companies/bravo/projects/web/deploys/old-app.md")"
OUT="$(HQ_SESSION_ID=sid-1 HQ_DEPLOY_BACKFILL_GAP=0 run --company bravo --apply)"; RC=$?
RES="$(last "$OUT")"
[ "$RC" = 0 ] && [ "$(field "$RES" written_from_local)" = 2 ] && [ "$(field "$RES" written_from_fetch)" = 1 ] && [ "$(field "$RES" needs_source)" = 2 ] \
  && [ "$(field "$RES" needs_source_apps)" = "board-notes,signin-page" ] && pass "apply writes 5 records and names the needs-source apps" || fail "apply (rc=$RC): $OUT"
[ "$OLD_SUM" = "$(shasum "$H/companies/bravo/projects/web/deploys/old-app.md")" ] && pass "an app that already has a record is skipped" || fail "old-app changed"
R="$H/companies/bravo/projects/web/deploys/site-a.md"
[ -f "$R" ] && grep -q '"backfill"' "$R" && grep -q 'Site A explains the onboarding checklist' "$R" && [ "$(fm "$R" project)" = web ] \
  && [ ! -e "$H/companies/bravo/projects/web/deploys/site-a/source" ] \
  && pass "a source inside a project files the record there, with the page text as description; no source copy by default" || fail "site-a: $(cat "$R" 2>/dev/null | head -30)"
R="$H/companies/bravo/deploys/promo-deck.md"
[ -f "$R" ] && [ "$(fm "$R" type)" = deck ] && [ "$(fm "$R" source_path)" = "workspace/drafts/promo-deck" ] \
  && [ ! -e "$H/companies/bravo/projects/web/deploys/promo-deck.md" ] \
  && pass "a workspace source goes to the company folder even with a session bound to a project; type deck from the name" || fail "promo-deck: $(head -20 "$R" 2>/dev/null)"
R="$H/companies/bravo/deploys/pub-page.md"
[ -f "$R" ] && grep -q '"source-fetched"' "$R" && [ "$(fm "$R" source_path)" = "http://127.0.0.1:$PORT/pub" ] && grep -q 'Three plans for teams' "$R" \
  && pass "a public app with no local source is fetched and recorded with its URL as source" || fail "pub-page: $(head -30 "$R" 2>/dev/null)"
R="$H/companies/bravo/deploys/signin-page.md"
[ -f "$R" ] && grep -q '"needs-source"' "$R" && ! grep -q '"source-fetched"' "$R" && pass "a sign-in redirect is not followed; the app is needs-source" || fail "signin-page: $(head -30 "$R" 2>/dev/null)"
R="$H/companies/bravo/deploys/board-notes.md"
[ -f "$R" ] && grep -q '"needs-source"' "$R" && grep -q '"text-withheld"' "$R" && [ "$(fm "$R" access_mode)" = password ] \
  && ! grep -q '^## Page text' "$R" && [ "$(fm "$R" source_path)" = "needs-source" ] \
  && pass "a gated app with no source gets a needs-source record with no page text" || fail "board-notes: $(cat "$R" 2>/dev/null)"
[ ! -e "$H/companies/bravo/deploys/someone-else.md" ] && pass "nothing written for someone else's app" || fail "someone-else recorded"
[ -f "$H/workspace/deploy-record-backfill/bravo.json" ] && [ "$(jq -r '.done | keys | join(",")' "$H/workspace/deploy-record-backfill/bravo.json")" = "board-notes,promo-deck,pub-page,signin-page,site-a" ] \
  && pass "the cursor lists every finished app" || fail "cursor: $(cat "$H/workspace/deploy-record-backfill/bravo.json" 2>/dev/null)"

echo "--- reruns and resume"
BEFORE="$(snapshot)"
RES="$(last "$(HQ_DEPLOY_BACKFILL_GAP=0 run --company bravo --apply)")"
[ "$(field "$RES" skipped)" = 6 ] && [ "$(field "$RES" written_from_local)" = 0 ] && [ "$BEFORE" = "$(snapshot)" ] \
  && pass "a second --apply skips everything and changes nothing" || fail "rerun: $RES"
rm "$H/companies/bravo/deploys/pub-page.md"
RES="$(last "$(HQ_DEPLOY_BACKFILL_GAP=0 run --company bravo --apply)")"
[ "$(field "$RES" skipped)" = 6 ] && [ ! -e "$H/companies/bravo/deploys/pub-page.md" ] \
  && pass "an app in the cursor is not written again after an interrupted run" || fail "cursor resume: $RES"
build_hq "$H"
mkdir -p "$H/workspace/deploy-record-backfill"
printf '{"done":{"board-notes":"needs_source","promo-deck":"written_from_local"}}\n' > "$H/workspace/deploy-record-backfill/bravo.json"
RES="$(last "$(HQ_DEPLOY_BACKFILL_GAP=0 run --company bravo --apply)")"
[ "$(field "$RES" skipped)" = 3 ] && [ "$(field "$RES" written_from_local)" = 1 ] && [ ! -e "$H/companies/bravo/deploys/promo-deck.md" ] \
  && [ -f "$H/companies/bravo/projects/web/deploys/site-a.md" ] && pass "a run resumes after the apps the cursor already has" || fail "resume from cursor: $RES"

echo "--- point a needs-source app at its folder"
build_hq "$H"
HQ_DEPLOY_BACKFILL_GAP=0 run --company bravo --apply >/dev/null
mkdir -p "$H/companies/bravo/projects/web/board"
printf '<!doctype html><title>Board</title><p>Board notes for October.</p>\n' > "$H/companies/bravo/projects/web/board/index.html"
RES="$(last "$(run --company bravo --apply --app board-notes --source "$H/companies/bravo/projects/web/board")")"
R="$H/companies/bravo/projects/web/deploys/board-notes.md"
[ "$(field "$RES" written_from_local)" = 1 ] && [ -f "$R" ] && ! grep -q '"needs-source"' "$R" && grep -q '"text-withheld"' "$R" \
  && [ ! -e "$H/companies/bravo/deploys/board-notes.md" ] && ! grep -q 'Board notes for October' "$R" \
  && pass "--app/--source replaces the needs-source record; the gate still withholds page text" || fail "--source: $RES"
OUT="$(run --company bravo --source /tmp)"; RC=$?; RES="$(last "$OUT")"
[ "$RC" = 64 ] && [ "$(field "$RES" reason)" = bad_args ] && pass "--source needs --app" || fail "--source alone: $RES"
OUT="$(run --company nope)"; RC=$?; RES="$(last "$OUT")"
[ "$RC" = 64 ] && [ "$(field "$RES" reason)" = company_not_found ] && pass "an unknown company exits 64" || fail "company: $RES"

echo "--- captions"
build_hq "$H"
RES="$(last "$(HQ_DEPLOY_BACKFILL_GAP=0 run --company bravo --apply --captions)")"
Q="$H/$(field "$RES" captions_queue)"
[ -f "$Q" ] && [ "$(jq -r '[.[].subdomain] | sort | join(",")' "$Q")" = "promo-deck,site-a" ] \
  && pass "--captions queues the thin records that have a source (not needs-source ones)" || fail "captions queue: $RES $(cat "$Q" 2>/dev/null)"
RES="$(last "$(run --company bravo --set-caption companies/bravo/deploys/promo-deck.md --caption "A quarterly promo deck for the sales team. It lists the offers and the dates.")")"
R="$H/companies/bravo/deploys/promo-deck.md"
[ "$(field "$RES" ok)" = true ] && grep -q '"caption-generated"' "$R" && grep -qx 'A quarterly promo deck for the sales team. It lists the offers and the dates.' "$R" \
  && pass "--set-caption replaces the description and marks it generated in the frontmatter" || fail "set-caption: $RES"
OUT="$(run --company bravo --set-caption companies/bravo/projects/web/deploys/old-app.md --caption "x")"; RC=$?; RES="$(last "$OUT")"
[ "$RC" = 64 ] && [ "$(field "$RES" reason)" = not_a_backfill_record ] && pass "--set-caption refuses records it did not write" || fail "set-caption guard: $RES"

echo "--- SKILL.md exposes /deploy record-existing"
grep -Fq '/deploy record-existing' "$SKILL" && grep -Fq '.claude/skills/deploy/scripts/deploy-record-backfill.sh --company' "$SKILL" \
  && pass "the deploy skill documents the command" || fail "SKILL.md lacks record-existing"
grep -Fq 'Bash(.claude/skills/deploy/scripts/deploy-record-backfill.sh:*)' "$SKILL" && pass "allowed-tools lets the skill run it" || fail "allowed-tools rule missing"

if [ "$FAIL" = 0 ]; then
  echo "deploy-record-backfill.test.sh: PASS"
else
  echo "deploy-record-backfill.test.sh: FAIL"
fi
exit "$FAIL"
