#!/usr/bin/env bash
# pass() never fails, so `cond && pass || fail` is a safe if/else here.
# shellcheck disable=SC2015
# deploy-record.test.sh — regression coverage for
# .claude/skills/deploy/scripts/deploy-record.sh, which writes a searchable
# markdown record of a finished deploy. Asserts: every frontmatter field is
# written and parses; page text is extracted from single- and multi-page sites
# with script, style, svg and the injected badge dropped; a rerun replaces the
# record in place; a missing index.html or an unwritable home exits non-zero
# and writes nothing; the body is capped at 1500 words; video wrappers record
# media names; same-site PDFs are read when pdftotext is available and tagged
# needs-description when it is not; narrow-gate deploys withhold page text;
# credential-shaped strings are redacted.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
REC="$ROOT/.claude/skills/deploy/scripts/deploy-record.sh"
FAIL=0
pass() { printf '  ok   %s\n' "$1"; }
fail() { printf '  FAIL %s\n' "$1"; FAIL=1; }

[ -x "$REC" ] || { echo "FAIL deploy-record.sh missing or not executable"; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "FAIL python3 is required to run this test"; exit 1; }

# field <json> <key> -> value of a top-level key (lists joined by commas).
field() {
  printf '%s' "$1" | python3 -I -c '
import json, sys
obj = json.loads(sys.stdin.read() or "{}")
val = obj.get(sys.argv[1], "")
if isinstance(val, list):
    val = ",".join(str(v) for v in val)
elif isinstance(val, bool):
    val = "true" if val else "false"
print(val)' "$2"
}

# fm <record.md> <key> -> frontmatter value, JSON-decoded; exits 3 if any
# frontmatter line is not `key: <JSON value>` (the record's YAML subset).
fm() {
  python3 -I -c '
import json, sys
lines = open(sys.argv[1], encoding="utf-8").read().split("\n")
assert lines[0] == "---", "no frontmatter"
end = lines.index("---", 1)
data = {}
for line in lines[1:end]:
    key, sep, raw = line.partition(": ")
    if not sep:
        sys.exit(3)
    data[key] = json.loads(raw)
val = data.get(sys.argv[2], "")
if isinstance(val, list):
    val = ",".join(str(v) for v in val)
elif isinstance(val, bool):
    val = "true" if val else "false"
print(val)' "$1" "$2"
}

# body <record.md> -> everything after the frontmatter.
body() { awk 'f>=2{print} /^---$/{f++}' "$1"; }

# absent <file> <pattern> <label>: the record must exist AND lack the pattern,
# so a run that wrote nothing can never pass a "did not leak" check.
absent() {
  if [ ! -f "$1" ]; then fail "$3 (record missing: $1)"
  elif grep -q -- "$2" "$1"; then fail "$3"
  else pass "$3"; fi
}

TMP="$(mktemp -d "${TMPDIR:-/tmp}/deploy-record-test.XXXXXX")"
trap 'chmod -R u+w "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT
TMP_REAL="$(cd "$TMP" && pwd -P)"
export HQ_DEPLOY_RECORD_PDFTOTEXT=none

app_json() { # file subdomain accessMode
  printf '{"id":"app-%s","name":"%s","subdomain":"%s","url":"https://%s.example.com","type":"static","accessMode":%s,"createdAt":"2026-10-01T12:00:00Z","status":"active"}\n' \
    "$2" "$2" "$2" "$2" "$3" > "$1"
}

# --- fixture: single page --------------------------------------------------
FAKE_KEY="AKIA""ABCDEFGHIJKLMNOP"
mkdir -p "$TMP/single"
cat > "$TMP/single/index.html" <<HTML
<!doctype html>
<html><head><title>Quarterly growth report</title>
<meta name="description" content="Revenue and retention for Q3.">
<style>.secret-css { color: red }</style>
<script>window.SECRET_SCRIPT = 1</script></head>
<body><header><h1>Q3 growth</h1></header>
<main><p>Revenue grew &amp; retention held at ninety percent.</p>
<svg><title>svg-title-noise</title><text>svg-text-noise</text></svg>
<noscript>noscript-noise</noscript>
<template><p>template-noise</p></template>
<img src="img/revenue.png?v=3" alt="Revenue by month">
<img src="data:image/png;base64,AAAA" alt="">
<p>Contact token ${FAKE_KEY} was rotated.</p></main>
<div id="hq-built-badge" hidden><a href="https://example.com">Built in HQ</a><div><span>badge-noise</span></div></div>
<footer><p>Footer after badge.</p></footer></body></html>
HTML
app_json "$TMP/single.json" "q3-growth" '"company"'

echo "--- happy path: single page"
mkdir -p "$TMP/hqa/companies/bravo/projects/growth-q3"
printf 'companies:\n  bravo:\n    name: Bravo\n' > "$TMP/hqa/companies/manifest.yaml"
HOME1="$TMP/hqa/companies/bravo/projects/growth-q3/deploys"
RES="$("$REC" --app-json "$TMP/single.json" --source "$TMP/single" --home "$HOME1" \
  --description "Q3 growth report for the board.
Second line." --type report --project growth-q3 --company bravo --created-by prs_test --deploy-id dep-42)"
RC=$?
REC1="$HOME1/q3-growth.md"
[ "$RC" = 0 ] && [ "$(field "$RES" ok)" = "true" ] && pass "exit 0 and ok:true" || fail "happy path failed (rc=$RC): $RES"
[ "$(field "$RES" record)" = "$TMP_REAL/hqa/companies/bravo/projects/growth-q3/deploys/q3-growth.md" ] && [ -f "$REC1" ] && pass "record written at <home>/<subdomain>.md (real path reported)" || fail "record path wrong: $RES"
fm "$REC1" record >/dev/null && pass "every frontmatter line is key: <JSON value>" || fail "frontmatter does not parse"
for key in app_id name subdomain url app_type type access_mode company project source_path created_by created_at recorded_at deploy_id title meta_description routes media words_extracted truncated tags; do
  grep -q "^$key: " "$REC1" || fail "frontmatter missing $key"
