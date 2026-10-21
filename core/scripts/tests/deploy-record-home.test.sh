#!/usr/bin/env bash
# pass() never fails, so `cond && pass || fail` is a safe if/else here.
# shellcheck disable=SC2015
# deploy-record-home.test.sh — regression coverage for
# .claude/skills/deploy/scripts/deploy-record-home.sh, which picks the folder a
# deploy record goes in and copies the deploy source next to it. Asserts each
# resolution rung (--project, the session's bound project, a project segment in
# the source path, then the cwd, then the company-level fallback), that a rung
# naming a missing project or another company falls through, that a source
# outside the project is copied to <home>/<subdomain>/source/ without
# node_modules, .git, files over 5 MB, symlinks, FIFOs or credential files,
# that a source already inside the project is recorded in place, that a rerun
# replaces the copy, that the session meta file is never written, and that
# bad input exits 64 with one JSON line.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
HOMESH="$ROOT/.claude/skills/deploy/scripts/deploy-record-home.sh"
FAIL=0
pass() { printf '  ok   %s\n' "$1"; }
fail() { printf '  FAIL %s\n' "$1"; FAIL=1; }

[ -x "$HOMESH" ] || { echo "FAIL deploy-record-home.sh missing or not executable"; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "FAIL python3 is required to run this test"; exit 1; }

# field <json> <key> -> value of a top-level key (lists joined by commas,
# null as empty, nested objects as key=value pairs).
field() {
  printf '%s' "$1" | python3 -I -c '
import json, sys
obj = json.loads(sys.stdin.read() or "{}")
val = obj.get(sys.argv[1], "")
if val is None:
    val = ""
elif isinstance(val, list):
    val = ",".join(str(v) for v in val)
elif isinstance(val, bool):
    val = "true" if val else "false"
elif isinstance(val, dict):
    val = ",".join("%s=%s" % kv for kv in sorted(val.items()))
print(val)' "$2"
}

# one_line <output> -> true when the output is exactly one JSON object line.
one_line() {
  printf '%s' "$1" | python3 -I -c '
import json, sys
lines = sys.stdin.read().strip("\n").split("\n")
sys.exit(0 if len(lines) == 1 and isinstance(json.loads(lines[0]), dict) else 1)'
}

TMP="$(mktemp -d "${TMPDIR:-/tmp}/deploy-record-home-test.XXXXXX")"
trap 'chmod -R u+w "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT
TMP_REAL="$(cd "$TMP" && pwd -P)"
H="$TMP_REAL/hq"

# A small HQ tree: two companies, two projects in alpha, one in bravo.
mkdir -p "$H/companies/alpha/projects/proj-a" "$H/companies/alpha/projects/proj-b/site" \
         "$H/companies/alpha/projects/proj-b/sub/dir" "$H/companies/bravo/projects/proj-x/site" \
         "$H/workspace/sessions/sid-alpha" "$H/workspace/sessions/sid-gone" \
         "$H/workspace/sessions/sid-bravo" "$H/workspace/project-summary/summary-site/node_modules/pkg"
printf '# manifest\ncompanies:\n  alpha:\n    name: Alpha\n    repos:\n      - x\n      - repos/private/alpha-app\n  bravo:\n    name: Bravo\n    repos:\n    - repos/private/bravo-app\n    - repos/private/shared/bravo-part\nunaffiliated_repos:\n  stray:\n    path: x\n' > "$H/companies/manifest.yaml"
printf 'session_id: sid-alpha\nstarted_at: "2026-10-19T10:00:00Z"\ncompany_slug: alpha\ncompany_slugs: alpha\nproject: proj-a\n' \
  > "$H/workspace/sessions/sid-alpha/meta.yaml"
printf 'session_id: sid-gone\ncompany_slug: alpha\nproject: "no-such-project"\n' > "$H/workspace/sessions/sid-gone/meta.yaml"
printf 'session_id: sid-bravo\ncompany_slug: bravo\nproject: proj-x\n' > "$H/workspace/sessions/sid-bravo/meta.yaml"
printf '<html><body>in project b</body></html>\n' > "$H/companies/alpha/projects/proj-b/site/index.html"
printf '<html><body>bravo page</body></html>\n' > "$H/companies/bravo/projects/proj-x/site/index.html"
printf '<html><body>summary</body></html>\n' > "$H/workspace/project-summary/summary-site/index.html"
printf 'module.exports = 1\n' > "$H/workspace/project-summary/summary-site/node_modules/pkg/index.js"

# An outside source with everything the copy must skip.
EXT="$TMP_REAL/ext/site"
mkdir -p "$EXT/assets" "$EXT/node_modules/dep" "$EXT/assets/node_modules/deep" "$EXT/.git/objects" "$TMP_REAL/elsewhere"
printf '<html><body>outside</body></html>\n' > "$EXT/index.html"
printf 'body{}\n' > "$EXT/assets/app.css"
printf 'x\n' > "$EXT/node_modules/dep/index.js"
printf 'x\n' > "$EXT/assets/node_modules/deep/index.js"
printf 'ref\n' > "$EXT/.git/HEAD"
printf 'PLACEHOLDER=1\n' > "$EXT/.env"
printf 'PLACEHOLDER=1\n' > "$EXT/.env.local"
printf 'PLACEHOLDER=\n' > "$EXT/.env.example"
printf 'not a key\n' > "$EXT/assets/server.pem"
printf 'x\n' > "$EXT/.DS_Store"
printf 'secret outside the source\n' > "$TMP_REAL/elsewhere/private.txt"
ln -s "$TMP_REAL/elsewhere/private.txt" "$EXT/assets/link.txt"
ln -s "$TMP_REAL/elsewhere" "$EXT/linkdir"
python3 -I -c '
import sys
with open(sys.argv[1], "wb") as fh: fh.truncate(5 * 1024 * 1024)
with open(sys.argv[2], "wb") as fh: fh.truncate(5 * 1024 * 1024 + 1)' "$EXT/assets/exact.bin" "$EXT/assets/big.mp4"
mkfifo "$EXT/assets/pipe" 2>/dev/null || true

