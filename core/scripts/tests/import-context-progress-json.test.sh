#!/usr/bin/env bash
# Regression tests for /import-context scan.sh --progress-json (JSON Lines
# progress stream for the HQ desktop first-run setup).
#
# Invariants:
#   1. Every line is one JSON object with "v":1 and a known "type"; the stream
#      opens with "start" and closes with "done".
#   2. Sources run in the order "start" lists them; each goes scanning ->
#      counts -> done, and the last count per key equals the done count.
#   3. Counts fire at fixed 1-2-5 milestones (deterministic, bounded).
#   4. Companies come from the rule pass: HQ manifest, git remote org, then
#      shared work folders. Projects group repos and session working dirs.
#   5. No content leakage: no prompt text, no absolute paths, no cwd field.
#   6. report.json is byte-identical with and without the flag, and the
#      default (no flag) stdout is unchanged.
#   7. Output is identical across runs of the same machine state.
#   8. --progress-json without --output is a usage error.
#   9. An unreadable claude.ai export is a source error, not a fatal one.
#  10. Remote URLs with credentials, token query strings, fragments, "/" in a
#      password, or URL syntax in org/name never leak; quoted config values
#      are unquoted; manifest ids are
#      slugged and "_template" is skipped; HQ company folders map only to
#      manifest companies; file lists survive newlines in file names.
#  11. Project ids are the same for the same layout under a different HOME.
#  12. SIGTERM mid-scan (to bash alone, or to the process group) exits 143
#      with no surviving children; every temp path the scan created is inside
#      its private dir and is gone.
#  13. The scan works under GNU mktemp semantics (TMPDIR honored, missing
#      TMPDIR folder is an error), as on Linux CI.

set -euo pipefail

SRC_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SCAN="$SRC_ROOT/.claude/skills/import-context/scan.sh"
BASH_BIN="${BASH_BIN:-bash}"

TMP_ROOT="$(mktemp -d)"
TMP_ROOT="$(cd "$TMP_ROOT" && pwd -P)"
trap 'rm -rf "$TMP_ROOT"' EXIT

PASS=0
fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { PASS=$((PASS + 1)); echo "ok - $*"; }

command -v jq >/dev/null 2>&1 || fail "jq is required to run these tests"
[ -f "$SCAN" ] || fail "scanner not found: $SCAN"

CANARY="PRIVATE-PROMPT-CANARY-7f3a"
FAKE_TOKEN="FAKE-TOKEN-fixture-value"

# ── fixture HQ root ──────────────────────────────────────────────────────────
HQ="$TMP_ROOT/hq"
mkdir -p "$HQ/companies"
cat > "$HQ/companies/manifest.yaml" <<'YAML'
# fixture manifest
companies:
  acme:
    name: Acme Corp
    github_org: acme-co
    repos: []
YAML

# ── fixture HOME ─────────────────────────────────────────────────────────────
H="$TMP_ROOT/home"
mkrepo() { # <dir> [remote url]
  mkdir -p "$1/.git"
  if [ -n "${2:-}" ]; then
    printf '[core]\n\tbare = false\n[remote "origin"]\n\turl = %s\n\tfetch = +refs/heads/*:refs/remotes/origin/*\n' "$2" > "$1/.git/config"
  else
    printf '[core]\n\tbare = false\n' > "$1/.git/config"
  fi
  printf '%s\n' "$CANARY" > "$1/README.md"
}
mkrepo "$H/code/acme/web" "https://github.com/acme-co/web.git"
mkrepo "$H/code/acme/docs"
mkrepo "$H/code/globex/app1"
mkrepo "$H/code/globex/app2"
mkrepo "$H/code/solo-tool"
mkrepo "$H/code/oss/lib" "git@gitlab.com:Initech/lib.git"
mkrepo "$H/code/acme/web/node_modules/dep" "https://github.com/someone/dep.git"
mkrepo "$H/work/beta/api" "git@github.com:Beta-Labs/api.git"
# hooli/alpha is alone in its folder until a session dir next to it shows up.
mkrepo "$H/code/hooli/alpha"
mkdir -p "$H/work/beta/api/src" "$H/notes/plans" "$H/code/hooli/beta"
# A linked worktree of acme/web: same remote, so the same project.
mkdir -p "$H/code/acme/web/.git/worktrees/web-wt" "$H/code/acme/web-wt"
printf '../..\n' > "$H/code/acme/web/.git/worktrees/web-wt/commondir"
printf 'gitdir: %s\n' "$H/code/acme/web/.git/worktrees/web-wt" > "$H/code/acme/web-wt/.git"

