#!/usr/bin/env bash
# hq-core: public
# Acceptance/behaviour tests for the US-004 close-time reconcile + vetted
# transcript handoff + SessionStart sweep hook
# (core/hooks/work-mesh-close.sh + the US-004 additions to
# core/scripts/work-mesh-lib.sh).
#
# BEHAVIORAL: assert on the observable artifacts — the reconcile POST body/verb,
# the spool JSONL events (close-attempt|reconciled|reconcile-*|copied|copy-*),
# the redacted copy under companies/<slug>/sessions/<personUid>/, the terminal
# marker files, git check-ignore of the staging path, foreground latency, and
# the fail-closed/consent/multi-company/harness gates — NOT internals.
#
# Hermetic: curl stubbed on PATH (no network); HOME + ~/.claude/projects + HQ
# root all inside an mktemp sandbox; token supplied via seam. bash-3.2 + CI
# (ubuntu-latest) compatible: no mapfile, no associative arrays, no ${var,,}.
#
# Coverage:
#   1  close happy path        -> reconcile POST + reconciled + redacted copy (AC1,2,4,9)
#   2  redaction scrub          -> secret redacted in copy; count logged; never leaked (AC4)
#   3  wm_redact_stream units   -> line-preserving; fails-closed on bad input (AC4)
#   4  structural work-record   -> no registration marker => refuse copy (AC2 gate)
#   5  double consent OFF        -> no copy + quarantine + terminal (AC7,9)
#   6  gates unreachable         -> fail-closed: no copy, stays pending (AC4)
#   7  size budget               -> skip-and-flag, never shipped (AC4)
#   8  multi-company             -> both reconciled crossCompany, no copy either (AC8)
#   9  non-Claude harness        -> reconcile + transcriptUnavailable, no copy (AC3)
#   10 staging hygiene           -> git check-ignore + .ignore cover the path (AC5)
#   11 sweep late-reconcile       -> inactive registered session backfilled (AC6)
#   12 sweep skips current+active -> current session + fresh transcript untouched (AC6)
#   13 sweep claim race           -> a held claim blocks a second sweep (AC6)
#   14 idempotent terminal         -> reconciled+copied record is a no-op (AC6)
#   15 foreground latency          -> close fg returns fast under a slow curl (BP#4)
#   16 token hygiene               -> token never in log or spool

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SRC_HOOK="$REPO_ROOT/core/hooks/work-mesh-close.sh"
SRC_LIB="$REPO_ROOT/core/scripts/work-mesh-lib.sh"
SRC_GITIGNORE="$REPO_ROOT/.gitignore"
SRC_IGNORE="$REPO_ROOT/.ignore"

for f in "$SRC_HOOK" "$SRC_LIB"; do
  [ -f "$f" ] || { echo "FATAL: missing source under test: $f" >&2; exit 1; }
done
command -v jq >/dev/null 2>&1 || { echo "FATAL: jq is required for these tests" >&2; exit 1; }

SANDBOX="$(mktemp -d)"
cleanup() {
  local i=0
  rm -rf "$SANDBOX" 2>/dev/null || true
  while [ -d "$SANDBOX" ] && [ "$i" -lt 60 ]; do
    sleep 0.1; rm -rf "$SANDBOX" 2>/dev/null || true; i=$((i + 1))
  done
}
trap cleanup EXIT

mkdir -p "$SANDBOX/core/hooks" "$SANDBOX/core/scripts" \
         "$SANDBOX/workspace/sessions" "$SANDBOX/workspace/metrics" \
         "$SANDBOX/workspace/logs" "$SANDBOX/workspace/work-mesh/cache" \
         "$SANDBOX/companies" "$SANDBOX/stubbin" \
         "$SANDBOX/home/.claude/projects/proj"
cp "$SRC_HOOK" "$SANDBOX/core/hooks/work-mesh-close.sh"
cp "$SRC_LIB"  "$SANDBOX/core/scripts/work-mesh-lib.sh"
chmod +x "$SANDBOX/core/hooks/work-mesh-close.sh"

HOOK="$SANDBOX/core/hooks/work-mesh-close.sh"
SPOOL="$SANDBOX/workspace/metrics/work-sessions.jsonl"
LOG="$SANDBOX/workspace/logs/work-mesh-hook.log"
PROJDIR="$SANDBOX/home/.claude/projects/proj"

# --- curl stub (POST bodies captured; canned GET bodies; latency/fail seams) --
cat > "$SANDBOX/stubbin/curl" <<'STUB'
#!/usr/bin/env bash
set -u
method="GET"; url=""; data=""; prev=""
for a in "$@"; do
  case "$prev" in
    -X)                      method="$a" ;;
    --data-binary|--data|-d) data="$a" ;;
  esac
  case "$a" in http://*|https://*) url="$a" ;; esac
  prev="$a"
done
# argv must NEVER carry the bearer token (it arrives via stdin, curl -H @-);
# capture argv + the stdin header line for hygiene assertions.
if [ -n "${WM_STUB_DIR:-}" ]; then
  mkdir -p "$WM_STUB_DIR" 2>/dev/null || true
  printf '%s\n' "$*" >> "$WM_STUB_DIR/argv.txt"
  if IFS= read -r -t 1 _hdr 2>/dev/null && [ -n "$_hdr" ]; then
    printf '%s\n' "$_hdr" >> "$WM_STUB_DIR/stdin-headers.txt"
  fi
fi
if [ -n "${WM_STUB_SLEEP:-}" ] && [ "${WM_STUB_SLEEP}" != "0" ]; then sleep "$WM_STUB_SLEEP"; fi
if [ -n "${WM_STUB_FAIL:-}" ] && [ "${WM_STUB_FAIL}" != "0" ]; then exit 7; fi
if [ "$method" = "POST" ]; then
  if [ -n "${WM_STUB_DIR:-}" ]; then
    mkdir -p "$WM_STUB_DIR" 2>/dev/null || true
    printf '%s\n' "$data" >> "$WM_STUB_DIR/post-bodies.jsonl"
    printf '%s\t%s\n' "$url" "$data" >> "$WM_STUB_DIR/post-log.txt"
  fi
  printf '%s' "${WM_STUB_POST_CODE:-201}"
  exit 0
fi
case "$url" in
  *"/membership/me"*)    printf '%s' "${WM_STUB_MEMBERSHIP:-}" ;;
  *"/v1/consent/gates"*) printf '%s' "${WM_STUB_GATES:-}" ;;
  *)                     printf '%s' "${WM_STUB_GET_DEFAULT:-}" ;;
