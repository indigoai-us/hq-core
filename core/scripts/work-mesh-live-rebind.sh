#!/usr/bin/env bash
# hq-core: public
# US-011 — enqueue session_end/session_start when project binding changes.
# Usage:
#   work-mesh-live-rebind.sh --session <sid>
#     Read state file and rebind if project changed vs live-binding marker.
#   work-mesh-live-rebind.sh --session <sid> \
#     --old-company C --old-project P [--old-task T] \
#     --company C2 --project P2 [--task T2]
set -euo pipefail

ROOT="${HQ_ROOT:-${CLAUDE_PROJECT_DIR:-}}"
if [ -z "$ROOT" ]; then
  ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fi
export HQ_ROOT="$ROOT"

# shellcheck source=lib/work-mesh-enqueue.sh
. "$ROOT/core/scripts/lib/work-mesh-enqueue.sh"
# shellcheck source=lib/work-mesh-live-hook.sh
. "$ROOT/core/scripts/lib/work-mesh-live-hook.sh" 2>/dev/null || true
# shellcheck source=lib/work-mesh-live-rebind.sh
. "$ROOT/core/scripts/lib/work-mesh-live-rebind.sh"

SID=""
OLD_CO="" OLD_PR="" OLD_TK=""
NEW_CO="" NEW_PR="" NEW_TK=""
FROM_STATE=0

while [ $# -gt 0 ]; do
  case "$1" in
    --session|--session-id) SID="${2:-}"; shift 2 ;;
    --old-company) OLD_CO="${2:-}"; shift 2 ;;
    --old-project) OLD_PR="${2:-}"; shift 2 ;;
    --old-task) OLD_TK="${2:-}"; shift 2 ;;
    --company|--company-slug) NEW_CO="${2:-}"; shift 2 ;;
    --project) NEW_PR="${2:-}"; shift 2 ;;
    --task) NEW_TK="${2:-}"; shift 2 ;;
    --from-state) FROM_STATE=1; shift ;;
    *) shift ;;
  esac
done

[ -n "$SID" ] || { echo "usage: work-mesh-live-rebind.sh --session <sid> ..." >&2; exit 1; }

if [ "$FROM_STATE" -eq 1 ] || [ -z "$NEW_PR" ]; then
  work_mesh_live_maybe_rebind_from_state "$SID"
else
  if [ -z "$OLD_PR" ]; then
    work_mesh_live_read_binding_marker "$SID"
    old=$REPLY
    OLD_CO="${old%%|*}"
    rest="${old#*|}"
    OLD_PR="${rest%%|*}"
    OLD_TK="${rest#*|}"
  fi
  work_mesh_live_rebind "$SID" "$OLD_CO" "$OLD_PR" "$OLD_TK" "$NEW_CO" "$NEW_PR" "$NEW_TK"
fi
exit 0
