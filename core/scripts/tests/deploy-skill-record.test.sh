#!/usr/bin/env bash
# pass() never fails, so `cond && pass || fail` is a safe if/else here.
# shellcheck disable=SC2015
# deploy-skill-record.test.sh — regression coverage for the /deploy record
# step (US-004 of hq-reuse-discovery). Asserts that SKILL.md wires C.4.5 after
# the upload completes and route-host.sh records the snapshot, and before C.5;
# that the step only runs when the upload succeeded; that a record failure is
# guarded under set -e and becomes one plain line after the link; and that
# deploy-record-step.sh writes records end to end for static, gated, route-mode
# and app deploys against a throwaway HQ.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SKILL="$ROOT/.claude/skills/deploy/SKILL.md"
STEP="$ROOT/.claude/skills/deploy/scripts/deploy-record-step.sh"
FAIL=0
pass() { printf '  ok   %s\n' "$1"; }
fail() { printf '  FAIL %s\n' "$1"; FAIL=1; }

[ -f "$SKILL" ] || { echo "FAIL deploy SKILL.md missing"; exit 1; }
[ -x "$STEP" ] || { echo "FAIL deploy-record-step.sh missing or not executable"; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "FAIL python3 is required to run this test"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "FAIL jq is required to run this test"; exit 1; }