esac
exit 0
STUB
chmod +x "$SANDBOX/stubbin/curl"

export PATH="$SANDBOX/stubbin:$PATH"
export HOME="$SANDBOX/home"
export HQ_ROOT="$SANDBOX"
export HQ_WORK_MESH_API_URL="http://127.0.0.1:9/wm-test"
export HQ_WORK_MESH_CLAUDE_PROJECTS_DIR="$SANDBOX/home/.claude/projects"

GATES_ALL_TRUE="$(jq -nc '{workRegistryEnabled:true,transcriptCaptureEnabled:true,transcriptOptIn:true}')"
GATES_CAPTURE_OFF="$(jq -nc '{workRegistryEnabled:true,transcriptCaptureEnabled:false,transcriptOptIn:true}')"
GATES_OPTIN_OFF="$(jq -nc '{workRegistryEnabled:true,transcriptCaptureEnabled:true,transcriptOptIn:false}')"
GATES_REGISTRY_OFF="$(jq -nc '{workRegistryEnabled:false,transcriptCaptureEnabled:true,transcriptOptIn:true}')"

# --- assertions -------------------------------------------------------------
PASS=0; FAIL=0
pass()  { PASS=$((PASS + 1)); echo "  ok:   $1"; }
failc() { FAIL=$((FAIL + 1)); echo "  FAIL: $1" >&2; }
assert_eq()           { if [ "$2" = "$3" ]; then pass "$1"; else failc "$1 (expected '$3', got '$2')"; fi; }
assert_true()         { local l="$1"; shift; if "$@"; then pass "$l"; else failc "$l"; fi; }
assert_false()        { local l="$1"; shift; if "$@"; then failc "$l (expected failure)"; else pass "$l"; fi; }
assert_contains()     { case "$2" in *"$3"*) pass "$1" ;; *) failc "$1 (missing '$3')" ;; esac; }
assert_not_contains() { case "$2" in *"$3"*) failc "$1 (unexpected '$3')" ;; *) pass "$1" ;; esac; }

count_event_sid() {  # <event> <sid>
  local ev="$1" sid="$2" n
  [ -f "$SPOOL" ] || { printf '0'; return 0; }
  n="$(jq -c --arg e "$ev" --arg s "$sid" 'select(.event==$e and .sessionId==$s)' "$SPOOL" 2>/dev/null | wc -l | tr -d '[:space:]')" || n=0
  printf '%s' "${n:-0}"
}
count_posts() { local d="$1"; if [ -f "$d/post-bodies.jsonl" ]; then wc -l < "$d/post-bodies.jsonl" | tr -d '[:space:]'; else printf '0'; fi; }
first_post_body() { local d="$1"; [ -f "$d/post-bodies.jsonl" ] || return 1; head -n1 "$d/post-bodies.jsonl"; }
reg_marker()  { printf '%s/workspace/sessions/%s/work-mesh-registered-%s' "$SANDBOX" "$1" "$2"; }
recon_marker(){ printf '%s/workspace/sessions/%s/work-mesh-reconciled-%s' "$SANDBOX" "$1" "$2"; }
copy_marker() { printf '%s/workspace/sessions/%s/work-mesh-copied-%s' "$SANDBOX" "$1" "$2"; }
staged_file() { printf '%s/companies/%s/sessions/%s/%s.jsonl' "$SANDBOX" "$1" "$2" "$3"; }
now_s() { date +%s; }

# Fabricate a US-003 registration (marker + attempt spool line + meta.yaml).
register_session() {  # <sid> <slug> [uid]
  local sid="$1" slug="$2" uid="${3:-cmp_$2}" sd
  sd="$SANDBOX/workspace/sessions/$sid"
  mkdir -p "$sd"
  printf 'company_slug: %s\nproject: proj_demo\n' "$slug" > "$sd/meta.yaml"
  : > "$(reg_marker "$sid" "$slug")"
  jq -nc --arg s "$sid" --arg c "$slug" --arg u "$uid" \
    '{ts:"t",event:"attempt",sessionId:$s,companySlug:$c,companyUid:$u,harness:"claude-code"}' >> "$SPOOL"
}
# Write a valid JSONL transcript for a session; optional 2nd arg injects a secret.
mk_transcript() {  # <sid> [secret]
  local sid="$1" secret="${2:-}" f="$PROJDIR/$1.jsonl"
  {
    printf '%s\n' '{"type":"assistant","timestamp":"2026-07-11T10:00:00Z","message":{"role":"assistant","model":"claude-opus-4-8","content":[{"type":"tool_use","name":"Edit","input":{"file_path":"/repo/a.ts"}}],"usage":{"input_tokens":10,"output_tokens":5}}}'
    printf '%s\n' '{"type":"assistant","timestamp":"2026-07-11T10:05:00Z","message":{"role":"assistant","model":"claude-opus-4-8","content":[{"type":"tool_use","name":"Write","input":{"file_path":"/repo/b.ts"}}]}}'
    if [ -n "$secret" ]; then
      jq -nc --arg sk "$secret" '{type:"user",timestamp:"2026-07-11T10:06:00Z",message:{role:"user",content:[{type:"tool_result",content:("token was " + $sk)}]}}'
    fi
  } > "$f"
  printf '%s' "$f"
}

# ===========================================================================
echo "CASE 1: close happy path -> reconcile POST + reconciled + redacted copy"
# ===========================================================================
sid=sid-happy; d1="$SANDBOX/stub-happy"
register_session "$sid" indigo cmp_indigo
tp1="$(mk_transcript "$sid")"
WM_ROOT="$SANDBOX" WM_SID="$sid" WM_HINT="$tp1" WM_HARNESS=claude-code \
  HQ_WORK_MESH_TOKEN=tok HQ_WORK_MESH_PERSON_UID=prs_test \
  WM_STUB_DIR="$d1" WM_STUB_GATES="$GATES_ALL_TRUE" WM_STUB_POST_CODE=200 \
  bash "$HOOK" __close_bg__ </dev/null
