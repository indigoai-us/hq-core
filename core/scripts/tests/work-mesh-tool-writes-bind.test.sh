#!/usr/bin/env bash
# hq-core: public
# US-040: a Write/Edit/MultiEdit under companies/<co>/projects/<slug>/ binds
# the session (once per slug) when it still needs a project, and a write of
# that project's prd.json syncs progress only when the CLI supports prd-sync.
# F14: a session already bound to project A still runs prd-sync when the write
# is companies/<same-co>/projects/<B>/prd.json (CLI rebinds). Other files in B
# stay skipped. Cross-company stays skipped.
# Bash redirects are not path-bound. Non-write tools return before any of this.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
HOOK="${TOOL_WRITES_HOOK:-$REPO_ROOT/core/hooks/PostToolUse/35-work-mesh-tool-writes.sh}"
[ -f "$HOOK" ] || { echo "FATAL: missing $HOOK" >&2; exit 1; }

PASS=0
FAIL=0
fail() { echo "FAIL: $*" >&2; FAIL=$((FAIL + 1)); }
pass() { echo "PASS: $*"; PASS=$((PASS + 1)); }

SANDBOX="$(mktemp -d)"
cleanup() { rm -rf "$SANDBOX" 2>/dev/null || true; }
trap cleanup EXIT

HOME_DIR="$SANDBOX/home"
HQ_ROOT_DIR="$SANDBOX/hq"
BIN="$SANDBOX/bin"
mkdir -p "$HOME_DIR/.hq/work-context/sessions" "$BIN" \
  "$HQ_ROOT_DIR/companies/indigo/projects/wm-smoke/docs" \
  "$HQ_ROOT_DIR/companies/indigo/knowledge" \
  "$HQ_ROOT_DIR/companies/acme/projects/wm-smoke"
export HOME="$HOME_DIR"
export WORK_MESH_HOME="$HOME_DIR"
export HQ_ROOT="$HQ_ROOT_DIR"
unset HQ_WORK_MESH_DISABLED HQ_DISABLED_HOOKS || true
unset CLAUDE_CODE_SESSION_ID CLAUDE_SESSION_ID HQ_SESSION_ID CODEX_SESSION_ID CODEX_THREAD_ID || true

STATE_DIR="$HOME_DIR/.hq/work-context/sessions"
LOG="$SANDBOX/hq-invocations.log"
: >"$LOG"

cat >"$BIN/hq" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >>"${HQ_STUB_LOG:?}"
if [ "$1" = "--version" ]; then
  printf '%s\n' "${HQ_STUB_VERSION:-hq 9.9.9-us040}"
  exit 0
fi
if [ "$1" = "mesh" ] && [ "$2" = "context" ] && [ "$3" = "prd-sync" ] && [ "$4" = "--help" ]; then
  if [ "${HQ_PRD_SYNC_SUPPORTED:-no}" = "yes" ]; then
    exit 0
  fi
  exit 1
fi
if [ "$1" = "mesh" ] && [ "$2" = "context" ] && [ "$3" = "bind-project" ] && [ "${HQ_BIND_FAIL:-no}" = "yes" ]; then
  exit 1
fi
if [ "${HQ_STUB_SLEEP:-0}" != "0" ]; then
  case "$*" in
    *"bind-project"*|*"prd-sync --session"*) sleep "$HQ_STUB_SLEEP" ;;
  esac
fi
exit 0
EOF
chmod +x "$BIN/hq"

seed() {
  # $1 sid  $2 contextStatus  $3 company  $4 projectId (or empty)
  local sid="$1" status="$2" co="$3" pid="$4"
  if [ -n "$pid" ]; then
    printf '{"contractVersion":1,"sessionId":"%s","contextStatus":"%s","companySlug":"%s","projectId":"%s","toolWrites":1,"updatedAt":"2026-09-20T10:00:00.000Z"}\n' \
      "$sid" "$status" "$co" "$pid" >"$STATE_DIR/$sid.json"
  else
    printf '{"contractVersion":1,"sessionId":"%s","contextStatus":"%s","companySlug":"%s","toolWrites":1,"updatedAt":"2026-09-20T10:00:00.000Z"}\n' \
      "$sid" "$status" "$co" >"$STATE_DIR/$sid.json"
  fi
}

