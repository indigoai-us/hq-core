#!/usr/bin/env bash
# Process budget for common no-op hook paths. The caller may point SOURCE_ROOT
# at an origin/main source snapshot to provide the fail-first control.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
SOURCE_ROOT="${HQ_TEST_SOURCE_ROOT:-$ROOT}"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

failures=0
fail() { echo "FAIL: $*" >&2; failures=$((failures + 1)); }
pass() { echo "PASS: $*"; }

[ -f "$SOURCE_ROOT/.claude/hooks/checkpoint-stop-gate.sh" ] || { echo "FAIL: missing checkpoint hook" >&2; exit 1; }
[ -f "$SOURCE_ROOT/.claude/hooks/reindex.sh" ] || { echo "FAIL: missing reindex hook" >&2; exit 1; }
REAL_JQ="$(command -v jq || true)"
[ -n "$REAL_JQ" ] || { echo "FAIL: jq is required for the hook payload parser" >&2; exit 1; }

SHIMS="$TMP_ROOT/shims"
mkdir -p "$SHIMS"
SPAWN_LOG="$TMP_ROOT/spawns.log"
for tool in cat cksum cut dirname grep jq mkdir mktemp rm stat chmod; do
  real="$(command -v "$tool" || true)"
  [ -n "$real" ] || continue
  cat >"$SHIMS/$tool" <<WRAPPER
#!/bin/bash
printf '%s\n' '$tool' >>"\$HOOK_SPAWN_LOG"
exec '$real' "\$@"
WRAPPER
  chmod +x "$SHIMS/$tool"
done

cat >"$SHIMS/hq" <<'HQ'
#!/bin/bash
printf 'hq %s\n' "$*" >>"$HOOK_SPAWN_LOG"
if [ "${1:-}" = "core" ] && [ "${2:-}" = "--help" ]; then
  printf 'checkpoint-stop-gate\nhq-session\n'
  exit 0
fi
if [ "${1:-}" = "core" ] && [ "${2:-}" = "checkpoint-stop-gate" ]; then
  while IFS= read -r hq_line || [ -n "$hq_line" ]; do :; done
  printf '{"decision":"allow"}\n'
  exit 0
fi
exit 0
HQ
chmod +x "$SHIMS/hq"

count_spawns() { wc -l <"$SPAWN_LOG" | tr -d ' '; }

# Cold Stop invocation: main probes `core --help` then invokes the command;
# the candidate should invoke only the command and preserve its output.
: >"$SPAWN_LOG"
checkpoint_out="$(printf '{"session_id":"spawn-budget"}' | env -i \
  PATH="$SHIMS:/usr/bin:/bin" \
  HOME="$TMP_ROOT/home" \
  HOOK_SPAWN_LOG="$SPAWN_LOG" \
  HQ_CHECKPOINT_GATE_NO_CLI=0 \
  /bin/bash "$SOURCE_ROOT/.claude/hooks/checkpoint-stop-gate.sh")"
checkpoint_count="$(count_spawns)"
if [ "$checkpoint_count" -le 3 ]; then
  pass "checkpoint-stop-gate common path spawned $checkpoint_count external commands (budget 3)"
else
  fail "checkpoint-stop-gate common path spawned $checkpoint_count external commands (budget 3)"
fi
case "$checkpoint_out" in *'"decision":"allow"'*) ;; *) fail "checkpoint-stop-gate did not preserve delegated output" ;; esac

# An unrelated Write is a common no-op. The dispatcher has already supplied
# tool name; only the file_path field needs parsing, and regex checks stay in Bash.
: >"$SPAWN_LOG"
write_payload="$(printf '{"tool_name":"Write","tool_input":{"file_path":"%s/workspace/notes.md"}}' "$SOURCE_ROOT")"
printf '%s' "$write_payload" | env -i \
  PATH="$SHIMS:/usr/bin:/bin" \
  HOOK_SPAWN_LOG="$SPAWN_LOG" \
  HQ_LIB_WINSEP=1 \
  HQ_HOOK_TOOL_NAME=Write \
  /bin/bash "$SOURCE_ROOT/.claude/hooks/reindex.sh" >/dev/null 2>&1
reindex_count="$(count_spawns)"
if [ "$reindex_count" -le 2 ]; then
  pass "reindex unrelated Write spawned $reindex_count external commands (budget 2)"
else
  fail "reindex unrelated Write spawned $reindex_count external commands (budget 2)"
fi

# Keep this test wired into the workflow. It is intentionally a shell-only,
# targeted check with no package setup.
if grep -Fq 'bash core/scripts/tests/stopgate-reindex-spawn-budget.test.sh' "$ROOT/.github/workflows/pr-checks.yml"; then
  pass "pr-checks.yml runs the stopgate/reindex spawn-budget test"
else
  fail "pr-checks.yml does not run the stopgate/reindex spawn-budget test"
fi

if [ "$failures" -gt 0 ]; then
  echo "FAILED: $failures spawn-budget assertion(s)" >&2
  exit 1
fi
echo "ALL PASS"