done
pass "all frontmatter fields present"
[ "$(fm "$REC1" app_id)" = "app-q3-growth" ] && [ "$(fm "$REC1" subdomain)" = "q3-growth" ] && [ "$(fm "$REC1" url)" = "https://q3-growth.example.com" ] && pass "app fields copied from app JSON" || fail "app fields wrong"
[ "$(fm "$REC1" app_type)" = "static" ] && [ "$(fm "$REC1" type)" = "report" ] && [ "$(fm "$REC1" access_mode)" = "company" ] && pass "app type, content type and access mode recorded" || fail "type fields wrong"
[ "$(fm "$REC1" company)" = "bravo" ] && [ "$(fm "$REC1" project)" = "growth-q3" ] && [ "$(fm "$REC1" created_by)" = "prs_test" ] && [ "$(fm "$REC1" deploy_id)" = "dep-42" ] && pass "company, project, creator and deploy id recorded" || fail "provenance fields wrong"
[ "$(fm "$REC1" created_at)" = "2026-10-01T12:00:00Z" ] && pass "created_at taken from the app" || fail "created_at wrong"
[ "$(fm "$REC1" title)" = "Quarterly growth report" ] && [ "$(fm "$REC1" meta_description)" = "Revenue and retention for Q3." ] && pass "title and meta description kept as separate fields" || fail "title/meta wrong"
[ "$(fm "$REC1" routes)" = "/" ] && pass "single page lists route /" || fail "routes wrong: $(fm "$REC1" routes)"
[ "$(fm "$REC1" media)" = "revenue.png" ] && pass "img basename recorded without query; data URI skipped" || fail "media wrong: $(fm "$REC1" media)"
[ "$(fm "$REC1" tags)" = "deploy,report,thin-text" ] && pass "tags carry deploy, the type and thin-text" || fail "tags wrong: $(fm "$REC1" tags)"
B="$(body "$REC1")"
printf '%s' "$B" | grep -q '^# Quarterly growth report$' && pass "heading is the page title" || fail "heading missing"
printf '%s' "$B" | grep -q '^Q3 growth report for the board. Second line.$' && pass "description collapsed to one paragraph" || fail "description missing or not collapsed"
printf '%s' "$B" | grep -q 'Revenue grew & retention held at ninety percent.' && pass "visible text extracted with entities decoded" || fail "page text missing"
printf '%s' "$B" | grep -q 'Revenue by month' && pass "image alt text included" || fail "alt text missing"
printf '%s' "$B" | grep -q 'Footer after badge.' && pass "text after the badge kept" || fail "text after badge lost"
for noise in secret-css SECRET_SCRIPT svg-title-noise svg-text-noise noscript-noise template-noise badge-noise "Built in HQ"; do
  absent "$REC1" "$noise" "dropped from record: $noise"
done
absent "$REC1" "$FAKE_KEY" "credential-shaped string redacted"
grep -q '<REDACTED:aws_key>' "$REC1" && pass "redaction marker names the pattern" || fail "redaction marker missing"
[ "$(field "$RES" type)" = "report" ] && [ "$(field "$RES" truncated)" = "false" ] && pass "JSON reports type and truncated" || fail "JSON fields wrong: $RES"

echo "--- multi-page site"
mkdir -p "$TMP/multi/2026-10-02" "$TMP/multi/node_modules/pkg" "$TMP/multi/.hidden"
printf '<html><head><title>Team hub</title></head><body><p>Hub home page.</p></body></html>\n' > "$TMP/multi/index.html"
printf '<html><body><p>Second route report.</p></body></html>\n' > "$TMP/multi/2026-10-02/index.html"
printf '<html><body><p>About page text.</p></body></html>\n' > "$TMP/multi/about.html"
printf '<html><body><p>node-modules-noise</p></body></html>\n' > "$TMP/multi/node_modules/pkg/index.html"
printf '<html><body><p>hidden-dir-noise</p></body></html>\n' > "$TMP/multi/.hidden/index.html"
app_json "$TMP/multi.json" "team-hub" 'null'
RES="$("$REC" --app-json "$TMP/multi.json" --source "$TMP/multi" --home "$TMP/home2" --description "Team hub with dated reports." --type report)"
REC2="$TMP/home2/team-hub.md"
[ "$(field "$RES" ok)" = "true" ] && pass "multi-page record written" || fail "multi-page failed: $RES"
[ "$(fm "$REC2" routes)" = "/,/2026-10-02/,/about.html" ] && pass "routes list root first, then other pages" || fail "routes wrong: $(fm "$REC2" routes)"
B="$(body "$REC2")"
printf '%s' "$B" | grep -q '^### /$' && printf '%s' "$B" | grep -q '^### /2026-10-02/$' && pass "each page gets a route heading" || fail "route headings missing"
printf '%s' "$B" | grep -q 'Hub home page.' && printf '%s' "$B" | grep -q 'Second route report.' && printf '%s' "$B" | grep -q 'About page text.' && pass "text from every page extracted" || fail "page text missing"
absent "$REC2" 'node-modules-noise\|hidden-dir-noise' "node_modules and dot-dirs skipped"
[ "$(fm "$REC2" access_mode)" = "public" ] && pass "null accessMode recorded as public" || fail "access mode wrong"

echo "--- overwrite in place"
RES="$("$REC" --app-json "$TMP/single.json" --source "$TMP/single" --home "$HOME1" --description "Replacement description." --type report)"
[ "$(field "$RES" ok)" = "true" ] && pass "second run ok" || fail "second run failed: $RES"
COUNT="$(find "$HOME1" -type f | wc -l | tr -d ' ')"
[ "$COUNT" = 1 ] && pass "exactly one file in home after rerun (no temp files)" || fail "expected 1 file, found $COUNT: $(ls -a "$HOME1")"
[ "$(fm "$REC1" company)" = "bravo" ] && [ "$(fm "$REC1" project)" = "growth-q3" ] && pass "company and project default to the home's path" || fail "path defaults: $(fm "$REC1" company)/$(fm "$REC1" project)"
grep -q 'Replacement description.' "$REC1" && ! grep -q 'Q3 growth report for the board' "$REC1" && pass "record replaced, old description gone" || fail "record not replaced"

echo "--- failure: no index.html"
mkdir -p "$TMP/noindex"
printf 'not html\n' > "$TMP/noindex/readme.txt"
RES="$("$REC" --app-json "$TMP/single.json" --source "$TMP/noindex" --home "$TMP/home3" --description "x" --type report)"
RC=$?
[ "$RC" != 0 ] && [ "$(field "$RES" reason)" = "no_index_html" ] && pass "missing index.html exits non-zero with reason" || fail "expected no_index_html non-zero (rc=$RC): $RES"
[ "$(printf '%s\n' "$RES" | wc -l | tr -d ' ')" = 1 ] && pass "failure is one line" || fail "failure output not one line"
[ ! -e "$TMP/home3" ] && pass "nothing written when index.html is missing" || fail "home created or record written"
RES="$("$REC" --app-json "$TMP/single.json" --source "$TMP/does-not-exist" --home "$TMP/home3" --description "x" --type report)"
RC=$?
[ "$RC" != 0 ] && [ "$(field "$RES" reason)" = "no_index_html" ] && [ ! -e "$TMP/home3" ] && pass "missing source dir exits non-zero, writes nothing" || fail "missing source dir (rc=$RC): $RES"