# run <session-id or ""> <args...>: no inherited session or HQ_ROOT, fixed HQ.
# Passes --access-mode "$RUN_ACCESS" (public unless a case clears it), because
# only public and company deploys are copied.
RUN_ACCESS=public
run() {
  local sid="$1"; shift
  env -u HQ_SESSION_ID -u CLAUDE_CODE_SESSION_ID -u CLAUDE_SESSION_ID -u CODEX_SESSION_ID \
      -u CODEX_THREAD_ID -u GROK_SESSION_ID -u HQ_ROOT ${sid:+HQ_SESSION_ID=$sid} \
      "$HOMESH" --hq-root "$H" ${RUN_ACCESS:+--access-mode "$RUN_ACCESS"} "$@"
}

META_SUM_BEFORE="$(cksum < "$H/workspace/sessions/sid-alpha/meta.yaml")"

echo "--- rung 1: --project"
RES="$(run "" --subdomain flag-site --source "$EXT" --company alpha --project proj-b --cwd "$TMP_REAL")"; RC=$?
[ "$RC" = 0 ] && one_line "$RES" && pass "flag run exits 0 with one JSON line" || fail "flag run (rc=$RC): $RES"
[ "$(field "$RES" resolution)" = "flag" ] && pass "resolution names the flag" || fail "flag resolution: $RES"
[ "$(field "$RES" home)" = "$H/companies/alpha/projects/proj-b/deploys" ] && [ -d "$H/companies/alpha/projects/proj-b/deploys" ] \
  && pass "home is companies/alpha/projects/proj-b/deploys and exists" || fail "flag home: $RES"
[ "$(field "$RES" home_rel)" = "companies/alpha/projects/proj-b/deploys" ] && pass "home_rel is HQ-relative" || fail "home_rel: $RES"
[ "$(field "$RES" project)" = "proj-b" ] && [ "$(field "$RES" company)" = "alpha" ] && pass "company and project reported" || fail "company/project: $RES"

RES="$(run sid-alpha --subdomain flag-site --source "$EXT" --project proj-b --cwd "$TMP_REAL")"
[ "$(field "$RES" resolution)" = "flag" ] && [ "$(field "$RES" project)" = "proj-b" ] && [ "$(field "$RES" company)" = "alpha" ] \
  && pass "--project without --company takes the session's company and beats the session's project" || fail "flag over session: $RES"

RES="$(run "" --subdomain flag-site --source "$EXT" --company alpha --project nope --cwd "$TMP_REAL")"; RC=$?
[ "$RC" = 64 ] && [ "$(field "$RES" reason)" = "project_not_found" ] && [ ! -d "$H/companies/alpha/projects/nope" ] \
  && pass "--project naming a missing project exits 64 and creates nothing" || fail "missing flag project (rc=$RC): $RES"

RES="$(run "" --subdomain flag-site --source "$EXT" --project proj-b --cwd "$TMP_REAL")"; RC=$?
[ "$RC" = 64 ] && [ "$(field "$RES" reason)" = "company_unresolved" ] && pass "--project with no company exits 64" || fail "flag no company (rc=$RC): $RES"

RES="$(run "" --subdomain flag-site --source "$EXT" --company gamma --cwd "$TMP_REAL")"; RC=$?
[ "$RC" = 64 ] && [ "$(field "$RES" reason)" = "company_not_found" ] && pass "an unknown company exits 64" || fail "unknown company (rc=$RC): $RES"
mkdir -p "$H/companies/stray/projects/p1"
RES="$(run "" --subdomain stray-site --source "$EXT" --company stray --project p1 --cwd "$TMP_REAL")"; RC=$?
[ "$RC" = 64 ] && [ "$(field "$RES" reason)" = "company_not_found" ] && [ ! -e "$H/companies/stray/projects/p1/deploys" ] \
  && pass "a company folder missing from the manifest exits 64" || fail "unlisted company (rc=$RC): $RES"
RES="$(run "" --subdomain stray-seg --source "$EXT" --cwd "$H/companies/stray/projects/p1")"; RC=$?
[ "$RC" = 64 ] && [ "$(field "$RES" reason)" = "company_unresolved" ] && pass "a path segment in an unlisted company is not used" || fail "unlisted segment (rc=$RC): $RES"

H2="$TMP_REAL/hq-flat"
mkdir -p "$H2/companies/alpha/projects/proj-a"
printf 'alpha:\n  name: Alpha\n_template:\n  name: x\n' > "$H2/companies/manifest.yaml"
RES="$(env -u HQ_ROOT "$HOMESH" --hq-root "$H2" --subdomain flat --source "$EXT" --company alpha --project proj-a --cwd "$TMP_REAL")"
[ "$(field "$RES" project)" = "proj-a" ] && pass "the older flat manifest layout is read too" || fail "flat manifest: $RES"
mkdir -p "$H2/companies/_template/projects/p"
RES="$(env -u HQ_ROOT "$HOMESH" --hq-root "$H2" --subdomain flat --source "$EXT" --company _template --cwd "$TMP_REAL")"; RC=$?
[ "$RC" = 64 ] && pass "the _template section is not a company" || fail "_template accepted (rc=$RC): $RES"

echo "--- rung 2: the session's bound project"
RES="$(run sid-alpha --subdomain sess-site --source "$EXT" --cwd "$TMP_REAL")"; RC=$?
[ "$RC" = 0 ] && [ "$(field "$RES" resolution)" = "session" ] && [ "$(field "$RES" project)" = "proj-a" ] \
  && [ "$(field "$RES" home)" = "$H/companies/alpha/projects/proj-a/deploys" ] \
  && pass "session bound to proj-a and no --project -> proj-a/deploys, source named session" || fail "session rung (rc=$RC): $RES"