session() { # <file> <cwd>
  mkdir -p "$(dirname "$1")"
  printf '{"type":"summary","summary":"%s"}\n{"type":"user","cwd":"%s","message":{"content":"%s %s"}}\n' \
    "$CANARY" "$2" "$CANARY" "$FAKE_TOKEN" > "$1"
}
CP="$H/.claude/projects"
session "$CP/p1/s1.jsonl" "$H/code/acme/web"
session "$CP/p2/s2.jsonl" "$H/work/beta/api/src"
session "$CP/p3/s3.jsonl" "$H"
session "$CP/p4/s4.jsonl" "$H/notes/plans"
session "$CP/p6/s6.jsonl" "$H/code/hooli/beta"
for i in $(seq 1 23); do session "$CP/p5/filler-$i.jsonl" "$H/code/acme/web"; done
mkdir -p "$H/.codex/sessions/2026/01/01"
printf '{"type":"session_meta","payload":{"id":"x","cwd":"%s","instructions":"%s"}}\n' \
  "$H/code/acme/web" "$CANARY" > "$H/.codex/sessions/2026/01/01/rollout-1.jsonl"
printf '{"type":"session_meta","payload":{"id":"y","cwd":"%s","instructions":"%s"}}\n' \
  "$H/sandbox/codex-only" "$CANARY" > "$H/.codex/sessions/2026/01/01/rollout-2.jsonl"
mkdir -p "$H/.grok/sessions/%2Fsrv%2Fx/abc"
printf '{"text":"%s"}\n' "$CANARY" > "$H/.grok/sessions/%2Fsrv%2Fx/abc/updates.jsonl"

# Fixed scan_id so report bytes can be compared across runs.
SHIM="$TMP_ROOT/shim"
mkdir -p "$SHIM"
printf '#!/bin/sh\necho 2026-01-01T00-00-00\n' > "$SHIM/date"
chmod +x "$SHIM/date"

run_scan() { # <out dir> [extra args...]
  local out="$1"; shift
  mkdir -p "$out"
  HOME="$H" PATH="$SHIM:$PATH" "$BASH_BIN" "$SCAN" \
    --hq-root="$HQ" --no-default-scopes --scope="$H/code" \
    --output="$out/report.json" "$@" >"$out/stdout" 2>"$out/stderr"
}

run_scan "$TMP_ROOT/a" --progress-json || fail "scan with --progress-json exited non-zero: $(head -5 "$TMP_ROOT/a/stderr")"
S="$TMP_ROOT/a/stdout"
EV="$(jq -s -c '.' "$S")"

# ── 1. schema ────────────────────────────────────────────────────────────────
[ -s "$S" ] || fail "T1: empty stream"
while IFS= read -r line; do
  printf '%s' "$line" | jq -e 'type == "object" and .v == 1 and (.type | IN("start","source","count","company","project","error","done"))' >/dev/null 2>&1 \
    || fail "T1: invalid event line: $line"
done < "$S"
jq -s -e '
  all(.[]; if .type == "start" then (.sources | type == "array" and all(.[]; (.id|type=="string") and (.label|type=="string")))
    elif .type == "source" then (.id|type=="string") and (.status | IN("scanning","done","skipped","error"))
    elif .type == "count" then (.source|type=="string") and (.key|type=="string") and (.value|type=="number")
    elif .type == "company" then (.id|type=="string") and (.name|type=="string") and (.basis | IN("hq-company","repo-org","folder"))
    elif .type == "project" then (.id|type=="string") and (.name|type=="string") and ((.company|type=="string") or .company == null) and (.basis | IN("repo","claude-code-cwd","codex-cwd"))
    elif .type == "error" then (.source|type=="string") and (.message|type=="string")
    elif .type == "done" then (.report|type=="string") and (.summary.companies|type=="number") and (.summary.projects|type=="number") and (.summary.sessions|type=="number")
    else false end)' "$S" >/dev/null || fail "T1: an event does not match its schema"