echo "--- failure: home not writable"
printf 'a file, not a dir\n' > "$TMP/blocker"
RES="$("$REC" --app-json "$TMP/single.json" --source "$TMP/single" --home "$TMP/blocker/home" --description "x" --type report)"
RC=$?
[ "$RC" != 0 ] && [ "$(field "$RES" reason)" = "home_not_writable" ] && pass "home under a file exits non-zero with reason" || fail "expected home_not_writable (rc=$RC): $RES"
[ "$(cat "$TMP/blocker")" = "a file, not a dir" ] && [ ! -e "$TMP/blocker/home" ] && pass "nothing written when home is not writable" || fail "blocker changed"
mkdir -p "$TMP/home-ro"
chmod 0555 "$TMP/home-ro"
if [ -w "$TMP/home-ro" ]; then
  # Running as root: permission bits do not stop writes, so the file-parent case above is the check.
  pass "read-only dir case not applicable as root (file-parent case covers it)"
else
  RES="$("$REC" --app-json "$TMP/single.json" --source "$TMP/single" --home "$TMP/home-ro" --description "x" --type report)"
  RC=$?
  [ "$RC" != 0 ] && [ "$(field "$RES" reason)" = "home_not_writable" ] && [ -z "$(ls -A "$TMP/home-ro")" ] && pass "read-only home exits non-zero, writes nothing" || fail "read-only home (rc=$RC): $RES"
fi
chmod 0755 "$TMP/home-ro"

echo "--- failure: a directory sits at the record path"
mkdir -p "$TMP/home-dir-clash/q3-growth.md/keep"
RES="$("$REC" --app-json "$TMP/single.json" --source "$TMP/single" --home "$TMP/home-dir-clash" --description "x" --type report)"
RC=$?
[ "$RC" = 1 ] && [ "$(field "$RES" reason)" = "record_conflict" ] && pass "a directory at the record path exits 1 with record_conflict" || fail "expected record_conflict (rc=$RC): $RES"
LEFT="$(find "$TMP/home-dir-clash" -maxdepth 1 -name '.*.tmp' | wc -l | tr -d ' ')"
[ "$LEFT" = 0 ] && pass "a failed write leaves no temp file" || fail "$LEFT temp file(s) left behind"
[ -d "$TMP/home-dir-clash/q3-growth.md/keep" ] && pass "existing path untouched" || fail "existing path changed"

echo "--- bad arguments exit 64"
RES="$("$REC" --app-json "$TMP/single.json" --source "$TMP/single" --home "$TMP/home4" --type report)"; RC=$?
[ "$RC" = 64 ] && [ "$(field "$RES" reason)" = "bad_args" ] && pass "missing --description -> 64" || fail "missing description (rc=$RC): $RES"
RES="$("$REC" --app-json "$TMP/single.json" --source "$TMP/single" --home "$TMP/home4" --description "   " --type report)"; RC=$?
[ "$RC" = 64 ] && [ "$(field "$RES" reason)" = "bad_args" ] && pass "blank --description -> 64" || fail "blank description (rc=$RC): $RES"
RES="$("$REC" --app-json "$TMP/single.json" --source "$TMP/single" --home "$TMP/home4" --description "x" --type slideshow)"; RC=$?
[ "$RC" = 64 ] && [ "$(field "$RES" reason)" = "bad_args" ] && pass "unknown --type -> 64" || fail "bad type (rc=$RC): $RES"
RES="$("$REC" --app-json "$TMP/single.json" --source "$TMP/single" --home "$TMP/home4" --description "x" --type report --tag 'Bad Tag')"; RC=$?
[ "$RC" = 64 ] && [ "$(field "$RES" reason)" = "bad_args" ] && pass "invalid --tag -> 64" || fail "bad tag (rc=$RC): $RES"
RES="$("$REC" --app-json "$TMP/single.json" --source "$TMP/single" --home "$TMP/home4" --description "x" --type report --bogus 1)"; RC=$?
[ "$RC" = 64 ] && pass "unknown option -> 64" || fail "unknown option (rc=$RC): $RES"
printf '{"subdomain":"../escape","url":"https://x.example.com"}' > "$TMP/evil.json"
RES="$("$REC" --app-json "$TMP/evil.json" --source "$TMP/single" --home "$TMP/home4" --description "x" --type report)"; RC=$?
[ "$RC" = 64 ] && [ "$(field "$RES" reason)" = "invalid_app_json" ] && pass "unsafe subdomain refused -> 64" || fail "unsafe subdomain (rc=$RC): $RES"
printf 'not json' > "$TMP/broken.json"
RES="$("$REC" --app-json "$TMP/broken.json" --source "$TMP/single" --home "$TMP/home4" --description "x" --type report)"; RC=$?
[ "$RC" = 64 ] && [ "$(field "$RES" reason)" = "invalid_app_json" ] && pass "malformed app JSON -> 64" || fail "broken json (rc=$RC): $RES"
[ ! -e "$TMP/home4" ] && pass "bad arguments write nothing" || fail "bad arguments created home"
[ ! -e "$TMP/escape.md" ] && pass "no file written outside home" || fail "path escape wrote a file"

echo "--- body capped at 1500 words"
mkdir -p "$TMP/long"
{
  printf '<html><head><title>Long explainer</title></head><body>'
  for i in $(seq 1 200); do printf '<p>word%s alpha beta gamma delta epsilon zeta eta theta iota</p>' "$i"; done
  printf '</body></html>\n'
} > "$TMP/long/index.html"
app_json "$TMP/long.json" "long-explainer" 'null'
RES="$("$REC" --app-json "$TMP/long.json" --source "$TMP/long" --home "$TMP/home5" --description "A long explainer." --type explainer)"
REC5="$TMP/home5/long-explainer.md"
[ "$(field "$RES" words)" = 2000 ] && [ "$(field "$RES" truncated)" = "true" ] && pass "2000 words reported, truncated true" || fail "word count wrong: $RES"
[ "$(fm "$REC5" words_extracted)" = 2000 ] && [ "$(fm "$REC5" truncated)" = "true" ] && pass "frontmatter records count and truncation" || fail "frontmatter count wrong"
BODY_WORDS="$(awk '/^## Page text$/{f=1;next} f' "$REC5" | wc -w | tr -d ' ')"
[ "$BODY_WORDS" = 1500 ] && pass "page text holds exactly 1500 words" || fail "page text has $BODY_WORDS words"
LAST_LINE="$(awk '/^## Page text$/{f=1;next} f && NF' "$REC5" | tail -1)"
[ "$LAST_LINE" = "word150 alpha beta gamma delta epsilon zeta eta theta iota" ] && pass "cap ends on the 1500th word" || fail "last kept line: $LAST_LINE"
absent "$REC5" 'word151 ' "nothing after the 1500th word kept"

