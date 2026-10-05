#!/usr/bin/env bash
# The derive helper is now a generated CLI forwarder. A CLI below its declared
# floor must keep the helper's fail-closed 127 disposition and diagnostic.
set -euo pipefail

HQ_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
ROOT="$TMP/hq"
MOCK_BIN="$TMP/bin"
mkdir -p "$ROOT/core/scripts/lib" "$ROOT/.claude/hooks" "$ROOT/core/policies" "$MOCK_BIN"
ln -s "$HQ_SRC/core/scripts/derive-trigger-facts.sh" "$ROOT/core/scripts/derive-trigger-facts.sh"
ln -s "$HQ_SRC/core/scripts/eval-trigger.sh" "$ROOT/core/scripts/eval-trigger.sh"
ln -s "$HQ_SRC/core/scripts/lib/hq-cli-floor.sh" "$ROOT/core/scripts/lib/hq-cli-floor.sh"
cp "$HQ_SRC/core/scripts/hook-lib.sh" "$ROOT/core/scripts/hook-lib.sh"
cp "$HQ_SRC/.claude/hooks/inject-policy-on-trigger.sh" "$ROOT/.claude/hooks/inject-policy-on-trigger.sh"
cat > "$MOCK_BIN/hq" <<'EOF'
#!/usr/bin/env bash
if [ "${1-}" = "--version" ]; then printf '5.341.2\n'; exit 0; fi
printf 'unexpected old hq invocation: %s\n' "$*" >&2
exit 64
EOF
chmod +x "$MOCK_BIN/hq"

payload='{"hook_event_name":"UserPromptSubmit","session_id":"synthetic-forwarder-test","cwd":"/tmp","prompt":"gh pr create","tool_input":{}}'
expected='derive-trigger-facts.sh: this script needs hq-cli >= 5.342.5 (found 5.341.2); upgrade with: npm install -g @indigoai-us/hq-cli@latest'
direct_out="$TMP/direct.out"
direct_err="$TMP/direct.err"
direct_status=0
printf '%s' "$payload" | env PATH="$MOCK_BIN:$PATH" HQ_ROOT="$ROOT" \
  bash "$ROOT/core/scripts/derive-trigger-facts.sh" UserPromptSubmit \
  >"$direct_out" 2>"$direct_err" || direct_status=$?
[ "$direct_status" -eq 127 ] || { echo "FAIL: old CLI must exit 127 (got $direct_status)" >&2; exit 1; }
[ ! -s "$direct_out" ] || { echo "FAIL: old CLI forwarder wrote stdout" >&2; exit 1; }
grep -Fxq "$expected" "$direct_err" || { echo "FAIL: old CLI diagnostic changed" >&2; exit 1; }

hook_out="$TMP/hook.out"
hook_err="$TMP/hook.err"
hook_status=0
printf '%s' "$payload" | env PATH="$MOCK_BIN:$PATH" HQ_ROOT="$ROOT" CLAUDE_PROJECT_DIR="$ROOT" \
  bash "$ROOT/.claude/hooks/inject-policy-on-trigger.sh" \
  >"$hook_out" 2>"$hook_err" || hook_status=$?
[ "$hook_status" -eq 0 ] || { echo "FAIL: injector must swallow helper 127 (got $hook_status)" >&2; exit 1; }
[ ! -s "$hook_out" ] || { echo "FAIL: injector emitted output after helper 127" >&2; exit 1; }
grep -Fxq "$expected" "$hook_err" || { echo "FAIL: injector diagnostic differs: $(cat "$hook_err")" >&2; exit 1; }

echo "derive-trigger-facts-forwarder-fail-closed: ok"