assert_eq   "happy: exactly one reconcile POST" "$(count_posts "$d1")" "1"
purl="$(cut -f1 "$d1/post-log.txt" 2>/dev/null | head -n1 || true)"
assert_contains "happy: POST hit the reconcile endpoint" "$purl" "/v1/work-mesh/work-sessions/reconcile"
body1="$(first_post_body "$d1")"
assert_eq   "happy: body.companyUid" "$(printf '%s' "$body1" | jq -r '.companyUid')" "cmp_indigo"
assert_eq   "happy: body.sessionId"  "$(printf '%s' "$body1" | jq -r '.sessionId')" "$sid"
assert_eq   "happy: outcome.sessionId matches" "$(printf '%s' "$body1" | jq -r '.outcome.sessionId')" "$sid"
assert_eq   "happy: outcome files totalCount=2" "$(printf '%s' "$body1" | jq -r '.outcome.files.totalCount')" "2"
assert_eq   "happy: outcome model captured" "$(printf '%s' "$body1" | jq -r '.outcome.models | index("claude-opus-4-8") != null')" "true"
assert_eq   "happy: outcome durationMs=300000" "$(printf '%s' "$body1" | jq -r '.outcome.durationMs')" "300000"
assert_eq   "happy: NO transcript flag on clean copy" "$(printf '%s' "$body1" | jq -r 'has("transcriptUnavailable") or has("crossCompany") or has("transcriptSkipped")')" "false"
assert_eq   "happy: reconciled event spooled" "$(count_event_sid reconciled "$sid")" "1"
assert_true "happy: reconciled marker written" test -f "$(recon_marker "$sid" indigo)"
assert_true "happy: transcript copied to staging" test -f "$(staged_file indigo prs_test "$sid")"
assert_eq   "happy: copied event spooled" "$(count_event_sid copied "$sid")" "1"
assert_true "happy: copied marker written" test -f "$(copy_marker "$sid" indigo)"

# ===========================================================================
echo "CASE 2: redaction scrub -> secret redacted in copy; count logged; no leak"
# ===========================================================================
sid=sid-redact; d2="$SANDBOX/stub-redact"
SECRET='sk-ant-AAAABBBBCCCCDDDDEEEEFFFFGGGGHHHH'
register_session "$sid" indigo cmp_indigo
tp2="$(mk_transcript "$sid" "$SECRET")"
WM_ROOT="$SANDBOX" WM_SID="$sid" WM_HINT="$tp2" WM_HARNESS=claude-code \
  HQ_WORK_MESH_TOKEN=tok HQ_WORK_MESH_PERSON_UID=prs_test \
  WM_STUB_DIR="$d2" WM_STUB_GATES="$GATES_ALL_TRUE" WM_STUB_POST_CODE=200 \
  bash "$HOOK" __close_bg__ </dev/null
copied2="$(staged_file indigo prs_test "$sid")"
assert_true "redact: copy exists" test -f "$copied2"
if [ -f "$copied2" ]; then
  if grep -qF "$SECRET" "$copied2"; then failc "redact: SECRET leaked into the copy"; else pass "redact: secret absent from the copy"; fi
  if grep -q '<REDACTED:anthropic_key>' "$copied2"; then pass "redact: secret replaced with a redaction token"; else failc "redact: no redaction token in the copy"; fi
fi
# redaction count logged on the copied spool line (>=1), never the secret.
rc2="$(jq -r --arg s "$sid" 'select(.event=="copied" and .sessionId==$s) | .redactionCount' "$SPOOL" 2>/dev/null | tail -n1)"
if [ -n "$rc2" ] && [ "$rc2" -ge 1 ] 2>/dev/null; then pass "redact: redactionCount>=1 on the copied event"; else failc "redact: redactionCount missing/zero ($rc2)"; fi
if grep -qF "$SECRET" "$LOG" 2>/dev/null; then failc "redact: secret leaked into hook log"; else pass "redact: secret absent from hook log"; fi
if grep -qF "$SECRET" "$SPOOL" 2>/dev/null; then failc "redact: secret leaked into spool"; else pass "redact: secret absent from spool"; fi

# ===========================================================================
echo "CASE 3: wm_redact_stream units -> line-preserving; fails-closed on bad input"
# ===========================================================================
(
  . "$SANDBOX/core/scripts/work-mesh-lib.sh"
  uin="$SANDBOX/u-in.jsonl"; uout="$SANDBOX/u-out.jsonl"
  printf 'line one AKIA1234567890ABCDEF end\nplain line\n' > "$uin"
  cnt="$(wm_redact_stream "$uin" "$uout")"; rc=$?
  [ "$rc" -eq 0 ] || { echo "  FAIL: redact-unit: nonzero on good input" >&2; exit 3; }
  grep -q '<REDACTED:aws_key>' "$uout" || { echo "  FAIL: redact-unit: aws key not redacted" >&2; exit 3; }
  grep -qF 'AKIA1234567890ABCDEF' "$uout" && { echo "  FAIL: redact-unit: aws key leaked" >&2; exit 3; }
  [ "$(wc -l < "$uin" | tr -d '[:space:]')" = "$(wc -l < "$uout" | tr -d '[:space:]')" ] || { echo "  FAIL: redact-unit: line count changed" >&2; exit 3; }
  [ "$cnt" -ge 1 ] 2>/dev/null || { echo "  FAIL: redact-unit: count<1" >&2; exit 3; }
  # Fail-closed on nonexistent input.
  if wm_redact_stream "$SANDBOX/does-not-exist.jsonl" "$SANDBOX/u-bad.out" >/dev/null 2>&1; then
    echo "  FAIL: redact-unit: returned 0 on missing input" >&2; exit 3
  fi
  echo "  ok:   redact-unit: line-preserving redaction + fail-closed on bad input"
) && PASS=$((PASS+1)) || FAIL=$((FAIL+1))

# ===========================================================================
echo "CASE 4: structural work-record gate -> no registration marker => refuse copy"
# ===========================================================================
sid=sid-nomarker; d4="$SANDBOX/stub-nomarker"
# Attempt spool line present (so it's a candidate) but DELETE the registration
# marker: the structural gate must refuse the copy while still reconciling.
register_session "$sid" indigo cmp_indigo
rm -f "$(reg_marker "$sid" indigo)"
tp4="$(mk_transcript "$sid")"
WM_ROOT="$SANDBOX" WM_SID="$sid" WM_HINT="$tp4" WM_HARNESS=claude-code \
  HQ_WORK_MESH_TOKEN=tok HQ_WORK_MESH_PERSON_UID=prs_test \
  WM_STUB_DIR="$d4" WM_STUB_GATES="$GATES_ALL_TRUE" WM_STUB_POST_CODE=200 \
  bash "$HOOK" __close_bg__ </dev/null