echo "--- video wrapper page"
mkdir -p "$TMP/video"
printf '<html><head><title>Product overview video</title></head><body><main><h1>Product overview</h1><video controls src="media/overview.mp4" poster="poster.jpg"></video><video><source src="clip-2.webm" type="video/webm"></video></main></body></html>\n' > "$TMP/video/index.html"
app_json "$TMP/video.json" "product-overview" 'null'
RES="$("$REC" --app-json "$TMP/video.json" --source "$TMP/video" --home "$TMP/home6" --description "A two-minute walkthrough of the product." --type video)"
REC6="$TMP/home6/product-overview.md"
[ "$(fm "$REC6" media)" = "overview.mp4,clip-2.webm" ] && pass "video and source file names recorded" || fail "video media wrong: $(fm "$REC6" media)"
[ "$(fm "$REC6" tags)" = "deploy,video,thin-text" ] && pass "thin video page tagged thin-text" || fail "video tags wrong: $(fm "$REC6" tags)"
grep -q 'A two-minute walkthrough of the product.' "$REC6" && pass "description carries the meaning of a thin page" || fail "video description missing"

echo "--- PDF-embed deck page"
mkdir -p "$TMP/deck/files" "$TMP/outside"
printf '%%PDF-1.4 fake\n' > "$TMP/deck/files/partner-deck.pdf"
printf '%%PDF-1.4 outside\n' > "$TMP/outside/secret.pdf"
cat > "$TMP/deck/index.html" <<'HTML'
<html><head><title>Partner deck</title></head><body>
<header><h1>Partner deck</h1><a href="files/partner-deck.pdf" download>Download PDF</a></header>
<object data="files/partner-deck.pdf#view=FitH" type="application/pdf"><p>Open the PDF</p></object>
<a href="https://other.example.org/elsewhere.pdf">External PDF</a>
<a href="../outside/secret.pdf">Escaping PDF</a>
<embed src="/files/partner-deck.pdf">
</body></html>
HTML
app_json "$TMP/deck.json" "partner-deck" 'null'
mkdir -p "$TMP/bin"
cat > "$TMP/bin/fake-pdftotext" <<'STUB'
#!/usr/bin/env bash
# Stand-in for pdftotext. Insists on the real CLI shape the script must use:
# a page limit and "-" as the last argument (stdout, not a .txt beside the PDF).
for last; do :; done
[ "$last" = "-" ] || { echo "stub: last argument must be -" >&2; exit 9; }
case " $* " in *" -l "*) ;; *) echo "stub: missing -l page limit" >&2; exit 9 ;; esac
pdf=""
for arg; do case "$arg" in *.pdf) pdf="$arg" ;; esac; done
printf 'Partner programme terms and revenue share from %s\n' "$(basename "$pdf")"
printf 'call %s\n' "$pdf" >> "${FAKE_PDF_LOG:?}"
STUB
chmod +x "$TMP/bin/fake-pdftotext"
export FAKE_PDF_LOG="$TMP/pdf-calls.log"
: > "$FAKE_PDF_LOG"
RES="$(HQ_DEPLOY_RECORD_PDFTOTEXT="$TMP/bin/fake-pdftotext" "$REC" --app-json "$TMP/deck.json" --source "$TMP/deck" --home "$TMP/home7" --description "Partner deck as a PDF." --type pdf-deck)"
REC7="$TMP/home7/partner-deck.md"
[ "$(field "$RES" ok)" = "true" ] && pass "PDF deck record written" || fail "PDF deck failed: $RES"
grep -q '^### PDF: partner-deck.pdf$' "$REC7" && grep -q 'Partner programme terms and revenue share from partner-deck.pdf' "$REC7" && pass "same-site PDF text extracted" || fail "PDF text missing"
[ "$(wc -l < "$FAKE_PDF_LOG" | tr -d ' ')" = 1 ] && pass "one PDF read once despite three references" || fail "PDF read $(wc -l < "$FAKE_PDF_LOG") times"
absent "$FAKE_PDF_LOG" 'secret.pdf\|elsewhere.pdf' "external-host and path-escaping PDFs ignored"
absent "$REC7" 'needs-description' "no needs-description when the PDF was read"
TXT_FILES="$(find "$TMP/deck" -name '*.txt' | wc -l | tr -d ' ')"
[ "$TXT_FILES" = 0 ] && pass "no .txt written into the source tree" || fail "pdftotext output landed in the source tree"
RES="$(HQ_DEPLOY_RECORD_PDFTOTEXT=none "$REC" --app-json "$TMP/deck.json" --source "$TMP/deck" --home "$TMP/home8" --description "Partner deck as a PDF." --type pdf-deck)"
RC=$?
REC8="$TMP/home8/partner-deck.md"
[ "$RC" = 0 ] && [ "$(field "$RES" ok)" = "true" ] && pass "missing PDF tool does not fail the record" || fail "no-tool run failed (rc=$RC): $RES"
[ "$(fm "$REC8" tags)" = "deploy,pdf-deck,thin-text,needs-description" ] && pass "missing PDF tool adds needs-description" || fail "no-tool tags wrong: $(fm "$REC8" tags)"
RES="$(HQ_DEPLOY_RECORD_PDFTOTEXT="$TMP/bin/not-there" "$REC" --app-json "$TMP/deck.json" --source "$TMP/deck" --home "$TMP/home9" --description "Partner deck." --type pdf-deck)"
grep -q 'needs-description' "$TMP/home9/partner-deck.md" && pass "non-executable PDF tool path treated as missing" || fail "bad tool path not handled"

echo "--- narrow gates withhold page text"
app_json "$TMP/pw.json" "board-memo" '"password"'
RES="$("$REC" --app-json "$TMP/pw.json" --source "$TMP/single" --home "$TMP/home10" --description "Board memo, password protected." --type memo)"
REC10="$TMP/home10/board-memo.md"
[ "$(field "$RES" ok)" = "true" ] && pass "password deploy record written" || fail "password deploy failed: $RES"
absent "$REC10" 'Revenue grew' "password deploy has no page text"
[ "$(fm "$REC10" title)" = "" ] && [ "$(fm "$REC10" meta_description)" = "" ] && [ "$(fm "$REC10" media)" = "" ] && pass "title, meta description and file names withheld" || fail "narrow-gate metadata leaked"
[ "$(fm "$REC10" routes)" = "/" ] && [ "$(fm "$REC10" words_extracted)" = 0 ] && pass "routes and word count withheld" || fail "narrow-gate routes/count leaked: $(fm "$REC10" routes) $(fm "$REC10" words_extracted)"
[ "$(fm "$REC10" tags)" = "deploy,memo,text-withheld" ] && pass "tagged text-withheld, no content-derived tags" || fail "narrow-gate tags: $(fm "$REC10" tags)"
grep -q '^# board-memo$' "$REC10" && grep -q 'Board memo, password protected.' "$REC10" && pass "heading falls back to the app name; description kept" || fail "narrow-gate heading or description wrong"
for gate in private selected; do
  app_json "$TMP/$gate.json" "gated-$gate" "\"$gate\""
  "$REC" --app-json "$TMP/$gate.json" --source "$TMP/single" --home "$TMP/home10" --description "Gated." --type memo >/dev/null
  absent "$TMP/home10/gated-$gate.md" 'Revenue grew' "$gate deploy withholds page text"
done

