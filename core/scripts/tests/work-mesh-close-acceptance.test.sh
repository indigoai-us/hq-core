#!/usr/bin/env bash
# hq-core: public
# US-004 e2eTests acceptance suite — close-time reconciliation hook + vetted
# transcript handoff + SessionStart sweep
# (core/hooks/work-mesh-close.sh + core/scripts/work-mesh-lib.sh + the shipped
# .gitignore/.ignore hygiene rules).
#
# One clearly-labeled case per PRD US-004 e2eTests entry (6 total). Each case is
# realized as a HERMETIC proxy of the live-mesh path (live-mesh E2E is deferred
# until server deploy — rollout invariant: hooks land last), but it exercises the
# REAL hook / sweep / redaction code end-to-end inside an mktemp sandbox with only
# curl/network stubbed. Assertions target BEHAVIOR — reconcile POST bodies
# captured by the stub, spool JSONL events, the redacted staged copy under
# companies/<slug>/sessions/<personUid>/, terminal marker files, and git
# check-ignore exit codes — never internal implementation details.
#
# e2eTests -> cases:
#   1  registered session, /handoff runs  -> reconciled outcome + staged copy
#   2  session killed w/o close, next start-> sweep late-reconciles + copies
#   3  killed MID-REDACTION, next start    -> sweep converges to exactly one
#                                             vetted copy; no unredacted bytes
#                                             (chaos: leftover temp + 2 sweeps,
#                                              sequential AND concurrent)
#   4  session bound TWO companies, close  -> no copy; records flagged crossCompany
#   5  transcript w/ a seeded fake secret  -> copy has the redaction marker, not
#                                             the secret; count logged, never leaked
#   6  staging path companies/*/sessions/  -> git check-ignore reports it ignored;
#                                             git add -A never stages it; .ignore
#                                             excludes it from qmd/Grep
#
# SECURITY: the seeded fake secret (an obviously-fake AKIA...FAKE... string that
# matches the redaction catalog) must NEVER appear in any file under the sandbox
# companies/ tree, the spool, the hook log, or a captured reconcile POST body —
# asserted in every case that produces a transcript copy.
#
# Hermetic: curl stubbed on PATH (no network); HOME + ~/.claude/projects + HQ
# root all inside an mktemp sandbox; token/person supplied via env seams; no real
# ~/.hq. bash-3.2 (macOS) + CI (ubuntu-latest) compatible: no mapfile, no
# associative arrays, no ${var,,}. Always fail-soft in the code under test; this
# harness itself continues-on-failure and reports a final tally.

set -euo pipefail

# ---------------------------------------------------------------------------
# Locate sources under test (this file lives in core/scripts/tests/).
# ---------------------------------------------------------------------------
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SRC_HOOK="$REPO_ROOT/core/hooks/work-mesh-close.sh"
SRC_LIB="$REPO_ROOT/core/scripts/work-mesh-lib.sh"
SRC_GITIGNORE="$REPO_ROOT/.gitignore"
SRC_IGNORE="$REPO_ROOT/.ignore"

for f in "$SRC_HOOK" "$SRC_LIB"; do
  [ -f "$f" ] || { echo "FATAL: missing source under test: $f" >&2; exit 1; }
done
command -v jq >/dev/null 2>&1 || { echo "FATAL: jq is required for these tests" >&2; exit 1; }

# ---------------------------------------------------------------------------
# HQ-shaped sandbox + cleanup trap. Detached bg close/sweep jobs (CASES 1,2,3)
# may still be writing into the sandbox at teardown; reap by retrying rm.
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# curl stub — installed FIRST on PATH so nothing touches the network. Captures
# POST bodies out-of-band; serves canned GET bodies (gates/membership); can
# simulate latency (WM_STUB_SLEEP) and transport failure (WM_STUB_FAIL).
# ---------------------------------------------------------------------------
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