line_of() { grep -n -F -- "$1" "$SKILL" | head -1 | cut -d: -f1; }
field() { jq -r --arg k "$2" 'if has($k) and .[$k] != null then .[$k] else "" end | if type == "array" then join(",") else tostring end' <<<"$1" 2>/dev/null; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/deploy-skill-record-test.XXXXXX")"
trap 'chmod -R u+w "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT
TMP_REAL="$(cd "$TMP" && pwd -P)"

echo "--- SKILL.md wires the step after the upload and before C.5"
complete="$(line_of '--url "$API/api/deploys/$DEPLOY_ID/complete"')"
snapshot="$(line_of 'ROUTE_RECORD_JSON=$(.claude/skills/deploy/scripts/route-host.sh record')"
app_up="$(line_of 'deploy_request app-deploy --method POST')"
step="$(line_of '### C.4.5 — Record the deploy')"
c5="$(line_of '### C.5 — Present the link')"
gate="$(line_of '#### Auth-gate verify')"
for v in complete snapshot app_up step c5 gate; do
  [ -n "${!v}" ] || fail "anchor missing in SKILL.md: $v"
done
[ "$complete" -lt "$snapshot" ] && [ "$snapshot" -lt "$step" ] && pass "C.4.5 comes after /complete and route-host.sh record" || fail "order: complete=$complete snapshot=$snapshot step=$step"
[ "$app_up" -lt "$step" ] && pass "C.4.5 comes after the app upload" || fail "app upload after the step"
[ "$gate" -lt "$step" ] && pass "C.4.5 comes after the auth-gate is proven" || fail "step before auth-gate verify"
[ "$step" -lt "$c5" ] && pass "C.4.5 comes before C.5" || fail "step after C.5"

BLOCK="$(awk '/^### C\.4\.5 /{on=1} /^### C\.5 /{on=0} on' "$SKILL" | awk '/^```bash/{b=1; next} /^```/{if(b){exit}} b')"
[ -n "$BLOCK" ] || fail "no bash block in C.4.5"
grep -Fq 'if [ "${UPLOAD_OK:-}" = "true" ] && [ -n "${LIVE_URL:-}" ]; then' <<<"$BLOCK" && pass "the step is gated on UPLOAD_OK and LIVE_URL" || fail "step not gated on a successful upload"
grep -Fq -- '--deploy-type "$DEPLOY_TYPE" 2>/dev/null) || true' <<<"$BLOCK" && pass "a non-zero exit is guarded under set -e" || fail "record step not guarded with || true"
grep -Fq -- '--access-mode "${HOST_ACCESS_MODE:-${ACCESS_MODE:-public}}"' <<<"$BLOCK" && pass "the step passes the deploy's access mode" || fail "access mode not passed"
grep -Fq -- '--description "${DEPLOY_DESCRIPTION:-}"' <<<"$BLOCK" && pass "the step passes the agent's description" || fail "description not passed"

# UPLOAD_OK=true is assigned only right after a successful upload.
ASSIGN_LINES="$(grep -n '^ *UPLOAD_OK=true$' "$SKILL" | cut -d: -f1 | tr '\n' ' ')"
[ "$(grep -c '^ *UPLOAD_OK=true$' "$SKILL")" = 2 ] && pass "UPLOAD_OK=true is set in exactly two places" || fail "UPLOAD_OK=true set at: $ASSIGN_LINES"
static_set="$(echo "$ASSIGN_LINES" | awk '{print $1}')"
app_set="$(echo "$ASSIGN_LINES" | awk '{print $2}')"
[ "$complete" -lt "$static_set" ] && [ "$static_set" -lt "$app_up" ] && pass "static: set after /complete" || fail "static UPLOAD_OK at $static_set"
[ "$app_up" -lt "$app_set" ] && [ "$app_set" -lt "$step" ] && pass "app: set after the app deploy" || fail "app UPLOAD_OK at $app_set"
sed -n "${complete},${static_set}p" "$SKILL" | grep -Fq "|| exit 1" && pass "a failed /complete exits before UPLOAD_OK is set" || fail "no exit between /complete and UPLOAD_OK"
sed -n "${app_up},${app_set}p" "$SKILL" | grep -Fq "|| exit 1" && pass "a failed app deploy exits before UPLOAD_OK is set" || fail "no exit between app deploy and UPLOAD_OK"

C5="$(awk '/^### C\.5 /{on=1} /^## /{if(on)exit} on' "$SKILL")"
grep -Fq 'RECORD_LINE' <<<"$C5" && pass "C.5 adds the record line after the link" || fail "C.5 does not mention RECORD_LINE"
STEPDOC="$(awk '/^### C\.4\.5 /{on=1} /^### C\.5 /{on=0} on' "$SKILL")"
grep -Fq 'required for every deploy, including videos, PDF decks, image-only graphics and gated deploys' <<<"$STEPDOC" \
  && pass "the description is mandatory for every deploy" || fail "mandatory description text missing"
for t in explainer report memo deck pdf-deck landing tool demo-site newsletter preview asset video stub; do
  grep -qw -- "$t" <<<"$STEPDOC" || fail "content type $t not listed in C.4.5"
done
pass "all 13 content types are listed"
REF="$(awk '/^## Inline-script reference/{on=1} /^## Notes/{on=0} on' "$SKILL")"
for s in deploy-record-step.sh deploy-record-home.sh deploy-record.sh; do
  grep -Fq "| \`$s" <<<"$REF" && pass "inline-script table documents $s" || fail "inline-script table lacks $s"
done
grep -Fq '{"ok":true,"record","home","resolution","copied","access_mode","words"}' <<<"$REF" && pass "the table gives the step's one-line JSON" || fail "step output not documented"

echo "--- the C.4.5 block runs only after a good upload and never fails the deploy"
SANDBOX="$TMP_REAL/sandbox"
mkdir -p "$SANDBOX/.claude/skills/deploy/scripts" "$SANDBOX/site"
printf '<html></html>\n' > "$SANDBOX/site/index.html"
# A stand-in step: logs its arguments, answers per STEP_MODE.
cat > "$SANDBOX/.claude/skills/deploy/scripts/deploy-record-step.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$STEP_LOG"
case "${STEP_MODE:-ok}" in
  ok) echo '{"ok":true,"record":"/x/r.md","home":"/x","resolution":"session","copied":true,"access_mode":"public","words":12}' ;;
  fail) echo '{"ok":false,"stage":"home","reason":"home_not_writable"}'; exit 1 ;;
  silent) exit 1 ;;