run_hook() {
  # $1 sid  $2 tool  $3 file_path (optional)  $4 extra env KEY=VAL
  local sid="$1" tool="$2" file="${3:-}" extra="${4:-}"
  local payload
  if [ "$tool" = "Bash" ]; then
    payload="$(printf '{"session_id":"%s","tool_name":"Bash","tool_input":{"command":"%s"}}' "$sid" "$file")"
  elif [ -n "$file" ]; then
    payload="$(printf '{"session_id":"%s","tool_name":"%s","tool_input":{"file_path":"%s"}}' "$sid" "$tool" "$file")"
  else
    payload="$(printf '{"session_id":"%s","tool_name":"%s","tool_input":{}}' "$sid" "$tool")"
  fi
  # shellcheck disable=SC2086
  printf '%s' "$payload" | env -u HQ_DISABLED_HOOKS -u HQ_WORK_MESH_DISABLED \
    HOME="$HOME" WORK_MESH_HOME="$WORK_MESH_HOME" HQ_ROOT="$HQ_ROOT" \
    PATH="$BIN:$PATH" HQ_STUB_LOG="$LOG" $extra \
    bash "$HOOK" >/dev/null 2>&1
}

# Detached hq calls land after the hook returns. Poll the stub log instead of
# sleeping a fixed interval (a 0.1s/0.4s wait missed bind-project under load).
poll_log() {
  local needle="$1" start now
  start=$(date +%s)
  while :; do
    if grep -F -q -- "$needle" "$LOG" 2>/dev/null; then
      return 0
    fi
    now=$(date +%s)
    [ $((now - start)) -ge 5 ] && return 1
    sleep 0.05
  done
}

# Block until this session's detached bind/prd workers have exited (or 5s).
# Lock files exist from the moment a flight is launched until its trap runs,
# so a just-spawned worker is not treated as "already finished".
wait_sid_quiet() {
  local sid="$1" start now f pid busy
  start=$(date +%s)
  while :; do
    busy=0
    for f in "$STATE_DIR/$sid".wm-bind-*.pid "$STATE_DIR/$sid".wm-prd.pid; do
      [ -e "$f" ] || continue
      pid="$(cat "$f" 2>/dev/null || true)"
      if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        busy=1
        break
      fi
    done
    if [ "$busy" -eq 0 ]; then
      # shellcheck disable=SC2086
      if ! ls "$STATE_DIR/$sid".wm-bind-*.lock "$STATE_DIR/$sid".wm-prd.lock >/dev/null 2>&1; then
        return 0
      fi
    fi
    now=$(date +%s)
    [ $((now - start)) -ge 5 ] && return 0
    sleep 0.05
  done
}

count_log() {
  grep -F -c -- "$1" "$LOG" 2>/dev/null || true
}

reset_log() { : >"$LOG"; }

# --- non-write exits before any hq call -------------------------------------
sid=sid-read
seed "$sid" needs_project indigo ""
reset_log
start=$(date +%s)
run_hook "$sid" Read "" "HQ_STUB_SLEEP=5"
end=$(date +%s)
if [ $((end - start)) -le 2 ]; then
  pass "non-write: returned without waiting on hq"
else
  fail "non-write: blocked for $((end - start))s"
fi
if [ ! -s "$LOG" ]; then
  pass "non-write: hq not invoked"
else
  fail "non-write: hq invoked: $(cat "$LOG")"
fi
tw=$(jq -r '.toolWrites' "$STATE_DIR/$sid.json")
[ "$tw" = "1" ] && pass "non-write: toolWrites unchanged" || fail "non-write: toolWrites=$tw"

