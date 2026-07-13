#!/usr/bin/env bash
# hq-core: public
# Acceptance tests for the US-003 company-bind Work Mesh registration hook
# (core/hooks/work-mesh-register.sh + core/scripts/work-mesh-lib.sh).
#
# These are BEHAVIORAL tests: they assert on the observable artifacts the hook
# produces — the per-(session,company) dedupe marker, the spool JSONL events
# (attempt|posted|skipped|declined|error), the captured POST body/HTTP verb, the
# bounded hook log, exit codes, and foreground wall-clock latency — NOT on the
# hook's internal implementation.
#
# Hermetic: no network (curl is stubbed on PATH), no real ~/.hq tokens (token is
# supplied via the HQ_WORK_MESH_TOKEN / HQ_COGNITO_TOKENS_FILE seams inside the
# sandbox), no dependence on the live HQ root (HQ_ROOT points at an HQ-shaped
# mktemp sandbox). bash-3.2 compatible (macOS system bash) and CI (ubuntu-latest):
# no mapfile, no associative arrays, no ${var,,}.
#
# Coverage (e2e#1-3 + the five PRD AC behaviors + payload contract):
#   1  kill switch HQ_WORK_MESH_DISABLED=1        -> full no-op
#   2  kill switch HQ_DISABLED_HOOKS              -> full no-op
#   3  bind fires POST (fast stub)                -> AC: bind fires post / e2e#1
#   4  fire-and-forget under a SLOW curl stub     -> e2e#1: session unblocked, fg <2s
#   5  duplicate bind                             -> AC: duplicate bind no-ops / e2e#3
#   6  API unreachable                            -> AC: offline spool line + unblocked / e2e#2
#   7  gate-off (workRegistryEnabled=false, bg)   -> AC: gate-off skip, no POST
#   8  gate-off foreground cached short-circuit   -> strengthens gate-off
#   9  POST body contract (adhoc, __bg__)         -> contract: no personUid, no projectId
#   10 POST body contract (project, __bg__)       -> contract: projectId iff binding==project
#   11 mid-session rebind to a 2nd company        -> 2nd marker + 2nd attempt line
#   12 token hygiene                              -> token string never in log or spool
#   13 missing token                              -> no-op skip, no POST
#   14 cwd inference (companies/<slug>/)          -> slug resolved from cwd
#   15 expired token file                         -> no-op skip, no POST
#   17 unsafe session/company path components     -> no marker path escape

set -euo pipefail

# ---------------------------------------------------------------------------
# Locate sources under test (this file lives in core/scripts/tests/).
# ---------------------------------------------------------------------------
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SRC_HOOK="$REPO_ROOT/core/hooks/work-mesh-register.sh"
SRC_LIB="$REPO_ROOT/core/scripts/work-mesh-lib.sh"

for f in "$SRC_HOOK" "$SRC_LIB"; do
  [ -f "$f" ] || { echo "FATAL: missing source under test: $f" >&2; exit 1; }
done
command -v jq >/dev/null 2>&1 || { echo "FATAL: jq is required for these tests" >&2; exit 1; }

# ---------------------------------------------------------------------------
# HQ-shaped sandbox + cleanup trap.
# ---------------------------------------------------------------------------
SANDBOX="$(mktemp -d)"
# A detached slow-stub background job (CASE 4) may still be writing into the
# sandbox when we tear down — its `mkdir -p` would recreate dirs right after a
# plain `rm -rf`, yielding a spurious "Directory not empty". Reap by retrying
# until the job finishes; never let cleanup change the suite's exit status.
cleanup() {
  local i=0
  rm -rf "$SANDBOX" 2>/dev/null || true
  while [ -d "$SANDBOX" ] && [ "$i" -lt 60 ]; do
    sleep 0.1
    rm -rf "$SANDBOX" 2>/dev/null || true
    i=$((i + 1))
  done
}
trap cleanup EXIT

mkdir -p "$SANDBOX/core/hooks" "$SANDBOX/core/scripts" \
         "$SANDBOX/workspace/sessions" "$SANDBOX/workspace/metrics" \
         "$SANDBOX/workspace/logs" "$SANDBOX/workspace/work-mesh/cache" \
         "$SANDBOX/stubbin" "$SANDBOX/home"
cp "$SRC_HOOK" "$SANDBOX/core/hooks/work-mesh-register.sh"
cp "$SRC_LIB"  "$SANDBOX/core/scripts/work-mesh-lib.sh"
chmod +x "$SANDBOX/core/hooks/work-mesh-register.sh"

HOOK="$SANDBOX/core/hooks/work-mesh-register.sh"
SPOOL="$SANDBOX/workspace/metrics/work-sessions.jsonl"
LOG="$SANDBOX/workspace/logs/work-mesh-hook.log"
CACHE="$SANDBOX/workspace/work-mesh/cache"

