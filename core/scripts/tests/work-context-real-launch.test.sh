#!/usr/bin/env bash
# hq-core: public
# US-011 acceptance: binding paths for Work Mesh Live trusted context.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
PASS=0
FAIL=0
fail() { echo "FAIL: $*" >&2; FAIL=$((FAIL + 1)); }
pass() { echo "PASS: $*"; PASS=$((PASS + 1)); }

SESSION_START="$REPO_ROOT/core/hooks/SessionStart/35-work-mesh-session-start.sh"
TURN_START="$REPO_ROOT/core/hooks/UserPromptSubmit/35-work-mesh-turn-start.sh"
TURN_END="$REPO_ROOT/core/hooks/Stop/70-work-mesh-turn-end.sh"
BIND="$REPO_ROOT/core/scripts/work-mesh-live-bind-trusted.sh"
REBIND="$REPO_ROOT/core/scripts/work-mesh-live-rebind.sh"
AUTO="$REPO_ROOT/.claude/hooks/auto-session-project.sh"

for f in "$SESSION_START" "$TURN_START" "$TURN_END" "$BIND" "$REBIND" "$AUTO"; do
  [ -f "$f" ] || { echo "FATAL: missing $f" >&2; exit 1; }
done
command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required" >&2; exit 1; }

SANDBOX="$(mktemp -d)"
cleanup() { rm -rf "$SANDBOX" 2>/dev/null || true; }
trap cleanup EXIT

HOME_DIR="$SANDBOX/home"
HQ="$SANDBOX/hq"
mkdir -p "$HOME_DIR" "$HQ/workspace/sessions" "$HQ/core/scripts" "$HQ/core/hooks/SessionStart" "$HQ/companies/acme" "$HQ/companies/otherco" \
  "$HQ/.claude/hooks" "$SANDBOX/bin"
cp -R "$REPO_ROOT/core/scripts/lib" "$HQ/core/scripts/lib"
cp "$REPO_ROOT/core/scripts/hq-session.sh" "$HQ/core/scripts/"
cp "$REPO_ROOT/core/scripts/work-mesh-live-bind-trusted.sh" "$HQ/core/scripts/"
cp "$REPO_ROOT/core/scripts/work-mesh-live-rebind.sh" "$HQ/core/scripts/"
cp "$REPO_ROOT/core/scripts/hook-lib.sh" "$HQ/core/scripts/"
cp "$REPO_ROOT/.claude/hooks/auto-session-project.sh" "$HQ/.claude/hooks/"
chmod +x "$HQ/core/scripts/"*.sh "$HQ/.claude/hooks/"*.sh
# Point hooks at repo (enqueue lives in real tree via HQ_ROOT for hooks)
cat > "$HQ/companies/manifest.yaml" <<'YAML'
companies:
  acme:
    name: Acme
  otherco:
    name: Otherco
YAML

export HOME="$HOME_DIR"
export WORK_MESH_HOME="$HOME_DIR"
export WORK_MESH_SPOOL="$HOME_DIR/.hq/work-mesh/spool.jsonl"
export WORK_MESH_SEQ_DIR="$HOME_DIR/.hq/work-mesh/seq"
export HQ_WORK_MESH_RECONCILE_STUB=1
export HQ_RECONCILE_PID_FILE="$SANDBOX/reconcile.pids"
export HQ_HQ_SESSION_NO_CLI=1
unset HQ_WORK_MESH_DISABLED HQ_DISABLED_HOOKS || true
# This fixture supplies its own runtime IDs. Do not let the caller's live
# SessionStart environment leak into the test and relabel a synthetic session.
unset HQ_SESSION_ID HQ_PARENT_SESSION_ID HQ_SPAWN_COMPANY HQ_SPAWN_PROJECT HQ_SPAWN_TASK || true

cat > "$SANDBOX/bin/hq" <<'HQ'
#!/usr/bin/env bash
if [ "$1" = "mesh" ] && [ "$2" = "context" ] && [ "$3" = "default" ] && [ "$4" = "get" ] && [ "$5" = "--json" ]; then
  printf '%s\n' "${HQ_DEFAULT_COMPANY_JSON:-}"
