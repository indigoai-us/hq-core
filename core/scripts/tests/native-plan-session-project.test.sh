#!/usr/bin/env bash
# native-plan-session-project.test.sh — a new chat's plan must never be filed
# under the previous chat's project (feedback_9929d112-27a0-4fb7-9360-cabbb7a6015a).
#
# native-plan-project-sync.sh read the machine-global
# .claude/state/active-session-project pointer, which holds whatever project was
# last active anywhere on the box. It now reads only this session's
# auto-session-project-<session key> marker.

set -euo pipefail

SRC_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP_ROOT=$(mktemp -d)
trap 'rm -rf "$TMP_ROOT"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

ROOT="$TMP_ROOT/hq"
mkdir -p "$ROOT/.claude/hooks" "$ROOT/.claude/state" "$ROOT/core/scripts"
cp "$SRC_ROOT/../.claude/hooks/native-plan-project-sync.sh" "$ROOT/.claude/hooks/"
cp "$SRC_ROOT/scripts/hook-lib.sh" "$ROOT/core/scripts/"
CALLS="$TMP_ROOT/helper.calls"
cat > "$ROOT/core/scripts/session-project.sh" <<SH
#!/usr/bin/env bash
cat >/dev/null
printf '%s\n' "\$*" >> "$CALLS"
SH
chmod +x "$ROOT/core/scripts/session-project.sh"

# The previous chat left the global pointer on its project.
printf 'personal/projects/previous-chat\n' > "$ROOT/.claude/state/active-session-project"

run_hook() {
  rm -f "$CALLS"
  printf '%s' "$1" | env -u HQ_SESSION_ID -u CLAUDE_CODE_SESSION_ID -u CLAUDE_SESSION_ID \
    HQ_ROOT="$ROOT" CLAUDE_PROJECT_DIR="$ROOT" \
    bash "$ROOT/.claude/hooks/native-plan-project-sync.sh" >/dev/null 2>&1 || true
}

# 1. New session with no project of its own: nothing is filed, and the
#    previous chat's project is not touched.
run_hook '{"session_id":"new-chat","tool_name":"ExitPlanMode","tool_input":{"plan":"New chat plan"}}'
[[ ! -s "$CALLS" ]] || fail "a session without its own project must not file its plan (helper called: $(cat "$CALLS"))"

# 2. New session whose own project was resolved: filed there, with --project.
printf '%s\n' "$ROOT/companies/syntha/projects/new-chat-project" \
  > "$ROOT/.claude/state/auto-session-project-new-chat"
run_hook '{"session_id":"new-chat","tool_name":"ExitPlanMode","tool_input":{"plan":"New chat plan"}}'
[[ -s "$CALLS" ]] || fail "a session with its own project must file its plan"
grep -Fq -- "--project companies/syntha/projects/new-chat-project" "$CALLS" \
  || fail "plan must be filed under this session's project, got: $(cat "$CALLS")"
if grep -Fq "previous-chat" "$CALLS"; then
  fail "plan was filed under the previous chat's project"
fi

# 3. A different session never picks up another session's marker.
run_hook '{"session_id":"third-chat","tool_name":"ExitPlanMode","tool_input":{"plan":"Third plan"}}'
[[ ! -s "$CALLS" ]] || fail "another session's marker must not be used (helper called: $(cat "$CALLS"))"

# 4. Path-traversal session ids are refused.
run_hook '{"session_id":"../new-chat","tool_name":"ExitPlanMode","tool_input":{"plan":"x"}}'
[[ ! -s "$CALLS" ]] || fail "a traversal session id must be refused"

echo "PASS: native plan sync files plans only under this session's project"