# The one seeded fake secret used across the suite. Obviously fake (contains
# FAKE) and matches the redaction catalog's AKIA[0-9A-Z]{16} rule -> redacts to
# <REDACTED:aws_key>. Per policy, seeded secrets in tests must be obviously fake.
FAKE_SECRET='AKIAFAKE1234567890AB'
REDACT_MARK='<REDACTED:aws_key>'

# ---------------------------------------------------------------------------
# Assertions (PASS/FAIL counters; continue-on-failure so one bad case can't hide
# the rest). Every fallible check is guarded so `set -e` never fires early.
# ---------------------------------------------------------------------------
PASS=0; FAIL=0
pass()  { PASS=$((PASS + 1)); echo "  ok:   $1"; }
failc() { FAIL=$((FAIL + 1)); echo "  FAIL: $1" >&2; }
assert_eq()    { if [ "$2" = "$3" ]; then pass "$1"; else failc "$1 (expected '$3', got '$2')"; fi; }
assert_true()  { local l="$1"; shift; if "$@"; then pass "$l"; else failc "$l"; fi; }
assert_false() { local l="$1"; shift; if "$@"; then failc "$l (expected failure)"; else pass "$l"; fi; }
assert_contains() { case "$2" in *"$3"*) pass "$1" ;; *) failc "$1 (missing '$3')" ;; esac; }

count_event_sid() {  # <event> <sid>
  local ev="$1" sid="$2" n
  [ -f "$SPOOL" ] || { printf '0'; return 0; }
  n="$(jq -c --arg e "$ev" --arg s "$sid" 'select(.event==$e and .sessionId==$s)' "$SPOOL" 2>/dev/null | wc -l | tr -d '[:space:]')" || n=0
  printf '%s' "${n:-0}"
}
count_posts()     { local d="$1"; if [ -f "$d/post-bodies.jsonl" ]; then wc -l < "$d/post-bodies.jsonl" | tr -d '[:space:]'; else printf '0'; fi; }
first_post_body() { local d="$1"; [ -f "$d/post-bodies.jsonl" ] || return 1; head -n1 "$d/post-bodies.jsonl"; }
reg_marker()   { printf '%s/workspace/sessions/%s/work-mesh-registered-%s' "$SANDBOX" "$1" "$2"; }
recon_marker() { printf '%s/workspace/sessions/%s/work-mesh-reconciled-%s' "$SANDBOX" "$1" "$2"; }
copy_marker()  { printf '%s/workspace/sessions/%s/work-mesh-copied-%s' "$SANDBOX" "$1" "$2"; }
staged_file()  { printf '%s/companies/%s/sessions/%s/%s.jsonl' "$SANDBOX" "$1" "$2" "$3"; }

# Poll (bounded, 5s @ 0.1s) for a spool event line for a given session id.
poll_event_sid() {
  local ev="$1" sid="$2" i=0
  while [ "$i" -lt 50 ]; do
    [ "$(count_event_sid "$ev" "$sid")" != "0" ] && return 0
    sleep 0.1; i=$((i + 1))
  done
  return 1
}

# assert_no_secret_leak <label> [stub_dir] — the seeded fake secret must be
# absent from EVERY sink the copy touches: the whole companies/ staging tree, the
# spool, the hook log, and (if given) the captured reconcile POST bodies.
assert_no_secret_leak() {
  local label="$1" stub="${2:-}" hit=0
  if [ -d "$SANDBOX/companies" ] && grep -rqF "$FAKE_SECRET" "$SANDBOX/companies" 2>/dev/null; then hit=1; fi
  if [ -f "$SPOOL" ] && grep -qF "$FAKE_SECRET" "$SPOOL" 2>/dev/null; then hit=1; fi
  if [ -f "$LOG" ]   && grep -qF "$FAKE_SECRET" "$LOG"   2>/dev/null; then hit=1; fi
  if [ -n "$stub" ] && [ -d "$stub" ] && grep -rqF "$FAKE_SECRET" "$stub" 2>/dev/null; then hit=1; fi
  if [ "$hit" -eq 0 ]; then pass "$label"; else failc "$label (secret leaked)"; fi
}