elif [ "$1" = "mesh" ] && [ "$2" = "context" ] && [ "$3" = "reconcile" ]; then
  [ -z "${HQ_RECONCILE_PID_FILE:-}" ] || printf '%s\n' "$$" >> "$HQ_RECONCILE_PID_FILE"
  observation=""
  shift 3
  while [ $# -gt 0 ]; do
    case "$1" in
      --observation-file) observation="${2:-}"; shift 2 ;;
      *) shift ;;
    esac
  done
  if [ -n "${HQ_RECONCILE_CAPTURE:-}" ] && [ -n "$observation" ]; then
    cat "$observation" >> "$HQ_RECONCILE_CAPTURE"
  fi
  if [ "${HQ_RECONCILE_SLEEP:-0}" != "0" ]; then
    sleep "$HQ_RECONCILE_SLEEP"
  fi
  if [ "${HQ_RECONCILE_WRITE_STATE:-}" = "1" ] && [ -n "$observation" ]; then
    sid="$(jq -r '.identity.sessionId // empty' "$observation")"
    if [ -n "$sid" ]; then
      mkdir -p "${HQ_WORK_CONTEXT_ROOT}/sessions"
      printf '{"sessionId":"%s","contextStatus":"needs_project"}\n' "$sid" > "${HQ_WORK_CONTEXT_ROOT}/sessions/$sid.json"
    fi
  fi
  result="${HQ_RECONCILE_RESULT:-}"
  if [ -n "$observation" ] && command -v jq >/dev/null 2>&1; then
    sid="$(jq -r '.identity.sessionId // empty' "$observation")"
    op="$(jq -r '.clientOperationId // empty' "$observation")"
    result="$(printf '%s' "$result" | jq -c --arg sid "$sid" --arg op "$op" 'if type == "object" then .sessionId = $sid | .clientOperationId = $op else . end' 2>/dev/null || printf '%s' "$result")"
  fi
  printf '%s\n' "$result"
fi
HQ
chmod +x "$SANDBOX/bin/hq"

reset_spool() {
  if [ -f "$SANDBOX/reconcile.pids" ]; then
    while IFS= read -r reconcile_pid; do
      case "$reconcile_pid" in ''|*[!0-9]*) continue ;; esac
      retry=0
      while kill -0 "$reconcile_pid" 2>/dev/null && [ "$retry" -lt 200 ]; do
        sleep 0.05
        retry=$((retry + 1))
      done
    done < "$SANDBOX/reconcile.pids"
    : > "$SANDBOX/reconcile.pids"
  fi
  rm -rf "$HOME_DIR/.hq"
  mkdir -p "$HOME_DIR/.hq/work-mesh" "$HOME_DIR/.hq/work-context/sessions" "$WORK_MESH_SEQ_DIR"
  : >"$WORK_MESH_SPOOL"
}

# --- 1) Bound by skill (meta + trusted reconcile before turn_end) ---
reset_spool
SID=sid-skill-1
mkdir -p "$HQ/workspace/sessions/$SID"
printf '%s\n' "$SID" > "$HQ/workspace/sessions/.current"
export HQ_ROOT="$HQ"
export CLAUDE_PROJECT_DIR="$HQ"
export CLAUDE_CODE_SESSION_ID="$SID"
export HQ_WORK_MESH_RECONCILE_LOG="$SANDBOX/recon-skill.log"
: >"$HQ_WORK_MESH_RECONCILE_LOG"

# Skill bind writes meta + trusted observation (stubbed reconcile)
bash "$HQ/core/scripts/work-mesh-live-bind-trusted.sh" \
  --root "$HQ" --session "$SID" \
  --company acme --project work-mesh-live --task US-3

meta="$HQ/workspace/sessions/$SID/meta.yaml"
grep -q 'company_slug: acme' "$meta" && pass "skill wrote company_slug" || fail "meta company missing"
grep -q 'project: work-mesh-live' "$meta" && pass "skill wrote project" || fail "meta project missing"
grep -q 'task: US-3' "$meta" && pass "skill wrote task" || fail "meta task missing"
grep -q 'reconcile-trusted' "$HQ_WORK_MESH_RECONCILE_LOG" \
  && pass "skill triggered trusted reconcile observation" \
  || fail "no trusted reconcile log"