assert_eq   "no-marker: reconcile still fired" "$(count_event_sid reconciled "$sid")" "1"
assert_false "no-marker: NO transcript copied" test -f "$(staged_file indigo prs_test "$sid")"
if jq -e --arg s "$sid" 'select(.event=="copy-skipped" and .sessionId==$s) | .reason=="no_work_record"' "$SPOOL" >/dev/null 2>&1; then
  pass "no-marker: copy-skipped reason no_work_record"
else
  failc "no-marker: copy-skip reason not no_work_record"
fi

# ===========================================================================
echo "CASE 5: double consent OFF -> no copy + quarantine + terminal"
# ===========================================================================
for variant in capture optin; do
  sid="sid-consent-$variant"; d5="$SANDBOX/stub-consent-$variant"
  register_session "$sid" indigo cmp_indigo
  tp5="$(mk_transcript "$sid")"
  # Pre-stage a stale copy (as if gates were once on) to prove quarantine.
  mkdir -p "$(dirname "$(staged_file indigo prs_test "$sid")")"
  printf 'STALE\n' > "$(staged_file indigo prs_test "$sid")"
  if [ "$variant" = capture ]; then g="$GATES_CAPTURE_OFF"; else g="$GATES_OPTIN_OFF"; fi
  WM_ROOT="$SANDBOX" WM_SID="$sid" WM_HINT="$tp5" WM_HARNESS=claude-code \
    HQ_WORK_MESH_TOKEN=tok HQ_WORK_MESH_PERSON_UID=prs_test \
    WM_STUB_DIR="$d5" WM_STUB_GATES="$g" WM_STUB_POST_CODE=200 \
    bash "$HOOK" __close_bg__ </dev/null
  assert_eq    "consent-$variant: reconcile still fired" "$(count_event_sid reconciled "$sid")" "1"
  assert_false "consent-$variant: stale staged copy quarantined" test -f "$(staged_file indigo prs_test "$sid")"
  if jq -e --arg s "$sid" 'select(.event=="copy-skipped" and .sessionId==$s) | .reason=="gates_off"' "$SPOOL" >/dev/null 2>&1; then
    pass "consent-$variant: copy-skipped reason gates_off"
  else
    failc "consent-$variant: copy-skip reason not gates_off"
  fi
  assert_true  "consent-$variant: copied marker terminal (no forever-retry)" test -f "$(copy_marker "$sid" indigo)"
done

# ===========================================================================
echo "CASE 6: gates unreachable -> fail-closed: no copy, stays pending"
# ===========================================================================
sid=sid-gatesdown; d6="$SANDBOX/stub-gatesdown"
register_session "$sid" indigo cmp_indigo
tp6="$(mk_transcript "$sid")"
# Empty gates body => wm_gates_refresh returns "" => unreachable.
WM_ROOT="$SANDBOX" WM_SID="$sid" WM_HINT="$tp6" WM_HARNESS=claude-code \
  HQ_WORK_MESH_TOKEN=tok HQ_WORK_MESH_PERSON_UID=prs_test \
  WM_STUB_DIR="$d6" WM_STUB_GATES="" WM_STUB_POST_CODE=200 \
  bash "$HOOK" __close_bg__ </dev/null
assert_eq    "gatesdown: reconcile still fired (server authoritative)" "$(count_event_sid reconciled "$sid")" "1"
assert_false "gatesdown: NO copy when gates unreachable (fail closed)" test -f "$(staged_file indigo prs_test "$sid")"
assert_false "gatesdown: copied marker ABSENT (stays pending for sweep)" test -f "$(copy_marker "$sid" indigo)"
if jq -e --arg s "$sid" 'select(.event=="copy-pending" and .sessionId==$s) | .reason=="gates_unreachable"' "$SPOOL" >/dev/null 2>&1; then
  pass "gatesdown: copy-pending reason gates_unreachable"
else
  failc "gatesdown: copy-pending reason not gates_unreachable"
fi

# ===========================================================================
echo "CASE 7: size budget -> skip-and-flag, never shipped"
# ===========================================================================
sid=sid-oversize; d7="$SANDBOX/stub-oversize"
register_session "$sid" indigo cmp_indigo
tp7="$(mk_transcript "$sid")"
WM_ROOT="$SANDBOX" WM_SID="$sid" WM_HINT="$tp7" WM_HARNESS=claude-code \
  HQ_WORK_MESH_TOKEN=tok HQ_WORK_MESH_PERSON_UID=prs_test \
  HQ_WORK_MESH_TRANSCRIPT_MAX_BYTES=10 \
  WM_STUB_DIR="$d7" WM_STUB_GATES="$GATES_ALL_TRUE" WM_STUB_POST_CODE=200 \
  bash "$HOOK" __close_bg__ </dev/null
assert_eq    "oversize: reconcile still fired" "$(count_event_sid reconciled "$sid")" "1"
assert_false "oversize: oversized transcript NEVER copied" test -f "$(staged_file indigo prs_test "$sid")"
if jq -e --arg s "$sid" 'select(.event=="copy-skipped" and .sessionId==$s) | .reason=="size_budget"' "$SPOOL" >/dev/null 2>&1; then
  pass "oversize: copy-skipped reason size_budget"
else
  failc "oversize: copy-skip reason not size_budget"
fi
body7="$(first_post_body "$d7")"
assert_eq "oversize: reconcile flagged transcriptSkipped" "$(printf '%s' "$body7" | jq -r 'has("transcriptSkipped")')" "true"

# ===========================================================================
echo "CASE 8: multi-company -> both reconciled crossCompany, no copy either"
# ===========================================================================
sid=sid-multi; d8="$SANDBOX/stub-multi"
register_session "$sid" alpha cmp_alpha
# add a second company registration for the SAME session
jq -nc --arg s "$sid" '{ts:"t",event:"attempt",sessionId:$s,companySlug:"beta",companyUid:"cmp_beta",harness:"claude-code"}' >> "$SPOOL"
printf 'company_slug: alpha\nproject: proj_demo\n' > "$SANDBOX/workspace/sessions/$sid/meta.yaml"
: > "$(reg_marker "$sid" beta)"
tp8="$(mk_transcript "$sid")"
WM_ROOT="$SANDBOX" WM_SID="$sid" WM_HINT="$tp8" WM_HARNESS=claude-code \
  HQ_WORK_MESH_TOKEN=tok HQ_WORK_MESH_PERSON_UID=prs_test \
  WM_STUB_DIR="$d8" WM_STUB_GATES="$GATES_ALL_TRUE" WM_STUB_POST_CODE=200 \
  bash "$HOOK" __close_bg__ </dev/null