# Fabricate a US-003 registration for a session (marker + 'attempt' spool line +
# meta.yaml) — the structural work-record the close/sweep gate requires.
register_session() {  # <sid> <slug> [uid]
  local sid="$1" slug="$2" uid="${3:-cmp_$2}" sd
  sd="$SANDBOX/workspace/sessions/$sid"
  mkdir -p "$sd"
  printf 'company_slug: %s\nproject: proj_demo\n' "$slug" > "$sd/meta.yaml"
  : > "$(reg_marker "$sid" "$slug")"
  jq -nc --arg s "$sid" --arg c "$slug" --arg u "$uid" \
    '{ts:"t",event:"attempt",sessionId:$s,companySlug:$c,companyUid:$u,harness:"claude-code"}' >> "$SPOOL"
}
# Write a valid JSONL transcript for a session; optional 2nd arg injects a secret
# into a tool_result (as a real transcript would carry it). Two Write/Edit
# tool_use lines -> files.totalCount=2; timestamps 5-6min apart -> durationMs>0.
mk_transcript() {  # <sid> [secret]  (prints the path)
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
echo "CASE 1 (e2e#1): registered session, /handoff runs -> reconciled outcome + staged copy"
# ===========================================================================
# Proxy of handoff-post.sh step 3b, which fires the close hook detached with NO
# hook stdin: `bash work-mesh-close.sh close`. The session is resolved from
# workspace/sessions/.current (the handoff path has no SessionEnd JSON). A fake
# secret is seeded to double as a security check.
sid=acc-handoff; d1="$SANDBOX/stub-handoff"
register_session "$sid" indigo cmp_indigo
mk_transcript "$sid" "$FAKE_SECRET" >/dev/null
printf '%s\n' "$sid" > "$SANDBOX/workspace/sessions/.current"
WM_STUB_DIR="$d1" WM_STUB_GATES="$GATES_ALL_TRUE" WM_STUB_POST_CODE=200 \
  HQ_WORK_MESH_TOKEN=tok HQ_WORK_MESH_PERSON_UID=prs_test \
  bash "$HOOK" close </dev/null
# The detached bg reconciles then copies; 'copied' is the terminal event.
if poll_event_sid copied "$sid"; then
  pass "handoff: detached close reconciled + copied within bounded wait"
else
  failc "handoff: close never converged (no 'copied' event)"
fi
staged1="$(staged_file indigo prs_test "$sid")"
assert_true "handoff: transcript exists under companies/<co>/sessions/<personUid>/" test -f "$staged1"
assert_eq   "handoff: work record shows exactly one reconciled outcome" "$(count_event_sid reconciled "$sid")" "1"
assert_true "handoff: reconciled marker written" test -f "$(recon_marker "$sid" indigo)"
assert_true "handoff: copied marker written" test -f "$(copy_marker "$sid" indigo)"
purl1="$(cut -f1 "$d1/post-log.txt" 2>/dev/null | head -n1 || true)"
assert_contains "handoff: POST hit the reconcile endpoint" "$purl1" "/v1/work-mesh/work-sessions/reconcile"
body1="$(first_post_body "$d1" || true)"
assert_eq "handoff: reconcile body.companyUid" "$(printf '%s' "$body1" | jq -r '.companyUid')" "cmp_indigo"
assert_eq "handoff: outcome.sessionId matches" "$(printf '%s' "$body1" | jq -r '.outcome.sessionId')" "$sid"
assert_eq "handoff: outcome.files.totalCount=2 (created/updated files)" "$(printf '%s' "$body1" | jq -r '.outcome.files.totalCount')" "2"
assert_eq "handoff: outcome captured the model" "$(printf '%s' "$body1" | jq -r '.outcome.models | index("claude-opus-4-8") != null')" "true"
dm1="$(printf '%s' "$body1" | jq -r '.outcome.durationMs')"
if [ -n "$dm1" ] && [ "$dm1" -gt 0 ] 2>/dev/null; then pass "handoff: outcome.durationMs>0"; else failc "handoff: outcome.durationMs not positive ($dm1)"; fi
# Security: the seeded secret is redacted in the copy and never leaks anywhere.
if [ -f "$staged1" ] && grep -qF "$FAKE_SECRET" "$staged1"; then failc "handoff: SECRET leaked into the copy"; else pass "handoff: secret absent from the staged copy"; fi
if [ -f "$staged1" ] && grep -qF "$REDACT_MARK" "$staged1"; then pass "handoff: staged copy carries the redaction marker"; else failc "handoff: no redaction marker in the copy"; fi
assert_no_secret_leak "handoff: secret never under companies/, spool, log, or POST body" "$d1"

# ===========================================================================
echo "CASE 2 (e2e#2): session killed w/o close, next start -> sweep late-reconciles + copies"
# ===========================================================================
# Proxy of the SessionStart sweep leaf (36-work-mesh-sweep.sh execs
# `work-mesh-close.sh sweep`). The killed session registered but never closed
# (no reconciled/copied markers); its transcript persists on disk with an OLD
# mtime so the sweep treats it as inactive; .current points at the NEW session.
sid=acc-killed; d2="$SANDBOX/stub-killed"
register_session "$sid" indigo cmp_indigo
tp2="$(mk_transcript "$sid" "$FAKE_SECRET")"
touch -t 202601010000 "$tp2" 2>/dev/null || true
printf '%s\n' "acc-next-session" > "$SANDBOX/workspace/sessions/.current"
WM_STUB_DIR="$d2" WM_STUB_GATES="$GATES_ALL_TRUE" WM_STUB_POST_CODE=200 \
  HQ_WORK_MESH_TOKEN=tok HQ_WORK_MESH_PERSON_UID=prs_test \
  HQ_WORK_MESH_ACTIVE_THRESHOLD_SEC=60 \
  bash "$HOOK" sweep </dev/null
if poll_event_sid copied "$sid"; then
  pass "sweep: killed session late-reconciled + copied by the next session's sweep"
else
  failc "sweep: killed session never converged (no 'copied' event)"
fi
assert_eq   "sweep: work record shows exactly one reconciled outcome" "$(count_event_sid reconciled "$sid")" "1"
assert_true "sweep: reconciled marker written" test -f "$(recon_marker "$sid" indigo)"
staged2="$(staged_file indigo prs_test "$sid")"
assert_true "sweep: transcript copied under companies/<co>/sessions/<personUid>/" test -f "$staged2"
assert_eq   "sweep: exactly one reconcile POST" "$(count_posts "$d2")" "1"
if [ -f "$staged2" ] && grep -qF "$FAKE_SECRET" "$staged2"; then failc "sweep: SECRET leaked into the copy"; else pass "sweep: secret absent from the staged copy"; fi
assert_no_secret_leak "sweep: secret never under companies/, spool, log, or POST body" "$d2"

# ===========================================================================
echo "CASE 3 (e2e#3): killed MID-REDACTION, next start -> converges to exactly one vetted copy (chaos)"
# ===========================================================================
# A close-bg killed mid-redaction leaves a `.<sid>.jsonl.redacting.<pid>` temp in
# the staging dir. The redaction is a STREAMING sed, so a real interrupted temp
# only ever holds redacted/truncated bytes — never the raw secret; we plant
# exactly such a benign partial temp. Then two sweeps (first sequential to prove
# idempotent convergence, then concurrent to prove the atomic claim serializes
# real races) must yield exactly ONE vetted copy with NO unredacted bytes
# anywhere under companies/.

# --- Part A: sequential — first sweep converges, second sweep is a no-op ---
sid=acc-chaos-a; d3a="$SANDBOX/stub-chaos-a"
register_session "$sid" indigo cmp_indigo
tp3a="$(mk_transcript "$sid" "$FAKE_SECRET")"
touch -t 202601010000 "$tp3a" 2>/dev/null || true
printf '%s\n' "acc-chaos-next-a" > "$SANDBOX/workspace/sessions/.current"
chaos_dir="$SANDBOX/companies/indigo/sessions/prs_test"
mkdir -p "$chaos_dir"
printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Edit","input":{"file_path":"/repo/partial.ts"}}]}}' \
  > "$chaos_dir/.$sid.jsonl.redacting.90001"
for _n in 1 2; do
  WM_ROOT="$SANDBOX" HQ_WORK_MESH_TOKEN=tok HQ_WORK_MESH_PERSON_UID=prs_test \
    HQ_WORK_MESH_ACTIVE_THRESHOLD_SEC=60 \
    WM_STUB_DIR="$d3a" WM_STUB_GATES="$GATES_ALL_TRUE" WM_STUB_POST_CODE=200 \
    bash "$HOOK" __sweep_bg__ </dev/null
done
staged3a="$(staged_file indigo prs_test "$sid")"
assert_true "chaos-seq: exactly one vetted copy at the deterministic dst" test -f "$staged3a"
assert_eq   "chaos-seq: exactly one reconcile POST across two sweeps (idempotent)" "$(count_posts "$d3a")" "1"
assert_eq   "chaos-seq: exactly one copied event" "$(count_event_sid copied "$sid")" "1"
assert_eq   "chaos-seq: exactly one reconciled event" "$(count_event_sid reconciled "$sid")" "1"
if [ -f "$staged3a" ] && grep -qF "$REDACT_MARK" "$staged3a"; then pass "chaos-seq: final copy carries the redaction marker"; else failc "chaos-seq: final copy missing the redaction marker"; fi
if grep -rqF "$FAKE_SECRET" "$SANDBOX/companies" 2>/dev/null; then failc "chaos-seq: unredacted secret bytes found under companies/"; else pass "chaos-seq: no unredacted secret bytes anywhere under companies/"; fi

# --- Part B: concurrent — two real sweeps race; the atomic claim yields one copy ---
sid=acc-chaos-b; d3b="$SANDBOX/stub-chaos-b"
register_session "$sid" indigo cmp_indigo
tp3b="$(mk_transcript "$sid" "$FAKE_SECRET")"
touch -t 202601010000 "$tp3b" 2>/dev/null || true
printf '%s\n' "acc-chaos-next-b" > "$SANDBOX/workspace/sessions/.current"
mkdir -p "$chaos_dir"
printf '%s\n' '{"type":"assistant","message":{"content":[]}}' > "$chaos_dir/.$sid.jsonl.redacting.90002"
WM_ROOT="$SANDBOX" HQ_WORK_MESH_TOKEN=tok HQ_WORK_MESH_PERSON_UID=prs_test \
  HQ_WORK_MESH_ACTIVE_THRESHOLD_SEC=60 \
  WM_STUB_DIR="$d3b" WM_STUB_GATES="$GATES_ALL_TRUE" WM_STUB_POST_CODE=200 \
  bash "$HOOK" __sweep_bg__ </dev/null &
WM_ROOT="$SANDBOX" HQ_WORK_MESH_TOKEN=tok HQ_WORK_MESH_PERSON_UID=prs_test \
  HQ_WORK_MESH_ACTIVE_THRESHOLD_SEC=60 \
  WM_STUB_DIR="$d3b" WM_STUB_GATES="$GATES_ALL_TRUE" WM_STUB_POST_CODE=200 \
  bash "$HOOK" __sweep_bg__ </dev/null &
wait || true
# Assert the CONVERGED final state (race-robust): a narrow interleaving can let
# both sweeps reconcile, but they can only ever land the SAME single dst file.
staged3b="$(staged_file indigo prs_test "$sid")"
assert_true "chaos-concurrent: exactly one vetted copy at the deterministic dst" test -f "$staged3b"
assert_true "chaos-concurrent: reconciled marker written" test -f "$(recon_marker "$sid" indigo)"
if [ -f "$staged3b" ] && grep -qF "$REDACT_MARK" "$staged3b"; then pass "chaos-concurrent: final copy carries the redaction marker"; else failc "chaos-concurrent: final copy missing the redaction marker"; fi
if grep -rqF "$FAKE_SECRET" "$SANDBOX/companies" 2>/dev/null; then failc "chaos-concurrent: unredacted secret bytes found under companies/"; else pass "chaos-concurrent: no unredacted secret bytes anywhere under companies/"; fi
assert_no_secret_leak "chaos: secret never in spool, log, or POST bodies" "$d3b"

# ===========================================================================
echo "CASE 4 (e2e#4): session bound TWO companies, close -> no copy; records flagged crossCompany"
# ===========================================================================
sid=acc-multi; d4="$SANDBOX/stub-multi"
register_session "$sid" alpha cmp_alpha
# Second company bind for the SAME session (a distinct 'attempt' line + marker).
jq -nc --arg s "$sid" '{ts:"t",event:"attempt",sessionId:$s,companySlug:"beta",companyUid:"cmp_beta",harness:"claude-code"}' >> "$SPOOL"
: > "$(reg_marker "$sid" beta)"
tp4="$(mk_transcript "$sid" "$FAKE_SECRET")"
WM_ROOT="$SANDBOX" WM_SID="$sid" WM_HINT="$tp4" WM_HARNESS=claude-code \
  HQ_WORK_MESH_TOKEN=tok HQ_WORK_MESH_PERSON_UID=prs_test \
  WM_STUB_DIR="$d4" WM_STUB_GATES="$GATES_ALL_TRUE" WM_STUB_POST_CODE=200 \
  bash "$HOOK" __close_bg__ </dev/null
assert_eq    "multi: two reconcile POSTs (one per bound company)" "$(count_posts "$d4")" "2"
assert_eq    "multi: two reconciled events" "$(count_event_sid reconciled "$sid")" "2"
assert_false "multi: NO transcript copied for alpha" test -f "$(staged_file alpha prs_test "$sid")"
assert_false "multi: NO transcript copied for beta"  test -f "$(staged_file beta  prs_test "$sid")"
if jq -e --arg s "$sid" 'select(.event=="reconciled" and .sessionId==$s) | has("crossCompany")' "$SPOOL" >/dev/null 2>&1; then
  pass "multi: reconciled records flagged crossCompany"
else
  failc "multi: reconciled records missing the crossCompany flag"
fi
b4="$(first_post_body "$d4" || true)"
assert_eq "multi: reconcile body flagged crossCompany" "$(printf '%s' "$b4" | jq -r 'has("crossCompany")')" "true"
assert_no_secret_leak "multi: secret never under companies/, spool, log, or POST body" "$d4"

# ===========================================================================
echo "CASE 5 (e2e#5): transcript w/ a seeded fake secret -> copy has the redaction marker, not the secret"
# ===========================================================================
sid=acc-redact; d5="$SANDBOX/stub-redact"
register_session "$sid" indigo cmp_indigo
tp5="$(mk_transcript "$sid" "$FAKE_SECRET")"
WM_ROOT="$SANDBOX" WM_SID="$sid" WM_HINT="$tp5" WM_HARNESS=claude-code \
  HQ_WORK_MESH_TOKEN=tok HQ_WORK_MESH_PERSON_UID=prs_test \
  WM_STUB_DIR="$d5" WM_STUB_GATES="$GATES_ALL_TRUE" WM_STUB_POST_CODE=200 \
  bash "$HOOK" __close_bg__ </dev/null
staged5="$(staged_file indigo prs_test "$sid")"
assert_true "redact: the copy exists" test -f "$staged5"
if [ -f "$staged5" ]; then
  if grep -qF "$FAKE_SECRET" "$staged5"; then failc "redact: the seeded secret leaked into the copy"; else pass "redact: the seeded fake secret is absent from the copy"; fi
  if grep -qF "$REDACT_MARK" "$staged5"; then pass "redact: the copy contains the redaction marker"; else failc "redact: the copy has no redaction marker"; fi
fi
# The redaction COUNT is logged on the copied event (>=1), never the secret.
rc5="$(jq -r --arg s "$sid" 'select(.event=="copied" and .sessionId==$s) | .redactionCount' "$SPOOL" 2>/dev/null | tail -n1)"
if [ -n "$rc5" ] && [ "$rc5" -ge 1 ] 2>/dev/null; then pass "redact: redactionCount>=1 recorded on the copied event"; else failc "redact: redactionCount missing/zero ($rc5)"; fi
# The ORIGINAL transcript (outside companies/) is untouched — we scrub the copy,
# not the source; proves redaction reads the original and writes a clean copy.
if grep -qF "$FAKE_SECRET" "$tp5"; then pass "redact: the source transcript (outside companies/) is untouched"; else failc "redact: the source transcript was unexpectedly altered"; fi
assert_no_secret_leak "redact: secret never under companies/, spool, log, or POST body" "$d5"

# ===========================================================================
echo "CASE 6 (e2e#6): staging path companies/*/sessions/ -> git check-ignore reports it ignored"
# ===========================================================================
# Build a throwaway git repo whose .gitignore is the shipped one, then prove the
# staging path is ignored, never enters the index under a simulated autocommit
# `git add -A`, and is excluded from qmd/Grep by the shipped .ignore.
GITSB="$SANDBOX/gitsb-acc"
mkdir -p "$GITSB"
cp "$SRC_GITIGNORE" "$GITSB/.gitignore"
( git -C "$GITSB" init -q \
    && git -C "$GITSB" config user.email t@t \
    && git -C "$GITSB" config user.name t \
    && git -C "$GITSB" config commit.gpgsign false ) >/dev/null 2>&1
mkdir -p "$GITSB/companies/indigo/sessions/prs_x"
printf 'x\n' > "$GITSB/companies/indigo/sessions/prs_x/sess.jsonl"
if git -C "$GITSB" check-ignore -q "companies/indigo/sessions/prs_x/sess.jsonl"; then
  pass "hygiene: git check-ignore reports the staging path ignored"
else
  failc "hygiene: the staging path is NOT gitignored"
fi
git -C "$GITSB" add -A >/dev/null 2>&1 || true
if git -C "$GITSB" ls-files --error-unmatch "companies/indigo/sessions/prs_x/sess.jsonl" >/dev/null 2>&1; then
  failc "hygiene: the staged transcript entered the git index (autocommit would catch it)"
else
  pass "hygiene: a simulated autocommit (git add -A) never stages the transcript"
fi
if [ -f "$SRC_IGNORE" ] && grep -q 'companies/\*/sessions/' "$SRC_IGNORE"; then
  pass "hygiene: .ignore excludes the staging path from qmd/Grep/search"
else
  failc "hygiene: .ignore is missing companies/*/sessions/"
fi

# ===========================================================================
echo ""
echo "----------------------------------------------------------------------"
echo "work-mesh-close acceptance (US-004 e2eTests): ${PASS} passed, ${FAIL} failed"
if [ "$FAIL" -ne 0 ]; then
  echo "FAIL: work-mesh-close-acceptance.test.sh" >&2
  exit 1
fi
echo "PASS: work-mesh-close-acceptance.test.sh"
exit 0
