#!/usr/bin/env bash
# hq-core: public
# Session end: report done for the CURRENT session's bound project.
# Shared-Done is enforced in the helper. Silent on stdout. Fail-soft.
set -uo pipefail
[ "${HQ_WORK_MESH_DISABLED:-}" = "1" ] && exit 0
case ",${HQ_DISABLED_HOOKS:-}," in
  *,work-mesh-done,*) exit 0 ;;
esac
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || exit 0
HQ_ROOT="${HQ_ROOT:-$(cd "$HOOK_DIR/../.." 2>/dev/null && pwd)}"
HELPER="$HQ_ROOT/core/scripts/work-mesh-session.sh"
[ -x "$HELPER" ] || exit 0
SESSION_SH="$HQ_ROOT/core/scripts/hq-session.sh"
[ -f "$SESSION_SH" ] || exit 0

CO="$(bash "$SESSION_SH" get company_slug 2>/dev/null || true)"
CO="$(printf '%s' "$CO" | tr -d '[:space:]"')"
[ -z "$CO" ] && exit 0

# The project MUST come from THIS session's own workspace/sessions/<id>/meta.yaml.
# It used to be read from the machine-global ~/.hq/work-mesh/cache/sessions-bind.json,
# a single PID-keyed record, so every Stop in any session reported against
# whatever project was last bound anywhere on this machine (cross-session
# misattribution). No project binding on this session => report nothing.
PROJ="$(bash "$SESSION_SH" get project 2>/dev/null || true)"
PROJ="$(printf '%s' "$PROJ" | tr -d '[:space:]"')"
[ -z "$PROJ" ] && exit 0

TASK="$(bash "$SESSION_SH" get task 2>/dev/null || true)"
TASK="$(printf '%s' "$TASK" | tr -d '[:space:]"')"

if [ -n "$TASK" ]; then
  bash "$HELPER" report --company "$CO" --project "$PROJ" --story "$TASK" \
    --status done --silent >/dev/null 2>&1 || true
else
  bash "$HELPER" report --company "$CO" --project "$PROJ" \
    --status done --silent >/dev/null 2>&1 || true
fi
exit 0