# Binding exists before first turn_end
env HOME="$HOME" WORK_MESH_HOME="$WORK_MESH_HOME" WORK_MESH_SPOOL="$WORK_MESH_SPOOL" \
  WORK_MESH_SEQ_DIR="$WORK_MESH_SEQ_DIR" HQ_ROOT="$REPO_ROOT" HQ_WORK_MESH_RECONCILE_STUB=1 \
  CLAUDE_CODE_SESSION_ID="$SID" \
  bash "$TURN_END" <<<"{\"session_id\":\"$SID\"}" >/dev/null
# Assert meta still bound at turn_end time
grep -q 'project: work-mesh-live' "$meta" \
  && pass "binding present before/at first turn_end" \
  || fail "binding lost at turn_end"

# --- 2) Bound by dispatch envelope (HQ_SPAWN_*) ---
reset_spool
SID=sid-spawn-1
export HQ_SPAWN_COMPANY=acme
export HQ_SPAWN_PROJECT=dispatch-proj
export HQ_SPAWN_TASK=US-9
export CLAUDE_CODE_SESSION_ID="$SID"
export HQ_ROOT="$REPO_ROOT"
env HOME="$HOME" WORK_MESH_HOME="$WORK_MESH_HOME" WORK_MESH_SPOOL="$WORK_MESH_SPOOL" \
  WORK_MESH_SEQ_DIR="$WORK_MESH_SEQ_DIR" HQ_ROOT="$REPO_ROOT" HQ_WORK_MESH_RECONCILE_STUB=1 \
  HQ_SPAWN_COMPANY=acme HQ_SPAWN_PROJECT=dispatch-proj HQ_SPAWN_TASK=US-9 \
  CLAUDE_CODE_SESSION_ID="$SID" \
  bash "$SESSION_START" <<<"{\"session_id\":\"$SID\",\"cwd\":\"/tmp\"}" >/dev/null
line="$(tail -n1 "$WORK_MESH_SPOOL")"
echo "$line" | jq -e '.kind=="session_start" and .companySlug=="acme" and .project=="dispatch-proj" and .task=="US-9"' >/dev/null \
  && pass "dispatch envelope binds session_start" \
  || fail "spawn bind: $line"
# trustedContext in reconcile path: marker written
[ -f "$HOME_DIR/.hq/work-context/sessions/$SID.live-binding" ] \
  && grep -q 'project=dispatch-proj' "$HOME_DIR/.hq/work-context/sessions/$SID.live-binding" \
  && pass "spawn wrote live-binding marker" \
  || fail "spawn live-binding missing"
unset HQ_SPAWN_COMPANY HQ_SPAWN_PROJECT HQ_SPAWN_TASK

# --- 2b) SessionStart binds an enabled human device default ---
reset_spool
SID=sid-device-default-1
cp "$SESSION_START" "$HQ/core/hooks/SessionStart/"
chmod +x "$HQ/core/hooks/SessionStart/35-work-mesh-session-start.sh"
env PATH="$SANDBOX/bin:$PATH" HOME="$HOME" WORK_MESH_HOME="$WORK_MESH_HOME" WORK_MESH_SPOOL="$WORK_MESH_SPOOL" \
  WORK_MESH_SEQ_DIR="$WORK_MESH_SEQ_DIR" HQ_ROOT="$HQ" HQ_WORK_MESH_RECONCILE_STUB=0 \
  HQ_RECONCILE_RESULT='{"contractVersion":1,"kind":"needs_project","classification":"needs_project","delivery":"queued","lifecycle":"open","sessionId":"sid-device-default-1","clientOperationId":"op-device-default","companySlug":"acme","companyUid":"cmp_acme"}' \
  HQ_DEFAULT_COMPANY_JSON='{"ok":true,"slug":"acme","enabled":true,"needsChoice":false,"source":"configured"}' \
  CLAUDE_CODE_SESSION_ID="$SID" \
  bash "$HQ/core/hooks/SessionStart/35-work-mesh-session-start.sh" <<<"{\"session_id\":\"$SID\",\"cwd\":\"/tmp\"}" >/dev/null
