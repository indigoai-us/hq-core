#!/usr/bin/env bash
# hq-core: public
# US-003/004 helper contract (no live mesh required for these cases).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
HELPER="$ROOT/core/scripts/work-mesh.sh"
HOOK="$ROOT/core/hooks/work-mesh-ground.sh"

export HQ_WORK_MESH_DISABLED=1
out="$(bash "$HELPER" ground --company indigo --json)"
echo "$out" | grep -q '"skipped":true'

unset HQ_WORK_MESH_DISABLED
out="$(bash "$HELPER" ground --company indigo --create wm-auto-nope --json --silent)"
echo "$out" | grep -q 'create requires --confirm'

help_out="$(bash "$HELPER" help)"
echo "$help_out" | grep -q 'ground'
echo "$help_out" | grep -q -- '--task-title'
echo "$help_out" | grep -q -- '--confirm'

HQ_ROOT="$ROOT" HQ_WORK_MESH_DISABLED=1 bash "$HOOK" </dev/null
echo "ok work-mesh-ground"