esac
STUB
chmod +x "$SANDBOX/.claude/skills/deploy/scripts/deploy-record-step.sh"
printf '%s\n' "$BLOCK" > "$SANDBOX/block.sh"
# run_block <upload_ok> <app_read ok|fail> <step mode>: prints RECORD_LINE.
run_block() {
  (
    cd "$SANDBOX" || exit 9
    set -euo pipefail
    export STEP_LOG="$SANDBOX/step.log" STEP_MODE="$3"
    rm -f "$STEP_LOG"
    deploy_request() {
      if [ "$APP_READ" = "ok" ]; then echo '{"id":"app-1","subdomain":"demo","accessMode":"public"}'; else return 1; fi
    }
    APP_READ="$2" API="https://api.example.test" APP_ID="app-1" LIVE_URL="https://demo.example.test"
    DEPLOY_TYPE=static ACCESS_MODE=public ORG_SLUG=bravo DEPLOY_ID=dep-1 ROUTE_URL_PATH=""
    RECORD_SOURCE="$SANDBOX/site" DEPLOY_DESCRIPTION="A demo page." DEPLOY_CONTENT_TYPE=demo-site
    if [ "$1" = "true" ]; then UPLOAD_OK=true; else unset UPLOAD_OK; fi
    # shellcheck disable=SC1091
    . "$SANDBOX/block.sh"
    printf 'RECORD_LINE=%s\n' "$RECORD_LINE"
  )
}
OUT="$(run_block false ok ok)"; RC=$?
[ "$RC" = 0 ] && [ "$OUT" = "RECORD_LINE=" ] && [ ! -e "$SANDBOX/step.log" ] && pass "no upload: the step does not run" || fail "ran without an upload (rc=$RC): $OUT"
OUT="$(run_block true ok ok)"; RC=$?
[ "$RC" = 0 ] && [ "$OUT" = "RECORD_LINE=" ] && pass "good upload, record written: no extra line" || fail "ok path (rc=$RC): $OUT"
grep -qx -- '--description' "$SANDBOX/step.log" && grep -qx 'A demo page.' "$SANDBOX/step.log" && grep -qx 'demo-site' "$SANDBOX/step.log" \
  && grep -qx 'bravo' "$SANDBOX/step.log" && grep -qx 'dep-1' "$SANDBOX/step.log" && ! grep -qx -- '--route' "$SANDBOX/step.log" \
  && pass "the step gets the description, type, company and deploy id, and no route outside route mode" || fail "step args: $(tr '\n' ' ' < "$SANDBOX/step.log")"
OUT="$(run_block true ok fail)"; RC=$?
[ "$RC" = 0 ] && [ "$OUT" = "RECORD_LINE=The searchable record for this deploy was not written (home_not_writable)." ] \
  && pass "a failed record is one plain line and the block still exits 0 under set -e" || fail "fail path (rc=$RC): $OUT"
OUT="$(run_block true ok silent)"; RC=$?
[ "$RC" = 0 ] && [ "$OUT" = "RECORD_LINE=The searchable record for this deploy was not written (unknown error)." ] \
  && pass "a step that prints nothing still yields one plain line" || fail "silent path (rc=$RC): $OUT"
OUT="$(run_block true fail ok)"; RC=$?
[ "$RC" = 0 ] && [ "$OUT" = "RECORD_LINE=The searchable record for this deploy was not written (the app or its source could not be read)." ] \
  && [ ! -e "$SANDBOX/step.log" ] && pass "an unreadable app skips the step with one plain line" || fail "app-read fail (rc=$RC): $OUT"

echo "--- deploy-record-step.sh end to end"
H="$TMP_REAL/hq"
mkdir -p "$H/companies/bravo/projects/web" "$H/workspace/sessions/sid-1"
printf 'companies:\n  bravo:\n    name: Bravo\n' > "$H/companies/manifest.yaml"
printf 'session_id: sid-1\ncompany_slug: bravo\nproject: web\n' > "$H/workspace/sessions/sid-1/meta.yaml"
DEPLOYS="$H/companies/bravo/projects/web/deploys"
run_step() {
  env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_SESSION_ID -u CODEX_SESSION_ID -u CODEX_THREAD_ID -u GROK_SESSION_ID -u HQ_ROOT \
    HQ_SESSION_ID=sid-1 HQ_DEPLOY_RECORD_PDFTOTEXT=none "$STEP" --hq-root "$H" "$@"
}
app_json() { # file subdomain accessMode
  printf '{"id":"app-%s","name":"%s","subdomain":"%s","url":"https://%s.example.test","type":"static","accessMode":"%s","createdAt":"2026-10-19T12:00:00Z"}\n' \
    "$2" "$2" "$2" "$2" "$3" > "$1"
}
SITE="$TMP_REAL/build/site"
mkdir -p "$SITE"
printf '<html><head><title>Q4 plan</title></head><body><p>Roadmap for the fourth quarter.</p></body></html>\n' > "$SITE/index.html"
app_json "$TMP_REAL/pub.json" q4-plan public
RES="$(run_step --app-json "$TMP_REAL/pub.json" --source "$SITE" --description "Q4 plan for the team." --type report --access-mode public --deploy-id dep-9)"; RC=$?
[ "$RC" = 0 ] && [ "$(field "$RES" ok)" = "true" ] && [ "$(field "$RES" record)" = "$DEPLOYS/q4-plan.md" ] && [ "$(field "$RES" resolution)" = "session" ] \
  && pass "static deploy: record lands in the session's project" || fail "static (rc=$RC): $RES"