line="$(tail -n1 "$WORK_MESH_SPOOL")"
if echo "$line" | jq -e '.kind=="session_start" and .companySlug=="acme"' >/dev/null; then
  fail "device default was promoted into session_start companySlug: $line"
else
  pass "device default remains outside trusted session_start context"
fi
grep -qx 'company_source: device_default' "$HQ/workspace/sessions/$SID/meta.yaml" \
  && pass "SessionStart records device_default source" \
  || fail "device-default source missing from SessionStart meta"

# --- 2c) conflicting cwd wins over a device default before scope minting ---
reset_spool
SID=sid-device-default-conflict
capture="$SANDBOX/device-default-conflict-observations.jsonl"
: > "$capture"
err="$SANDBOX/device-default-conflict.err"
env PATH="$SANDBOX/bin:$PATH" HOME="$HOME" WORK_MESH_HOME="$WORK_MESH_HOME" WORK_MESH_SPOOL="$WORK_MESH_SPOOL" \
  WORK_MESH_SEQ_DIR="$WORK_MESH_SEQ_DIR" HQ_ROOT="$HQ" HQ_RECONCILE_CAPTURE="$capture" \
  HQ_WORK_MESH_RECONCILE_STUB=0 \
  HQ_RECONCILE_RESULT='{
    "contractVersion": 1,
    "kind": "company_conflict",
    "classification": "company_conflict",
    "delivery": "clean",
    "lifecycle": "open",
    "sessionId": "sid-device-default-conflict",
    "clientOperationId": "op-company-conflict"
  }' \
  HQ_DEFAULT_COMPANY_JSON='{"ok":true,"slug":"acme","enabled":true,"needsChoice":false,"source":"configured"}' \
  CLAUDE_CODE_SESSION_ID="$SID" \
  bash "$HQ/core/hooks/SessionStart/35-work-mesh-session-start.sh" \
  <<<"{\"session_id\":\"$SID\",\"cwd\":\"$HQ/companies/otherco/projects/x\"}" >/dev/null 2>"$err"
[ ! -f "$HQ/workspace/sessions/$SID/meta.yaml" ] \
  && pass "cwd conflict leaves device-default session unbound" \
  || fail "cwd conflict wrote a device-default meta binding"
line="$(tail -n1 "$WORK_MESH_SPOOL")"
echo "$line" | jq -e 'has("companySlug") | not' >/dev/null \
  && pass "cwd conflict does not enqueue default company" \
  || fail "cwd conflict enqueued default company: $line"
jq -e --arg cwd "$HQ/companies/otherco/projects/x" \
  '.cwd==$cwd and ((.trustedContext // {}) | has("companySlug") | not)' "$capture" >/dev/null \
  && pass "resolver receives cwd without a trusted device default" \
  || fail "resolver observation trusted the device default"
grep -q 'company_conflict; leaving device-default session unbound' "$err" \
  && pass "cwd conflict emits one-line notice" \
  || fail "cwd conflict notice missing"