RES="$(run "" --subdomain sess-site --source "$EXT" --session-id sid-alpha --cwd "$TMP_REAL")"
[ "$(field "$RES" resolution)" = "session" ] && pass "--session-id selects the meta file" || fail "--session-id: $RES"
RES="$(env -u HQ_SESSION_ID -u CLAUDE_SESSION_ID -u CODEX_SESSION_ID -u CODEX_THREAD_ID -u GROK_SESSION_ID -u HQ_ROOT \
  CLAUDE_CODE_SESSION_ID=sid-alpha "$HOMESH" --hq-root "$H" --subdomain sess-site --source "$EXT" --cwd "$TMP_REAL")"
[ "$(field "$RES" resolution)" = "session" ] && pass "CLAUDE_CODE_SESSION_ID is read" || fail "CLAUDE_CODE_SESSION_ID: $RES"
[ "$(cksum < "$H/workspace/sessions/sid-alpha/meta.yaml")" = "$META_SUM_BEFORE" ] && pass "session meta.yaml is never written" || fail "meta.yaml changed"

RES="$(run sid-gone --subdomain gone-site --source "$H/companies/alpha/projects/proj-b/site" --cwd "$TMP_REAL")"
[ "$(field "$RES" resolution)" = "source_path" ] && [ "$(field "$RES" notes)" = "session_project_missing" ] \
  && pass "a session project with no folder falls through and is noted" || fail "missing session project: $RES"

RES="$(run sid-bravo --subdomain other-site --source "$EXT" --company alpha --cwd "$TMP_REAL")"
[ "$(field "$RES" resolution)" = "fallback" ] && [ "$(field "$RES" company)" = "alpha" ] \
  && [ "$(field "$RES" notes)" = "session_project_other_company" ] \
  && pass "a session project in another company is skipped" || fail "other-company session: $RES"

RES="$(run sid-missing --subdomain nometa-site --source "$EXT" --company alpha --cwd "$TMP_REAL")"
[ "$(field "$RES" resolution)" = "fallback" ] && [ "$(field "$RES" notes)" = "session_meta_missing" ] \
  && pass "a session with no meta file falls through and is noted" || fail "no meta: $RES"

echo "--- rung 3: project segment in the source path, then the cwd"
RES="$(run "" --subdomain inside-site --source "$H/companies/alpha/projects/proj-b/site" --cwd "$TMP_REAL")"; RC=$?
[ "$RC" = 0 ] && [ "$(field "$RES" resolution)" = "source_path" ] && [ "$(field "$RES" project)" = "proj-b" ] \
  && pass "source under companies/alpha/projects/proj-b resolves to proj-b" || fail "source segment (rc=$RC): $RES"
[ "$(field "$RES" copied)" = "false" ] && [ "$(field "$RES" source_path)" = "companies/alpha/projects/proj-b/site" ] \
  && [ "$(field "$RES" source)" = "$H/companies/alpha/projects/proj-b/site" ] \
  && pass "a source already inside the project is recorded in place" || fail "inside source: $RES"
[ ! -e "$H/companies/alpha/projects/proj-b/deploys/inside-site" ] && pass "nothing copied for a source inside the project" || fail "inside source was copied"

RES="$(run "" --subdomain cwd-site --source "$EXT" --cwd "$H/companies/alpha/projects/proj-b/sub/dir")"; RC=$?
[ "$RC" = 0 ] && [ "$(field "$RES" resolution)" = "cwd" ] && [ "$(field "$RES" project)" = "proj-b" ] \
  && pass "a cwd under proj-b resolves to proj-b" || fail "cwd segment (rc=$RC): $RES"
RES="$(cd "$H/companies/alpha/projects/proj-b/sub" && run "" --subdomain cwd-site2 --source "$EXT")"
[ "$(field "$RES" resolution)" = "cwd" ] && pass "the working directory is the default cwd" || fail "default cwd: $RES"

RES="$(run "" --subdomain src-wins --source "$H/companies/alpha/projects/proj-b/site" --cwd "$H/companies/alpha/projects/proj-a")"
[ "$(field "$RES" resolution)" = "source_path" ] && [ "$(field "$RES" project)" = "proj-b" ] \
  && pass "the source path is tried before the cwd" || fail "source before cwd: $RES"

RES="$(run "" --subdomain bravo-cwd --source "$EXT" --company alpha --cwd "$H/companies/bravo/projects/proj-x")"
[ "$(field "$RES" resolution)" = "fallback" ] && [ "$(field "$RES" company)" = "alpha" ] && [ "$(field "$RES" notes)" = "cwd_project_other_company" ] \
  && pass "a cwd project in another company is skipped" || fail "other-company cwd: $RES"

echo "--- rung 4: company-level fallback"
RES="$(run "" --subdomain fallback-site --source "$EXT" --company alpha --cwd "$TMP_REAL")"; RC=$?
[ "$RC" = 0 ] && [ "$(field "$RES" resolution)" = "fallback" ] && [ "$(field "$RES" project)" = "" ] \
  && [ "$(field "$RES" home)" = "$H/companies/alpha/deploys" ] && [ -d "$H/companies/alpha/deploys" ] \
  && pass "no project from any rung -> companies/alpha/deploys" || fail "fallback (rc=$RC): $RES"
[ -f "$H/companies/alpha/deploys/fallback-site/source/index.html" ] && pass "fallback copies the outside source under deploys/<subdomain>/source" || fail "fallback copy missing"
RES="$(run "" --subdomain nowhere --source "$EXT" --cwd "$TMP_REAL")"; RC=$?
[ "$RC" = 64 ] && [ "$(field "$RES" reason)" = "company_unresolved" ] && pass "no company from any source exits 64" || fail "no company (rc=$RC): $RES"
mkdir -p "$H/companies/alpha/knowledge/site"
printf '<html></html>\n' > "$H/companies/alpha/knowledge/site/index.html"
RES="$(run "" --subdomain knowledge-site --source "$H/companies/alpha/knowledge/site" --company alpha --cwd "$TMP_REAL")"
[ "$(field "$RES" resolution)" = "fallback" ] && [ "$(field "$RES" copied)" = "false" ] \
  && [ "$(field "$RES" source_path)" = "companies/alpha/knowledge/site" ] \
  && pass "fallback records a source already inside the company in place" || fail "fallback inside company: $RES"