[ "$(jq -r '.[0].type' <<<"$EV")" = "start" ] || fail "T1: first event must be start"
[ "$(jq -r '.[-1].type' <<<"$EV")" = "done" ] || fail "T1: last event must be done"
[ "$(jq '[.[] | select(.type=="start" or .type=="done")] | length' <<<"$EV")" = "2" ] || fail "T1: exactly one start and one done"
ok "every line is a v1 event matching its schema; start first, done last"

# ── 2. source order and lifecycle ────────────────────────────────────────────
[ "$(jq -c '[.[0].sources[].id]' <<<"$EV")" = '["hq","repos","claude-code","codex","grok","artifacts"]' ] \
  || fail "T2: start sources: $(jq -c '[.[0].sources[].id]' <<<"$EV")"
[ "$(jq -c '[.[] | select(.type=="source" and .status=="scanning") | .id]' <<<"$EV")" = "$(jq -c '[.[0].sources[].id]' <<<"$EV")" ] \
  || fail "T2: sources must be scanned in start order"
jq -e '
  . as $ev
  | [$ev[0].sources[].id] | all(.[]; . as $id |
      ([$ev | to_entries[] | select(.value.type=="source" and .value.id==$id and .value.status=="scanning") | .key]) as $s
      | ([$ev | to_entries[] | select(.value.type=="source" and .value.id==$id and .value.status=="done") | .key]) as $d
      | ($s | length) == 1 and ($d | length) == 1
        and ([$ev | to_entries[] | select(.value.type=="count" and .value.source==$id) | .key] | all(. > $s[0] and . < $d[0])))' <<<"$EV" >/dev/null \
  || fail "T2: each source must emit scanning, then its counts, then done"
jq -e '
  . as $ev
  | [$ev[] | select(.type=="source" and .status=="done")]
  | all(.[]; . as $d | all(($d.counts // {}) | to_entries[];
      .key as $k | .value as $v
      | ([$ev[] | select(.type=="count" and .source==$d.id and .key==$k) | .value] | last) == $v))' <<<"$EV" >/dev/null \
  || fail "T2: last count per key must equal the done count"
ok "sources scanned in start order: scanning -> counts -> done, final counts repeated in done"

# ── 3. milestones ────────────────────────────────────────────────────────────
[ "$(jq -c '[.[] | select(.type=="count" and .source=="claude-code") | .value]' <<<"$EV")" = "[1,2,5,10,20,28]" ] \
  || fail "T3: claude-code count milestones: $(jq -c '[.[] | select(.type=="count" and .source=="claude-code") | .value]' <<<"$EV")"
jq -e '[.[] | select(.type=="count")] | group_by(.source + "/" + .key) | all(.[]; [.[].value] as $v | $v == ($v | unique))' <<<"$EV" >/dev/null \
  || fail "T3: counts per key must strictly increase"
ok "count events fire at 1-2-5 milestones and strictly increase"

# ── 4. companies and projects ────────────────────────────────────────────────
got_companies="$(jq -c '[.[] | select(.type=="company") | [.id, .name, .basis]]' <<<"$EV")"
want_companies='[["acme","Acme Corp","hq-company"],["globex","globex","folder"],["initech","Initech","repo-org"],["beta-labs","Beta-Labs","repo-org"],["hooli","hooli","folder"]]'
[ "$got_companies" = "$want_companies" ] || fail "T4: companies: $got_companies"
got_projects="$(jq -c '[.[] | select(.type=="project") | [.name, .company, .basis]]' <<<"$EV")"
# alpha appears twice: first with no company, then re-sent (same id) once a
# session dir beside it makes "hooli" a folder company. Consumers upsert by id.
want_projects='[["alpha",null,"repo"],["app1","globex","repo"],["app2","globex","repo"],["docs","acme","repo"],["lib","initech","repo"],["solo-tool",null,"repo"],["web","acme","repo"],["alpha","hooli","repo"],["api","beta-labs","claude-code-cwd"],["beta","hooli","claude-code-cwd"],["plans",null,"claude-code-cwd"],["codex-only",null,"codex-cwd"]]'
[ "$got_projects" = "$want_projects" ] || fail "T4: projects: $got_projects"
jq -e '[.[] | select(.type=="project") | .id] | all(test("^p_[0-9a-f]{12}$")) and ((unique | length) == 11)' <<<"$EV" >/dev/null \
  || fail "T4: project ids must be p_<12 hex>, 11 distinct"
jq -e '[.[] | select(.type=="project")] | group_by(.id) | all(.[]; length == 1 or (length == 2 and .[0].company == null and .[1].company != null and .[0].name == .[1].name and .[0].basis == .[1].basis))' <<<"$EV" >/dev/null \
  || fail "T4: a repeated project id may only move from no company to a company"
jq -e 'reduce .[] as $e ({ok: true, seen: []};
    if $e.type == "company" then .seen += [$e.id]
    elif $e.type == "project" and $e.company != null then .ok = (.ok and (.seen | index($e.company) != null))
    else . end) | .ok' <<<"$EV" >/dev/null \
  || fail "T4: every project company must be announced before the project"
