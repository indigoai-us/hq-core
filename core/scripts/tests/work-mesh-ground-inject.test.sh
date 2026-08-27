#!/usr/bin/env bash
# Injects live Board from work-mesh-ground; never orients from local prd.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

mkdir -p "$TMP/core/hooks" "$TMP/core/scripts" "$TMP/companies/indigo/projects/work-desktop-dogfood"
cp "$ROOT/core/hooks/work-mesh-ground.sh" "$TMP/core/hooks/work-mesh-ground.sh"
cp "$ROOT/core/scripts/hook-lib.sh" "$TMP/core/scripts/hook-lib.sh"
chmod +x "$TMP/core/hooks/work-mesh-ground.sh"

cat > "$TMP/companies/manifest.yaml" <<'YAML'
companies:
  indigo:
    name: Indigo
YAML

cat > "$TMP/core/scripts/hq-session.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$TMP/core/scripts/hq-session.sh"

cat > "$TMP/core/scripts/work-mesh-session.sh" <<'SH'
#!/usr/bin/env bash
# Stub helper: emit a Board with one in_progress and one queued story.
cat <<'JSON'
{"ok":true,"action":"ground","projectId":"work-desktop-dogfood","bound":true,"stories":[{"id":"US-001","title":"Live row","status":"in_progress"},{"id":"US-004","title":"Queued row","status":"queued"}]}
JSON
SH
chmod +x "$TMP/core/scripts/work-mesh-session.sh"

payload='{"hook_event_name":"UserPromptSubmit","prompt":"I want to start work in the work desktop dogfood project please"}'
out="$(HQ_ROOT="$TMP" bash "$TMP/core/hooks/work-mesh-ground.sh" <<<"$payload")"
echo "$out" | grep -q 'LIVE WORK MESH BOARD' || fail "hook did not inject Board"
echo "$out" | grep -q 'in_progress US-001' || fail "hook missing live in_progress row"
echo "$out" | grep -q 'queued US-004' || fail "hook missing queued row"
echo "$out" | grep -q 'prd.passes is not status' || fail "hook missing prd fallback warning"
echo "$out" | grep -q 'additionalContext' || fail "hook did not wrap additionalContext"
[ -f "$TMP/.claude/state/work-mesh-board" ] || fail "hook did not write .claude/state/work-mesh-board"
grep -q 'in_progress US-001' "$TMP/.claude/state/work-mesh-board" || fail "state snapshot missing live row"

out_off="$(HQ_ROOT="$TMP" HQ_WORK_MESH_DISABLED=1 bash "$TMP/core/hooks/work-mesh-ground.sh" <<<"$payload")"
[ -z "$out_off" ] || fail "disabled hook must stay silent"

cat > "$TMP/core/scripts/work-mesh-session.sh" <<'SH'
#!/usr/bin/env bash
exit 1
SH
chmod +x "$TMP/core/scripts/work-mesh-session.sh"
out_fail="$(HQ_ROOT="$TMP" bash "$TMP/core/hooks/work-mesh-ground.sh" <<<"$payload")"
[ -z "$out_fail" ] || fail "failed helper must stay silent (local prd is the fallback, not a noisy inject)"

echo "ok work-mesh-ground-inject"
