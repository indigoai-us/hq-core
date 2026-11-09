#!/usr/bin/env bash
# hq-core: public
# Regression: protect-core.sh compares paths case-insensitively. On default
# macOS (APFS) and Windows (NTFS) filesystems .CLAUDE/, CORE/ and .Claude/
# name the same files as .claude/ and core/, so a case-sensitive compare let an
# Edit or Write to the locked scaffold through by changing letter case.
# The HQ_BYPASS_CORE_PROTECT value check stays exact ("1" or "true").
set -euo pipefail
ROOT="$(git rev-parse --show-toplevel)"
HOOK="$ROOT/.claude/hooks/protect-core.sh"
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not available"; exit 0; }
command -v yq >/dev/null 2>&1 || { echo "SKIP: yq not available"; exit 0; }
PROJ="$(mktemp -d)"; trap 'rm -rf "$PROJ"' EXIT
mkdir -p "$PROJ/core" "$PROJ/.claude"
cat > "$PROJ/core/core.yaml" <<'YAML'
rules:
  locked:
    - .claude/
    - core/
  exclude:
    - .claude/settings.local.json
  reviewable: []
YAML
export CLAUDE_PROJECT_DIR="$PROJ"
FAIL=0
expect() {
  local want="$1" fp="$2" label="$3" rc=0
  jq -n --arg p "$fp" '{tool_name:"Edit", tool_input:{file_path:$p}}' \
    | bash "$HOOK" >/dev/null 2>&1 || rc=$?
  if [ "$rc" = "$want" ]; then echo "  ok: $label"
  else echo "FAIL: $label (want $want got $rc)" >&2; FAIL=$((FAIL+1)); fi
}
expect 2 "$PROJ/core/scripts/x.sh"        'core/ blocked'
expect 2 "$PROJ/CORE/scripts/x.sh"        'CORE/ blocked'
expect 2 "$PROJ/Core/scripts/x.sh"        'Core/ blocked'
expect 2 "$PROJ/.CLAUDE/hooks/x.sh"       '.CLAUDE/ blocked'
expect 2 "$PROJ/.Claude/CLAUDE.md"        '.Claude/CLAUDE.md charter blocked'
expect 2 "$PROJ/.claude/SETTINGS.json"    '.claude/SETTINGS.json blocked'
expect 2 "$PROJ/./CORE//scripts/x.sh"     './ and // with CORE/ blocked'
expect 2 "$PROJ/personal/../Core/x.sh"    '.. segment with Core/ blocked'
expect 0 "$PROJ/personal/x.md"            'personal/ allowed'
expect 0 "$PROJ/.claude/settings.local.json" 'exclude still allowed'
# Bypass value contract unchanged: "TRUE" is not an accepted value.
printf '{"env":{"HQ_BYPASS_CORE_PROTECT":"TRUE"}}' > "$PROJ/.claude/settings.local.json"
expect 2 "$PROJ/CORE/x.sh"                'bypass value TRUE not accepted'
printf '{"env":{"HQ_BYPASS_CORE_PROTECT":"1"}}' > "$PROJ/.claude/settings.local.json"
expect 0 "$PROJ/CORE/x.sh"                'bypass value 1 accepted'
[ "$FAIL" -eq 0 ] || { echo "FAIL=$FAIL"; exit 1; }
echo "PASS"