[ "$(jq -c '.[-1].summary' <<<"$EV")" = '{"companies":5,"projects":11,"sessions":31}' ] \
  || fail "T4: done summary: $(jq -c '.[-1].summary' <<<"$EV")"
[ "$(jq -r '.[-1].report' <<<"$EV")" = "$TMP_ROOT/a/report.json" ] || fail "T4: done.report must be the absolute report path"
[ "$(jq -c '[.[] | select(.type=="source" and .id=="repos" and .status=="done") | .counts]' <<<"$EV")" = '[{"repos":8}]' ] \
  || fail "T4: repos done counts: $(jq -c '[.[] | select(.type=="source" and .id=="repos" and .status=="done") | .counts]' <<<"$EV")"
ok "rule pass: HQ company, repo orgs, folder companies; repos and session dirs grouped into projects; upsert on late company"

# Session counts agree with report.json.
for src in claude-code codex grok; do
  stream_n="$(jq -r --arg s "$src" '[.[] | select(.type=="source" and .id==$s and .status=="done")][0].counts.sessions' <<<"$EV")"
  report_n="$(jq -r --arg s "$src" '.categories.conversations[] | select(.source==$s) | .sessions' "$TMP_ROOT/a/report.json")"
  [ "$stream_n" = "$report_n" ] || fail "T4: $src sessions stream=$stream_n report=$report_n"
done
ok "stream session counts match report.json"

# ── 5. privacy ───────────────────────────────────────────────────────────────
for needle in "$CANARY" "$FAKE_TOKEN" '"cwd"' "$H"; do
  if grep -qF -- "$needle" "$S"; then fail "T5: stream leaks '$needle'"; fi
done
# The only absolute path in the stream is done.report.
[ "$(jq '[.[] | select(.type != "done") | tostring | select(test("\"/"))] | length' <<<"$EV")" = "0" ] \
  || fail "T5: an absolute path appears outside done.report"
ok "no file contents, prompts, secrets, cwd fields or absolute paths in events"

# ── 6. report byte-identical; default stdout unchanged ───────────────────────
run_scan "$TMP_ROOT/b" || fail "T6: default scan exited non-zero"
cmp -s "$TMP_ROOT/a/report.json" "$TMP_ROOT/b/report.json" || fail "T6: report.json differs with --progress-json"
[ "$(cat "$TMP_ROOT/b/stdout")" = "$TMP_ROOT/b/report.json" ] || fail "T6: default stdout must stay the report path"
ok "report.json byte-identical with and without the flag; default stdout unchanged"

# ── 7. determinism ───────────────────────────────────────────────────────────
cp "$S" "$TMP_ROOT/first.jsonl"
run_scan "$TMP_ROOT/a" --progress-json || fail "T7: second run failed"
cmp -s "$TMP_ROOT/first.jsonl" "$TMP_ROOT/a/stdout" || fail "T7: event stream differs between runs"
ok "identical event stream across runs"

# ── 8. usage error ───────────────────────────────────────────────────────────
set +e
HOME="$H" "$BASH_BIN" "$SCAN" --hq-root="$HQ" --no-default-scopes --progress-json >"$TMP_ROOT/u.out" 2>"$TMP_ROOT/u.err"
rc=$?
set -e
[ "$rc" -eq 2 ] || fail "T8: --progress-json without --output must exit 2, got $rc"
[ ! -s "$TMP_ROOT/u.out" ] || fail "T8: usage error must not write to stdout"
ok "--progress-json without --output is a usage error"