[ "$(field "$RES" copied)" = "true" ] && [ -f "$DEPLOYS/q4-plan/source/index.html" ] && pass "the public source is copied next to the record" || fail "no copy: $RES"
grep -q 'Roadmap for the fourth quarter.' "$DEPLOYS/q4-plan.md" && grep -q '^source_path: "companies/bravo/projects/web/deploys/q4-plan/source"$' "$DEPLOYS/q4-plan.md" \
  && grep -q '^deploy_id: "dep-9"$' "$DEPLOYS/q4-plan.md" && pass "record has page text, the copied source path and the deploy id" || fail "record content"

RES="$(run_step --app-json "$TMP_REAL/pub.json" --source "$SITE" --description "   " --type report)"; RC=$?
[ "$RC" = 1 ] && [ "$(field "$RES" reason)" = "description_missing" ] && pass "an empty description is refused" || fail "empty description (rc=$RC): $RES"

app_json "$TMP_REAL/pw.json" board-notes password
RES="$(run_step --app-json "$TMP_REAL/pw.json" --source "$SITE" --description "Board notes, password protected." --type memo --access-mode password)"; RC=$?
[ "$RC" = 0 ] && [ "$(field "$RES" copied)" = "false" ] && [ "$(field "$RES" access_mode)" = "password" ] && [ ! -e "$DEPLOYS/board-notes" ] \
  && ! grep -q 'Roadmap' "$DEPLOYS/board-notes.md" && grep -q 'Board notes, password protected.' "$DEPLOYS/board-notes.md" \
  && pass "password deploy: description only, no copy" || fail "gated (rc=$RC): $RES"
RES="$(run_step --app-json "$TMP_REAL/pw.json" --source "$SITE" --description "Loosened." --type memo --access-mode public)"
[ "$(field "$RES" access_mode)" = "password" ] && [ "$(field "$RES" copied)" = "false" ] && pass "a public flag cannot loosen the app's password gate" || fail "flag loosened gate: $RES"

app_json "$TMP_REAL/host.json" team-hub public
RES="$(run_step --app-json "$TMP_REAL/host.json" --source "$SITE" --description "Team hub home." --type landing --access-mode public --route /2026-10-01/)"
RES="$(run_step --app-json "$TMP_REAL/host.json" --source "$SITE" --description "October second report." --type report --access-mode public --route /2026-10-02/)"; RC=$?
TAGS="$(grep '^tags: ' "$DEPLOYS/team-hub.md")"
[ "$RC" = 0 ] && grep -q '"route-2026-10-01"' <<<"$TAGS" && grep -q '"route-2026-10-02"' <<<"$TAGS" \
  && pass "route mode: the host record keeps earlier route tags and adds the new one" || fail "route tags (rc=$RC): $TAGS"
grep -qx 'Team hub home. Also at /2026-10-02/: October second report.' "$DEPLOYS/team-hub.md" \
  && pass "route mode: the new page's description is appended to the host's" || fail "route description: $(sed -n '/^# /{n;n;p;}' "$DEPLOYS/team-hub.md")"
run_step --app-json "$TMP_REAL/host.json" --source "$SITE" --description "October second report, revised." --type report --access-mode public --route /2026-10-02/ >/dev/null
run_step --app-json "$TMP_REAL/host.json" --source "$SITE" --description "October second report, final." --type report --access-mode public --route /2026-10-02/ >/dev/null
grep -qx 'Team hub home. Also at /2026-10-02/: October second report, final.' "$DEPLOYS/team-hub.md" \
  && pass "route mode: redeploying a route replaces its text instead of appending again" || fail "route redeploy: $(sed -n '/^# /{n;n;p;}' "$DEPLOYS/team-hub.md")"
