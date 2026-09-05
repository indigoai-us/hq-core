#!/usr/bin/env bash
# US-011 — auto-session-project is a shim: never selects/creates from prompts.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_empty() {
  local value="$1" label="$2"
  [ -z "$value" ] || fail "$label: expected empty, got: $value"
}
assert_contains() {
  local haystack="$1" needle="$2" label="$3"
  [[ "$haystack" == *"$needle"* ]] || fail "$label: missing '$needle'"
}

mkdir -p "$TMP/.claude/hooks" "$TMP/core/scripts" "$TMP/companies/acme/projects" \
  "$TMP/workspace/sessions" "$TMP/home/.hq/work-context/sessions"
cp "$ROOT/.claude/hooks/auto-session-project.sh" "$TMP/.claude/hooks/"
cp "$ROOT/core/scripts/hook-lib.sh" "$TMP/core/scripts/"
cp "$ROOT/core/scripts/resolve-company.sh" "$TMP/core/scripts/"
chmod +x "$TMP/.claude/hooks/auto-session-project.sh" "$TMP/core/scripts/resolve-company.sh"

cat > "$TMP/companies/manifest.yaml" <<'YAML'
companies:
  acme:
    name: Acme
YAML

unset HQ_SESSION_ID CLAUDE_CODE_SESSION_ID CLAUDE_SESSION_ID CODEX_SESSION_ID CODEX_THREAD_ID
export HQ_HQ_SESSION_NO_CLI=1
export HQ_ROOT="$TMP"
export CLAUDE_PROJECT_DIR="$TMP"
export HOME="$TMP/home"
export WORK_MESH_HOME="$TMP/home"

run_hook() {
  local payload="$1"
  CLAUDE_PROJECT_DIR="$TMP" HQ_ROOT="$TMP" HOME="$HOME" WORK_MESH_HOME="$WORK_MESH_HOME" \
    "$TMP/.claude/hooks/auto-session-project.sh" <<<"$payload" 2>/dev/null || true
}

# --- Misfile regression (2026-09-01) + ok + version: no project, no company ---
for prompt in \
  "walk through how the work mesh is set up" \
  "ok really will fix sync try now please" \
  "version check please run now" \
  "ok" \
  "version"
do
  sid="misfile-$(printf '%s' "$prompt" | cksum | awk '{print $1}')"
  out="$(run_hook "{\"session_id\":\"$sid\",\"prompt\":$(printf '%s' "$prompt" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')}")"
  assert_empty "$out" "unbound prompt must be quiet ($prompt)"
  # No project dirs created under companies from classifier
  found="$(find "$TMP/companies" -mindepth 3 -maxdepth 3 -type d 2>/dev/null | grep -v '/acme/projects$' || true)"
  [ -z "$found" ] || fail "prompt created project dirs: $found ($prompt)"
  [ ! -d "$TMP/companies/ok" ] || fail "ghost companies/ok must not be created"
done
echo "PASS: misfile/ok/version prompts choose no project and no company"

# --- Unresolved / needs_project state: still quiet, no mkdir ---
mkdir -p "$TMP/home/.hq/work-context/sessions"
cat > "$TMP/home/.hq/work-context/sessions/sid-unresolved.json" <<'JSON'
{
  "contractVersion": 1,
  "sessionId": "sid-unresolved",
  "contextStatus": "unresolved",
  "updatedAt": "2026-09-04T00:00:00Z"
}
JSON
out="$(run_hook '{"session_id":"sid-unresolved","prompt":"please implement the feature carefully now"}')"
assert_empty "$out" "unresolved state stays quiet"
[ ! -d "$TMP/companies/acme/projects/please-implement" ] || fail "must not create from prompt under unresolved"

# --- Bound: ensure local folder + materialize prd from board.md ---
mkdir -p "$TMP/home/.hq/work-context/sessions/sid-bound"
cat > "$TMP/home/.hq/work-context/sessions/sid-bound.json" <<'JSON'
{
  "contractVersion": 1,
  "sessionId": "sid-bound",
  "contextStatus": "bound",
  "companySlug": "acme",
  "companyUid": "cmp_acme",
  "projectId": "atlas-live",
  "taskId": "US-3",
  "updatedAt": "2026-09-04T00:00:00Z"
}
JSON
cat > "$TMP/home/.hq/work-context/sessions/sid-bound/board.md" <<'MD'
# Board snapshot
- projectId: atlas-live
- projectName: Atlas Live
## Stories
- US-1 [done] — First
- US-3 [in_progress] — Third
MD
out="$(run_hook '{"session_id":"sid-bound","prompt":"continue"}')"
assert_contains "$out" "companies/acme/projects/atlas-live" "bound context mentions local project"
[ -f "$TMP/companies/acme/projects/atlas-live/prd.json" ] || fail "prd.json not materialized"
python3 - "$TMP/companies/acme/projects/atlas-live/prd.json" <<'PY' || fail "prd stories missing"
import json,sys
prd=json.load(open(sys.argv[1]))
ids=[s.get("id") for s in prd.get("userStories",[])]
assert "US-1" in ids and "US-3" in ids, ids
assert prd.get("metadata",{}).get("origin")=="work-mesh-live-board"
print("ok")
PY
echo "PASS: bound session materializes local prd from board"

# --- Bound but unregistered company: no ghost tenant ---
cat > "$TMP/home/.hq/work-context/sessions/sid-ghost.json" <<'JSON'
{
  "contractVersion": 1,
  "sessionId": "sid-ghost",
  "contextStatus": "bound",
  "companySlug": "ghostco",
  "projectId": "nope",
  "updatedAt": "2026-09-04T00:00:00Z"
}
JSON
out="$(run_hook '{"session_id":"sid-ghost","prompt":"continue work please now"}')"
assert_empty "$out" "unregistered company bound state is quiet"
[ ! -d "$TMP/companies/ghostco" ] || fail "must not mkdir unregistered company"

# --- Disabled env ---
out="$(HQ_AUTO_SESSION_PROJECT=0 run_hook '{"session_id":"sid-bound","prompt":"x"}')"
assert_empty "$out" "disabled env quiet"

echo "auto-session-project US-011 shim: ok"