# ── 9. unreadable claude.ai export ───────────────────────────────────────────
run_scan "$TMP_ROOT/c" --progress-json --claude-export="$TMP_ROOT/missing-export" || fail "T9: scan failed"
CE="$(jq -s -c '.' "$TMP_ROOT/c/stdout")"
jq -e '[.[] | select(.type=="source" and .id=="claude-ai")] | (.[0].status == "scanning") and (.[1].status == "error") and (.[1].message | length > 0)' <<<"$CE" >/dev/null \
  || fail "T9: claude-ai must report status error with a message"
[ "$(jq -r '.[-1].type' <<<"$CE")" = "done" ] || fail "T9: scan must still finish with done"
if jq -c '.[] | select(.type != "done")' <<<"$CE" | grep -qF "$TMP_ROOT"; then fail "T9: an event leaks a path"; fi
ok "unreadable claude.ai export is a non-fatal source error"

# ── 10. hostile remotes, odd names, HQ folders ───────────────────────────────
H2="$TMP_ROOT/home2"
HQ2="$TMP_ROOT/hq2"
mkdir -p "$HQ2/companies"
cat > "$HQ2/companies/manifest.yaml" <<'YAML'
companies:
  _template:
    name: Template
  My_Co:
    name: Mine
  acme:
    name: Acme Corp
YAML
mkrepo "$H2/code/r/cred" "https://alice:$FAKE_TOKEN@github.com/OrgX/repoA.git"
mkrepo "$H2/code/r/query" "https://github.com/OrgY/repoB.git?private_token=$FAKE_TOKEN"
mkrepo "$H2/code/r/frag" "https://github.com/OrgZ/repoF.git#$FAKE_TOKEN"
mkrepo "$H2/code/r/slashpw" "https://u:p/q@gitlab.com/grp/sub/repoC"
mkrepo "$H2/code/r/pct" "git@github.com:bad%20org/repoP.git"
mkrepo "$H2/code/r/space" "https://github.com/bad org/repoS.git"
mkrepo "$H2/code/r/local" "/srv/git/repoL.git"
mkrepo "$H2/code/r/quoted" '"https://github.com/OrgQ/repoQ.git"'
mkrepo "$H2/code/nl/a"$'\n'"b"
mkrepo "$H2/code/9f1c2d3e-4b5a-6789-abcd-ef0123456789/u1"
mkrepo "$H2/code/9f1c2d3e-4b5a-6789-abcd-ef0123456789/u2"
session "$H2/.claude/projects/p2/lib.jsonl" "$H2/Library/Application Support/Claude/scratch/libproj"
session "$H2/.claude/projects/p1/s1.jsonl" "$HQ2/companies/My_Co/projects/site"
session "$H2/.claude/projects/p1/s2.jsonl" "$HQ2/companies/cmp_x/projects/cache"
session "$H2/.claude/projects/p1/odd"$'\n'"name.jsonl" "$H2/notes/drafts"
HOME="$H2" "$BASH_BIN" "$SCAN" --hq-root="$HQ2" --no-default-scopes --scope="$H2/code" \
  --output="$TMP_ROOT/h2/report.json" --progress-json >"$TMP_ROOT/h2.jsonl" 2>"$TMP_ROOT/h2.err" \
  || fail "T10: scan failed: $(head -3 "$TMP_ROOT/h2.err")"
E2="$(jq -s -c '.' "$TMP_ROOT/h2.jsonl")" || fail "T10: stream is not valid JSON Lines"
for needle in "$FAKE_TOKEN" "alice" "private_token" "p/q" "@" "?" "#" "%" "$H2" "$HQ2"; do
  if jq -c '.[] | select(.type != "done")' <<<"$E2" | grep -qF -- "$needle"; then fail "T10: stream leaks '$needle'"; fi
done
[ "$(jq -c '[.[] | select(.type=="company" and .basis=="hq-company") | [.id, .name]]' <<<"$E2")" = '[["my-co","Mine"],["acme","Acme Corp"]]' ] \
  || fail "T10: manifest companies must be slugged and skip _template: $(jq -c '[.[] | select(.type=="company")]' <<<"$E2")"