echo "--- source copy"
RES="$(run "" --subdomain copy-site --source "$EXT" --company alpha --project proj-a --cwd "$TMP_REAL")"; RC=$?
C="$H/companies/alpha/projects/proj-a/deploys/copy-site/source"
[ "$RC" = 0 ] && [ "$(field "$RES" copied)" = "true" ] && [ "$(field "$RES" source)" = "$C" ] \
  && [ "$(field "$RES" source_path)" = "companies/alpha/projects/proj-a/deploys/copy-site/source" ] \
  && pass "an outside source is copied and source_path names the copy" || fail "copy result (rc=$RC): $RES"
case "$(field "$RES" copied_from)" in */ext/site) true ;; *) false ;; esac && pass "copied_from names the original" || fail "copied_from: $RES"
[ -f "$C/index.html" ] && [ -f "$C/assets/app.css" ] && [ -f "$C/.env.example" ] && pass "pages, assets and .env.example are copied" || fail "copy content"
[ ! -e "$C/node_modules" ] && [ ! -e "$C/assets/node_modules" ] && pass "node_modules is excluded at every depth" || fail "node_modules copied"
[ ! -e "$C/.git" ] && pass ".git is excluded" || fail ".git copied"
[ ! -e "$C/assets/big.mp4" ] && [ -f "$C/assets/exact.bin" ] && pass "a file over 5 MB is excluded, exactly 5 MB is kept" || fail "size exclusion"
[ ! -e "$C/.env" ] && [ ! -e "$C/.env.local" ] && [ ! -e "$C/assets/server.pem" ] && pass "credential-shaped files are excluded" || fail "secret-like files copied"
[ ! -e "$C/assets/link.txt" ] && [ ! -e "$C/linkdir" ] && ! grep -rq "secret outside" "$C" && pass "symlinks out of the source are not followed or copied" || fail "symlink copied"
[ ! -e "$C/assets/pipe" ] && [ ! -e "$C/.DS_Store" ] && pass "FIFOs and .DS_Store are skipped" || fail "special/junk copied"
EXC="$(field "$RES" excluded)"
case "$EXC" in *git=1*) pass "excluded counts report .git" ;; *) fail "excluded git count: $EXC" ;; esac
case "$EXC" in *node_modules=2*) pass "excluded counts report both node_modules" ;; *) fail "excluded node_modules count: $EXC" ;; esac
case "$EXC" in *oversize=1*) pass "excluded counts report the oversize file" ;; *) fail "excluded oversize count: $EXC" ;; esac
case "$EXC" in *secret_like=3*) pass "excluded counts report the credential files" ;; *) fail "excluded secret count: $EXC" ;; esac
case "$EXC" in *symlink=2*) pass "excluded counts report both symlinks" ;; *) fail "excluded symlink count: $EXC" ;; esac
[ "$(field "$RES" files_copied)" = "4" ] && pass "files_copied counts the copied files" || fail "files_copied: $RES"
[ -f "$EXT/.env" ] && [ -f "$EXT/assets/big.mp4" ] && pass "the original source is left alone" || fail "source modified"

echo "--- rerun replaces the copy"
rm -f "$EXT/assets/app.css"
printf '<html><body>outside v2</body></html>\n' > "$EXT/index.html"
RES="$(run "" --subdomain copy-site --source "$EXT" --company alpha --project proj-a --cwd "$TMP_REAL")"; RC=$?
[ "$RC" = 0 ] && grep -q "outside v2" "$C/index.html" && [ ! -e "$C/assets/app.css" ] \
  && pass "a rerun replaces the copy, dropping files removed from the source" || fail "rerun (rc=$RC): $RES"
LEFT="$(find "$H/companies/alpha/projects/proj-a/deploys/copy-site" -mindepth 1 -maxdepth 1 -name '.source.*' | wc -l | tr -d ' ')"
[ "$LEFT" = 0 ] && pass "no temp or old copy is left behind" || fail "leftover temp dirs: $LEFT"

echo "--- e2e: a workspace/project-summary source"
RES="$(run sid-alpha --subdomain summary-site --source "$H/workspace/project-summary/summary-site" --cwd "$H")"
S="$H/companies/alpha/projects/proj-a/deploys/summary-site/source"
[ "$(field "$RES" copied)" = "true" ] && [ -f "$S/index.html" ] && [ ! -e "$S/node_modules" ] \
  && pass "a project-summary source is copied into the project without node_modules" || fail "summary e2e: $RES"

echo "--- company isolation and containment"
RES="$(run "" --subdomain cross --source "$H/companies/bravo/projects/proj-x/site" --company alpha --cwd "$TMP_REAL")"; RC=$?
[ "$RC" = 64 ] && [ "$(field "$RES" reason)" = "source_in_other_company" ] && [ ! -e "$H/companies/alpha/deploys/cross" ] \
  && pass "a source inside another company is never copied into this one" || fail "cross-company copy (rc=$RC): $RES"
RES="$(run "" --subdomain whole-co --source "$H/companies/alpha" --company alpha --project proj-b --cwd "$TMP_REAL")"; RC=$?
[ "$RC" = 64 ] && [ "$(field "$RES" reason)" = "source_contains_home" ] && [ ! -e "$H/companies/alpha/projects/proj-b/deploys/whole-co" ] \
  && pass "a source that contains the home is refused" || fail "source contains home (rc=$RC): $RES"
RES="$(run "" --subdomain whole-hq --source "$H" --company alpha --cwd "$TMP_REAL")"; RC=$?
[ "$RC" = 64 ] && [ "$(field "$RES" reason)" = "source_contains_home" ] && pass "the HQ root as a source is refused" || fail "HQ root source (rc=$RC): $RES"