# --- 2d) failed or noncanonical preflight never promotes the device default ---
for preflight_case in garbage timeout; do
  reset_spool
  SID="sid-device-default-$preflight_case"
  err="$SANDBOX/device-default-$preflight_case.err"
  reconcile_result='not json at all'
  reconcile_sleep=0
  if [ "$preflight_case" = "timeout" ]; then
    reconcile_result='{"contractVersion":1,"kind":"needs_project","classification":"needs_project","delivery":"queued","lifecycle":"open","sessionId":"sid-device-default-timeout","clientOperationId":"op-timeout"}'
    reconcile_sleep=5
  fi
  env PATH="$SANDBOX/bin:$PATH" HOME="$HOME" WORK_MESH_HOME="$WORK_MESH_HOME" WORK_MESH_SPOOL="$WORK_MESH_SPOOL" \
    WORK_MESH_SEQ_DIR="$WORK_MESH_SEQ_DIR" HQ_ROOT="$HQ" HQ_WORK_CONTEXT_ROOT="$HOME_DIR/.hq/work-context" \
    HQ_WORK_MESH_RECONCILE_STUB=0 HQ_RECONCILE_RESULT="$reconcile_result" HQ_RECONCILE_SLEEP="$reconcile_sleep" \
    HQ_DEFAULT_COMPANY_JSON='{"ok":true,"slug":"acme","enabled":true,"needsChoice":false,"source":"configured"}' \
    CLAUDE_CODE_SESSION_ID="$SID" \
    bash "$HQ/core/hooks/SessionStart/35-work-mesh-session-start.sh" \
    <<<"{\"session_id\":\"$SID\",\"cwd\":\"/tmp\"}" >/dev/null 2>"$err"
  [ ! -f "$HQ/workspace/sessions/$SID/meta.yaml" ] \
    && pass "$preflight_case preflight leaves device-default session unbound" \
    || fail "$preflight_case preflight wrote a device-default meta binding"
  grep -q 'preflight unresolved; leaving device-default session unbound' "$err" \
    && pass "$preflight_case preflight emits one-line notice" \
    || fail "$preflight_case preflight notice missing"
done

# --- 2d2) no configured default is intentionally silent ---
reset_spool
SID=sid-device-default-none
err="$SANDBOX/device-default-none.err"
env PATH="$SANDBOX/bin:$PATH" HOME="$HOME" WORK_MESH_HOME="$WORK_MESH_HOME" WORK_MESH_SPOOL="$WORK_MESH_SPOOL" \
  WORK_MESH_SEQ_DIR="$WORK_MESH_SEQ_DIR" HQ_ROOT="$HQ" HQ_WORK_CONTEXT_ROOT="$HOME_DIR/.hq/work-context" \
  HQ_WORK_MESH_RECONCILE_STUB=0 \
  HQ_RECONCILE_RESULT='{"contractVersion":1,"kind":"needs_company","classification":"needs_company","delivery":"clean","lifecycle":"open","sessionId":"placeholder","clientOperationId":"placeholder"}' \
  HQ_DEFAULT_COMPANY_JSON='{"ok":true,"enabled":false,"needsChoice":false,"source":"disabled"}' \
  CLAUDE_CODE_SESSION_ID="$SID" \
  bash "$HQ/core/hooks/SessionStart/35-work-mesh-session-start.sh" \
  <<<"{\"session_id\":\"$SID\"}" >/dev/null 2>"$err"
[ ! -s "$err" ] && pass "no-default preflight stays silent" || fail "no-default preflight wrote stderr"
[ ! -f "$HQ/workspace/sessions/$SID/meta.yaml" ] && pass "no-default preflight writes no binding" || fail "no-default preflight wrote binding"

# --- 2e) a new session stays eligible when preflight creates local state ---
reset_spool
SID=sid-device-default-preflight-state
env PATH="$SANDBOX/bin:$PATH" HOME="$HOME" WORK_MESH_HOME="$WORK_MESH_HOME" WORK_MESH_SPOOL="$WORK_MESH_SPOOL" \
  WORK_MESH_SEQ_DIR="$WORK_MESH_SEQ_DIR" HQ_ROOT="$HQ" HQ_WORK_CONTEXT_ROOT="$HOME_DIR/.hq/work-context" \
  HQ_WORK_MESH_RECONCILE_STUB=0 HQ_RECONCILE_WRITE_STATE=1 \
  HQ_RECONCILE_RESULT='{"contractVersion":1,"kind":"needs_project","classification":"needs_project","delivery":"queued","lifecycle":"open","sessionId":"sid-device-default-preflight-state","clientOperationId":"op-preflight-state","companySlug":"acme","companyUid":"cmp_acme"}' \
  HQ_DEFAULT_COMPANY_JSON='{"ok":true,"slug":"acme","enabled":true,"needsChoice":false,"source":"configured"}' \
  CLAUDE_CODE_SESSION_ID="$SID" \
  bash "$HQ/core/hooks/SessionStart/35-work-mesh-session-start.sh" \
  <<<"{\"session_id\":\"$SID\",\"cwd\":\"/tmp\"}" >/dev/null