assert_eq "multi: two reconcile POSTs (one per company)" "$(count_posts "$d8")" "2"
assert_eq "multi: two reconciled events" "$(count_event_sid reconciled "$sid")" "2"
assert_false "multi: no copy for alpha" test -f "$(staged_file alpha prs_test "$sid")"
assert_false "multi: no copy for beta"  test -f "$(staged_file beta  prs_test "$sid")"
if jq -e --arg s "$sid" 'select(.event=="reconciled" and .sessionId==$s) | has("crossCompany")' "$SPOOL" >/dev/null 2>&1; then
  pass "multi: reconciled events flagged crossCompany"
else
  failc "multi: reconciled events missing crossCompany flag"
fi
b8="$(first_post_body "$d8")"
assert_eq "multi: reconcile body flagged crossCompany" "$(printf '%s' "$b8" | jq -r 'has("crossCompany")')" "true"

# ===========================================================================
echo "CASE 9: non-Claude harness -> reconcile + transcriptUnavailable, no copy"
# ===========================================================================
sid=sid-codex; d9="$SANDBOX/stub-codex"
register_session "$sid" indigo cmp_indigo
# transcript exists on disk but harness is codex -> v1 skips the copy.
tp9="$(mk_transcript "$sid")"
WM_ROOT="$SANDBOX" WM_SID="$sid" WM_HINT="$tp9" WM_HARNESS=codex \
  HQ_WORK_MESH_TOKEN=tok HQ_WORK_MESH_PERSON_UID=prs_test \
  WM_STUB_DIR="$d9" WM_STUB_GATES="$GATES_ALL_TRUE" WM_STUB_POST_CODE=200 \
  bash "$HOOK" __close_bg__ </dev/null
assert_eq    "codex: reconcile fired" "$(count_event_sid reconciled "$sid")" "1"
assert_false "codex: NO copy for non-Claude harness" test -f "$(staged_file indigo prs_test "$sid")"
b9="$(first_post_body "$d9")"
assert_eq "codex: reconcile flagged transcriptUnavailable" "$(printf '%s' "$b9" | jq -r 'has("transcriptUnavailable")')" "true"
if jq -e --arg s "$sid" 'select(.event=="copy-skipped" and .sessionId==$s) | .reason=="transcript_unavailable"' "$SPOOL" >/dev/null 2>&1; then
  pass "codex: copy-skipped reason transcript_unavailable"
else
  failc "codex: copy-skip reason not transcript_unavailable"
fi

# ===========================================================================
echo "CASE 10: staging hygiene -> git check-ignore + .ignore cover the path"
# ===========================================================================
GITSB="$SANDBOX/gitsb"
mkdir -p "$GITSB"
cp "$SRC_GITIGNORE" "$GITSB/.gitignore"
( git -C "$GITSB" init -q && git -C "$GITSB" config user.email t@t && git -C "$GITSB" config user.name t ) >/dev/null 2>&1
mkdir -p "$GITSB/companies/indigo/sessions/prs_test"
printf 'x\n' > "$GITSB/companies/indigo/sessions/prs_test/sid-x.jsonl"
if git -C "$GITSB" check-ignore -q "companies/indigo/sessions/prs_test/sid-x.jsonl"; then
  pass "hygiene: .gitignore excludes companies/*/sessions/ from git"
else
  failc "hygiene: staging path is NOT gitignored"
fi
# The path must also be absent from a git add (untracked + ignored).
git -C "$GITSB" add -A >/dev/null 2>&1 || true
if git -C "$GITSB" ls-files --error-unmatch "companies/indigo/sessions/prs_test/sid-x.jsonl" >/dev/null 2>&1; then
  failc "hygiene: staged transcript entered git index"
else
  pass "hygiene: staged transcript never enters the git index"
fi
if [ -f "$SRC_IGNORE" ] && grep -q 'companies/\*/sessions/' "$SRC_IGNORE"; then
  pass "hygiene: .ignore excludes staging path from qmd/Grep"
else
  failc "hygiene: .ignore missing companies/*/sessions/"
fi

# ===========================================================================
echo "CASE 11: sweep late-reconcile -> inactive registered session backfilled"
# ===========================================================================
sid=sid-sweep; d11="$SANDBOX/stub-sweep"
register_session "$sid" indigo cmp_indigo
tp11="$(mk_transcript "$sid")"
# Make the transcript look OLD so the activity heuristic treats it inactive.
touch -t 202601010000 "$tp11" 2>/dev/null || true
printf '%s\n' "some-other-current-session" > "$SANDBOX/workspace/sessions/.current"
WM_ROOT="$SANDBOX" HQ_WORK_MESH_TOKEN=tok HQ_WORK_MESH_PERSON_UID=prs_test \
  HQ_WORK_MESH_ACTIVE_THRESHOLD_SEC=60 \
  WM_STUB_DIR="$d11" WM_STUB_GATES="$GATES_ALL_TRUE" WM_STUB_POST_CODE=200 \
  bash "$HOOK" __sweep_bg__ </dev/null
assert_eq   "sweep: inactive session reconciled by the sweep" "$(count_event_sid reconciled "$sid")" "1"
assert_true "sweep: reconciled marker written" test -f "$(recon_marker "$sid" indigo)"
assert_true "sweep: transcript copied by the sweep" test -f "$(staged_file indigo prs_test "$sid")"

# ===========================================================================
echo "CASE 12: sweep skips current + active sessions"
# ===========================================================================
# (a) current session is skipped
sid=sid-current; d12a="$SANDBOX/stub-cur"
register_session "$sid" indigo cmp_indigo
mk_transcript "$sid" >/dev/null
printf '%s\n' "$sid" > "$SANDBOX/workspace/sessions/.current"
WM_ROOT="$SANDBOX" HQ_WORK_MESH_TOKEN=tok HQ_WORK_MESH_PERSON_UID=prs_test \
  WM_STUB_DIR="$d12a" WM_STUB_GATES="$GATES_ALL_TRUE" WM_STUB_POST_CODE=200 \
  bash "$HOOK" __sweep_bg__ </dev/null