proj() { jq -r --arg n "$1" '[.[] | select(.type=="project" and .name==$n)] | last | "\(.company)"' <<<"$E2"; }
[ "$(proj repoA)" = "orgx" ] || fail "T10: credential remote: repoA company=$(proj repoA)"
[ "$(proj repoB)" = "orgy" ] || fail "T10: token query remote: repoB company=$(proj repoB)"
[ "$(proj repoF)" = "orgz" ] || fail "T10: fragment remote: repoF company=$(proj repoF)"
[ "$(proj repoC)" = "grp" ]  || fail "T10: slash in password: repoC company=$(proj repoC)"
[ "$(proj repoQ)" = "orgq" ] || fail "T10: quoted config value must be unquoted: repoQ company=$(proj repoQ)"
jq -e '[.[] | select(.type=="project" or .type=="company") | .name] | all(test("\"") | not)' <<<"$E2" >/dev/null \
  || fail "T10: a project or company name kept a quote: $(jq -c '[.[] | select(.type=="project" or .type=="company") | .name]' <<<"$E2")"
for unusable in pct space local; do
  [ "$(proj "$unusable")" = "null" ] || fail "T10: unusable remote must fall back to the folder name: $unusable=$(proj "$unusable")"
done
for bad in repoP repoS repoL "bad org" bad%20org; do
  jq -e --arg n "$bad" '[.[] | select((.type=="project" or .type=="company") and .name==$n)] | length == 0' <<<"$E2" >/dev/null \
    || fail "T10: name from an unusable remote leaked: $bad"
done
[ "$(proj site)" = "my-co" ] || fail "T10: HQ company project folder must map to the slugged company: site=$(proj site)"
[ "$(proj cache)" = "null" ] || fail "T10: non-manifest company folders are not companies: cache=$(proj cache)"
[ "$(proj drafts)" = "null" ] || fail "T10: session with a newline in its file name must still be read"
jq -e '[.[] | select(.type=="project") | .name] | all(test("\n") | not)' <<<"$E2" >/dev/null \
  || fail "T10: a path with a newline must be skipped, not split"
[ "$(proj u1)" = "null" ] && [ "$(proj u2)" = "null" ] \
  || fail "T10: machine-generated folder names (UUIDs) must not become companies"
jq -e '[.[] | select(.type=="project" and .name=="libproj")] | length == 0' <<<"$E2" >/dev/null \
  || fail "T10: app data under ~/Library is not a project"
[ "$(jq -c '[.[] | select(.type=="source" and .id=="claude-code" and .status=="done") | .counts.sessions]' <<<"$E2")" = "[4]" ] \
  || fail "T10: claude-code must count the session file with a newline in its name"
jq -e '. as $ev | [$ev[] | select(.type=="company") | .id] as $c
  | all($ev[] | select(.type=="project" and .company != null); .company as $x | $c | index($x) != null)' <<<"$E2" >/dev/null \
  || fail "T10: every project company must be an announced company id"
ok "remotes: credentials, tokens, fragments and odd URLs never leak; manifest ids slugged; NUL-safe lists"

# ── 11. ids are stable across machines (relative identity, fixed salt) ──────
H3="$TMP_ROOT/elsewhere/home"
mkdir -p "$H3"
cp -R "$H/." "$H3/"
# Session cwds name the HOME they were recorded under; rewrite to the new one.
find "$H3/.claude/projects" "$H3/.codex/sessions" -type f -name '*.jsonl' -print0 \
  | xargs -0 sed -i.bak "s|$H/|$H3/|g; s|\"$H\"|\"$H3\"|g"
find "$H3" -name '*.bak' -type f -delete
HOME="$H3" PATH="$SHIM:$PATH" "$BASH_BIN" "$SCAN" --hq-root="$HQ" --no-default-scopes --scope="$H3/code" \
  --output="$TMP_ROOT/h3/report.json" --progress-json >"$TMP_ROOT/h3.jsonl" 2>"$TMP_ROOT/h3.err" || fail "T11: scan failed"
diff <(grep -v '"type":"done"' "$S") <(grep -v '"type":"done"' "$TMP_ROOT/h3.jsonl") >/dev/null \
  || fail "T11: same layout under a different HOME must give the same events and ids"
ok "project ids depend on remote identity or HOME-relative path, not the machine"

# ── 12. SIGTERM mid-scan: exit 143, no orphans, no temp files left ──────────
# A logging mktemp shim records every path the scan creates, so the test
# checks those exact paths (macOS mktemp ignores TMPDIR, so watching a TMPDIR
# folder alone would miss files written elsewhere). Every created path must
# sit inside the scan's private dir (the first one created) and none may
# survive the signal.
REAL_MKTEMP="$(command -v mktemp)"
MKLOG_SHIM="$TMP_ROOT/mklogshim"
mkdir -p "$MKLOG_SHIM"
# shellcheck disable=SC2016 # shim source text, expanded when the shim runs
printf '#!/bin/sh\nout="$("%s" "$@")" || exit $?\nprintf "%%s\\n" "$out" >> "$MKTEMP_LOG"\nprintf "%%s\\n" "$out"\n' \
  "$REAL_MKTEMP" > "$MKLOG_SHIM/mktemp"
