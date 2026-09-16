#!/usr/bin/env bash
# hq-core: public
# Regression: hook registration is not a sufficient scope boundary. If a
# dispatcher invokes these guards for another tool, their own tool-name check
# must prevent a Glob hygiene guard from bricking the session while preserving
# protect-core's fail-closed write protection.
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
GLOB_HOOK="$ROOT/.claude/hooks/block-hq-glob.sh"
PROTECT_HOOK="$ROOT/.claude/hooks/protect-core.sh"

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not available"; exit 0; }

failures=0
pass() { echo "  ok: $*"; }
fail() {
  echo "  FAIL: $1 (expected exit $2, got $3)" >&2
  if [ -n "$4" ]; then
    printf '    output: %s\n' "$4" >&2
  fi
  failures=$((failures + 1))
}

[ -f "$GLOB_HOOK" ] || { echo "FAIL: missing $GLOB_HOOK" >&2; exit 1; }
[ -f "$PROTECT_HOOK" ] || { echo "FAIL: missing $PROTECT_HOOK" >&2; exit 1; }

PROJ="$(mktemp -d)"
trap 'rm -rf "$PROJ"' EXIT
mkdir -p "$PROJ/bin" "$PROJ/core"
cat >"$PROJ/core/core.yaml" <<'YAML'
rules:
  locked:
    - core/
  exclude: []
  reviewable: []
YAML
# protect-core needs only these two queries. Keep this regression independent
# of the runner image's yq package, like the hook's own fixture tests.
cat >"$PROJ/bin/yq" <<'YQ'
#!/usr/bin/env bash
case "$2" in
  '.rules.locked[]') printf '%s\n' 'core/' ;;
  '.rules.reviewable[]') : ;;
  *) exit 1 ;;
esac
YQ
chmod +x "$PROJ/bin/yq"
LOCKED_PATH="$PROJ/core/locked.sh"

run_hook() {
  local hook="$1" expected="$2" label="$3" payload="$4" tool_env="$5"
  local output rc
  set +e
  if [ "$tool_env" = "__unset__" ]; then
    output="$(printf '%s' "$payload" | env -u HQ_HOOK_TOOL_NAME CLAUDE_PROJECT_DIR="$PROJ" PATH="$PROJ/bin:$PATH" bash "$hook" 2>&1)"
  else
    output="$(printf '%s' "$payload" | HQ_HOOK_TOOL_NAME="$tool_env" CLAUDE_PROJECT_DIR="$PROJ" PATH="$PROJ/bin:$PATH" bash "$hook" 2>&1)"
  fi
  rc=$?
  set -e
  if [ "$rc" -eq "$expected" ]; then
    pass "$label (exit $rc)"
  else
    fail "$label" "$expected" "$rc" "$output"
  fi
}

echo "[1] block-hq-glob asserts Glob scope and keeps its real checks"
run_hook "$GLOB_HOOK" 0 "Bash payload is outside Glob scope" \
  '{"tool_name":"Bash","tool_input":{"command":"pwd"}}' "__unset__"
run_hook "$GLOB_HOOK" 0 "Skill payload is outside Glob scope" \
  '{"tool_name":"Skill","tool_input":{"skill":"hq-bug"}}' "__unset__"
run_hook "$GLOB_HOOK" 0 "missing tool name fails open" \
  '{"tool_input":{}}' "__unset__"
run_hook "$GLOB_HOOK" 0 "camel-case payload tool name is outside Glob scope" \
  '{"toolName":"Bash","toolInput":{"command":"pwd"}}' "__unset__"
run_hook "$GLOB_HOOK" 0 "master-hook tool environment takes precedence" \
  '{"tool_name":"Glob","tool_input":{}}' "Bash"
run_hook "$GLOB_HOOK" 0 "empty master-hook tool environment fails open" \
  '{"tool_name":"Glob","tool_input":{}}' ""
run_hook "$GLOB_HOOK" 2 "Glob without a path remains blocked" \
  '{"tool_name":"Glob","tool_input":{"pattern":"**/*.md"}}' "__unset__"
run_hook "$GLOB_HOOK" 2 "Glob discovery of prd.json remains blocked" \
  '{"tool_name":"Glob","tool_input":{"pattern":"**/prd.json","path":"core/"}}' "__unset__"

echo "[2] protect-core allows only established read-only tool names"
for tool in Read NotebookRead Glob Grep LS list_dir ListDir list read_file grep; do
  run_hook "$PROTECT_HOOK" 0 "$tool read-only access to a locked path is allowed" \
    "{\"tool_name\":\"$tool\",\"tool_input\":{\"file_path\":\"$LOCKED_PATH\"}}" "__unset__"
done
run_hook "$PROTECT_HOOK" 2 "Edit to a locked path remains blocked" \
  "{\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"$LOCKED_PATH\"}}" "__unset__"
run_hook "$PROTECT_HOOK" 2 "unknown tool name remains fail-closed" \
  "{\"tool_input\":{\"file_path\":\"$LOCKED_PATH\"}}" "__unset__"

if [ "$failures" -ne 0 ]; then
  echo "FAIL: hook-tool-scope-self-assert: $failures assertion(s) failed" >&2
  exit 1
fi

echo "hook-tool-scope-self-assert: all passed"