echo "--- access mode is resolved fail-closed"
# gate_case <subdomain> <app JSON fields> <expected access_mode> [extra args]
gate_case() {
  printf '{"id":"g","name":"%s","subdomain":"%s","url":"https://%s.example.com","type":"static",%s}\n' "$1" "$1" "$1" "$2" > "$TMP/gate-$1.json"
  local sub="$1" fields="$2" want="$3"; shift 3
  RES="$("$REC" --app-json "$TMP/gate-$sub.json" --source "$TMP/single" --home "$TMP/home-gates" --description "Gate case." --type memo "$@")"
  if [ "$(field "$RES" access_mode)" = "$want" ]; then pass "$fields $* -> $want"; else fail "$fields $* -> $(field "$RES" access_mode), want $want: $RES"; fi
}
gate_case legacy-pw '"passwordProtected":true' password
gate_case legacy-private '"privateMode":true,"accessMode":"public"' private
gate_case policy-selected '"accessPolicy":{"mode":"selected"},"accessMode":null' selected
gate_case cased '"accessMode":"Password"' password
gate_case unknown-mode '"accessMode":"partners-only"' unknown
gate_case typed-mode '"accessMode":7' unknown
gate_case plain-company '"accessMode":"company"' company
gate_case gate-after-upload '"accessMode":null' password --access-mode password
gate_case no-gate-fields '"status":"active"' unknown
gate_case mode-public-but-password '"accessMode":"public","passwordProtected":true' password
gate_case policy-public-but-private '"accessPolicy":{"mode":"public"},"privateMode":true' private
gate_case legacy-null-fields '"accessMode":null,"privateMode":false,"passwordProtected":false' public
gate_case override-cannot-loosen '"passwordProtected":true' password --access-mode company
gate_case private-beats-public-flag '"accessMode":"private"' private --access-mode public
gate_case unknown-beats-company-flag '"accessMode":"partners-only"' unknown --access-mode company
gate_case flag-tightens-company '"accessMode":"company"' selected --access-mode selected
gate_case flag-company-on-public '"accessMode":"public"' company --access-mode company
for sub in legacy-pw legacy-private policy-selected cased unknown-mode typed-mode gate-after-upload \
           no-gate-fields mode-public-but-password policy-public-but-private \
           override-cannot-loosen private-beats-public-flag unknown-beats-company-flag flag-tightens-company; do
  absent "$TMP/home-gates/$sub.md" 'Revenue grew' "page text withheld for $sub"
done
grep -q 'Revenue grew' "$TMP/home-gates/plain-company.md" && pass "company deploy keeps page text" || fail "company deploy lost its text"
RES="$("$REC" --app-json "$TMP/single.json" --source "$TMP/single" --home "$TMP/home-gates" --description "x" --type memo --access-mode everyone)"; RC=$?
[ "$RC" = 64 ] && [ "$(field "$RES" reason)" = "bad_args" ] && pass "unknown --access-mode -> 64" || fail "bad --access-mode (rc=$RC): $RES"

echo "--- extra tags, source path and file mode"
mkdir -p "$TMP/hq/companies/bravo/projects/growth/site"
printf 'companies:\n  bravo:\n    name: Bravo\n' > "$TMP/hq/companies/manifest.yaml"
cp "$TMP/single/index.html" "$TMP/hq/companies/bravo/projects/growth/site/index.html"
RES="$( (umask 022; "$REC" --app-json "$TMP/single.json" --source "$TMP/hq/companies/bravo/projects/growth/site" --home "$TMP/hq/companies/bravo/projects/growth/deploys" --description "In-HQ source." --type report --tag backfill --tag report))"
REC11="$TMP/hq/companies/bravo/projects/growth/deploys/q3-growth.md"
[ "$(fm "$REC11" source_path)" = "companies/bravo/projects/growth/site" ] && pass "source path stored relative to the HQ root" || fail "source_path wrong: $(fm "$REC11" source_path)"
[ "$(fm "$REC11" tags)" = "deploy,report,thin-text,backfill" ] && pass "--tag appended once, duplicates dropped" || fail "extra tags wrong: $(fm "$REC11" tags)"
MODE="$(python3 -I -c 'import os,stat,sys; print(oct(stat.S_IMODE(os.stat(sys.argv[1]).st_mode)))' "$REC11")"
[ "$MODE" = "0o644" ] && pass "record mode follows umask (0644)" || fail "record mode is $MODE"

echo "--- only regular files inside the source are read"
mkdir -p "$TMP/links/sub" "$TMP/outside-notes"
printf 'OUTSIDE-SECRET-MARKER private notes\n' > "$TMP/outside-notes/notes.txt"
printf '<html><head><title>Links root</title></head><body><p>Root page text.</p></body></html>\n' > "$TMP/links/index.html"
printf '<html><head><title>About us</title></head><body><p>About text.</p></body></html>\n' > "$TMP/links/sub/about.html"
ln -s ../outside-notes/notes.txt "$TMP/links/notes.html"
ln -s missing-target.html "$TMP/links/old.html"
ln -s index.html "$TMP/links/home.html"
mkfifo "$TMP/links/live.html"
app_json "$TMP/links.json" "links-site" 'null'
RES="$("$REC" --app-json "$TMP/links.json" --source "$TMP/links" --home "$TMP/home14" --description "Links fixture." --type report)"
RC=$?
REC14="$TMP/home14/links-site.md"
[ "$RC" = 0 ] && [ "$(field "$RES" ok)" = "true" ] && pass "dangling link and FIFO do not abort or hang the run" || fail "links fixture failed (rc=$RC): $RES"
absent "$REC14" 'OUTSIDE-SECRET-MARKER' "symlink to a file outside the source is not read"
[ "$(fm "$REC14" routes)" = "/,/sub/about.html" ] && pass "out-of-tree, dangling, FIFO and alias pages skipped" || fail "routes wrong: $(fm "$REC14" routes)"
grep -q '^### /sub/about.html (About us)$' "$REC14" && pass "each page's title is in its heading" || fail "page title missing from heading"
mkdir -p "$TMP/rootlink"
printf '<html><body><p>OUTSIDE-ROOT-MARKER</p></body></html>\n' > "$TMP/outside-notes/page.html"
ln -s ../outside-notes/page.html "$TMP/rootlink/index.html"
RES="$("$REC" --app-json "$TMP/links.json" --source "$TMP/rootlink" --home "$TMP/home15" --description "x" --type report)"
RC=$?
[ "$RC" = 1 ] && [ "$(field "$RES" reason)" = "no_index_html" ] && [ ! -e "$TMP/home15" ] && pass "root index.html linking outside the source is refused" || fail "outside root link (rc=$RC): $RES"