assert_eq "sweep-current: current session NOT reconciled" "$(count_event_sid reconciled "$sid")" "0"
assert_eq "sweep-current: no POST for the current session" "$(count_posts "$d12a")" "0"
# (b) fresh (recent-mtime) session is skipped as possibly-active
sid=sid-fresh; d12b="$SANDBOX/stub-fresh"
register_session "$sid" indigo cmp_indigo
tpf="$(mk_transcript "$sid")"; touch "$tpf" 2>/dev/null || true
printf '%s\n' "someone-else" > "$SANDBOX/workspace/sessions/.current"
WM_ROOT="$SANDBOX" HQ_WORK_MESH_TOKEN=tok HQ_WORK_MESH_PERSON_UID=prs_test \
  HQ_WORK_MESH_ACTIVE_THRESHOLD_SEC=100000 \
  WM_STUB_DIR="$d12b" WM_STUB_GATES="$GATES_ALL_TRUE" WM_STUB_POST_CODE=200 \
  bash "$HOOK" __sweep_bg__ </dev/null
assert_eq "sweep-fresh: fresh session left for its own close hook" "$(count_event_sid reconciled "$sid")" "0"

# ===========================================================================
echo "CASE 13: sweep claim race -> a held claim blocks a second sweep"
# ===========================================================================
sid=sid-claim; d13="$SANDBOX/stub-claim"
register_session "$sid" indigo cmp_indigo
tp13="$(mk_transcript "$sid")"; touch -t 202601010000 "$tp13" 2>/dev/null || true
printf '%s\n' "other" > "$SANDBOX/workspace/sessions/.current"
# Pre-hold the claim (as a concurrent sweep would): mkdir the claim dir.
claimdir="$SANDBOX/workspace/sessions/$sid/work-mesh-sweep-claim-indigo"
mkdir -p "$claimdir"
WM_ROOT="$SANDBOX" HQ_WORK_MESH_TOKEN=tok HQ_WORK_MESH_PERSON_UID=prs_test \
  HQ_WORK_MESH_ACTIVE_THRESHOLD_SEC=60 \
  WM_STUB_DIR="$d13" WM_STUB_GATES="$GATES_ALL_TRUE" WM_STUB_POST_CODE=200 \
  bash "$HOOK" __sweep_bg__ </dev/null
assert_eq "claim-race: held claim blocks the sweep (exactly-once)" "$(count_event_sid reconciled "$sid")" "0"
assert_eq "claim-race: no POST while claim held" "$(count_posts "$d13")" "0"

# ===========================================================================
echo "CASE 14: idempotent terminal -> reconciled+copied record is a no-op"
# ===========================================================================
sid=sid-idem; d14="$SANDBOX/stub-idem"
register_session "$sid" indigo cmp_indigo
tp14="$(mk_transcript "$sid")"; touch -t 202601010000 "$tp14" 2>/dev/null || true
: > "$(recon_marker "$sid" indigo)"
: > "$(copy_marker "$sid" indigo)"
printf '%s\n' "other" > "$SANDBOX/workspace/sessions/.current"
WM_ROOT="$SANDBOX" HQ_WORK_MESH_TOKEN=tok HQ_WORK_MESH_PERSON_UID=prs_test \
  HQ_WORK_MESH_ACTIVE_THRESHOLD_SEC=60 \
  WM_STUB_DIR="$d14" WM_STUB_GATES="$GATES_ALL_TRUE" WM_STUB_POST_CODE=200 \
  bash "$HOOK" __sweep_bg__ </dev/null
assert_eq "idempotent: terminal record produced no reconcile POST" "$(count_posts "$d14")" "0"
assert_eq "idempotent: no new reconciled event" "$(count_event_sid reconciled "$sid")" "0"

# ===========================================================================
echo "CASE 15: foreground latency -> close fg returns fast under a slow curl"
# ===========================================================================
sid=sid-fg; d15="$SANDBOX/stub-fg"
register_session "$sid" indigo cmp_indigo
tp15="$(mk_transcript "$sid")"
input="$(jq -nc --arg s "$sid" --arg t "$tp15" '{session_id:$s, transcript_path:$t, cwd:""}')"
t0="$(perl -MTime::HiRes=time -e 'printf "%d", time()*1000' 2>/dev/null || echo $(( $(date +%s) * 1000 )))"
out="$(printf '%s' "$input" | WM_STUB_DIR="$d15" WM_STUB_GATES="$GATES_ALL_TRUE" \
        HQ_WORK_MESH_TOKEN=tok HQ_WORK_MESH_PERSON_UID=prs_test WM_STUB_SLEEP=3 \
        bash "$HOOK" close)"
t1="$(perl -MTime::HiRes=time -e 'printf "%d", time()*1000' 2>/dev/null || echo $(( $(date +%s) * 1000 )))"
elapsed=$((t1 - t0))
echo "  (close foreground elapsed: ${elapsed}ms with a 3s stub curl)"
if [ "$elapsed" -lt 2000 ]; then pass "fg-latency: close foreground returned <2s despite 3s background curl"; else failc "fg-latency: foreground blocked (${elapsed}ms)"; fi
assert_eq "fg-latency: foreground stays silent" "$out" ""
assert_eq "fg-latency: close-attempt spooled before the network" "$(count_event_sid close-attempt "$sid")" "1"

# ===========================================================================
echo "CASE 16: token hygiene -> token never in log or spool"
# ===========================================================================
sid=sid-tok; d16="$SANDBOX/stub-tok"
TOKENVAL='SECRET-CLOSE-TOKEN-DO-NOT-LEAK-xyz789'
register_session "$sid" indigo cmp_indigo
tp16="$(mk_transcript "$sid")"
WM_ROOT="$SANDBOX" WM_SID="$sid" WM_HINT="$tp16" WM_HARNESS=claude-code \
  HQ_WORK_MESH_TOKEN="$TOKENVAL" HQ_WORK_MESH_PERSON_UID=prs_test \
  WM_STUB_DIR="$d16" WM_STUB_GATES="$GATES_ALL_TRUE" WM_STUB_POST_CODE=200 \
  bash "$HOOK" __close_bg__ </dev/null
if grep -qF "$TOKENVAL" "$LOG" 2>/dev/null; then failc "token hygiene: token leaked into log"; else pass "token hygiene: token absent from log"; fi
if grep -qF "$TOKENVAL" "$SPOOL" 2>/dev/null; then failc "token hygiene: token leaked into spool"; else pass "token hygiene: token absent from spool"; fi
if [ -f "$d16/argv.txt" ] && grep -qF "$TOKENVAL" "$d16/argv.txt"; then failc "token hygiene: token leaked into curl argv (visible in process table)"; else pass "token hygiene: token absent from curl argv"; fi
if [ -f "$d16/stdin-headers.txt" ] && grep -qF "$TOKENVAL" "$d16/stdin-headers.txt"; then pass "token hygiene: token delivered via stdin header (auth intact)"; else failc "token hygiene: Authorization header not delivered via stdin"; fi

