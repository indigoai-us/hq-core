#!/usr/bin/env bash
# Assert session-title extracts its event payload with one jq process, and
# preserves both hook outputs on SessionStart and UserPromptSubmit.
set -euo pipefail

TEST_DIR="$(cd "${BASH_SOURCE[0]%/*}" && pwd)"
ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
HOOK_SOURCE="${SESSION_TITLE_HOOK:-$ROOT/.claude/hooks/session-title.sh}"
REAL_JQ="$(type -P jq || true)"
[ -n "$REAL_JQ" ] || { echo 'FAIL: jq is required' >&2; exit 1; }
[ -f "$HOOK_SOURCE" ] || { echo "FAIL: missing hook source: $HOOK_SOURCE" >&2; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/session-title-spawn-budget.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
FIX="$TMP/hq"
TOOLS="$TMP/tools"
LOG="$TMP/jq.calls"
mkdir -p "$FIX/.claude/hooks" "$FIX/.claude/state" "$FIX/core/scripts" "$TOOLS"
cp "$ROOT/core/scripts/hook-lib.sh" "$FIX/core/scripts/hook-lib.sh"
cp "$HOOK_SOURCE" "$FIX/.claude/hooks/session-title.sh"
cat > "$FIX/core/scripts/session-title.sh" <<'STUB'
#!/usr/bin/env bash
printf 'hq · chat\n'
STUB
chmod +x "$FIX/core/scripts/session-title.sh"
cat > "$TOOLS/jq" <<'STUB'
#!/usr/bin/env bash
printf 'jq\n' >> "$SESSION_TITLE_JQ_CALL_LOG"
exec "$SESSION_TITLE_REAL_JQ" "$@"
STUB
chmod +x "$TOOLS/jq"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
run_and_check() {
  local event="$1" payload="$2" output count
  : > "$LOG"
  output="$(printf '%s' "$payload" | env -u BASH_ENV -u ENV \
    PATH="$TOOLS:$PATH" HOME="$TMP/home" HQ_ROOT="$FIX" CLAUDE_PROJECT_DIR="$FIX" \
    HQ_HOOK_EVENT="$event" HQ_HOOK_SESSION_ID=session-budget \
    SESSION_TITLE_JQ_CALL_LOG="$LOG" SESSION_TITLE_REAL_JQ="$REAL_JQ" \
    bash "$FIX/.claude/hooks/session-title.sh")" \
    || fail "$event hook did not complete"
  count="$(wc -l < "$LOG" | tr -d '[:space:]')"
  [ "$count" -eq 2 ] || fail "$event used $count jq processes; expected one payload parse and one output encode"
  case "$output" in *'"sessionTitle": "hq · chat"'*) ;; *) fail "$event output lost the computed session title: $output" ;; esac
  case "$output" in *"$event"*) ;; *) fail "$event output lost the event name: $output" ;; esac
  if [ "$event" = UserPromptSubmit ]; then
    case "$output" in *'HQ session naming (first turn)'*) ;; *) fail 'UserPromptSubmit output lost its first-turn nudge' ;; esac
  fi
}

run_and_check SessionStart '{"hook_event_name":"SessionStart","source":"startup","session_id":"session-budget","transcript_path":"","session_title":""}'
rm -f "$FIX/.claude/state/session-title-session-budget"*
: > "$FIX/.claude/state/auto-session-project-session-budget"
run_and_check UserPromptSubmit '{"hook_event_name":"UserPromptSubmit","session_id":"session-budget","prompt":"ordinary request","transcript_path":"","session_title":""}'
# A NUL escape in the prompt must not shift later fields (session_id) when the
# payload is parsed in one NUL-framed jq pass.
rm -f "$FIX/.claude/state/session-title-"* "$FIX/.claude/state/auto-session-project-"*
: > "$FIX/.claude/state/auto-session-project-nul-check"
printf '%s' '{"hook_event_name":"UserPromptSubmit","session_id":"nul-check","prompt":"before\u0000after\n\n","transcript_path":"","session_title":""}' \
  | env -u BASH_ENV -u ENV -u HQ_HOOK_SESSION_ID \
    PATH="$TOOLS:$PATH" HOME="$TMP/home" HQ_ROOT="$FIX" CLAUDE_PROJECT_DIR="$FIX" \
    HQ_HOOK_EVENT=UserPromptSubmit \
    SESSION_TITLE_JQ_CALL_LOG="$LOG" SESSION_TITLE_REAL_JQ="$REAL_JQ" \
    bash "$FIX/.claude/hooks/session-title.sh" >/dev/null || fail 'NUL prompt hook did not complete'
compgen -G "$FIX/.claude/state/session-title-nul-check*" >/dev/null \
  || fail "NUL in prompt shifted session_id: $(ls "$FIX/.claude/state" | tr '\n' ' ')"
printf 'PASS: SessionStart and UserPromptSubmit payload parsing uses one jq process; hook output retained\n'
