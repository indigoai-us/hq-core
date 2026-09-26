#!/bin/bash
# Regression test for .claude/hooks/check-stale-model-pin.sh (SessionStart).
# Hermetic: a synthetic HQ root under mktemp, the hook resolved via
# CLAUDE_PROJECT_DIR. No network, no real settings touched.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$HERE/../check-stale-model-pin.sh"
pass=0; fail=0
check() { if [ "$2" -eq 0 ]; then printf 'ok   - %s\n' "$1"; pass=$((pass+1)); else printf 'FAIL - %s\n' "$1"; fail=$((fail+1)); fi; }

TMP="$(mktemp -d /tmp/stale-pin-test.XXXXXX)"; trap 'rm -rf "$TMP"' EXIT
ROOT="$TMP/hq"; mkdir -p "$ROOT/personal/settings" "$ROOT/core/settings"
CORE_CAT="$ROOT/core/settings/current-models.yaml"
cat > "$CORE_CAT" <<'YML'
# comment
claude-opus: claude-opus-5-5, claude-opus-5
codex-terra: gpt-5.6-terra
YML
run() { env -i PATH="$PATH" HOME="$HOME" CLAUDE_PROJECT_DIR="$ROOT" "$@" bash "$HOOK" </dev/null; }
orch() { printf 'conduct:\n  child_defaults:\n    - main: { model: x, effort: low }\n      children: { engine: claude, model: %s, effort: low }\n' "$1" > "$ROOT/personal/settings/orchestrator.yaml"; }

# 1. current pin -> silent
orch claude-opus-5-5
out="$(run)"; [ -z "$out" ]; check "current pin is silent" "$?"

# 2. stale pin in orchestrator.yaml -> warning names both models and the file
orch claude-opus-5
out="$(run)"
echo "$out" | grep -q 'conduct child default in personal/settings/orchestrator.yaml is pinned to claude-opus-5; newer model claude-opus-5-5 is available'
check "stale orchestrator pin warns with pinned + newer model" "$?"
echo "$out" | grep -q '^<stale-model-pin>'; check "warning is wrapped in <stale-model-pin>" "$?"

# 3. core orchestrator.yaml is read when there is no personal one
rm "$ROOT/personal/settings/orchestrator.yaml"
printf 'conduct:\n  child_defaults:\n    - main: { model: x, effort: low }\n      children: { engine: claude, model: claude-opus-5, effort: low }\n' > "$ROOT/core/settings/orchestrator.yaml"
out="$(run)"; echo "$out" | grep -q 'conduct child default in core/settings/orchestrator.yaml is pinned to claude-opus-5'
check "falls back to core/settings/orchestrator.yaml" "$?"
rm "$ROOT/core/settings/orchestrator.yaml"

# 4. stale env pin -> warning names the variable
out="$(run HQ_WORKFLOW_CLAUDE_EXEC_MODEL=claude-opus-5)"
echo "$out" | grep -q 'environment variable HQ_WORKFLOW_CLAUDE_EXEC_MODEL is pinned to claude-opus-5; newer model claude-opus-5-5'
check "stale env pin warns naming the variable" "$?"

# 5. unknown model / short alias -> silent
out="$(run HQ_WORKFLOW_CLAUDE_EXEC_MODEL=sonnet)"; [ -z "$out" ]; check "unlisted alias is ignored" "$?"

# 6. personal catalog overrides core: mark the old pin current there
printf 'claude-opus: claude-opus-5, claude-opus-5-5\n' > "$ROOT/personal/settings/current-models.yaml"
out="$(run HQ_WORKFLOW_CLAUDE_EXEC_MODEL=claude-opus-5)"; [ -z "$out" ]
check "personal/settings/current-models.yaml overrides the core catalog" "$?"
rm "$ROOT/personal/settings/current-models.yaml"

# 7. missing catalog -> silent, exit 0
mv "$CORE_CAT" "$CORE_CAT.bak"; out="$(run HQ_WORKFLOW_CLAUDE_EXEC_MODEL=claude-opus-5)"; rc=$?
if [ "$rc" -eq 0 ] && [ -z "$out" ]; then check "missing catalog is fail-soft" 0; else check "missing catalog is fail-soft" 1; fi
mv "$CORE_CAT.bak" "$CORE_CAT"

# 8. disabled via HQ_DISABLED_HOOKS
out="$(run HQ_DISABLED_HOOKS=check-stale-model-pin HQ_WORKFLOW_CLAUDE_EXEC_MODEL=claude-opus-5)"; [ -z "$out" ]
check "HQ_DISABLED_HOOKS=check-stale-model-pin silences it" "$?"

printf '\n%s passed, %s failed\n' "$pass" "$fail"; [ "$fail" -eq 0 ]