# ===========================================================================
echo "CASE 17: sweep stale-claim reclaim -> a crash-orphaned claim is reclaimed"
# ===========================================================================
# AC6 crash-proofness: a sweep killed BETWEEN claiming and releasing leaves a
# claim dir behind. Because the sweep is the ONLY recovery path for a session
# killed-without-close, an un-reclaimable claim would wedge that (sid,slug)
# forever. A STALE claim (dir mtime past the staleness threshold) must be
# reclaimed and the record late-reconciled + copied.
sid=sid-staleclaim; d17="$SANDBOX/stub-staleclaim"
register_session "$sid" indigo cmp_indigo
tp17="$(mk_transcript "$sid")"; touch -t 202601010000 "$tp17" 2>/dev/null || true
printf '%s\n' "other" > "$SANDBOX/workspace/sessions/.current"
# Plant a claim as a killed sweep would, then back-date it well past staleness.
claimdir17="$SANDBOX/workspace/sessions/$sid/work-mesh-sweep-claim-indigo"
mkdir -p "$claimdir17"
touch -t 202601010000 "$claimdir17" 2>/dev/null || true
WM_ROOT="$SANDBOX" HQ_WORK_MESH_TOKEN=tok HQ_WORK_MESH_PERSON_UID=prs_test \
  HQ_WORK_MESH_ACTIVE_THRESHOLD_SEC=60 HQ_WORK_MESH_CLAIM_STALE_SEC=60 \
  WM_STUB_DIR="$d17" WM_STUB_GATES="$GATES_ALL_TRUE" WM_STUB_POST_CODE=200 \
  bash "$HOOK" __sweep_bg__ </dev/null
assert_eq   "stale-claim: reclaimed + reconciled exactly once" "$(count_event_sid reconciled "$sid")" "1"
assert_true "stale-claim: transcript copied after reclaim" test -f "$(staged_file indigo prs_test "$sid")"
assert_false "stale-claim: claim dir released (rmdir'd after the work)" test -d "$claimdir17"
# A FRESH claim (default staleness) must still block — no premature reclaim.
sid=sid-freshclaim; d17b="$SANDBOX/stub-freshclaim"
register_session "$sid" indigo cmp_indigo
tp17b="$(mk_transcript "$sid")"; touch -t 202601010000 "$tp17b" 2>/dev/null || true
printf '%s\n' "other" > "$SANDBOX/workspace/sessions/.current"
mkdir -p "$SANDBOX/workspace/sessions/$sid/work-mesh-sweep-claim-indigo"
WM_ROOT="$SANDBOX" HQ_WORK_MESH_TOKEN=tok HQ_WORK_MESH_PERSON_UID=prs_test \
  HQ_WORK_MESH_ACTIVE_THRESHOLD_SEC=60 \
  WM_STUB_DIR="$d17b" WM_STUB_GATES="$GATES_ALL_TRUE" WM_STUB_POST_CODE=200 \
  bash "$HOOK" __sweep_bg__ </dev/null
assert_eq "stale-claim: a FRESH claim still blocks (no premature reclaim)" "$(count_event_sid reconciled "$sid")" "0"

# ===========================================================================
echo "CASE 18: outcome file paths are relativized to HQ root (no username/abs)"
# ===========================================================================
# The reconcile outcome posts .outcome.files.paths under the registry consent
# tier (NOT the stricter transcript double-consent), so absolute local paths
# would leak the local username + machine layout on the lower tier. Paths under
# the HQ root must be emitted repo-relative (companies/<slug>/…) — no absolute
# home/HQ-root prefix.
sid=sid-relpath; d18="$SANDBOX/stub-relpath"
register_session "$sid" indigo cmp_indigo
tp18="$PROJDIR/$sid.jsonl"
{
  jq -nc --arg fp "$SANDBOX/companies/indigo/knowledge/x.md" \
    '{type:"assistant",timestamp:"2026-07-11T10:00:00Z",message:{role:"assistant",model:"claude-opus-4-8",content:[{type:"tool_use",name:"Edit",input:{file_path:$fp}}]}}'
  jq -nc --arg fp "$SANDBOX/repos/private/foo/bar.ts" \
    '{type:"assistant",timestamp:"2026-07-11T10:05:00Z",message:{role:"assistant",content:[{type:"tool_use",name:"Write",input:{file_path:$fp}}]}}'
} > "$tp18"
WM_ROOT="$SANDBOX" WM_SID="$sid" WM_HINT="$tp18" WM_HARNESS=claude-code \
  HQ_WORK_MESH_TOKEN=tok HQ_WORK_MESH_PERSON_UID=prs_test \
  WM_STUB_DIR="$d18" WM_STUB_GATES="$GATES_ALL_TRUE" WM_STUB_POST_CODE=200 \
  bash "$HOOK" __close_bg__ </dev/null
body18="$(first_post_body "$d18")"
assert_eq "relpath: reconcile fired" "$(count_posts "$d18")" "1"
assert_eq "relpath: totalCount=2 preserved" "$(printf '%s' "$body18" | jq -r '.outcome.files.totalCount')" "2"
assert_eq "relpath: emitted paths are repo-relative to HQ root" \
  "$(printf '%s' "$body18" | jq -rc '.outcome.files.paths')" \
  '["companies/indigo/knowledge/x.md","repos/private/foo/bar.ts"]'
# Nothing under outcome.files.paths may retain an absolute (/…) or username prefix.
if printf '%s' "$body18" | jq -e '.outcome.files.paths[] | select(startswith("/"))' >/dev/null 2>&1; then
  failc "relpath: an absolute path leaked into outcome.files.paths"
else
  pass "relpath: no absolute/username-bearing path in outcome.files.paths"
fi

# Cross-company session (multi) must STILL post empty paths (unchanged behavior).
sid=sid-relpath-multi; d18b="$SANDBOX/stub-relpath-multi"
register_session "$sid" indigo cmp_indigo
register_session "$sid" levelfit cmp_levelfit
tp18b="$PROJDIR/$sid.jsonl"
jq -nc --arg fp "$SANDBOX/companies/indigo/knowledge/y.md" \
  '{type:"assistant",timestamp:"2026-07-11T10:00:00Z",message:{role:"assistant",model:"claude-opus-4-8",content:[{type:"tool_use",name:"Edit",input:{file_path:$fp}}]}}' > "$tp18b"