echo "--- links never carry the home into another company"
ln -s "$H/companies/bravo/projects/proj-x" "$H/companies/alpha/projects/linked"
RES="$(run "" --subdomain linked-site --source "$EXT" --company alpha --project linked --cwd "$TMP_REAL")"; RC=$?
[ "$RC" = 64 ] && [ "$(field "$RES" reason)" = "home_outside_company" ] && [ ! -e "$H/companies/bravo/projects/proj-x/deploys" ] \
  && pass "a project folder linked into another company is refused" || fail "linked project (rc=$RC): $RES"
mkdir -p "$H/companies/alpha/projects/proj-dl" "$TMP_REAL/elsewhere-deploys"
ln -s "$TMP_REAL/elsewhere-deploys" "$H/companies/alpha/projects/proj-dl/deploys"
RES="$(run "" --subdomain dl-site --source "$EXT" --company alpha --project proj-dl --cwd "$TMP_REAL")"; RC=$?
[ "$RC" = 64 ] && [ "$(field "$RES" reason)" = "home_outside_company" ] && [ -z "$(ls -A "$TMP_REAL/elsewhere-deploys")" ] \
  && pass "a deploys folder that is a link is refused" || fail "linked deploys (rc=$RC): $RES"
H3="$TMP_REAL/hq-linkco"
mkdir -p "$H3/companies/bravo/projects/p1"
printf 'companies:\n  alpha:\n    name: Alpha\n  bravo:\n    name: Bravo\n' > "$H3/companies/manifest.yaml"
ln -s "$H3/companies/bravo" "$H3/companies/alpha"
RES="$(env -u HQ_ROOT "$HOMESH" --hq-root "$H3" --subdomain co-link --source "$EXT" --company alpha --cwd "$TMP_REAL")"; RC=$?
[ "$RC" = 64 ] && [ "$(field "$RES" reason)" = "home_outside_company" ] && [ ! -e "$H3/companies/bravo/deploys" ] \
  && pass "a company folder that links to another company is refused" || fail "linked company (rc=$RC): $RES"

echo "--- only a copy this script made is ever replaced"
[ -f "$C/.hq-deploy-source" ] && pass "the copy carries its marker file" || fail "marker missing"
CH="$H/companies/alpha/projects/proj-a/deploys"
mkdir -p "$CH/hand-made/source"
printf 'notes someone keeps here\n' > "$CH/hand-made/source/notes.txt"
RES="$(run "" --subdomain hand-made --source "$EXT" --company alpha --project proj-a --cwd "$TMP_REAL")"; RC=$?
[ "$RC" = 1 ] && [ "$(field "$RES" reason)" = "source_conflict" ] && [ -f "$CH/hand-made/source/notes.txt" ] \
  && [ -z "$(find "$CH/hand-made" -maxdepth 1 -name '.source.*')" ] \
  && pass "a source folder this script did not make is left alone" || fail "hand-made folder replaced (rc=$RC): $RES"
mkdir -p "$CH/link-src" "$TMP_REAL/keep-me"
printf 'keep\n' > "$TMP_REAL/keep-me/k.txt"
touch "$TMP_REAL/keep-me/.hq-deploy-source"
ln -s "$TMP_REAL/keep-me" "$CH/link-src/source"
RES="$(run "" --subdomain link-src --source "$EXT" --company alpha --project proj-a --cwd "$TMP_REAL")"; RC=$?
[ "$RC" = 1 ] && [ "$(field "$RES" reason)" = "source_conflict" ] && [ -L "$CH/link-src/source" ] && [ -f "$TMP_REAL/keep-me/k.txt" ] \
  && pass "a source path that is a link is left alone, even with a marker" || fail "linked source replaced (rc=$RC): $RES"
printf 'a file\n' > "$CH/file-sub"
RES="$(run "" --subdomain file-sub --source "$EXT" --company alpha --project proj-a --cwd "$TMP_REAL")"; RC=$?
[ "$RC" = 1 ] && [ "$(field "$RES" reason)" = "source_conflict" ] && grep -q 'a file' "$CH/file-sub" \
  && pass "a file at <home>/<subdomain> is left alone" || fail "file at subdomain path (rc=$RC): $RES"

echo "--- gated deploys are never copied into the company folder"
GH="$H/companies/alpha/projects/proj-a/deploys"
for mode in private password selected; do
  RES="$(RUN_ACCESS=$mode run "" --subdomain gated-$mode --source "$EXT" --company alpha --project proj-a --cwd "$TMP_REAL")"; RC=$?
  [ "$RC" = 0 ] && [ "$(field "$RES" copied)" = "false" ] && [ "$(field "$RES" copy_withheld)" = "$mode" ] \
    && [ "$(field "$RES" access_mode)" = "$mode" ] && [ "$(field "$RES" source)" = "$EXT" ] \
    && [ "$(field "$RES" notes)" = "source_not_copied_gated" ] && [ ! -e "$GH/gated-$mode" ] \
    && pass "$mode deploy: no copy, copy_withheld says why, source left in place" || fail "$mode copied (rc=$RC): $RES"
done
RES="$(RUN_ACCESS="" run "" --subdomain no-gate --source "$EXT" --company alpha --project proj-a --cwd "$TMP_REAL")"
[ "$(field "$RES" copied)" = "false" ] && [ "$(field "$RES" copy_withheld)" = "unknown" ] && [ ! -e "$GH/no-gate" ] \
  && pass "no --access-mode and no --app-json counts as unknown, no copy" || fail "ungated default copied: $RES"
printf '{"id":"a1","subdomain":"pw-app","accessMode":"password"}\n' > "$TMP_REAL/pw-app.json"
RES="$(RUN_ACCESS=public run "" --subdomain pw-app --app-json "$TMP_REAL/pw-app.json" --source "$EXT" --company alpha --project proj-a --cwd "$TMP_REAL")"
[ "$(field "$RES" access_mode)" = "password" ] && [ "$(field "$RES" copied)" = "false" ] && [ ! -e "$GH/pw-app" ] \
  && pass "--access-mode public cannot loosen a password app" || fail "flag loosened app gate: $RES"
