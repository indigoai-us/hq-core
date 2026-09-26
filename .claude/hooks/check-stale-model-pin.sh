#!/bin/bash
# check-stale-model-pin.sh — SessionStart hook
#
# Warns when HQ is pinned to an out-of-date model after a newer one ships.
#
# Pins it checks:
#   - conduct.child_defaults[].children.model in orchestrator.yaml
#     (personal/settings wins over core/settings)
#   - HQ_WORKFLOW_*MODEL variables exported in the launching shell
# Catalog: core/settings/current-models.yaml, one family per line, newest
# first; personal/settings/current-models.yaml overrides it when present.
# A pin that is in a family but not its first entry prints one line naming
# the pinned model, the newer one, and where the pin lives.
#
# Silent when nothing is stale. Advisory: always exits 0, a missing catalog
# is a no-op. Gated by hook-gate.sh as "check-stale-model-pin" (standard
# profile); HQ_DISABLED_HOOKS=check-stale-model-pin also silences it.

set -uo pipefail
trap 'exit 0' EXIT

cat >/dev/null 2>&1 || true

disabled_hooks=",$(printf '%s' "${HQ_DISABLED_HOOKS:-}" | tr -d '[:space:]'),"
case "$disabled_hooks" in *,check-stale-model-pin,*) exit 0 ;; esac

HQ_ROOT="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

CATALOG="${HQ_CURRENT_MODELS_FILE:-}"
if [ -z "$CATALOG" ]; then
  CATALOG="$HQ_ROOT/core/settings/current-models.yaml"
  [ -f "$HQ_ROOT/personal/settings/current-models.yaml" ] && CATALOG="$HQ_ROOT/personal/settings/current-models.yaml"
fi
[ -f "$CATALOG" ] || exit 0

SETTINGS="$HQ_ROOT/core/settings/orchestrator.yaml"
[ -f "$HQ_ROOT/personal/settings/orchestrator.yaml" ] && SETTINGS="$HQ_ROOT/personal/settings/orchestrator.yaml"

# newest_for <model> -> prints the newest model in the same family, or nothing.
newest_for() {
  local pin="$1" line list first item
  while IFS= read -r line; do
    case "$line" in ''|'#'*) continue ;; esac
    case "$line" in *:*) ;; *) continue ;; esac
    list="${line#*:}"
    first=""
    for item in $(printf '%s' "$list" | tr ',' ' '); do
      [ -z "$first" ] && first="$item"
      if [ "$item" = "$pin" ]; then
        [ "$first" != "$pin" ] && printf '%s' "$first"
        return 0
      fi
    done
  done < "$CATALOG"
  return 0
}

warnings=""
add_warning() { # add_warning <pin> <where>
  local pin="$1" where="$2" newer
  newer="$(newest_for "$pin")"
  [ -n "$newer" ] || return 0
  warnings="${warnings}  - ${where} is pinned to ${pin}; newer model ${newer} is available.
"
}

# 1. orchestrator.yaml conduct child defaults
if [ -f "$SETTINGS" ]; then
  rel="${SETTINGS#"$HQ_ROOT"/}"
  for m in $(sed -nE 's/^[[:space:]]+children:[[:space:]]*\{.*[[:space:],{]model:[[:space:]]*([^,}[:space:]]+).*/\1/p' "$SETTINGS" | sort -u); do
    add_warning "$m" "conduct child default in ${rel}"
  done
fi

# 2. HQ_WORKFLOW_*MODEL exported in this shell
for var in HQ_WORKFLOW_MODEL HQ_WORKFLOW_CLAUDE_PLAN_MODEL HQ_WORKFLOW_CLAUDE_EXEC_MODEL \
           HQ_WORKFLOW_CODEX_PLAN_MODEL HQ_WORKFLOW_CODEX_EXEC_MODEL \
           HQ_WORKFLOW_GROK_PLAN_MODEL HQ_WORKFLOW_GROK_EXEC_MODEL; do
  val="$(printenv "$var" 2>/dev/null || true)"
  [ -n "$val" ] && add_warning "$val" "environment variable ${var}"
done

[ -n "$warnings" ] || exit 0

printf '<stale-model-pin>\nHQ is pinned to an out-of-date model:\n%sUpdate the pin (personal/settings/orchestrator.yaml or the exported variable), or edit the model catalog (personal/settings/current-models.yaml overrides core/settings/current-models.yaml) if the older pin is intentional.\n</stale-model-pin>\n' "$warnings"