# ---------------------------------------------------------------------------
# curl stub — installed FIRST on PATH so the hook's background POST/GET never
# touch the network. Captures POST bodies; serves canned GET bodies; can
# simulate latency (WM_STUB_SLEEP) and transport failure (WM_STUB_FAIL).
# ---------------------------------------------------------------------------
cat > "$SANDBOX/stubbin/curl" <<'STUB'
#!/usr/bin/env bash
# Test stub for `curl` — just enough of the surface the work-mesh hook uses.
set -u
method="GET"; url=""; data=""; prev=""
for a in "$@"; do
  case "$prev" in
    -X)                    method="$a" ;;
    --data-binary|--data|-d) data="$a" ;;
  esac
  case "$a" in
    http://*|https://*) url="$a" ;;
  esac
  prev="$a"
done

# Record the invocation for hygiene assertions. argv must NEVER carry the bearer
# token — it now arrives via stdin (curl -H @-). Also capture the stdin header
# line so a test can prove the token is still delivered (auth intact).
if [ -n "${WM_STUB_DIR:-}" ]; then
  mkdir -p "$WM_STUB_DIR" 2>/dev/null || true
  printf '%s\n' "$*" >> "$WM_STUB_DIR/argv.txt"
  if IFS= read -r -t 1 _hdr 2>/dev/null && [ -n "$_hdr" ]; then
    printf '%s\n' "$_hdr" >> "$WM_STUB_DIR/stdin-headers.txt"
  fi
fi

# Optional latency (proves a slow background POST cannot stall the foreground).
if [ -n "${WM_STUB_SLEEP:-}" ] && [ "${WM_STUB_SLEEP}" != "0" ]; then
  sleep "$WM_STUB_SLEEP"
fi
# Simulate an unreachable API / transport failure (curl exit != 0).
if [ -n "${WM_STUB_FAIL:-}" ] && [ "${WM_STUB_FAIL}" != "0" ]; then
  exit 7
fi

if [ "$method" = "POST" ]; then
  # Hook calls: curl ... -o /dev/null -w '%{http_code}' -X POST --data-binary <body>
  # so we must print ONLY the HTTP code and capture the body out-of-band.
  if [ -n "${WM_STUB_DIR:-}" ]; then
    mkdir -p "$WM_STUB_DIR" 2>/dev/null || true
    printf '%s\n' "$data" >> "$WM_STUB_DIR/post-bodies.jsonl"
    printf '%s\t%s\n' "$url" "$data" >> "$WM_STUB_DIR/post-log.txt"
  fi
  printf '%s' "${WM_STUB_POST_CODE:-201}"
  exit 0
fi

# GET: hook expects the response BODY on stdout.
case "$url" in
  *"/membership/me"*)     printf '%s' "${WM_STUB_MEMBERSHIP:-}" ;;
  *"/v1/consent/gates"*)  printf '%s' "${WM_STUB_GATES:-}" ;;
  *)                      printf '%s' "${WM_STUB_GET_DEFAULT:-}" ;;
esac
exit 0
STUB
chmod +x "$SANDBOX/stubbin/curl"

# ---------------------------------------------------------------------------
# Constant environment for every invocation:
#   - stubbed PATH (curl overridden; jq/awk/etc. still resolve from real PATH)
#   - HOME redirected into the sandbox so no real ~/.hq is ever read
#   - unroutable API base so even a stub mishap cannot reach the network
#   - HQ_ROOT + a canned membership body
# ---------------------------------------------------------------------------
export PATH="$SANDBOX/stubbin:$PATH"
export HOME="$SANDBOX/home"
export HQ_ROOT="$SANDBOX"
export HQ_WORK_MESH_API_URL="http://127.0.0.1:9/wm-test"
export WM_STUB_MEMBERSHIP
WM_STUB_MEMBERSHIP="$(jq -nc '{memberships:[{companyUid:"cmp_indigo",companySlug:"indigo"}]}')"

GATES_TRUE="$(jq -nc '{workRegistryEnabled:true}')"
GATES_FALSE="$(jq -nc '{workRegistryEnabled:false}')"

# ---------------------------------------------------------------------------
# Assertion + helper harness (PASS/FAIL counters; continue-on-failure).
# Every fallible check runs inside an if/&&/|| so `set -e` never fires early.
# ---------------------------------------------------------------------------
PASS=0; FAIL=0
pass()  { PASS=$((PASS + 1)); echo "  ok:   $1"; }
failc() { FAIL=$((FAIL + 1)); echo "  FAIL: $1" >&2; }