LONG="$(printf 'Daily sales report with regional totals and notes %.0s' 1 2 3)"; LONG="${LONG% }"
for day in 03 04 05 06 07 08 09 10 11 12 13 14 15 16 17 18 19 20 21 22; do
  run_step --app-json "$TMP_REAL/host.json" --source "$SITE" --description "$LONG for October $day." --type report --access-mode public --route "/2026-10-$day/" >/dev/null
done
DESC="$(sed -n '/^# /{n;n;p;}' "$DEPLOYS/team-hub.md")"
[ "${#DESC}" -le 2000 ] && grep -q "Also at /2026-10-22/: $LONG for October 22.$" <<<"$DESC" && grep -q '^Team hub home. Also at ' <<<"$DESC" \
  && ! grep -q 'Also at /2026-10-03/' <<<"$DESC" \
  && pass "route mode: past the size cap the oldest routes drop and the newest route's text is kept" || fail "route cap (${#DESC} chars): ${DESC:0:200}...${DESC: -200}"

APPDIR="$H/companies/bravo/projects/web/api-app"
mkdir -p "$APPDIR/api"
printf '{"name":"invoice-api","description":"Invoice lookup API for the finance team."}\n' > "$APPDIR/package.json"
printf '# Invoice API\n\nLooks up invoices by number.\n\nUsed by the finance dashboard.\n' > "$APPDIR/README.md"
app_json "$TMP_REAL/app.json" invoice-api company
BEFORE="$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'hq-deploy-record-*' 2>/dev/null | wc -l | tr -d ' ')"
RES="$(run_step --app-json "$TMP_REAL/app.json" --source "$APPDIR" --description "Invoice API for finance." --type tool --access-mode company --deploy-type app)"; RC=$?
AFTER="$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'hq-deploy-record-*' 2>/dev/null | wc -l | tr -d ' ')"
[ "$RC" = 0 ] && [ "$(field "$RES" copied)" = "false" ] && grep -q 'Looks up invoices by number.' "$DEPLOYS/invoice-api.md" \
  && grep -q '^title: "invoice-api"$' "$DEPLOYS/invoice-api.md" \
  && pass "app deploy with no index.html: recorded from README and package.json" || fail "app stub (rc=$RC): $RES"
grep -q '^source_path: "companies/bravo/projects/web/api-app"$' "$DEPLOYS/invoice-api.md" && pass "app record names the real source, not the generated page" || fail "app source_path: $(grep '^source_path' "$DEPLOYS/invoice-api.md")"
[ "$BEFORE" = "$AFTER" ] && pass "the generated page is removed afterwards" || fail "stub temp dir left behind ($BEFORE -> $AFTER)"
mkdir -p "$TMP_REAL/bare-app"
RES="$(run_step --app-json "$TMP_REAL/app.json" --source "$TMP_REAL/bare-app" --description "x" --type tool --deploy-type app)"; RC=$?
[ "$RC" = 1 ] && [ "$(field "$RES" stage)" = "prepare" ] && [ "$(field "$RES" reason)" = "no_index_html" ] && pass "an app with nothing to read fails in prepare" || fail "bare app (rc=$RC): $RES"

RES="$(run_step --app-json "$TMP_REAL/pub.json" --source "$SITE" --description "x" --type report --company nope)"; RC=$?
[ "$RC" = 1 ] && [ "$(field "$RES" stage)" = "home" ] && [ "$(field "$RES" reason)" = "company_not_found" ] && pass "a home failure is reported with its stage" || fail "home fail (rc=$RC): $RES"
RES="$(run_step --app-json "$TMP_REAL/pub.json" --source "$SITE" --description "x" --type poster)"; RC=$?
[ "$RC" = 1 ] && [ "$(field "$RES" stage)" = "record" ] && [ "$(field "$RES" reason)" = "bad_args" ] && pass "a record failure is reported with its stage" || fail "record fail (rc=$RC): $RES"
printf 'nope' > "$TMP_REAL/bad.json"
RES="$(run_step --app-json "$TMP_REAL/bad.json" --source "$SITE" --description "x" --type report)"; RC=$?
[ "$RC" = 1 ] && [ "$(field "$RES" reason)" = "invalid_app_json" ] && pass "unreadable app JSON fails in prepare" || fail "bad app json (rc=$RC): $RES"

if [ "$FAIL" = 0 ]; then
  echo "deploy-skill-record.test.sh: PASS"
else
  echo "deploy-skill-record.test.sh: FAIL"
fi
exit "$FAIL"
