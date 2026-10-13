#!/usr/bin/env bash
# Regression: /checkpoint step 1 must not scan all of workspace/ and must
# terminate within its time bound.
#
# 2026-10-13: a Codex /checkpoint run issued an unbounded `find workspace ...`
# that descended into ~163 worktrees under workspace/worktrees and kept running
# as an orphan (ppid 1) after the session's shell was killed. The skill now
# routes step 1 through core/scripts/checkpoint-recent-auto.sh.

set -uo pipefail

CORE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ROOT="$(cd "$CORE_ROOT/.." && pwd)"
SCRIPT="$ROOT/core/scripts/checkpoint-recent-auto.sh"
SKILL="$ROOT/.claude/skills/checkpoint/SKILL.md"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "  ok - $*"; }

fr="$TMP/hq"
mkdir -p "$fr/workspace/threads/journal" "$fr/workspace/worktrees/repo-a/workspace/threads"
touch "$fr/workspace/threads/T-a-auto-1.json"
touch "$fr/workspace/threads/T-b-auto-2.json"
touch "$fr/workspace/threads/T-c-manual.json"
# Decoys that must never be returned: nested threads and a worktree copy.
touch "$fr/workspace/threads/journal/T-z-auto-nested.json"
touch "$fr/workspace/worktrees/repo-a/workspace/threads/T-z-auto-wt.json"
touch "$fr/workspace/T-z-auto-root.json"

# 1. Returns the newest top-level auto-checkpoint only.
out="$(bash "$SCRIPT" "$fr" 5)"
[ "$out" = "$fr/workspace/threads/T-b-auto-2.json" ] \
  || fail "expected newest top-level auto checkpoint, got: $out"
pass "returns newest top-level auto-checkpoint"

# 2. Does not descend: record the exact find invocation through a PATH shim.
#    It must start at workspace/threads with -maxdepth 1, never at workspace/.
real_find="$(command -v find)"
mkdir -p "$TMP/logbin"
{
  echo '#!/bin/sh'
  echo "printf '%s\\n' \"\$@\" > '$TMP/find-args'"
  echo "exec '$real_find' \"\$@\""
} > "$TMP/logbin/find"
chmod +x "$TMP/logbin/find"
out="$(PATH="$TMP/logbin:$PATH" bash "$SCRIPT" "$fr" 5)"
args="$(tr '\n' ' ' < "$TMP/find-args")"
case "$args" in "$fr/workspace/threads -maxdepth 1 "*) ;; *) fail "unexpected find args: $args" ;; esac
case "$out" in *worktrees*|*journal*|*auto-root*) fail "descended outside threads top level: $out" ;; esac
pass "does not read workspace/worktrees or nested thread dirs"

# 3. Missing threads dir is a quiet no-op.
out="$(bash "$SCRIPT" "$TMP/none" 5)"; rc=$?
[ "$rc" = 0 ] && [ -z "$out" ] || fail "missing threads dir: rc=$rc out=$out"
pass "missing workspace/threads is a no-op"

# 4. Terminates within the bound even when find would hang. A fake `find`
#    on PATH sleeps far past the limit; the alarm must kill it.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/find" <<'EOF'
#!/bin/sh
exec sleep 61
EOF
chmod +x "$TMP/bin/find"
start=$(date +%s)
PATH="$TMP/bin:$PATH" HQ_CHECKPOINT_FIND_TIMEOUT=2 bash "$SCRIPT" "$fr" 5 >/dev/null; rc=$?
elapsed=$(( $(date +%s) - start ))
[ "$rc" = 0 ] || fail "timeout path should exit 0, got $rc"
[ "$elapsed" -le 6 ] || fail "did not terminate within bound (took ${elapsed}s)"
pgrep -f '^sleep 61$' >/dev/null 2>&1 && fail "find child survived its deadline"
pass "terminates within the time bound (${elapsed}s, limit 2s)"

# 5. The skill routes step 1 through the helper and has no unbounded find.
grep -q 'core/scripts/checkpoint-recent-auto.sh' "$SKILL" || fail "skill does not call the helper"
if grep -nE '^\s*find workspace' "$SKILL" | grep -v -- '-maxdepth' | grep -q .; then
  fail "skill still contains an unbounded find over workspace"
fi
pass "checkpoint skill has no unbounded find over workspace"

echo "checkpoint-recent-auto: all tests passed"