printf '{"id":"a2","subdomain":"pm-app","privateMode":true,"accessMode":"public"}\n' > "$TMP_REAL/pm-app.json"
RES="$(RUN_ACCESS="" run "" --subdomain pm-app --app-json "$TMP_REAL/pm-app.json" --source "$EXT" --company alpha --project proj-a --cwd "$TMP_REAL")"
[ "$(field "$RES" access_mode)" = "private" ] && [ "$(field "$RES" copied)" = "false" ] && pass "privateMode in the app JSON blocks the copy" || fail "privateMode copied: $RES"
printf '{"id":"a3","subdomain":"co-app","accessMode":"company"}\n' > "$TMP_REAL/co-app.json"
RES="$(RUN_ACCESS="" run "" --subdomain co-app --app-json "$TMP_REAL/co-app.json" --source "$EXT" --company alpha --project proj-a --cwd "$TMP_REAL")"
[ "$(field "$RES" access_mode)" = "company" ] && [ "$(field "$RES" copied)" = "true" ] && [ -f "$GH/co-app/source/index.html" ] \
  && pass "a company deploy is copied" || fail "company deploy not copied: $RES"
RES="$(RUN_ACCESS=private run "" --subdomain co-app2 --app-json "$TMP_REAL/co-app.json" --source "$EXT" --company alpha --project proj-a --cwd "$TMP_REAL")"
[ "$(field "$RES" access_mode)" = "private" ] && [ "$(field "$RES" copied)" = "false" ] && pass "--access-mode can tighten a company app" || fail "flag did not tighten: $RES"
RES="$(RUN_ACCESS=everyone run "" --subdomain bad-gate --source "$EXT" --company alpha)"; RC=$?
[ "$RC" = 64 ] && [ "$(field "$RES" reason)" = "bad_args" ] && pass "unknown --access-mode exits 64" || fail "bad access mode (rc=$RC): $RES"
printf 'not json' > "$TMP_REAL/bad-app.json"
RES="$(RUN_ACCESS="" run "" --subdomain bad-app --app-json "$TMP_REAL/bad-app.json" --source "$EXT" --company alpha)"; RC=$?
[ "$RC" = 64 ] && [ "$(field "$RES" reason)" = "invalid_app_json" ] && pass "unreadable --app-json exits 64" || fail "bad app json (rc=$RC): $RES"

RES="$(run "" --subdomain no-copy --copy no --source "$EXT" --company alpha --project proj-a --cwd "$TMP_REAL")"
[ "$(field "$RES" copied)" = "false" ] && [ "$(field "$RES" copy_withheld)" = "not_requested" ] && [ "$(field "$RES" source)" = "$EXT" ] \
  && [ ! -e "$GH/no-copy" ] && pass "--copy no resolves the home without copying" || fail "--copy no: $RES"
RES="$(run "" --subdomain no-copy --copy maybe --source "$EXT" --company alpha)"; RC=$?
[ "$RC" = 64 ] && [ "$(field "$RES" reason)" = "bad_args" ] && pass "--copy takes only yes or no" || fail "--copy maybe (rc=$RC): $RES"

echo "--- more credential files are skipped and text is redacted"
SRC2="$TMP_REAL/ext2/site"
mkdir -p "$SRC2/config"
printf '<html><body>two</body></html>\n' > "$SRC2/index.html"
for f in credentials credentials.json .envrc .git-credentials prod.tfstate prod.tfstate.backup vars.tfvars \
         service-account-prod.json secrets.yaml secret.json .pgpass .htpasswd config/Credentials; do
  printf 'x\n' > "$SRC2/$f"
done
AWS_VAL="AKIA""ABCDEFGHIJKLMNOP"
PW_VAL="hunter""22copy"
printf 'const key = "%s";\nconst cfg = { password: "%s" };\n' "$AWS_VAL" "$PW_VAL" > "$SRC2/app.js"
printf 'binary\000image bytes %s\n' "$AWS_VAL" > "$SRC2/photo.bin"
printf 'export const k = "%s";\n' "$AWS_VAL" > "$SRC2/App.tsx"
for f in Widget.jsx Page.vue Card.svelte; do printf 'const pw = { password: "%s" };\n' "$PW_VAL" > "$SRC2/$f"; done
for f in deploy_key deploy_key.pub id_ed25519_sk id_ecdsa_sk.pub legacy_rsa putty.ppk; do printf 'x\n' > "$SRC2/$f"; done
RES="$(run "" --subdomain creds-copy --source "$SRC2" --company alpha --project proj-a --cwd "$TMP_REAL")"
C2="$GH/creds-copy/source"
LEFT2="$(cd "$C2" && find . -type f ! -name .hq-deploy-source | LC_ALL=C sort | tr '\n' ' ')"
[ "$LEFT2" = "./App.tsx ./Card.svelte ./Page.vue ./Widget.jsx ./app.js ./index.html ./photo.bin " ] && pass "every credential-named file is skipped" || fail "copied: $LEFT2"
EXC2="$(field "$RES" excluded)"
case "$EXC2" in *secret_like=19*) pass "excluded counts all 19 credential files (deploy_key, id_*_sk, *_rsa, .ppk included)" ;; *) fail "secret count: $EXC2" ;; esac
! grep -q "$AWS_VAL" "$C2/app.js" && ! grep -q "$PW_VAL" "$C2/app.js" && grep -q 'REDACTED' "$C2/app.js" \
  && pass "credential values in text files are redacted in the copy" || fail "app.js not redacted"
for f in App.tsx Widget.jsx Page.vue Card.svelte; do
  ! grep -q "$AWS_VAL" "$C2/$f" && ! grep -q "$PW_VAL" "$C2/$f" && grep -q 'REDACTED' "$C2/$f" || fail "$f not redacted"
done
pass "tsx, jsx, vue and svelte files are redacted too"
[ "$(field "$RES" files_redacted)" = "5" ] && pass "files_redacted counts the 5 redacted files" || fail "files_redacted: $RES"
grep -q "$AWS_VAL" "$SRC2/app.js" && pass "the original file is left alone" || fail "original modified"
cmp -s "$SRC2/photo.bin" "$C2/photo.bin" && pass "files that are not text are copied byte for byte" || fail "binary changed"