grep -qx 'company_slug: acme' "$HQ/workspace/sessions/$SID/meta.yaml" \
  && pass "preflight-created state does not block new-session meta binding" \
  || fail "preflight-created state blocked new-session meta binding"
jq -e '.company_slug == "acme"' "$HQ/workspace/sessions/$SID/scope-capability.json" >/dev/null \
  && pass "preflight-created state does not block new-session scope binding" \
  || fail "preflight-created state blocked new-session scope binding"

# --- 3) Deterministic cwd mapping stays a reconcile concern; hooks pass cwd ---
reset_spool
SID=sid-cwd-1
export CLAUDE_CODE_SESSION_ID="$SID"
env HOME="$HOME" WORK_MESH_HOME="$WORK_MESH_HOME" WORK_MESH_SPOOL="$WORK_MESH_SPOOL" \
  WORK_MESH_SEQ_DIR="$WORK_MESH_SEQ_DIR" HQ_ROOT="$REPO_ROOT" HQ_WORK_MESH_RECONCILE_STUB=1 \
  CLAUDE_CODE_SESSION_ID="$SID" \
  bash "$SESSION_START" <<<"{\"session_id\":\"$SID\",\"cwd\":\"$REPO_ROOT/companies/acme/projects/x\"}" >/dev/null
line="$(tail -n1 "$WORK_MESH_SPOOL")"
echo "$line" | jq -e --arg cwd "$REPO_ROOT/companies/acme/projects/x" \
  '.kind=="session_start" and .cwd==$cwd and (has("project")|not)' >/dev/null \
  && pass "deterministic cwd recorded; no invented project on hook" \
  || fail "cwd mapping: $line"

# --- 4) Ambiguous stays unresolved (auto-session-project quiet; no project) ---
reset_spool
SID=sid-amb-1
mkdir -p "$HOME_DIR/.hq/work-context/sessions"
cat > "$HOME_DIR/.hq/work-context/sessions/$SID.json" <<'JSON'
{"contractVersion":1,"sessionId":"sid-amb-1","contextStatus":"needs_project","updatedAt":"2026-09-04T00:00:00Z"}
JSON
out="$(env HOME="$HOME" WORK_MESH_HOME="$WORK_MESH_HOME" HQ_ROOT="$HQ" CLAUDE_PROJECT_DIR="$HQ" \
  "$HQ/.claude/hooks/auto-session-project.sh" \
  <<<"{\"session_id\":\"$SID\",\"prompt\":\"please continue the implementation work\"}" 2>/dev/null || true)"
[ -z "$out" ] && pass "ambiguous/needs_project stays unresolved (shim quiet)" \
  || fail "ambiguous produced context: $out"
[ ! -d "$HQ/companies/acme/projects/please-continue" ] \
  && pass "ambiguous did not create a project folder" \
  || fail "ambiguous created project"

# --- 5) Misfile regression via auto-session-project ---
out="$(env HOME="$HOME" WORK_MESH_HOME="$WORK_MESH_HOME" HQ_ROOT="$HQ" CLAUDE_PROJECT_DIR="$HQ" \
  "$HQ/.claude/hooks/auto-session-project.sh" \
  <<<"{\"session_id\":\"sid-mis\",\"prompt\":\"walk through how the work mesh is set up\"}" 2>/dev/null || true)"
[ -z "$out" ] && pass "misfile walkthrough quiet" || fail "misfile not quiet: $out"

# --- 6) Rebind: session_end old + session_start new ---
reset_spool
SID=sid-rebind-1
export CLAUDE_CODE_SESSION_ID="$SID" HQ_ROOT="$REPO_ROOT"
# Seed marker with old project
mkdir -p "$HOME_DIR/.hq/work-context/sessions"
printf 'companySlug=acme\nproject=old-proj\ntask=US-1\n' \
  > "$HOME_DIR/.hq/work-context/sessions/$SID.live-binding"