assert_eq()           { if [ "$2" = "$3" ]; then pass "$1"; else failc "$1 (expected '$3', got '$2')"; fi; }
assert_true()         { local l="$1"; shift; if "$@"; then pass "$l"; else failc "$l"; fi; }
assert_false()        { local l="$1"; shift; if "$@"; then failc "$l (expected failure)"; else pass "$l"; fi; }
assert_contains()     { case "$2" in *"$3"*) pass "$1" ;; *) failc "$1 (missing '$3')" ;; esac; }
assert_not_contains() { case "$2" in *"$3"*) failc "$1 (unexpected '$3')" ;; *) pass "$1" ;; esac; }

# Poll (bounded, 5s @ 0.1s) for a file to become non-empty — for detached/async
# background artifacts. `[cond] && return` is exempt from -e (not the final &&).
poll_nonempty() {
  local f="$1" i=0
  while [ "$i" -lt 50 ]; do
    [ -s "$f" ] && return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}
# Poll for a spool event line for a given session id to appear.
poll_event_sid() {
  local ev="$1" sid="$2" i=0
  while [ "$i" -lt 50 ]; do
    [ "$(count_event_sid "$ev" "$sid")" != "0" ] && return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

count_event_sid() {  # <event> <sid>
  local ev="$1" sid="$2" n
  [ -f "$SPOOL" ] || { printf '0'; return 0; }
  n="$(jq -c --arg e "$ev" --arg s "$sid" \
        'select(.event==$e and .sessionId==$s)' "$SPOOL" 2>/dev/null \
        | wc -l | tr -d '[:space:]')" || n=0
  printf '%s' "${n:-0}"
}
count_event_slug() {  # <event> <companySlug>
  local ev="$1" slug="$2" n
  [ -f "$SPOOL" ] || { printf '0'; return 0; }
  n="$(jq -c --arg e "$ev" --arg s "$slug" \
        'select(.event==$e and .companySlug==$s)' "$SPOOL" 2>/dev/null \
        | wc -l | tr -d '[:space:]')" || n=0
  printf '%s' "${n:-0}"
}
count_posts() {  # <stub-dir>
  local d="$1"
  if [ -f "$d/post-bodies.jsonl" ]; then
    wc -l < "$d/post-bodies.jsonl" | tr -d '[:space:]'
  else
    printf '0'
  fi
}
first_post_body() {  # <stub-dir>
  local d="$1"
  [ -f "$d/post-bodies.jsonl" ] || return 1
  head -n 1 "$d/post-bodies.jsonl"
}
marker_path() {  # <sid> <slug-keyfrag>
  printf '%s/workspace/sessions/%s/work-mesh-registered-%s' "$SANDBOX" "$1" "$2"
}
set_meta_company() {  # <sid> <slug>  (truncates — rebind must not append)
  local d="$SANDBOX/workspace/sessions/$1"
  mkdir -p "$d"
  printf 'company_slug: %s\n' "$2" > "$d/meta.yaml"
}
mk_input() {  # <sid> <cwd>
  jq -nc --arg sid "$1" --arg cwd "$2" '{session_id:$sid, cwd:$cwd}'
}
now_ms() {
  perl -MTime::HiRes=time -e 'printf "%d", time()*1000' 2>/dev/null \
    || printf '%s' "$(( $(date +%s) * 1000 ))"
}

# ===========================================================================
echo "CASE 1: HQ_WORK_MESH_DISABLED=1 -> full no-op"
# ===========================================================================
sid=sid-disabled
set_meta_company "$sid" indigo
out="$(mk_input "$sid" "" | HQ_WORK_MESH_DISABLED=1 HQ_WORK_MESH_TOKEN=t \
        HQ_WORK_MESH_COMPANY_UID=cmp_indigo bash "$HOOK" SessionStart)"
assert_eq         "kill switch: foreground stays silent" "$out" ""
assert_false      "kill switch: no dedupe marker written" test -f "$(marker_path "$sid" indigo)"
assert_eq         "kill switch: no attempt spooled" "$(count_event_sid attempt "$sid")" "0"

# ===========================================================================
echo "CASE 2: HQ_DISABLED_HOOKS contains work-mesh-register -> full no-op"
# ===========================================================================
sid=sid-hookdisabled
set_meta_company "$sid" indigo
out="$(mk_input "$sid" "" | HQ_DISABLED_HOOKS='foo,work-mesh-register,bar' \
        HQ_WORK_MESH_TOKEN=t HQ_WORK_MESH_COMPANY_UID=cmp_indigo bash "$HOOK" SessionStart)"
assert_eq    "hook-disabled: foreground stays silent" "$out" ""
assert_false "hook-disabled: no dedupe marker written" test -f "$(marker_path "$sid" indigo)"
assert_eq    "hook-disabled: no attempt spooled" "$(count_event_sid attempt "$sid")" "0"

# ===========================================================================
echo "CASE 3: bind fires POST (fast stub) — AC 'bind fires post' / e2e#1"
# ===========================================================================
sid=sid-bind
d3="$SANDBOX/stub-bind"
set_meta_company "$sid" indigo
out="$(mk_input "$sid" "" | HQ_WORK_MESH_TOKEN=tok-bind HQ_WORK_MESH_COMPANY_UID=cmp_indigo \
        WM_STUB_DIR="$d3" WM_STUB_GATES="$GATES_TRUE" WM_STUB_POST_CODE=201 \
        bash "$HOOK" SessionStart)"
assert_eq    "bind: foreground stays silent (master-hook captures stdout)" "$out" ""
assert_true  "bind: dedupe marker written synchronously" test -f "$(marker_path "$sid" indigo)"
assert_eq    "bind: exactly one attempt spooled" "$(count_event_sid attempt "$sid")" "1"
if poll_nonempty "$d3/post-bodies.jsonl"; then
  pass "bind: background POST fired within bounded wait"
else
  failc "bind: background POST never fired"
fi
assert_eq       "bind: exactly one POST" "$(count_posts "$d3")" "1"
post_url="$(cut -f1 "$d3/post-log.txt" 2>/dev/null | head -n1 || true)"
assert_contains "bind: POST hit the work-sessions endpoint" "$post_url" "/v1/work-mesh/work-sessions"
if poll_event_sid posted "$sid"; then
  pass "bind: 'posted' event spooled after 201"
else
  failc "bind: 'posted' event never spooled"
fi

# ===========================================================================
echo "CASE 4: fire-and-forget under a SLOW curl stub — e2e#1 session unblocked"
# ===========================================================================
sid=sid-fast
d4="$SANDBOX/stub-fast"
set_meta_company "$sid" indigo
t0="$(now_ms)"
out="$(mk_input "$sid" "" | HQ_WORK_MESH_TOKEN=tok HQ_WORK_MESH_COMPANY_UID=cmp_indigo \
        WM_STUB_DIR="$d4" WM_STUB_GATES="$GATES_TRUE" WM_STUB_SLEEP=3 \
        bash "$HOOK" SessionStart)"
t1="$(now_ms)"
elapsed=$((t1 - t0))
echo "  (foreground elapsed: ${elapsed}ms with a 3s stub curl)"
if [ "$elapsed" -lt 2000 ]; then
  pass "fire-and-forget: foreground returned in <2s despite a 3s background curl"
else
  failc "fire-and-forget: foreground blocked on the network (${elapsed}ms)"
fi
assert_eq   "fire-and-forget: foreground stays silent" "$out" ""
assert_true "fire-and-forget: attempt spooled before the (slow) network" \
            test "$(count_event_sid attempt "$sid")" = "1"

# ===========================================================================
echo "CASE 5: duplicate bind — AC 'duplicate bind no-ops' / e2e#3"
# ===========================================================================
sid=sid-dup
d5="$SANDBOX/stub-dup"
set_meta_company "$sid" indigo
# First bind.
mk_input "$sid" "" | HQ_WORK_MESH_TOKEN=tok HQ_WORK_MESH_COMPANY_UID=cmp_indigo \
  WM_STUB_DIR="$d5" WM_STUB_GATES="$GATES_TRUE" bash "$HOOK" SessionStart >/dev/null
if poll_nonempty "$d5/post-bodies.jsonl"; then
  pass "dup: first bind produced a POST"
else
  failc "dup: first bind produced no POST"
fi
# Second bind of the SAME (session, company) — marker must short-circuit it.
out="$(mk_input "$sid" "" | HQ_WORK_MESH_TOKEN=tok HQ_WORK_MESH_COMPANY_UID=cmp_indigo \
        WM_STUB_DIR="$d5" WM_STUB_GATES="$GATES_TRUE" bash "$HOOK" SessionStart)"
assert_eq "dup: second bind stays silent" "$out" ""
assert_eq "dup: still exactly one attempt line" "$(count_event_sid attempt "$sid")" "1"
# Give any (erroneously spawned) second background a chance to POST, then assert none did.
sleep 0.5
assert_eq "dup: still exactly one POST (no duplicate registration)" "$(count_posts "$d5")" "1"

# ===========================================================================
echo "CASE 6: API unreachable — AC 'offline spool line' + 'session unblocked' / e2e#2"
# ===========================================================================
sid=sid-unreach
d6="$SANDBOX/stub-unreach"
set_meta_company "$sid" indigo
t0="$(now_ms)"
out="$(mk_input "$sid" "" | HQ_WORK_MESH_TOKEN=tok HQ_WORK_MESH_COMPANY_UID=cmp_indigo \
        WM_STUB_DIR="$d6" WM_STUB_FAIL=1 bash "$HOOK" SessionStart)"
t1="$(now_ms)"
elapsed=$((t1 - t0))
if [ "$elapsed" -lt 2000 ]; then
  pass "unreachable: session proceeds fast (<2s)"
else
  failc "unreachable: session was blocked (${elapsed}ms)"
fi
assert_eq   "unreachable: foreground stays silent" "$out" ""
assert_eq   "unreachable: local 'attempt' spool line exists" "$(count_event_sid attempt "$sid")" "1"
assert_eq   "unreachable: no POST body captured (transport failed)" "$(count_posts "$d6")" "0"
if poll_event_sid error "$sid"; then
  pass "unreachable: background recorded an 'error' spool line (US-004 sweep backfill)"
else
  failc "unreachable: no 'error' spool line recorded"
fi
if grep -q 'post failed' "$LOG" 2>/dev/null; then
  pass "unreachable: hook log notes the failed post"
else
  failc "unreachable: hook log has no failure note"
fi

# ===========================================================================
echo "CASE 7: gate-off (workRegistryEnabled=false) — AC 'gate-off skip', no POST"
# ===========================================================================
sid=sid-gateoff
d7="$SANDBOX/stub-gateoff"
# __bg__ synchronous mode: exercises the gate decision deterministically.
WM_ROOT="$SANDBOX" WM_SID="$sid" WM_SLUG=gateoffco WM_UID=cmp_gateoff \
  WM_BINDING=adhoc WM_CATEGORY=adhoc WM_INTENT="gate test" WM_HARNESS=claude-code \
  HQ_WORK_MESH_TOKEN=tok WM_STUB_DIR="$d7" WM_STUB_GATES="$GATES_FALSE" \
  bash "$HOOK" __bg__ </dev/null
assert_eq "gate-off: no POST when registry disabled" "$(count_posts "$d7")" "0"
assert_eq "gate-off: 'skipped' event spooled" "$(count_event_sid skipped "$sid")" "1"
if jq -e --arg s "$sid" \
      'select(.sessionId==$s and .event=="skipped") | .reason=="registry_disabled"' \
      "$SPOOL" >/dev/null 2>&1; then
  pass "gate-off: skip reason is registry_disabled"
else
  failc "gate-off: skip reason not registry_disabled"
fi
if grep -q 'cmp_gateoff' "$LOG" 2>/dev/null && grep -q 'workRegistryEnabled=false' "$LOG" 2>/dev/null; then
  pass "gate-off: hook log records the disabled decision for this uid"
else
  failc "gate-off: hook log missing disabled-decision evidence"
fi

# ===========================================================================
echo "CASE 8: gate-off foreground cached short-circuit — zero-network skip"
# ===========================================================================
sid=sid-gcache
set_meta_company "$sid" gcacheco
# Pre-seed a FRESH gates cache saying disabled for the (env-supplied) uid.
printf '%s' "$GATES_FALSE" > "$CACHE/gates-cmp_gcache"
out="$(mk_input "$sid" "" | HQ_WORK_MESH_TOKEN=tok HQ_WORK_MESH_COMPANY_UID=cmp_gcache \
        WM_STUB_DIR="$SANDBOX/stub-gcache" WM_STUB_GATES="$GATES_TRUE" bash "$HOOK" SessionStart)"
assert_eq    "cached-gate-off: foreground stays silent" "$out" ""
assert_false "cached-gate-off: no marker (fully short-circuited)" test -f "$(marker_path "$sid" gcacheco)"
assert_eq    "cached-gate-off: no attempt spooled" "$(count_event_sid attempt "$sid")" "0"
assert_eq    "cached-gate-off: no POST" "$(count_posts "$SANDBOX/stub-gcache")" "0"
if grep -q 'cached' "$LOG" 2>/dev/null && grep -q 'gcacheco' "$LOG" 2>/dev/null; then
  pass "cached-gate-off: hook log notes the cached skip"
else
  failc "cached-gate-off: hook log missing cached-skip note"
fi

# ===========================================================================
echo "CASE 9: POST body contract (adhoc) — no personUid, no projectId"
# ===========================================================================
sid=sid-adhoc
d9="$SANDBOX/stub-adhoc"
WM_ROOT="$SANDBOX" WM_SID="$sid" WM_SLUG=indigo WM_UID=cmp_adhoc \
  WM_BINDING=adhoc WM_CATEGORY=adhoc WM_INTENT="adhoc intent" WM_HARNESS=claude-code \
  HQ_WORK_MESH_TOKEN=tok WM_STUB_DIR="$d9" WM_STUB_GATES="$GATES_TRUE" WM_STUB_POST_CODE=201 \
  bash "$HOOK" __bg__ </dev/null
if body="$(first_post_body "$d9")"; then
  assert_eq       "adhoc contract: companyUid"  "$(printf '%s' "$body" | jq -r '.companyUid')" "cmp_adhoc"
  assert_eq       "adhoc contract: sessionId"   "$(printf '%s' "$body" | jq -r '.sessionId')" "$sid"
  assert_eq       "adhoc contract: harness"     "$(printf '%s' "$body" | jq -r '.harness')" "claude-code"
  assert_eq       "adhoc contract: binding"     "$(printf '%s' "$body" | jq -r '.classification.binding')" "adhoc"
  assert_eq       "adhoc contract: category"    "$(printf '%s' "$body" | jq -r '.classification.category')" "adhoc"
  assert_eq       "adhoc contract: intentSummary present" "$(printf '%s' "$body" | jq -r '.classification.intentSummary')" "adhoc intent"
  assert_eq       "adhoc contract: NO personUid" "$(printf '%s' "$body" | jq -r 'has("personUid")')" "false"
  assert_eq       "adhoc contract: NO projectId (binding=adhoc)" "$(printf '%s' "$body" | jq -r '.classification | has("projectId")')" "false"
else
  failc "adhoc contract: no POST body captured"
fi

# ===========================================================================
echo "CASE 10: POST body contract (project) — projectId iff binding==project"
# ===========================================================================
sid=sid-proj
d10="$SANDBOX/stub-proj"
WM_ROOT="$SANDBOX" WM_SID="$sid" WM_SLUG=indigo WM_UID=cmp_proj \
  WM_BINDING=project WM_PROJECT=proj_abc123 WM_CATEGORY=adhoc \
  WM_INTENT="project intent" WM_HARNESS=claude-code \
  HQ_WORK_MESH_TOKEN=tok WM_STUB_DIR="$d10" WM_STUB_GATES="$GATES_TRUE" WM_STUB_POST_CODE=201 \
  bash "$HOOK" __bg__ </dev/null
if body="$(first_post_body "$d10")"; then
  assert_eq "project contract: binding==project" "$(printf '%s' "$body" | jq -r '.classification.binding')" "project"
  assert_eq "project contract: projectId present and correct" "$(printf '%s' "$body" | jq -r '.classification.projectId')" "proj_abc123"
  assert_eq "project contract: still NO personUid" "$(printf '%s' "$body" | jq -r 'has("personUid")')" "false"
else
  failc "project contract: no POST body captured"
fi

# ===========================================================================
echo "CASE 11: mid-session rebind to a 2nd company — 2nd marker + 2nd attempt"
# ===========================================================================
sid=sid-rebind
d11="$SANDBOX/stub-rebind"
# Bind company A.
set_meta_company "$sid" alpha
mk_input "$sid" "" | HQ_WORK_MESH_TOKEN=tok WM_STUB_DIR="$d11" \
  WM_STUB_GATES="$GATES_TRUE" bash "$HOOK" SessionStart >/dev/null
assert_true "rebind: marker for company A (alpha)" test -f "$(marker_path "$sid" alpha)"
assert_eq   "rebind: one attempt for alpha" "$(count_event_slug attempt alpha)" "1"
# Rebind to company B mid-session (meta company_slug changes).
set_meta_company "$sid" beta
mk_input "$sid" "" | HQ_WORK_MESH_TOKEN=tok WM_STUB_DIR="$d11" \
  WM_STUB_GATES="$GATES_TRUE" bash "$HOOK" SessionStart >/dev/null
assert_true "rebind: separate marker for company B (beta)" test -f "$(marker_path "$sid" beta)"
assert_eq   "rebind: one attempt for beta" "$(count_event_slug attempt beta)" "1"
assert_eq   "rebind: two distinct attempt lines for the session" "$(count_event_sid attempt "$sid")" "2"

# ===========================================================================
echo "CASE 12: token hygiene — bearer token never in log or spool"
# ===========================================================================
sid=sid-token
d12="$SANDBOX/stub-token"
TOKENVAL='SECRET-TOKEN-DO-NOT-LEAK-abc123XYZ'
WM_ROOT="$SANDBOX" WM_SID="$sid" WM_SLUG=indigo WM_UID=cmp_token \
  WM_BINDING=adhoc WM_CATEGORY=adhoc WM_INTENT="token hygiene" WM_HARNESS=claude-code \
  HQ_WORK_MESH_TOKEN="$TOKENVAL" WM_STUB_DIR="$d12" WM_STUB_GATES="$GATES_TRUE" \
  WM_STUB_POST_CODE=201 bash "$HOOK" __bg__ </dev/null
assert_true "token hygiene: a POST actually happened (token was in play)" test -s "$d12/post-bodies.jsonl"
if [ -f "$LOG" ] && grep -qF "$TOKENVAL" "$LOG"; then
  failc "token hygiene: token leaked into the hook log"
else
  pass "token hygiene: token absent from hook log"
fi
if [ -f "$SPOOL" ] && grep -qF "$TOKENVAL" "$SPOOL"; then
  failc "token hygiene: token leaked into the spool"
else
  pass "token hygiene: token absent from the spool"
fi
if [ -f "$d12/argv.txt" ] && grep -qF "$TOKENVAL" "$d12/argv.txt"; then
  failc "token hygiene: token leaked into curl argv (visible in process table)"
else
  pass "token hygiene: token absent from curl argv"
fi
if [ -f "$d12/stdin-headers.txt" ] && grep -qF "$TOKENVAL" "$d12/stdin-headers.txt"; then
  pass "token hygiene: token delivered via stdin header (auth intact)"
else
  failc "token hygiene: Authorization header not delivered via stdin"
fi

# ===========================================================================
echo "CASE 13: missing token — no-op skip, no POST"
# ===========================================================================
sid=sid-notok
d13="$SANDBOX/stub-notok"
# No HQ_WORK_MESH_TOKEN; point the token file at a nonexistent path (hermetic).
WM_ROOT="$SANDBOX" WM_SID="$sid" WM_SLUG=indigo WM_UID=cmp_notok \
  WM_BINDING=adhoc WM_CATEGORY=adhoc WM_INTENT="no token" WM_HARNESS=claude-code \
  HQ_COGNITO_TOKENS_FILE="$SANDBOX/no-such-tokens.json" \
  WM_STUB_DIR="$d13" WM_STUB_GATES="$GATES_TRUE" bash "$HOOK" __bg__ </dev/null
assert_eq "missing token: no POST" "$(count_posts "$d13")" "0"
assert_eq "missing token: 'skipped' event spooled" "$(count_event_sid skipped "$sid")" "1"
if jq -e --arg s "$sid" \
      'select(.sessionId==$s and .event=="skipped") | .reason=="no_token"' \
      "$SPOOL" >/dev/null 2>&1; then
  pass "missing token: skip reason is no_token"
else
  failc "missing token: skip reason not no_token"
fi

# ===========================================================================
echo "CASE 14: cwd inference — slug resolved from companies/<slug>/ path"
# ===========================================================================
sid=sid-cwd
d14="$SANDBOX/stub-cwd"
# No meta company_slug: force the cwd-inference branch.
mkdir -p "$SANDBOX/workspace/sessions/$sid"
: > "$SANDBOX/workspace/sessions/$sid/meta.yaml"
cwd="$SANDBOX/companies/indigo/repos/hq"
out="$(mk_input "$sid" "$cwd" | HQ_WORK_MESH_TOKEN=tok HQ_WORK_MESH_COMPANY_UID=cmp_indigo \
        WM_STUB_DIR="$d14" WM_STUB_GATES="$GATES_TRUE" bash "$HOOK" SessionStart)"
assert_eq   "cwd inference: foreground stays silent" "$out" ""
assert_true "cwd inference: marker uses the inferred slug (indigo)" test -f "$(marker_path "$sid" indigo)"
assert_eq   "cwd inference: exactly one attempt for this session" "$(count_event_sid attempt "$sid")" "1"
if jq -e --arg s "$sid" \
      'select(.sessionId==$s and .event=="attempt") | .companySlug=="indigo"' \
      "$SPOOL" >/dev/null 2>&1; then
  pass "cwd inference: attempt line carries the inferred companySlug=indigo"
else
  failc "cwd inference: attempt line did not carry companySlug=indigo"
fi

# ===========================================================================
echo "CASE 15: expired token file — no-op skip, no POST"
# ===========================================================================
sid=sid-exp
d15="$SANDBOX/stub-exp"
TF="$SANDBOX/expired-tokens.json"
# expiresAt is epoch MILLISECONDS in the past -> token is expired -> no-op.
jq -n --arg id 'tok-expired' --argjson exp 1000 \
  '{idToken:$id, accessToken:"acc", expiresAt:$exp}' > "$TF"
WM_ROOT="$SANDBOX" WM_SID="$sid" WM_SLUG=indigo WM_UID=cmp_exp \
  WM_BINDING=adhoc WM_CATEGORY=adhoc WM_INTENT="expired" WM_HARNESS=claude-code \
  HQ_COGNITO_TOKENS_FILE="$TF" WM_STUB_DIR="$d15" WM_STUB_GATES="$GATES_TRUE" \
  bash "$HOOK" __bg__ </dev/null
assert_eq "expired token: no POST" "$(count_posts "$d15")" "0"
assert_eq "expired token: 'skipped' event spooled" "$(count_event_sid skipped "$sid")" "1"
if jq -e --arg s "$sid" \
      'select(.sessionId==$s and .event=="skipped") | .reason=="no_token"' \
      "$SPOOL" >/dev/null 2>&1; then
  pass "expired token: skip reason is no_token"
else
  failc "expired token: skip reason not no_token"
fi

# ===========================================================================
echo "CASE 16: TLS/scheme guard — cleartext non-loopback http:// base -> no POST"
# ===========================================================================
# A valid token + explicit uid are present, so the ONLY thing that can suppress
# the network call is the base-scheme guard: an http:// base to a non-loopback
# host must be refused (token never sent in cleartext) and the request becomes a
# locally-logged no-op — never a session block. Paired with a loopback-http
# positive control proving it is the SCHEME, not the setup, that gates the POST.
sid=sid-insecure
d16="$SANDBOX/stub-insecure"
WM_ROOT="$SANDBOX" WM_SID="$sid" WM_SLUG=indigo WM_UID=cmp_indigo \
  WM_BINDING=adhoc WM_CATEGORY=adhoc WM_INTENT="insecure base" WM_HARNESS=claude-code \
  HQ_WORK_MESH_TOKEN=tok-insecure HQ_WORK_MESH_API_URL="http://mesh.internal.example:8080/api" \
  WM_STUB_DIR="$d16" WM_STUB_GATES="$GATES_TRUE" bash "$HOOK" __bg__ </dev/null
assert_eq "insecure base: no POST (curl never called)" "$(count_posts "$d16")" "0"
assert_false "insecure base: no GET either (curl never called)" test -f "$d16/argv.txt"
if grep -q 'refusing insecure API base scheme' "$LOG" 2>/dev/null; then
  pass "insecure base: refusal is locally logged"
else
  failc "insecure base: no refusal note in hook log"
fi

# Positive control: identical setup but a loopback http:// base -> POST fires.
sid=sid-loopback-ok
d16b="$SANDBOX/stub-loopback-ok"
WM_ROOT="$SANDBOX" WM_SID="$sid" WM_SLUG=indigo WM_UID=cmp_indigo \
  WM_BINDING=adhoc WM_CATEGORY=adhoc WM_INTENT="loopback ok" WM_HARNESS=claude-code \
  HQ_WORK_MESH_TOKEN=tok-loopback HQ_WORK_MESH_API_URL="http://127.0.0.1:9/wm-test" \
  WM_STUB_DIR="$d16b" WM_STUB_GATES="$GATES_TRUE" WM_STUB_POST_CODE=201 \
  bash "$HOOK" __bg__ </dev/null
assert_eq "loopback http base: POST fires (loopback exception allowed)" "$(count_posts "$d16b")" "1"

# ===========================================================================
echo "CASE 17: unsafe path components are rejected before marker creation"
# ===========================================================================
outside17="$SANDBOX/../work-mesh-register-escape-$$"
rm -rf "$outside17"
bad_sid="../../../$(basename "$outside17")"
out="$(mk_input "$bad_sid" "$SANDBOX/companies/indigo" | \
        HQ_WORK_MESH_TOKEN=tok HQ_WORK_MESH_COMPANY_UID=cmp_indigo \
        WM_STUB_DIR="$SANDBOX/stub-bad-sid" WM_STUB_GATES="$GATES_TRUE" \
        bash "$HOOK" SessionStart)"
assert_eq "unsafe session: foreground stays silent" "$out" ""
assert_false "unsafe session: marker path cannot escape workspace/sessions" test -e "$outside17"
assert_eq "unsafe session: no attempt spooled" "$(count_event_sid attempt "$bad_sid")" "0"

sid=sid-bad-slug
set_meta_company "$sid" '../escape-company'
out="$(mk_input "$sid" "" | HQ_WORK_MESH_TOKEN=tok HQ_WORK_MESH_COMPANY_UID=cmp_indigo \
        WM_STUB_DIR="$SANDBOX/stub-bad-slug" WM_STUB_GATES="$GATES_TRUE" \
        bash "$HOOK" SessionStart)"
assert_eq "unsafe company: foreground stays silent" "$out" ""
assert_false "unsafe company: no dedupe marker written" test -f "$(marker_path "$sid" .._escape-company)"
assert_eq "unsafe company: no attempt spooled" "$(count_event_sid attempt "$sid")" "0"
rm -rf "$outside17"

# ===========================================================================
echo ""
echo "----------------------------------------------------------------------"
echo "work-mesh-register acceptance: ${PASS} passed, ${FAIL} failed"
if [ "$FAIL" -ne 0 ]; then
  echo "FAIL: work-mesh-register.test.sh" >&2
  exit 1
fi
echo "PASS: work-mesh-register.test.sh"
exit 0