echo "--- a wrong --source is not copied"
mkdir -p "$TMP_REAL/no-index/sub"
printf 'x\n' > "$TMP_REAL/no-index/sub/page.html"
RES="$(run "" --subdomain no-index --source "$TMP_REAL/no-index" --company alpha --project proj-a --cwd "$TMP_REAL")"; RC=$?
[ "$RC" = 1 ] && [ "$(field "$RES" reason)" = "no_index_html" ] && [ ! -e "$GH/no-index" ] \
  && pass "a source with no index.html is not copied" || fail "no index (rc=$RC): $RES"
mkdir -p "$TMP_REAL/link-index"
ln -s "$EXT/index.html" "$TMP_REAL/link-index/index.html"
RES="$(run "" --subdomain link-index --source "$TMP_REAL/link-index" --company alpha --project proj-a --cwd "$TMP_REAL")"; RC=$?
[ "$RC" = 1 ] && [ "$(field "$RES" reason)" = "no_index_html" ] && pass "an index.html that is a link does not count" || fail "linked index (rc=$RC): $RES"
BIG="$TMP_REAL/many/site"
mkdir -p "$BIG"
printf '<html></html>\n' > "$BIG/index.html"
python3 -I -c '
import os, sys
for i in range(2000):
    with open(os.path.join(sys.argv[1], "f%04d.txt" % i), "w") as fh:
        fh.write("x")' "$BIG"
RES="$(run "" --subdomain many --source "$BIG" --company alpha --project proj-a --cwd "$TMP_REAL")"; RC=$?
[ "$RC" = 1 ] && [ "$(field "$RES" reason)" = "source_too_large" ] && [ ! -e "$GH/many/source" ] \
  && [ -z "$(find "$GH/many" -mindepth 1 -maxdepth 1 2>/dev/null)" ] \
  && pass "past 2000 files the copy stops and leaves nothing behind" || fail "file cap (rc=$RC): $RES"
rm -f "$BIG/f1999.txt"
RES="$(run "" --subdomain many --source "$BIG" --company alpha --project proj-a --cwd "$TMP_REAL")"
[ "$(field "$RES" files_copied)" = "2000" ] && pass "exactly 2000 files is allowed" || fail "2000 files: $RES"

echo "--- sources owned by another company outside companies/"
for rel in repos/private/bravo-app/site workspace/worktrees/bravo-app/site workspace/reports/bravo/site; do
  mkdir -p "$H/$rel"
  printf '<html></html>\n' > "$H/$rel/index.html"
  RES="$(run "" --subdomain other-src --source "$H/$rel" --company alpha --project proj-a --cwd "$TMP_REAL")"; RC=$?
  [ "$RC" = 64 ] && [ "$(field "$RES" reason)" = "source_in_other_company" ] && [ ! -e "$GH/other-src" ] \
    && pass "$rel belongs to bravo and is refused" || fail "$rel (rc=$RC): $RES"
done
mkdir -p "$H/repos/private/alpha-app/site"
printf '<html></html>\n' > "$H/repos/private/alpha-app/site/index.html"
RES="$(run "" --subdomain own-repo --source "$H/repos/private/alpha-app/site" --company alpha --project proj-a --cwd "$TMP_REAL")"
[ "$(field "$RES" copied)" = "true" ] && pass "a source in the company's own repo is copied" || fail "own repo: $RES"

echo "--- a source that contains another company's folder is refused (Stefan's repro)"
printf '<html></html>\n' > "$H/workspace/reports/index.html"
printf 'bravo notes\n' > "$H/workspace/reports/bravo/notes.md"
RES="$(run "" --subdomain reports-all --source "$H/workspace/reports" --company alpha --project proj-a --cwd "$TMP_REAL")"; RC=$?
[ "$RC" = 64 ] && [ "$(field "$RES" reason)" = "source_in_other_company" ] && [ ! -e "$GH/reports-all/source" ] \
  && [ -z "$(find "$GH/reports-all" -mindepth 1 2>/dev/null)" ] \
  && pass "workspace/reports holding reports/bravo/ is refused and nothing is left behind" || fail "workspace/reports (rc=$RC): $RES"
mkdir -p "$H/repos/private/shared/bravo-part" "$H/repos/private/shared/alpha-bits"
printf '<html></html>\n' > "$H/repos/private/shared/index.html"
printf 'bravo code\n' > "$H/repos/private/shared/bravo-part/main.js"
RES="$(run "" --subdomain shared-repos --source "$H/repos/private/shared" --company alpha --project proj-a --cwd "$TMP_REAL")"; RC=$?
[ "$RC" = 64 ] && [ "$(field "$RES" reason)" = "source_in_other_company" ] && [ ! -e "$GH/shared-repos/source" ] \
  && pass "a folder holding a repo the manifest lists for bravo is refused" || fail "nested bravo repo (rc=$RC): $RES"
for rel in repos repos/private repos/public workspace workspace/worktrees personal core .claude; do
  mkdir -p "$H/$rel"
  printf '<html></html>\n' > "$H/$rel/index.html"
  RES="$(run "" --subdomain broad --source "$H/$rel" --company alpha --project proj-a --cwd "$TMP_REAL")"; RC=$?
  [ "$RC" = 64 ] && [ "$(field "$RES" reason)" = "source_too_broad" ] || fail "$rel as a source (rc=$RC): $RES"
done
[ ! -e "$GH/broad" ] && pass "top-level HQ folders (repos, workspace, personal, core, .claude) are never a source" || fail "broad source copied"
rm -f "$H/workspace/reports/index.html"

echo "--- a nested HQ never becomes the root"
NEST="$H/companies/bravo/projects/proj-x/nested"
mkdir -p "$NEST/companies/alpha/projects/proj-a"
printf 'companies:\n  alpha:\n    name: Planted\n' > "$NEST/companies/manifest.yaml"
RES="$(env -u HQ_ROOT "$HOMESH" --hq-root "$NEST" --access-mode private --subdomain nested --source "$EXT" --company alpha --project proj-a --cwd "$TMP_REAL")"
[ "$(field "$RES" home)" = "$H/companies/alpha/projects/proj-a/deploys" ] && [ ! -e "$NEST/companies/alpha/projects/proj-a/deploys" ] \
  && pass "--hq-root inside another HQ resolves to the outermost HQ, as deploy-record.sh does" || fail "nested root: $RES"

