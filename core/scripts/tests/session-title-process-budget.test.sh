#!/usr/bin/env bash
# Keep the SessionStart session-title hook's child-process fanout bounded.
set -euo pipefail

TEST_DIR="$(cd "${BASH_SOURCE[0]%/*}" && pwd)"
ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
HOOK_SOURCE="${SESSION_TITLE_HOOK:-$ROOT/.claude/hooks/session-title.sh}"
STRACE="$(command -v strace || true)"
[ -n "$STRACE" ] || { echo 'FAIL: strace is required for the session-title process budget' >&2; exit 1; }
[ -f "$HOOK_SOURCE" ] || { echo "FAIL: missing hook source: $HOOK_SOURCE" >&2; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/session-title-process-budget.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
FIX="$TMP/hq"
mkdir -p "$FIX/.claude/hooks" "$FIX/.claude/state" "$FIX/core/scripts" "$FIX/repos/private/hp32-demo"
cp "$HOOK_SOURCE" "$FIX/.claude/hooks/session-title.sh"
cp "$ROOT/core/scripts/hook-lib.sh" "$FIX/core/scripts/hook-lib.sh"
cp "$ROOT/core/scripts/session-title.sh" "$FIX/core/scripts/session-title.sh"
chmod +x "$FIX/core/scripts/session-title.sh"
printf '%s\n' "$FIX/repos/private/hp32-demo" > "$FIX/.claude/state/auto-session-project-budget-session"
printf 'stale session state\n' > "$FIX/.claude/state/session-title-old-session.manual"
printf 'stale project marker\n' > "$FIX/.claude/state/auto-session-project-old-session"
printf 'shared title ledger\n' > "$FIX/.claude/state/session-title.hq-titles"
touch -d '16 days ago' "$FIX/.claude/state/session-title-old-session.manual" \
  "$FIX/.claude/state/auto-session-project-old-session" \
  "$FIX/.claude/state/session-title.hq-titles"

EXPECTED="$TMP/expected.json"
ACTUAL="$TMP/actual.json"
TRACE="$TMP/strace.log"
printf '{\n  "hookSpecificOutput": {\n    "hookEventName": "SessionStart",\n    "sessionTitle": "hp32-demo"\n  }\n}\n' > "$EXPECTED"

payload='{"hook_event_name":"SessionStart","source":"startup","session_id":"budget-session","transcript_path":"","session_title":""}'
printf '%s' "$payload" | HQ_ROOT="$FIX" CLAUDE_PROJECT_DIR="$FIX" \
  "$STRACE" -f -qq -e trace=execve,clone,clone3,fork,vfork -o "$TRACE" \
  bash "$FIX/.claude/hooks/session-title.sh" > "$ACTUAL" 2> "$TMP/stderr" \
  || { echo 'FAIL: session-title SessionStart invocation failed' >&2; exit 1; }

cmp -s "$EXPECTED" "$ACTUAL" \
  || { diff -u "$EXPECTED" "$ACTUAL" >&2 || true; echo 'FAIL: SessionStart output changed' >&2; exit 1; }
echo '  ok: SessionStart title output matches the byte-for-byte fixture'
[ ! -e "$FIX/.claude/state/session-title-old-session.manual" ] \
  || { echo 'FAIL: stale session-title state was not pruned' >&2; exit 1; }
[ ! -e "$FIX/.claude/state/auto-session-project-old-session" ] \
  || { echo 'FAIL: stale project marker was not pruned' >&2; exit 1; }
[ -f "$FIX/.claude/state/session-title.hq-titles" ] \
  || { echo 'FAIL: shared HQ-title ledger was pruned' >&2; exit 1; }
echo '  ok: stale per-session files are pruned and the shared title ledger survives'

# Count distinct child PIDs that successfully exec a program. A shell script
# and its shebang interpreter can produce multiple successful execve calls in
# the same PID, so count each child only once and exclude the root Bash.
children="$(awk '
  /execve\(/ && / = 0$/ {
    pid=$1
    if (root == "") { root=pid; next }
    if (pid != root) seen[pid]=1
  }
  END { for (pid in seen) count++; print count+0 }
' "$TRACE")"
[ "$children" -le 5 ] \
  || { echo "FAIL: hook launched $children child processes; budget is 5" >&2; exit 1; }
echo "  ok: SessionStart launched $children child processes (budget 5)"
echo 'session-title-process-budget: ok'