# State now bound to new project (as organize would write)
cat > "$HOME_DIR/.hq/work-context/sessions/$SID.json" <<'JSON'
{
  "contractVersion": 1,
  "sessionId": "sid-rebind-1",
  "contextStatus": "bound",
  "companySlug": "acme",
  "projectId": "new-proj",
  "taskId": "US-2",
  "updatedAt": "2026-09-04T00:00:00Z"
}
JSON
env HOME="$HOME" WORK_MESH_HOME="$WORK_MESH_HOME" WORK_MESH_SPOOL="$WORK_MESH_SPOOL" \
  WORK_MESH_SEQ_DIR="$WORK_MESH_SEQ_DIR" HQ_ROOT="$REPO_ROOT" \
  CLAUDE_CODE_SESSION_ID="$SID" \
  bash "$REBIND" --session "$SID" --from-state
# Expect session_end then session_start
# Filter kinds
kinds="$(jq -r '.kind' "$WORK_MESH_SPOOL")"
printf '%s\n' "$kinds" | grep -qx 'session_end' || true
echo "$kinds" | head -n1 | grep -q session_end \
  && pass "rebind first line session_end" \
  || fail "rebind kinds: $kinds"
echo "$kinds" | tail -n1 | grep -q session_start \
  && pass "rebind last line session_start" \
  || fail "rebind missing session_start: $kinds"
jq -e 'select(.kind=="session_end" and .project=="old-proj")' "$WORK_MESH_SPOOL" >/dev/null \
  && pass "session_end carries old project" || fail "old project missing on end"
jq -e 'select(.kind=="session_start" and .project=="new-proj" and .task=="US-2")' "$WORK_MESH_SPOOL" >/dev/null \
  && pass "session_start carries new project" || fail "new project missing on start"

# Also: turn_start triggers maybe_rebind
reset_spool
SID=sid-rebind-2
printf 'companySlug=acme\nproject=alpha\ntask=\n' \
  > "$HOME_DIR/.hq/work-context/sessions/$SID.live-binding"
cat > "$HOME_DIR/.hq/work-context/sessions/$SID.json" <<'JSON'
{"contractVersion":1,"sessionId":"sid-rebind-2","contextStatus":"bound","companySlug":"acme","projectId":"beta","updatedAt":"2026-09-04T00:00:00Z"}
JSON
env HOME="$HOME" WORK_MESH_HOME="$WORK_MESH_HOME" WORK_MESH_SPOOL="$WORK_MESH_SPOOL" \
  WORK_MESH_SEQ_DIR="$WORK_MESH_SEQ_DIR" HQ_ROOT="$REPO_ROOT" HQ_WORK_MESH_RECONCILE_STUB=1 \
  CLAUDE_CODE_SESSION_ID="$SID" \
  bash "$TURN_START" <<<"{\"session_id\":\"$SID\",\"prompt\":\"please continue the implementation work\"}" >/dev/null
jq -e 'select(.kind=="session_end" and .project=="alpha")' "$WORK_MESH_SPOOL" >/dev/null \
  && pass "turn_start rebind emits session_end" || fail "turn_start no session_end"
jq -e 'select(.kind=="session_start" and .project=="beta")' "$WORK_MESH_SPOOL" >/dev/null \
  && pass "turn_start rebind emits session_start" || fail "turn_start no session_start"

# --- HQ_SPAWN export present in hq-agent-session.sh ---
grep -q 'export HQ_SPAWN_COMPANY=' "$REPO_ROOT/core/scripts/hq-agent-session.sh" \
  && grep -q 'export HQ_SPAWN_PROJECT=' "$REPO_ROOT/core/scripts/hq-agent-session.sh" \
  && grep -q 'export HQ_SPAWN_TASK=' "$REPO_ROOT/core/scripts/hq-agent-session.sh" \
  && pass "hq-agent-session exports HQ_SPAWN_*" \
  || fail "HQ_SPAWN exports missing"

# --- Skills reference shared bind ---
for s in startwork execute-task run-project plan brainstorm deep-plan; do
  if grep -q 'work-mesh-live-bind' "$REPO_ROOT/.claude/skills/$s/SKILL.md"; then
    pass "skill $s references trusted bind"
  else
    fail "skill $s missing trusted bind reference"
  fi
done

echo
echo "work-context-real-launch: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