echo "--- malformed markup and odd references"
mkdir -p "$TMP/bad"
printf '<html><body><p>kept before bad markup</p><![foo[ bar ]]><p>after bad markup</p><a href="files/report%%00.pdf">nul</a></body></html>\n' > "$TMP/bad/index.html"
app_json "$TMP/bad.json" "bad-markup" 'null'
RES="$("$REC" --app-json "$TMP/bad.json" --source "$TMP/bad" --home "$TMP/home16" --description "Bad markup." --type stub)"
RC=$?
REC16="$TMP/home16/bad-markup.md"
[ "$RC" = 0 ] && [ "$(field "$RES" ok)" = "true" ] && pass "malformed markup and a NUL in a link still write a record" || fail "bad markup (rc=$RC): $RES"
grep -q 'kept before bad markup' "$REC16" && pass "text before the bad markup kept" || fail "text lost"
if printf '%s' "$(fm "$REC16" tags)" | grep -q 'extract-partial' || grep -q 'after bad markup' "$REC16"; then
  pass "parse failure is tagged extract-partial, or the parser recovered"
else
  fail "text after bad markup lost without an extract-partial tag"
fi

echo "--- nested skipped subtrees"
mkdir -p "$TMP/nested"
printf '<html><body><svg><svg><text>inner-svg-noise</text></svg><text>outer-svg-noise</text></svg><template><template><p>inner-tpl-noise</p></template><p>outer-tpl-noise</p></template><div id="hq-built-badge"><div><div>deep-badge-noise</div></div></div><p>after nested blocks</p></body></html>\n' > "$TMP/nested/index.html"
app_json "$TMP/nested.json" "nested-skip" 'null'
"$REC" --app-json "$TMP/nested.json" --source "$TMP/nested" --home "$TMP/home17" --description "Nested." --type stub >/dev/null
REC17="$TMP/home17/nested-skip.md"
for noise in inner-svg-noise outer-svg-noise inner-tpl-noise outer-tpl-noise deep-badge-noise; do
  absent "$REC17" "$noise" "nested subtree dropped: $noise"
done
grep -q 'after nested blocks' "$REC17" && pass "text after nested subtrees kept" || fail "skip never ended"

echo "--- caps and escaping in frontmatter"
mkdir -p "$TMP/caps"
LONG="$(for i in $(seq 1 600); do printf 'lorem%s ' "$i"; done)"
printf '<html><head><title>%s</title><meta name="description" content="%s"></head><body><p>Caps page.</p></body></html>\n' "$LONG" "$LONG" > "$TMP/caps/index.html"
app_json "$TMP/caps.json" "caps-page" 'null'
"$REC" --app-json "$TMP/caps.json" --source "$TMP/caps" --home "$TMP/home18" --description "Caps." --type stub >/dev/null
REC18="$TMP/home18/caps-page.md"
TITLE_LEN="$(fm "$REC18" title | wc -c | tr -d ' ')"
META_LEN="$(fm "$REC18" meta_description | wc -c | tr -d ' ')"
[ "$TITLE_LEN" -le 205 ] && pass "title capped at 200 characters" || fail "title is $TITLE_LEN chars"
[ "$META_LEN" -le 505 ] && pass "meta description capped at 500 characters" || fail "meta is $META_LEN chars"
mkdir -p "$TMP/unclosed"
printf '<html><head><title>Unclosed title %s<body><p>Body after unclosed title.</p></body></html>\n' "$LONG" > "$TMP/unclosed/index.html"
app_json "$TMP/unclosed.json" "unclosed-title" 'null'
RES="$("$REC" --app-json "$TMP/unclosed.json" --source "$TMP/unclosed" --home "$TMP/home19" --description "Unclosed." --type stub)"
TITLE_LEN="$(fm "$TMP/home19/unclosed-title.md" title | wc -c | tr -d ' ')"
[ "$(field "$RES" ok)" = "true" ] && [ "$TITLE_LEN" -le 205 ] && pass "an unclosed title cannot swallow the page into frontmatter" || fail "unclosed title ($TITLE_LEN chars): $RES"
mkdir -p "$TMP/odd"
python3 -I -c 'import sys; open(sys.argv[1], "w", encoding="utf-8").write("<html><head><title>Deck\x7f v2 \u0080   café ☃</title></head><body><p>Odd chars.</p></body></html>\n")' "$TMP/odd/index.html"
app_json "$TMP/odd.json" "odd-chars" 'null'
"$REC" --app-json "$TMP/odd.json" --source "$TMP/odd" --home "$TMP/home20" --description "Odd." --type stub >/dev/null
NONASCII="$(awk 'NR==1{next} /^---$/{exit} {print}' "$TMP/home20/odd-chars.md" | LC_ALL=C grep -c '[^ -~]')"
[ "$NONASCII" = 0 ] && pass "frontmatter is plain ASCII (controls and U+2028 escaped)" || fail "$NONASCII frontmatter lines carry raw non-ASCII"
fm "$TMP/home20/odd-chars.md" title | grep -q 'caf' && pass "escaped title still decodes" || fail "title lost"

echo "--- more credential shapes are redacted"
mkdir -p "$TMP/creds"
JWT_VAL="eyJ""hbGciOiJIUzI1NiJ9.eyJ""zdWIiOiIxMjM0NTY3ODkwIn0.abcdefghijklmnop"
CONN_VAL="admin:""s3cretpw"
ENV_VAL="hunter2""-env-value"
BEARER_VAL="abcdefghij""klmnopqrst"
GHS_VAL="ghs""_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
GLPAT_VAL="glpat""-abcdefghijklmnopqrstu"
XAPP_VAL="xapp""-1-A0123456789-abcdef0123"
ASIA_VAL="ASIA""ABCDEFGHIJKLMNOP"
HOOK_VAL="hooks.slack.com/services/""T0000/B0000/XXXXXXXXXXXX"
RK_VAL="rk_""live_ABCDEFGHIJKLMNOPQRSTUVWX"
PEM_BODY="MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcw""PEMBODYMARKER"
{
  printf '<html><body><pre>\n'
  printf 'token %s\n' "$JWT_VAL"
  printf 'DATABASE_URL=postgres://%s@db.example.com/app\n' "$CONN_VAL"
  printf 'DB_PASSWORD=%s\n' "$ENV_VAL"
  printf 'authorization: bearer %s\n' "$BEARER_VAL"
  printf 'gh %s gl %s app %s aws %s rk %s\n' "$GHS_VAL" "$GLPAT_VAL" "$XAPP_VAL" "$ASIA_VAL" "$RK_VAL"
  printf 'webhook https://%s\n' "$HOOK_VAL"
  printf -- '-----BEGIN %s-----\n%s\n-----END %s-----\n' "PRIVATE KEY" "$PEM_BODY" "PRIVATE KEY"
  printf '</pre></body></html>\n'
} > "$TMP/creds/index.html"
app_json "$TMP/creds.json" "creds-page" 'null'
"$REC" --app-json "$TMP/creds.json" --source "$TMP/creds" --home "$TMP/home21" --description "Creds." --type stub >/dev/null
REC21="$TMP/home21/creds-page.md"
for val in "$JWT_VAL" "$CONN_VAL" "$ENV_VAL" "$BEARER_VAL" "$GHS_VAL" "$GLPAT_VAL" "$XAPP_VAL" "$ASIA_VAL" "$HOOK_VAL" "$RK_VAL" PEMBODYMARKER; do
  absent "$REC21" "$val" "redacted: ${val:0:6}..."