WM_ROOT="$SANDBOX" WM_SID="$sid" WM_HINT="$tp18b" WM_HARNESS=claude-code \
  HQ_WORK_MESH_TOKEN=tok HQ_WORK_MESH_PERSON_UID=prs_test \
  WM_STUB_DIR="$d18b" WM_STUB_GATES="$GATES_ALL_TRUE" WM_STUB_POST_CODE=200 \
  bash "$HOOK" __close_bg__ </dev/null
if [ -f "$d18b/post-bodies.jsonl" ]; then
  allempty=true
  while IFS= read -r ln; do
    [ "$(printf '%s' "$ln" | jq -rc '.outcome.files.paths')" = "[]" ] || allempty=false
  done < "$d18b/post-bodies.jsonl"
  if [ "$allempty" = true ]; then
    pass "relpath: cross-company reconciles still post empty paths"
  else
    failc "relpath: cross-company reconcile leaked non-empty paths"
  fi
else
  failc "relpath: cross-company produced no reconcile POST"
fi

# ===========================================================================
echo "CASE 19: transcript staging rejects path-traversal identifiers"
# ===========================================================================
tp19="$PROJDIR/sid-path-safe.jsonl"
printf '%s\n' '{"type":"assistant","message":{"content":"safe"}}' > "$tp19"
outside19="$SANDBOX/../work-mesh-path-escape-$$"
rm -rf "$outside19"
if WM_ROOT="$SANDBOX" bash -c '. "$1"; wm_copy_transcript "$2" prs_test sid-safe "$3"' \
  _ "$SRC_LIB" "../../$(basename "$outside19")" "$tp19" >/dev/null 2>&1; then
  failc "path-safety: traversal company slug was accepted"
else
  pass "path-safety: traversal company slug rejected"
fi
if WM_ROOT="$SANDBOX" bash -c '. "$1"; wm_copy_transcript indigo "$2" sid-safe "$3"' \
  _ "$SRC_LIB" '../prs_escape' "$tp19" >/dev/null 2>&1; then
  failc "path-safety: traversal person uid was accepted"
else
  pass "path-safety: traversal person uid rejected"
fi
if WM_ROOT="$SANDBOX" bash -c '. "$1"; wm_copy_transcript indigo prs_test "$2" "$3"' \
  _ "$SRC_LIB" '../sid-escape' "$tp19" >/dev/null 2>&1; then
  failc "path-safety: traversal session id was accepted"
else
  pass "path-safety: traversal session id rejected"
fi
assert_false "path-safety: no directory was created outside the staging tree" test -e "$outside19"

outside19link="$SANDBOX/../work-mesh-symlink-escape-$$"
mkdir -p "$outside19link" "$SANDBOX/companies/evilco/sessions"
ln -s "$outside19link" "$SANDBOX/companies/evilco/sessions/prs_test"
if WM_ROOT="$SANDBOX" bash -c '. "$1"; wm_copy_transcript evilco prs_test sid-safe "$2"' \
  _ "$SRC_LIB" "$tp19" >/dev/null 2>&1; then
  failc "path-safety: symlinked staging directory was accepted"
else
  pass "path-safety: symlinked staging directory rejected"
fi
assert_false "path-safety: symlink escape received no transcript" test -e "$outside19link/sid-safe.jsonl"

# ===========================================================================
echo "CASE 20: transcript discovery cannot select arbitrary files or symlinks"
# ===========================================================================
sid=sid-source-safe
valid20="$PROJDIR/$sid.jsonl"
printf '%s\n' '{"type":"assistant","message":{"content":"valid"}}' > "$valid20"
found20="$(WM_ROOT="$SANDBOX" HQ_WORK_MESH_CLAUDE_PROJECTS_DIR="$HQ_WORK_MESH_CLAUDE_PROJECTS_DIR" \
  bash -c '. "$1"; wm_find_transcript "$2" "$3"' _ "$SRC_LIB" "$sid" "$valid20")"
assert_eq "source-safety: valid canonical transcript is accepted" "$found20" "$valid20"

outside20="$SANDBOX/$sid.jsonl"
printf '%s\n' '{"secret":"outside approved transcript tree"}' > "$outside20"
found20="$(WM_ROOT="$SANDBOX" HQ_WORK_MESH_CLAUDE_PROJECTS_DIR="$HQ_WORK_MESH_CLAUDE_PROJECTS_DIR" \
  bash -c '. "$1"; wm_find_transcript "$2" "$3"' _ "$SRC_LIB" "$sid" "$outside20")"
assert_eq "source-safety: outside hint is ignored in favor of canonical transcript" "$found20" "$valid20"

sid=sid-source-link
outside20="$SANDBOX/$sid.jsonl"
printf '%s\n' '{"secret":"symlink target"}' > "$outside20"
ln -s "$outside20" "$PROJDIR/$sid.jsonl"
found20="$(WM_ROOT="$SANDBOX" HQ_WORK_MESH_CLAUDE_PROJECTS_DIR="$HQ_WORK_MESH_CLAUDE_PROJECTS_DIR" \
  bash -c '. "$1"; wm_find_transcript "$2" "$3"' _ "$SRC_LIB" "$sid" "$PROJDIR/$sid.jsonl")"
assert_eq "source-safety: symlinked transcript is rejected" "$found20" ""

# ===========================================================================
echo "CASE 21: file mtime probe rejects GNU stat text before numeric fallback"
# ===========================================================================
mkdir -p "$SANDBOX/statbin"
cat > "$SANDBOX/statbin/stat" <<'STAT_STUB'
#!/usr/bin/env bash
if [ "${1:-}" = "-f" ]; then
  printf '%s\n' 'File: synthetic GNU filesystem output'
  exit 0
fi
if [ "${1:-}" = "-c" ]; then
  printf '%s\n' '1234567890'
  exit 0
fi
exit 1
STAT_STUB
chmod +x "$SANDBOX/statbin/stat"
mtime21="$(PATH="$SANDBOX/statbin:$PATH" WM_ROOT="$SANDBOX" \
  bash -c '. "$1"; wm_file_mtime "$2"' _ "$SRC_LIB" "$valid20")"
assert_eq "mtime: GNU filesystem text falls through to numeric -c result" "$mtime21" "1234567890"

# ===========================================================================
echo ""
echo "----------------------------------------------------------------------"
echo "work-mesh-close acceptance: ${PASS} passed, ${FAIL} failed"
if [ "$FAIL" -ne 0 ]; then
  echo "FAIL: work-mesh-close.test.sh" >&2
  exit 1
fi
echo "PASS: work-mesh-close.test.sh"
exit 0
