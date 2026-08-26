#!/usr/bin/env bash
# hq-core: public
# Session end: report done for the bound task. Shared-Done is enforced in the helper.
# Silent on stdout. Fail-soft.
set -uo pipefail
[ "${HQ_WORK_MESH_DISABLED:-}" = "1" ] && exit 0
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || exit 0
HQ_ROOT="${HQ_ROOT:-$(cd "$HOOK_DIR/../.." 2>/dev/null && pwd)}"
HELPER="$HQ_ROOT/core/scripts/work-mesh-session.sh"
[ -x "$HELPER" ] || exit 0
CO="$(bash "$HQ_ROOT/core/scripts/hq-session.sh" get company_slug 2>/dev/null || true)"
[ -z "$CO" ] && exit 0
PROJ="$(node -e 'const fs=require("fs");const p=process.env.HOME+"/.hq/work-mesh/cache/sessions-bind.json";try{const j=JSON.parse(fs.readFileSync(p,"utf8"));process.stdout.write(String(j.projectId||""))}catch(e){}' 2>/dev/null || true)"
[ -z "$PROJ" ] && exit 0
bash "$HELPER" report --company "$CO" --project "$PROJ" --status done --silent >/dev/null 2>&1 || true
exit 0