done
grep -q 'db.example.com/app' "$REC21" && pass "connection string keeps its host, loses its credentials" || fail "connection host lost"

echo "--- query-string tokens and lowercase secrets are redacted"
mkdir -p "$TMP/creds2"
QS_TOKEN="qs""tokenvalue123"
QS_SIG="sig""value456"
QS_KEY="mapkey""789xyz"
LOW_PW="hunter""22lower"
LOW_TOKEN="tok""abc123lower"
LOW_APIKEY="apik""eyvalue000"
LOW_ENV="lowerenv""value999"
{
  printf '<html><body>\n'
  printf '<p><a href="https://files.example.com/report.pdf?token=%s&amp;v=2">Download</a></p>\n' "$QS_TOKEN"
  printf '<p>Signed link https://cdn.example.com/a.png?X-Amz-Signature=%s&amp;x=1</p>\n' "$QS_SIG"
  printf '<p>Maps https://maps.example.com/js?key=%s#map</p>\n' "$QS_KEY"
  printf '<pre>password: %s\ntoken = %s\napiKey: "%s"\ndb_password=%s</pre>\n' "$LOW_PW" "$LOW_TOKEN" "$LOW_APIKEY" "$LOW_ENV"
  printf '<p>Reset your password in settings.</p>\n'
  printf '</body></html>\n'
} > "$TMP/creds2/index.html"
printf '{"id":"c2","name":"creds-two","subdomain":"creds-two","url":"https://creds-two.example.com/?token=%s","type":"static","accessMode":null}\n' "$QS_TOKEN" > "$TMP/creds2.json"
"$REC" --app-json "$TMP/creds2.json" --source "$TMP/creds2" --home "$TMP/home22" --description "Creds two, see ?token=$QS_TOKEN" --type stub >/dev/null
REC22="$TMP/home22/creds-two.md"
for val in "$QS_TOKEN" "$QS_SIG" "$QS_KEY" "$LOW_PW" "$LOW_TOKEN" "$LOW_APIKEY" "$LOW_ENV"; do
  absent "$REC22" "$val" "redacted: ${val:0:6}..."
done
grep -q 'Reset your password in settings.' "$REC22" && pass "prose that mentions a password is kept" || fail "plain prose redacted"
grep -q '<REDACTED:url_secret>' "$REC22" && grep -q '<REDACTED:secret_assignment>' "$REC22" && pass "markers name the query-string and assignment patterns" || fail "new markers missing"
[ "$(fm "$REC22" url)" = "https://creds-two.example.com/?token=<REDACTED:url_secret>" ] && pass "the app URL is redacted in the frontmatter" || fail "url field: $(fm "$REC22" url)"

echo "--- the record stays inside the company it names"
mkdir -p "$TMP/hqb/companies/bravo/projects/web" "$TMP/hqb/companies/other/projects/x" "$TMP/hqb/companies/stray" "$TMP/hqb/workspace"
printf 'companies:\n  bravo:\n    name: Bravo\n  other:\n    name: Other\n' > "$TMP/hqb/companies/manifest.yaml"
co_case() { # label expected-reason args...
  local label="$1" want="$2"; shift 2
  RES="$("$REC" --app-json "$TMP/single.json" --source "$TMP/single" --description "Co case." --type report "$@")"; RC=$?
  if [ "$RC" = 64 ] && [ "$(field "$RES" reason)" = "$want" ]; then pass "$label -> $want"; else fail "$label (rc=$RC): $RES"; fi
}
co_case "parent-directory --company" bad_args --company ../other --home "$TMP/hqb/companies/bravo/deploys"
co_case "--company with a slash" bad_args --company bravo/x --home "$TMP/hqb/companies/bravo/deploys"
co_case "uppercase --project" bad_args --company bravo --project Web --home "$TMP/hqb/companies/bravo/projects/web/deploys"
co_case "home in another company" home_outside_company --company bravo --home "$TMP/hqb/companies/other/projects/x/deploys"
co_case "home climbing out with .." home_outside_company --company bravo --home "$TMP/hqb/companies/bravo/../other/deploys"
co_case "home is companies/ itself" home_outside_company --home "$TMP/hqb/companies"
co_case "home outside companies/ with --company" home_outside_company --company bravo --home "$TMP/hqb/workspace/deploys"
co_case "home outside any HQ with --company" home_outside_company --company bravo --home "$TMP/home23"
co_case "company folder not in the manifest" company_not_found --home "$TMP/hqb/companies/stray/deploys"
co_case "--project not matching the home" home_outside_company --company bravo --project other --home "$TMP/hqb/companies/bravo/projects/web/deploys"
[ ! -e "$TMP/hqb/companies/other/deploys" ] && [ ! -e "$TMP/hqb/companies/other/projects/x/deploys" ] && [ ! -e "$TMP/hqb/companies/stray/deploys" ] && [ ! -e "$TMP/home23" ] \
  && pass "a refused home is never created" || fail "refused home was created"
ln -s "$TMP/hqb/companies/other" "$TMP/hqb/companies/bravo/link-to-other"
co_case "home through a symlink into another company" home_outside_company --company bravo --home "$TMP/hqb/companies/bravo/link-to-other/deploys"
RES="$("$REC" --app-json "$TMP/single.json" --source "$TMP/single" --description "Company deploy." --type report --home "$TMP/hqb/companies/bravo/deploys")"
[ "$(field "$RES" ok)" = "true" ] && [ "$(fm "$TMP/hqb/companies/bravo/deploys/q3-growth.md" company)" = "bravo" ] && [ "$(fm "$TMP/hqb/companies/bravo/deploys/q3-growth.md" project)" = "" ] \
  && pass "company fallback home records the company and no project" || fail "fallback home: $RES"

echo "--- a file that is not a record is never overwritten"
mkdir -p "$TMP/home24"
printf 'Hand-written notes, not a record.\n' > "$TMP/home24/q3-growth.md"
RES="$("$REC" --app-json "$TMP/single.json" --source "$TMP/single" --home "$TMP/home24" --description "x" --type report)"; RC=$?
[ "$RC" = 1 ] && [ "$(field "$RES" reason)" = "record_conflict" ] && grep -q 'Hand-written notes' "$TMP/home24/q3-growth.md" \
  && pass "a non-record file at the record path is left alone" || fail "non-record overwritten (rc=$RC): $RES"