# --- write outside a project folder -----------------------------------------
sid=sid-out
seed "$sid" needs_project indigo ""
reset_log
run_hook "$sid" Write "$HQ_ROOT/companies/indigo/knowledge/note.md"
wait_sid_quiet "$sid"
if [ ! -s "$LOG" ] && [ ! -f "$STATE_DIR/$sid.wm-bind-wm-smoke" ]; then
  pass "outside project: no bind"
else
  fail "outside project: unexpected bind log=$(cat "$LOG" 2>/dev/null) marker=$(ls "$STATE_DIR/$sid".wm-bind-* 2>/dev/null)"
fi

# --- cross-company path ------------------------------------------------------
sid=sid-xco
seed "$sid" needs_project indigo ""
reset_log
run_hook "$sid" Edit "$HQ_ROOT/companies/acme/projects/wm-smoke/digest.md"
wait_sid_quiet "$sid"
if [ ! -s "$LOG" ] && [ ! -f "$STATE_DIR/$sid.wm-bind-wm-smoke" ]; then
  pass "cross-company: no bind"
else
  fail "cross-company: bound across companies: $(cat "$LOG" 2>/dev/null)"
fi

# --- bash redirect into a project path is not a bind -------------------------
sid=sid-bash
seed "$sid" needs_project indigo ""
reset_log
run_hook "$sid" Bash "echo hi > $HQ_ROOT/companies/indigo/projects/wm-smoke/digest.md"
wait_sid_quiet "$sid"
if [ ! -s "$LOG" ]; then
  pass "bash redirect: no bind"
else
  fail "bash redirect: hq invoked: $(cat "$LOG")"
fi

# --- write under the project binds once --------------------------------------
sid=sid-bind
seed "$sid" needs_project indigo ""
reset_log
run_hook "$sid" Write "$HQ_ROOT/companies/indigo/projects/wm-smoke/digest.md"
run_hook "$sid" Edit "companies/indigo/projects/wm-smoke/docs/more.md"
if poll_log "bind-project wm-smoke"; then
  wait_sid_quiet "$sid"
  n=$(count_log "bind-project wm-smoke")
  [ "$n" = "1" ] && pass "project write: bind-project once (calls=$n)" || fail "project write: bind-project calls=$n"
else
  fail "project write: bind-project not called. log=$(cat "$LOG" 2>/dev/null)"
fi
[ -f "$STATE_DIR/$sid.wm-bind-wm-smoke" ] && pass "project write: marker once" || fail "project write: marker missing"
[ ! -f "$STATE_DIR/$sid.wm-bind-wm-smoke.backoff" ] && pass "project write: no backoff after success" || fail "project write: backoff left after success"

# --- failed bind does not stick the success marker -------------------------
sid=sid-bind-fail
seed "$sid" needs_project indigo ""
reset_log
run_hook "$sid" Write "$HQ_ROOT/companies/indigo/projects/wm-smoke/digest.md" "HQ_BIND_FAIL=yes HQ_WM_BIND_BACKOFF_SEC=60"
if poll_log "bind-project wm-smoke"; then
  pass "bind failure: bind-project was attempted"
else
  fail "bind failure: bind-project not called. log=$(cat "$LOG" 2>/dev/null)"
fi
wait_sid_quiet "$sid"
if [ -f "$STATE_DIR/$sid.wm-bind-wm-smoke" ]; then
  fail "bind failure: success marker written; later writes will not retry"
else
  pass "bind failure: success marker absent"
fi
[ -f "$STATE_DIR/$sid.wm-bind-wm-smoke.backoff" ] && pass "bind failure: backoff marker written" || fail "bind failure: backoff marker missing"
run_hook "$sid" Edit "$HQ_ROOT/companies/indigo/projects/wm-smoke/docs/more.md" "HQ_BIND_FAIL=yes HQ_WM_BIND_BACKOFF_SEC=60"
wait_sid_quiet "$sid"
n=$(count_log "bind-project wm-smoke")
[ "$n" = "1" ] && pass "bind failure: backoff suppresses an immediate retry (calls=$n)" || fail "bind failure: calls during backoff=$n"
printf '1\n' >"$STATE_DIR/$sid.wm-bind-wm-smoke.backoff"
run_hook "$sid" Write "$HQ_ROOT/companies/indigo/projects/wm-smoke/digest.md" "HQ_BIND_FAIL=yes HQ_WM_BIND_BACKOFF_SEC=60"
if poll_log "bind-project wm-smoke --session $sid"; then
  n=$(count_log "bind-project wm-smoke")
  # The second line is the retry. Keep polling until that line exists or 5s.
  start=$(date +%s)
  while [ "$n" -lt 2 ]; do
    now=$(date +%s)
    [ $((now - start)) -ge 5 ] && break
    sleep 0.05
    n=$(count_log "bind-project wm-smoke")
  done