chmod +x "$MKLOG_SHIM/mktemp"

# check_sig_temp <label> <log>: every logged path is under the first one and
# none exists any more. Leftovers are removed before failing.
check_sig_temp() {
  local label="$1" log="$2" first p left=""
  [ -s "$log" ] || fail "$label: the scan created no temp paths"
  first="$(head -1 "$log")"
  while IFS= read -r p; do
    [ -e "$p" ] && left="$left $p"
  done < "$log"
  if [ -n "$left" ]; then
    while IFS= read -r p; do rm -rf "$p"; done < "$log"
    fail "$label: temp paths left behind:$left"
  fi
  while IFS= read -r p; do
    case "$p" in "$first"|"$first"/*) ;; *) fail "$label: temp path outside the scan's private dir: $p" ;; esac
  done < "$log"
}

marker_running() { pgrep -f "sleep $1" >/dev/null; }

# 12a. TERM to the bash process only, while find streams into a read loop
# (the trap runs at once; scan_abort must stop the children itself).
SIG_TMP="$TMP_ROOT/sigtmp"
mkdir -p "$SIG_TMP" "$TMP_ROOT/slowshim"
MARK="31.4159"
REAL_FIND="$(command -v find)"
printf '#!/bin/sh\nsleep %s\nexec "%s" "$@"\n' "$MARK" "$REAL_FIND" > "$TMP_ROOT/slowshim/find"
chmod +x "$TMP_ROOT/slowshim/find"
: > "$TMP_ROOT/sig-a.log"
HOME="$H" TMPDIR="$SIG_TMP" MKTEMP_LOG="$TMP_ROOT/sig-a.log" \
  PATH="$MKLOG_SHIM:$TMP_ROOT/slowshim:$PATH" "$BASH_BIN" "$SCAN" --hq-root="$HQ" \
  --no-default-scopes --scope="$H/code" --output="$TMP_ROOT/sig/report.json" --progress-json \
  >"$TMP_ROOT/sig.jsonl" 2>"$TMP_ROOT/sig.err" &
spid=$!
for _ in $(seq 1 100); do marker_running "$MARK" && break; sleep 0.1; done
marker_running "$MARK" || fail "T12a: scan never reached the slow find"
kill -TERM "$spid"
set +e; wait "$spid"; src=$?; set -e
[ "$src" -eq 143 ] || fail "T12a: SIGTERM must exit 143, got $src"
sleep 0.3
if marker_running "$MARK"; then fail "T12a: a child of the scan survived SIGTERM"; fi
check_sig_temp T12a "$TMP_ROOT/sig-a.log"
[ -z "$(ls -A "$SIG_TMP")" ] || fail "T12a: temp files left behind: $(ls -A "$SIG_TMP")"
[ ! -e "$TMP_ROOT/sig/report.json" ] || fail "T12a: an interrupted scan must not publish a report"
[ "$(head -1 "$TMP_ROOT/sig.jsonl" | jq -r '.type')" = "start" ] || fail "T12a: stream should have started"

# 12b. TERM to the whole process group (as hq-cli sends it) while a report
# helper holds its own temp files (find stderr and the found-path list).
MARK2="27.1828"
mkdir -p "$TMP_ROOT/slowshim2"
printf '#!/bin/sh\ncase " $* " in *" -type d -name .claude "*) sleep %s ;; esac\nexec "%s" "$@"\n' \
  "$MARK2" "$REAL_FIND" > "$TMP_ROOT/slowshim2/find"
chmod +x "$TMP_ROOT/slowshim2/find"
: > "$TMP_ROOT/sig-b.log"
set -m
HOME="$H" TMPDIR="$SIG_TMP" MKTEMP_LOG="$TMP_ROOT/sig-b.log" \
  PATH="$MKLOG_SHIM:$TMP_ROOT/slowshim2:$PATH" "$BASH_BIN" "$SCAN" --hq-root="$HQ" \
  --no-default-scopes --scope="$H/code" --output="$TMP_ROOT/sig2/report.json" --progress-json \
  >"$TMP_ROOT/sig2.jsonl" 2>"$TMP_ROOT/sig2.err" &
spid=$!
set +m
for _ in $(seq 1 100); do marker_running "$MARK2" && break; sleep 0.1; done
marker_running "$MARK2" || fail "T12b: scan never reached the slow report find"
[ "$(grep -c '' "$TMP_ROOT/sig-b.log")" -ge 3 ] \
  || fail "T12b: expected the scan dir plus helper temp files, got: $(tr '\n' ' ' < "$TMP_ROOT/sig-b.log")"
kill -TERM -- "-$spid"
set +e; wait "$spid"; src=$?; set -e
[ "$src" -eq 143 ] || fail "T12b: SIGTERM must exit 143, got $src"
sleep 0.3
if marker_running "$MARK2"; then fail "T12b: a child of the scan survived SIGTERM"; fi
check_sig_temp T12b "$TMP_ROOT/sig-b.log"
[ -z "$(ls -A "$SIG_TMP")" ] || fail "T12b: temp files left behind: $(ls -A "$SIG_TMP")"
[ ! -e "$TMP_ROOT/sig2/report.json" ] || fail "T12b: an interrupted scan must not publish a report"
ok "SIGTERM mid-scan exits 143 and leaves no children or temp files; every temp file is inside the scan's private dir"

# ── 13. GNU mktemp semantics (Linux CI) ─────────────────────────────────────
# GNU mktemp honors TMPDIR and fails when that folder is missing. This shim
# copies that behavior on any OS. A scan whose private temp dir is deleted
# early (for example by a RETURN trap firing when a file sourced inside main
# finishes) fails here.
GNU_SHIM="$TMP_ROOT/gnushim"
mkdir -p "$GNU_SHIM"
cat > "$GNU_SHIM/mktemp" <<SHIM
#!/bin/sh
d=""; t=""; dash_t=""
for a do
  case "\$a" in
    -d) d="-d" ;;
    -t) dash_t=1 ;;
    -q|-u) ;;
    -*) echo "mktemp shim: unsupported option \$a" >&2; exit 2 ;;
    *) t="\$a" ;;
  esac
done
base="\${TMPDIR:-/tmp}"
if [ -z "\$t" ]; then t="\$base/tmp.XXXXXXXXXX"
elif [ -n "\$dash_t" ]; then t="\$base/\$t"
fi
dir="\${t%/*}"
[ "\$dir" != "\$t" ] && [ ! -d "\$dir" ] && {
  echo "mktemp: failed to create file via template '\$t': No such file or directory" >&2; exit 1; }
out="\$("$REAL_MKTEMP" \$d "\$t")" || exit \$?
printf '%s\n' "\$out" >> "\$MKTEMP_LOG"
printf '%s\n' "\$out"
SHIM
chmod +x "$GNU_SHIM/mktemp"
GNU_TMP="$TMP_ROOT/gnutmp"
mkdir -p "$GNU_TMP"
: > "$TMP_ROOT/gnu.log"
TMPDIR="$GNU_TMP" MKTEMP_LOG="$TMP_ROOT/gnu.log" PATH="$GNU_SHIM:$PATH" run_scan "$TMP_ROOT/gnu" --progress-json \
  || fail "T13: scan with GNU mktemp semantics exited non-zero: $(head -5 "$TMP_ROOT/gnu/stderr")"
cmp -s "$TMP_ROOT/b/report.json" "$TMP_ROOT/gnu/report.json" || fail "T13: report differs under GNU mktemp semantics"
[ "$(tail -1 "$TMP_ROOT/gnu/stdout" | jq -r '.type')" = "done" ] || fail "T13: stream must end with done"
case "$(head -1 "$TMP_ROOT/gnu.log")" in
  "$GNU_TMP"/?*) ;;
  *) fail "T13: scan dir must be created under TMPDIR: $(head -1 "$TMP_ROOT/gnu.log")" ;;
esac
[ -z "$(ls -A "$GNU_TMP")" ] || fail "T13: temp files left behind after a normal run: $(ls -A "$GNU_TMP")"
check_sig_temp T13 "$TMP_ROOT/gnu.log"
ok "scan succeeds under GNU mktemp semantics and cleans its private temp dir"

echo "PASS: $PASS import-context --progress-json assertion group(s) green"