[ "$(find "$TMP/home24" -type f | wc -l | tr -d ' ')" = 1 ] && pass "no temp file left after a conflict" || fail "temp left after conflict"
mkdir -p "$TMP/home25"
printf 'target of a link\n' > "$TMP/home25-target.md"
ln -s "$TMP/home25-target.md" "$TMP/home25/q3-growth.md"
RES="$("$REC" --app-json "$TMP/single.json" --source "$TMP/single" --home "$TMP/home25" --description "x" --type report)"; RC=$?
[ "$RC" = 1 ] && [ "$(field "$RES" reason)" = "record_conflict" ] && [ -L "$TMP/home25/q3-growth.md" ] && grep -q 'target of a link' "$TMP/home25-target.md" \
  && pass "a symlink at the record path is left alone" || fail "symlink replaced (rc=$RC): $RES"
mkdir -p "$TMP/home27"
ln -s "$REC1" "$TMP/home27/q3-growth.md"
SUM_BEFORE="$(cksum < "$REC1")"
RES="$("$REC" --app-json "$TMP/single.json" --source "$TMP/single" --home "$TMP/home27" --description "x" --type report)"; RC=$?
[ "$RC" = 1 ] && [ "$(field "$RES" reason)" = "record_conflict" ] && [ -L "$TMP/home27/q3-growth.md" ] && [ "$(cksum < "$REC1")" = "$SUM_BEFORE" ] \
  && pass "a symlink to another record is left alone" || fail "symlink to record replaced (rc=$RC): $RES"
mkdir -p "$TMP/home26/q3-growth.md"
RES="$("$REC" --app-json "$TMP/single.json" --source "$TMP/single" --home "$TMP/home26" --description "x" --type report)"; RC=$?
[ "$RC" = 1 ] && [ "$(field "$RES" reason)" = "record_conflict" ] && pass "a directory at the record path is a conflict" || fail "dir at record path (rc=$RC): $RES"

echo "--- review follow-ups from #1382"
GHP_VAL="ghp""_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
mkdir -p "$TMP/untitled"
printf '<html><body><p>No title tag on this page.</p></body></html>\n' > "$TMP/untitled/index.html"
printf '{"id":"u1","name":"untitled-app","subdomain":"untitled-app","url":"https://untitled-app.example.com","type":"static","accessMode":null,"title":"Launch %s"}\n' "$GHP_VAL" > "$TMP/untitled.json"
"$REC" --app-json "$TMP/untitled.json" --source "$TMP/untitled" --home "$TMP/home28" --description "Untitled." --type stub \
  --created-by "password: hunter""22creator" --deploy-id "dep-$GHP_VAL" >/dev/null
REC28="$TMP/home28/untitled-app.md"
grep -q '^# Launch <REDACTED:github_pat>$' "$REC28" && pass "the app title used as the heading is redacted" || fail "heading: $(grep '^# ' "$REC28")"
absent "$REC28" "$GHP_VAL" "no token from the app title, --deploy-id or --created-by"
absent "$REC28" "hunter22creator" "--created-by is redacted"

mkdir -p "$TMP/hqp/companies/bravo/projects/x/companies/other/deploys" "$TMP/hqp/companies/other"
printf 'companies:\n  bravo:\n    name: Bravo\n  other:\n    name: Other\n' > "$TMP/hqp/companies/manifest.yaml"
printf 'companies:\n  other:\n    name: Other\n' > "$TMP/hqp/companies/bravo/projects/x/companies/manifest.yaml"
PLANT="$TMP/hqp/companies/bravo/projects/x/companies/other/deploys"
RES="$("$REC" --app-json "$TMP/single.json" --source "$TMP/single" --home "$PLANT" --description "x" --type report --company other)"; RC=$?
[ "$RC" = 64 ] && [ "$(field "$RES" reason)" = "home_outside_company" ] && [ ! -e "$PLANT/q3-growth.md" ] \
  && pass "a manifest planted in bravo's tree cannot label a record for another company" || fail "planted manifest (rc=$RC): $RES"
RES="$("$REC" --app-json "$TMP/single.json" --source "$TMP/single" --home "$PLANT" --description "x" --type report)"
[ "$(fm "$PLANT/q3-growth.md" company)" = "bravo" ] && [ "$(fm "$PLANT/q3-growth.md" project)" = "x" ] \
  && pass "the outermost HQ decides the company (bravo, project x)" || fail "planted default: $RES"

"$REC" --app-json "$TMP/single.json" --source "$TMP/single" --home "$TMP/home29" --description "x" --type report \
  --source-path "companies/bravo/projects/x/api-app?token=$GHP_VAL" >/dev/null
case "$(fm "$TMP/home29/q3-growth.md" source_path)" in "companies/bravo/projects/x/api-app?token=<REDACTED:"*">") true ;; *) false ;; esac \
  && pass "--source-path is recorded as given, redacted" || fail "source-path: $(fm "$TMP/home29/q3-growth.md" source_path)"

echo "--- record path is real even for a relative home"
RES="$(cd "$TMP" && "$REC" --app-json "$TMP/single.json" --source "$TMP/single" --home relhome --description "Relative." --type report)"
WANT="$TMP_REAL/relhome/q3-growth.md"
[ "$(field "$RES" record)" = "$WANT" ] && [ -f "$WANT" ] && pass "JSON record path is absolute and real" || fail "record path: $(field "$RES" record) want $WANT"

echo "--- missing python"
mkdir -p "$TMP/nopy"
for tool in dirname; do ln -s "$(command -v "$tool")" "$TMP/nopy/$tool"; done
RES="$(PATH="$TMP/nopy" "$BASH" "$REC" --app-json "$TMP/single.json" --source "$TMP/single" --home "$TMP/home12" --description "x" --type report)"
RC=$?
[ "$RC" = 1 ] && [ "$(field "$RES" reason)" = "missing_dependency" ] && [ ! -e "$TMP/home12" ] && pass "no python3 -> missing_dependency, nothing written" || fail "missing python (rc=$RC): $RES"

echo "--- isolated interpreter"
grep -q 'exec "$PY" -I ' "$REC" && pass "extractor runs under python -I" || fail "extractor not run with -I"
mkdir -p "$TMP/trap"
printf 'raise SystemExit("artifact code ran")\n' > "$TMP/trap/json.py"
printf '<html><body><p>Trap page text.</p></body></html>\n' > "$TMP/trap/index.html"
app_json "$TMP/trap.json" "trap-page" 'null'
RES="$(cd "$TMP/trap" && PYTHONPATH="$TMP/trap" "$REC" --app-json "$TMP/trap.json" --source "$TMP/trap" --home "$TMP/home13" --description "Trap." --type stub)"
[ "$(field "$RES" ok)" = "true" ] && grep -q 'Trap page text.' "$TMP/home13/trap-page.md" && pass "a json.py in the artifact, the cwd and PYTHONPATH is never imported" || fail "artifact code shadowed stdlib: $RES"

if [ "$FAIL" = 0 ]; then
  echo "deploy-record.test.sh: PASS"
else
  echo "deploy-record.test.sh: FAIL"
fi
exit "$FAIL"