fi
n=$(count_log "bind-project wm-smoke")
[ "$n" = "2" ] && pass "bind failure: retries after backoff expires (calls=$n)" || fail "bind failure: calls after backoff=$n"

# --- already bound: no second project bind -----------------------------------
sid=sid-bound
seed "$sid" bound indigo wm-smoke
reset_log
run_hook "$sid" Write "$HQ_ROOT/companies/indigo/projects/other/digest.md"
wait_sid_quiet "$sid"
if [ ! -s "$LOG" ]; then
  pass "already bound: other project does not rebind"
else
  fail "already bound: unexpected $(cat "$LOG")"
fi

# --- F14: bound to A, same-company B/prd.json -> prd-sync (CLI rebinds) ------
sid=sid-f14-prd
seed "$sid" bound indigo wm-smoke
reset_log
run_hook "$sid" Write "$HQ_ROOT/companies/indigo/projects/other/prd.json" \
  "HQ_PRD_SYNC_SUPPORTED=yes HQ_STUB_VERSION=hq-9.9.9-f14"
if poll_log "prd-sync --session $sid --file $HQ_ROOT/companies/indigo/projects/other/prd.json"; then
  pass "f14 same-company switch: prd-sync invoked for other/prd.json"
else
  fail "f14 same-company switch: prd-sync missing. log=$(cat "$LOG" 2>/dev/null)"
fi
wait_sid_quiet "$sid"
if grep -F -q "bind-project" "$LOG"; then
  fail "f14 same-company switch: bind-project should not run; prd-sync rebinds. log=$(cat "$LOG")"
else
  pass "f14 same-company switch: no bind-project (cli prd-sync rebinds)"
fi

# --- F14: bound to A, same-company B/note.md stays skipped -------------------
sid=sid-f14-note
seed "$sid" bound indigo wm-smoke
reset_log
run_hook "$sid" Write "$HQ_ROOT/companies/indigo/projects/other/note.md" \
  "HQ_PRD_SYNC_SUPPORTED=yes HQ_STUB_VERSION=hq-9.9.9-f14"
wait_sid_quiet "$sid"
if [ ! -s "$LOG" ]; then
  pass "f14 other-project note.md: hq not invoked"
else
  fail "f14 other-project note.md: unexpected $(cat "$LOG")"
fi

# --- F14: bound to A, other-company prd.json stays skipped -------------------
sid=sid-f14-xco
seed "$sid" bound indigo wm-smoke
reset_log
run_hook "$sid" Write "$HQ_ROOT/companies/acme/projects/wm-smoke/prd.json" \
  "HQ_PRD_SYNC_SUPPORTED=yes HQ_STUB_VERSION=hq-9.9.9-f14"
wait_sid_quiet "$sid"
if [ ! -s "$LOG" ]; then
  pass "f14 cross-company prd.json: hq not invoked"
else
  fail "f14 cross-company prd.json: unexpected $(cat "$LOG")"
fi

# --- prd.json syncs only when the CLI supports it ----------------------------
sid=sid-prd-no
seed "$sid" needs_project indigo ""
reset_log
run_hook "$sid" Write "$HQ_ROOT/companies/indigo/projects/wm-smoke/prd.json" "HQ_PRD_SYNC_SUPPORTED=no"
if poll_log "bind-project wm-smoke"; then
  pass "prd unsupported: still binds"
else
  fail "prd unsupported: did not bind. log=$(cat "$LOG" 2>/dev/null)"
