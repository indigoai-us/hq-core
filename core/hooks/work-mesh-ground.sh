#!/usr/bin/env bash
# hq-core: public
# Company-bound substantive prompts: ground against the mesh. Never genesis here.
# Silent on stdout — master-hook captures it. Fail-soft.
set -uo pipefail
[ "${HQ_WORK_MESH_DISABLED:-}" = "1" ] && exit 0
STDIN_JSON="$(cat 2>/dev/null || echo '{}')"
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || exit 0
HQ_ROOT="${HQ_ROOT:-$(cd "$HOOK_DIR/../.." 2>/dev/null && pwd)}"
HELPER="$HQ_ROOT/core/scripts/work-mesh-session.sh"
[ -x "$HELPER" ] || exit 0
command -v node >/dev/null 2>&1 || exit 0
PROMPT="$(printf '%s' "$STDIN_JSON" | node -e 'let d="";process.stdin.on("data",c=>d+=c);process.stdin.on("end",()=>{try{const j=JSON.parse(d||"{}");process.stdout.write(String(j.prompt||""))}catch{}})')"
[ "${#PROMPT}" -lt 12 ] && exit 0
CO="$(bash "$HQ_ROOT/core/scripts/hq-session.sh" get company_slug 2>/dev/null || true)"
[ -z "$CO" ] && exit 0
case "$PROMPT" in
  /*) exit 0 ;;
esac
bash "$HELPER" ground --company "$CO" --prompt "$PROMPT" --json --silent >/dev/null 2>&1 || true
exit 0
