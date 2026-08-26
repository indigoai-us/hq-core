#!/usr/bin/env bash
# Runtime adapter entry: ground / task-title / done via work-mesh.sh.
# Fail-soft. Never genesis without --confirm (callers must pass it explicitly).
set -uo pipefail
HQ_ROOT="${HQ_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
HELPER="$HQ_ROOT/core/scripts/work-mesh.sh"
[ -x "$HOME/.hq/work-mesh/bin/work-mesh.sh" ] && HELPER="$HOME/.hq/work-mesh/bin/work-mesh.sh"
[ -x "$HELPER" ] || exit 0
[ "${HQ_WORK_MESH_DISABLED:-}" = "1" ] && exit 0
exec bash "$HELPER" "$@"
