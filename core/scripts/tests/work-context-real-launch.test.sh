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
mkdir -p "$HOME_DIR" "$HQ/workspace/sessions" "$HQ/core/scripts" "$HQ/companies/acme" \
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
YAML

export HOME="$HOME_DIR"
export WORK_MESH_HOME="$HOME_DIR"
export WORK_MESH_SPOOL="$HOME_DIR/.hq/work-mesh/spool.jsonl"
export WORK_MESH_SEQ_DIR="$HOME_DIR/.hq/work-mesh/seq"
export HQ_WORK_MESH_RECONCILE_STUB=1
export HQ_HQ_SESSION_NO_CLI=1
unset HQ_WORK_MESH_DISABLED HQ_DISABLED_HOOKS || true

reset_spool() {
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
mapfile -t lines < "$WORK_MESH_SPOOL"
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
