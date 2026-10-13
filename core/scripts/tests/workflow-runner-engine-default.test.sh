#!/bin/bash
# hq-core: public
# workflow-runner engine selection: claude is the default engine, and codex runs
# only with the explicit HQ_ALLOW_CODEX=1 opt-in. Without it, a codex request
# (opts.engine or HQ_WORKFLOW_ENGINE) runs on claude and never spawns codex.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
RUNNER="$REPO_ROOT/core/scripts/workflow-runner.mjs"

pass=0
fail=0
check() {
  if [ "$2" -eq 0 ]; then
    printf 'ok   - %s\n' "$1"; pass=$((pass + 1))
  else
    printf 'FAIL - %s\n' "$1"; fail=$((fail + 1))
  fi
}

TMP="$(mktemp -d /tmp/workflow-runner-engine.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
TMP="$(cd "$TMP" && pwd -P)"
mkdir -p "$TMP/bin" "$TMP/hqroot/.claude" "$TMP/hqroot/workspace"
printf '{}\n' > "$TMP/hqroot/.claude/settings.json"

cat > "$TMP/bin/claude" <<'FAKE'
#!/usr/bin/env bash
[ "${1:-}" = "--version" ] && { echo claude-test; exit 0; }
echo claude >> "${FAKE_REC:?}"
printf '{"type":"result","subtype":"success","is_error":false,"result":"from-claude","permission_denials":[]}\n'
FAKE
cat > "$TMP/bin/codex" <<'FAKE'
#!/usr/bin/env bash
[ "${1:-}" = "--version" ] && { echo codex-test; exit 0; }
echo codex >> "${FAKE_REC:?}"
out=""
while [ $# -gt 0 ]; do
  case "$1" in --output-last-message) out="$2"; shift 2 ;; *) shift ;; esac
done
[ -n "$out" ] && printf 'from-codex' > "$out"
exit 0
FAKE
chmod +x "$TMP/bin/claude" "$TMP/bin/codex"

run_wf() { # <name> <engine-opt-js> [env assignments...]
  local name="$1" opt="$2"; shift 2
  REC="$TMP/rec-$name"; : > "$REC"
  cat > "$TMP/wf-$name.mjs" <<WF
export const meta = { name: '$name', description: 'engine default' }
return await agent('hello', { ${opt} tier: 'exec', timeoutSecs: 30, label: 'a' })
WF
  OUT="$(env -u HQ_ALLOW_CODEX -u HQ_WORKFLOW_ENGINE -u HQ_CONDUCT_ENGINE "$@" \
    FAKE_REC="$REC" \
    HQ_WORKFLOW_CODEX_BIN="$TMP/bin/codex" \
    HQ_WORKFLOW_CLAUDE_BIN="$TMP/bin/claude" \
    HQ_WORKFLOW_CPU_CHECK=0 HQ_ROOT="$TMP/hqroot" \
    node "$RUNNER" "$TMP/wf-$name.mjs" --quiet --run-dir "$TMP/run-$name" 2>"$TMP/stderr-$name")"
  RC=$?
  SPAWNED="$(tr '\n' ' ' < "$REC" | sed 's/ $//')"
}

run_wf default ''
[ "$RC" -eq 0 ] && [ "$SPAWNED" = "claude" ]
check "no engine given: claude runs (got '$SPAWNED', rc $RC)" "$?"

run_wf codex-no-optin "engine: 'codex',"
[ "$RC" -eq 0 ] && [ "$SPAWNED" = "claude" ]
check "engine codex without HQ_ALLOW_CODEX: claude runs, codex never spawns (got '$SPAWNED')" "$?"

run_wf env-codex-no-optin '' HQ_WORKFLOW_ENGINE=codex
[ "$RC" -eq 0 ] && [ "$SPAWNED" = "claude" ]
check "HQ_WORKFLOW_ENGINE=codex without opt-in: claude runs (got '$SPAWNED')" "$?"

run_wf codex-optin "engine: 'codex'," HQ_ALLOW_CODEX=1
[ "$RC" -eq 0 ] && [ "$SPAWNED" = "codex" ]
check "engine codex with HQ_ALLOW_CODEX=1: codex runs (got '$SPAWNED')" "$?"

run_wf default-optin '' HQ_ALLOW_CODEX=1
[ "$RC" -eq 0 ] && [ "$SPAWNED" = "claude" ]
check "HQ_ALLOW_CODEX=1 alone does not change the claude default (got '$SPAWNED')" "$?"

printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