echo "--- a session with no company never resolves a project"
mkdir -p "$H/companies/projects/proj-a" "$H/workspace/sessions/sid-noco"
printf 'session_id: sid-noco\ncompany_slug: ""\nproject: proj-a\n' > "$H/workspace/sessions/sid-noco/meta.yaml"
RES="$(run sid-noco --subdomain noco --source "$EXT" --cwd "$TMP_REAL")"; RC=$?
[ "$RC" = 64 ] && [ "$(field "$RES" reason)" = "company_unresolved" ] && [ ! -e "$H/companies/projects/proj-a/deploys" ] \
  && pass "an empty company_slug does not resolve to companies/projects/<slug>" || fail "empty company (rc=$RC): $RES"

echo "--- files are opened without following links"
mkdir -p "$TMP_REAL/nofollow"
printf 'linked secret\n' > "$TMP_REAL/nofollow/real.txt"
ln -s "$TMP_REAL/nofollow/real.txt" "$TMP_REAL/nofollow/link.txt"
mkfifo "$TMP_REAL/nofollow/pipe" 2>/dev/null || true
OUTNF="$(env -u PYTHONPATH python3 -I -c '
import importlib.util, sys
spec = importlib.util.spec_from_file_location("drh", sys.argv[1])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
print(mod.read_regular(sys.argv[2])[1], mod.read_regular(sys.argv[3])[1], mod.read_regular(sys.argv[4])[1])' \
  "$ROOT/.claude/skills/deploy/scripts/deploy-record-home.py" "$TMP_REAL/nofollow/link.txt" "$TMP_REAL/nofollow/pipe" "$TMP_REAL/nofollow/real.txt")"
[ "$OUTNF" = "symlink special None" ] && pass "a link read at copy time is refused, a FIFO does not hang" || fail "read_regular: $OUTNF"

echo "--- bad input"
for args in "--source $EXT --company alpha" "--subdomain Bad_Sub --source $EXT --company alpha" \
            "--subdomain ok --source $EXT --company alpha --bogus 1" "--subdomain ok --source $EXT --session-id ../x" \
            "--subdomain ok --source $EXT --company ../alpha" "--subdomain ok --source $EXT --company alpha --company alpha" \
            "--subdomain ok --source"; do
  # shellcheck disable=SC2086
  RES="$(run "" $args)"; RC=$?
  [ "$RC" = 64 ] && one_line "$RES" && [ "$(field "$RES" reason)" = "bad_args" ] && pass "bad args exit 64: ${args#--subdomain }" || fail "bad args (rc=$RC) [$args]: $RES"
done
RES="$(run "" --subdomain ok --source "$TMP_REAL/missing" --company alpha)"; RC=$?
[ "$RC" = 64 ] && [ "$(field "$RES" reason)" = "source_not_found" ] && pass "a missing source exits 64" || fail "missing source (rc=$RC): $RES"
RES="$(env -u HQ_ROOT "$HOMESH" --hq-root "$TMP_REAL/ext" --subdomain ok --source "$EXT" --company alpha)"; RC=$?
[ "$RC" = 64 ] && [ "$(field "$RES" reason)" = "bad_args" ] && pass "--hq-root without a manifest exits 64" || fail "bad hq root (rc=$RC): $RES"

echo "--- unwritable home"
mkdir -p "$H/companies/alpha/projects/locked"
chmod 555 "$H/companies/alpha/projects/locked"
RES="$(run "" --subdomain locked-site --source "$EXT" --company alpha --project locked --cwd "$TMP_REAL")"; RC=$?
chmod 755 "$H/companies/alpha/projects/locked"
if [ "$(id -u)" = 0 ]; then
  pass "unwritable home (skipped assertion: running as root ignores modes)"
else
  [ "$RC" = 1 ] && one_line "$RES" && [ "$(field "$RES" reason)" = "home_not_writable" ] && pass "an unwritable home exits 1 with one JSON line" || fail "unwritable home (rc=$RC): $RES"
fi

echo "--- missing python"
mkdir -p "$TMP/nopy"
for tool in dirname; do ln -s "$(command -v "$tool")" "$TMP/nopy/$tool"; done
RES="$(PATH="$TMP/nopy" "$BASH" "$HOMESH" --hq-root "$H" --subdomain nopy --source "$EXT" --company alpha)"; RC=$?
[ "$RC" = 1 ] && [ "$(field "$RES" reason)" = "missing_dependency" ] && [ ! -e "$H/companies/alpha/deploys/nopy" ] \
  && pass "no python3 -> missing_dependency, nothing copied" || fail "missing python (rc=$RC): $RES"

echo "--- isolated interpreter"
grep -q 'exec "$PY" -I ' "$HOMESH" && pass "resolver runs under python -I" || fail "resolver not run with -I"
mkdir -p "$TMP_REAL/trap"
printf 'raise SystemExit("artifact code ran")\n' > "$TMP_REAL/trap/json.py"
printf '<html></html>\n' > "$TMP_REAL/trap/index.html"
RES="$(cd "$TMP_REAL/trap" && PYTHONPATH="$TMP_REAL/trap" run "" --subdomain trap --source "$TMP_REAL/trap" --company alpha)"
[ "$(field "$RES" ok)" = "true" ] && [ -f "$H/companies/alpha/deploys/trap/source/json.py" ] \
  && pass "a json.py in the source, the cwd and PYTHONPATH is never imported" || fail "source code shadowed stdlib: $RES"

if [ "$FAIL" = 0 ]; then
  echo "deploy-record-home.test.sh: PASS"
else
  echo "deploy-record-home.test.sh: FAIL"
fi
exit "$FAIL"
