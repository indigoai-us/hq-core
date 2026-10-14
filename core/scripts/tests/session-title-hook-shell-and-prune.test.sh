#!/usr/bin/env bash
# session-title-hook-shell-and-prune.test.sh
#
# Regression coverage for two review findings on HP-32 (PR #1236):
#
#   T1  UserPromptSubmit under the system Bash (/bin/bash, 3.2 on macOS) leaves
#       the optional helper-argument array empty. Expanding "${arr[@]}" on an
#       empty array under `set -u` aborts Bash 3.2 before the helper runs, so no
#       title was ever emitted. The hook must emit the title under /bin/bash.
#   T2  The same hook also works under the Bash found on PATH.
#   T3  SessionStart for a session id whose own state file is older than 14
#       days: the helper prunes that file, so the command and title the hook
#       read from it beforehand are stale and must not be used. With the stale
#       title matching the computed one, the old ordering suppressed the emit
#       ("unchanged") and re-persisted the stale command.
#
# Uses the real title helper and hook library. Override the hook under test
# with SESSION_TITLE_HOOK and the system shell with SESSION_TITLE_SYSTEM_BASH.
set -uo pipefail

TEST_DIR="$(cd "${BASH_SOURCE[0]%/*}" && pwd)"
ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
HOOK_SOURCE="${SESSION_TITLE_HOOK:-$ROOT/.claude/hooks/session-title.sh}"
SYSTEM_BASH="${SESSION_TITLE_SYSTEM_BASH:-/bin/bash}"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
pass_count=0
ok() { pass_count=$((pass_count + 1)); printf 'ok %s — %s\n' "$pass_count" "$1"; }

[ -f "$HOOK_SOURCE" ] || fail "missing hook source: $HOOK_SOURCE"
[ -x "$SYSTEM_BASH" ] || fail "missing system bash: $SYSTEM_BASH"
command -v node >/dev/null 2>&1 || fail "node is required by the title helper"
command -v jq >/dev/null 2>&1 || fail "jq is required by the hook output"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/session-title-shell-prune.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

FIX="$TMP/hq"
STATE_DIR="$FIX/.claude/state"
PROJECT="$FIX/repos/private/hp32-demo"
mkdir -p "$FIX/.claude/hooks" "$STATE_DIR" "$FIX/core/scripts" "$PROJECT"
cp "$HOOK_SOURCE" "$FIX/.claude/hooks/session-title.sh"
cp "$ROOT/core/scripts/hook-lib.sh" "$FIX/core/scripts/hook-lib.sh"
cp "$ROOT/core/scripts/session-title.sh" "$FIX/core/scripts/session-title.sh"
chmod +x "$FIX/core/scripts/session-title.sh"

run_hook() {
  # $1 = bash interpreter, $2 = JSON payload; prints the hook's stdout.
  printf '%s' "$2" | HQ_ROOT="$FIX" CLAUDE_PROJECT_DIR="$FIX" HQ_SESSION_TITLE=auto \
    "$1" "$FIX/.claude/hooks/session-title.sh" 2>"$TMP/stderr"
}

emitted_title() {
  printf '%s' "$1" | jq -r '.hookSpecificOutput.sessionTitle // empty' 2>/dev/null
}

# A fresh project marker for every session keeps the title deterministic and
# skips the hook's bounded wait for project resolution.
mark_project() { printf '%s\n' "$PROJECT" > "$STATE_DIR/auto-session-project-$1"; }

# --- T1 / T2: empty optional-argument array under set -u --------------------
prompt_payload() {
  printf '{"hook_event_name":"UserPromptSubmit","prompt":"hello","session_id":"%s","transcript_path":"","session_title":""}' "$1"
}

SYSTEM_BASH_VERSION="$("$SYSTEM_BASH" -c 'echo $BASH_VERSION')"
mark_project bash32-session
out="$(run_hook "$SYSTEM_BASH" "$(prompt_payload bash32-session)")"
rc=$?
[ "$rc" -eq 0 ] || fail "T1: hook exited $rc under $SYSTEM_BASH: $(cat "$TMP/stderr")"
grep -q 'unbound variable' "$TMP/stderr" && fail "T1: unbound variable under $SYSTEM_BASH: $(cat "$TMP/stderr")"
[ "$(emitted_title "$out")" = "hp32-demo" ] \
  || fail "T1: expected title hp32-demo under $SYSTEM_BASH ($SYSTEM_BASH_VERSION), got: ${out:-<no output>}"
ok "UserPromptSubmit emits the title under $SYSTEM_BASH ($SYSTEM_BASH_VERSION)"

mark_project path-bash-session
out="$(run_hook bash "$(prompt_payload path-bash-session)")"
[ "$(emitted_title "$out")" = "hp32-demo" ] || fail "T2: expected title hp32-demo under PATH bash, got: ${out:-<no output>}"
ok "UserPromptSubmit emits the title under PATH bash"

# --- T3: SessionStart reuses a session id whose state is past the prune age --
SID="stale-resume-session"
mark_project "$SID"
STATE="$STATE_DIR/session-title-$SID"
# Line 1 = last command, line 2 = last emitted title (the hook's state format).
printf '%s\n%s\n' "hqwork" "hp32-demo" > "$STATE"
touch -t 202001010000 "$STATE"

start_payload='{"hook_event_name":"SessionStart","source":"resume","session_id":"'"$SID"'","transcript_path":"","session_title":""}'
out="$(run_hook "$SYSTEM_BASH" "$start_payload")"
[ "$(emitted_title "$out")" = "hp32-demo" ] \
  || fail "T3: SessionStart used pruned state (stale command or title); got: ${out:-<no output>}"
ok "SessionStart after a 14-day prune emits the title from a clean slate"

[ -f "$STATE" ] || fail "T3: hook did not rewrite the session state file"
{ IFS= read -r saved_command || true; IFS= read -r saved_title || true; } < "$STATE"
[ -z "$saved_command" ] || fail "T3: stale command '$saved_command' was carried into the new state"
[ "$saved_title" = "hp32-demo" ] || fail "T3: expected saved title hp32-demo, got '$saved_title'"
ok "SessionStart after a 14-day prune drops the stale command"

echo "session-title-hook-shell-and-prune: $pass_count passed"