fi
wait_sid_quiet "$sid"
if grep -F -q "prd-sync --session" "$LOG"; then
  fail "prd unsupported: prd-sync was called: $(cat "$LOG")"
else
  pass "prd unsupported: prd-sync not called"
fi
# second write must reuse the cached probe (no extra --help)
helps_before=$(count_log "prd-sync --help")
run_hook "$sid" Write "$HQ_ROOT/companies/indigo/projects/wm-smoke/prd.json" "HQ_PRD_SYNC_SUPPORTED=no"
wait_sid_quiet "$sid"
helps_after=$(count_log "prd-sync --help")
if [ "$helps_after" = "$helps_before" ]; then
  pass "prd unsupported: probe cached (help calls stayed $helps_after)"
else
  fail "prd unsupported: probe not cached ($helps_before -> $helps_after)"
fi

sid=sid-prd-yes
seed "$sid" needs_project indigo ""
reset_log
run_hook "$sid" MultiEdit "$HQ_ROOT/companies/indigo/projects/wm-smoke/prd.json" "HQ_PRD_SYNC_SUPPORTED=yes HQ_STUB_VERSION=hq-9.9.9-prd-yes"
if poll_log "prd-sync --session $sid --file $HQ_ROOT/companies/indigo/projects/wm-smoke/prd.json"; then
  pass "prd supported: prd-sync called with the file"
else
  fail "prd supported: missing prd-sync. log=$(cat "$LOG" 2>/dev/null)"
fi
if poll_log "bind-project wm-smoke"; then
  pass "prd supported: also binds when needs_project"
else
  fail "prd supported: bind missing. log=$(cat "$LOG" 2>/dev/null)"
fi

# nested prd.json is not the project prd
sid=sid-prd-nested
seed "$sid" needs_project indigo ""
reset_log
run_hook "$sid" Write "$HQ_ROOT/companies/indigo/projects/wm-smoke/docs/prd.json" "HQ_PRD_SYNC_SUPPORTED=yes HQ_STUB_VERSION=hq-9.9.9-prd-yes"
wait_sid_quiet "$sid"
if grep -F -q "prd-sync --session" "$LOG"; then
  fail "nested prd: synced unexpectedly: $(cat "$LOG")"
else
  pass "nested prd: no prd-sync"
fi

# --- overlapping prd writes coalesce to one in-flight sync plus one rerun ---
sid=sid-prd-coalesce
seed "$sid" bound indigo wm-smoke
reset_log
_co_env="HQ_PRD_SYNC_SUPPORTED=yes HQ_STUB_SLEEP=2 HQ_STUB_VERSION=hq-9.9.9-prd-coalesce"
run_hook "$sid" Write "$HQ_ROOT/companies/indigo/projects/wm-smoke/prd.json" "$_co_env"
run_hook "$sid" Write "$HQ_ROOT/companies/indigo/projects/wm-smoke/prd.json" "$_co_env"
run_hook "$sid" Write "$HQ_ROOT/companies/indigo/projects/wm-smoke/prd.json" "$_co_env"
if poll_log "prd-sync --session"; then
  n=$(count_log "prd-sync --session")
else
  n=0
fi
[ "$n" = "1" ] && pass "prd coalesce: one flight while the first sync is running (calls=$n)" || fail "prd coalesce: calls while in flight=$n (want 1)"
start=$(date +%s)
n=$(count_log "prd-sync --session")
while [ "$n" -lt 2 ]; do
  now=$(date +%s)
  [ $((now - start)) -ge 5 ] && break
  sleep 0.05
  n=$(count_log "prd-sync --session")
done
[ "$n" = "2" ] && pass "prd coalesce: dirty flag reruns once (calls=$n)" || fail "prd coalesce: calls after settle=$n (want 2)"
wait_sid_quiet "$sid"
n=$(count_log "prd-sync --session")
[ "$n" = "2" ] && pass "prd coalesce: no further sync after the rerun (calls=$n)" || fail "prd coalesce: extra calls=$n"

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
