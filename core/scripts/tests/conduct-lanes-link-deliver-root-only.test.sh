#!/usr/bin/env bash
# Regression: conductor link messages must reach only the conducted root
# session. Claude Code fires a subagent's PostToolUse under the parent's
# session_id, and the hook used to drain the root's queue into the subagent.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
LINK="$ROOT/.claude/hooks/conduct-lanes-link-deliver.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
BIN="$TMP/bin"
QUEUE="$TMP/queue"
mkdir -p "$BIN" "$QUEUE/pending" "$QUEUE/delivered" "$TMP/root/workspace/lanes-links/by-session"
SAVED_PATH="$PATH"
export PATH="$BIN:/usr/bin:/bin"
export CLAUDE_PROJECT_DIR="$TMP/root"
export FAKE_QUEUE="$QUEUE" FAKE_CALLS="$TMP/calls"
unset HQ_HOOK_AGENT_ID HQ_HOOK_AGENT_TYPE

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

# Fake hq with the same claim-then-deliver contract as hq lanes link _deliver:
# any call drains every pending message and marks it delivered.
cat > "$BIN/hq" <<'FAKE'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >> "$FAKE_CALLS"
cat > /dev/null
body=""
for f in "$FAKE_QUEUE"/pending/*; do
  [ -f "$f" ] || continue
  body="$body$(cat "$f")"
  mv "$f" "$FAKE_QUEUE/delivered/"
done
[ -n "$body" ] || { printf '{}\n'; exit 0; }
jq -cn --arg b "[conduct] The session conducting you sent this while you were working.

$body" '{hookSpecificOutput:{hookEventName:"PostToolUse",additionalContext:$b}}'
FAKE
chmod +x "$BIN/hq"

SID=root-sess-1
printf 'child cl-test worker\n' > "$TMP/root/workspace/lanes-links/by-session/$SID"
printf 'relay-marker-42' > "$QUEUE/pending/0001.msg"
queued() { [ -f "$QUEUE/pending/0001.msg" ] && [ ! -e "$QUEUE/delivered/0001.msg" ]; }
run_hook() { printf '%s' "$2" | "$LINK" "$1" > "$TMP/out" 2> "$TMP/err"; }

child_payloads=(
  "{\"hook_event_name\":\"PostToolUse\",\"session_id\":\"$SID\",\"agent_id\":\"a1b2c3\",\"agent_type\":\"general-purpose\",\"tool_name\":\"Read\"}"
  "{\"hook_event_name\":\"PostToolUse\",\"sessionId\":\"$SID\",\"agentId\":\"a1b2c3\",\"tool_name\":\"Read\"}"
  "{\"hook_event_name\":\"PostToolUse\",\"session_id\":\"$SID\",\"transcript_path\":\"/home/u/.claude/projects/p/$SID/subagents/agent-a1.jsonl\"}"
  "{\"hook_event_name\":\"PostToolUse\",\"session_id\":\"$SID\",\"transcript_path\":\"C:\\\\Users\\\\u\\\\.claude\\\\projects\\\\p\\\\$SID\\\\subagents\\\\agent-a1.jsonl\"}"
  # A non-string agent_id still marks a child (master-hook's "present and not
  # null" rule), and a null agent_id does not hide a camelCase agentId.
  "{\"hook_event_name\":\"PostToolUse\",\"session_id\":\"$SID\",\"agent_id\":12345,\"tool_name\":\"Read\"}"
  "{\"hook_event_name\":\"PostToolUse\",\"session_id\":\"$SID\",\"agent_id\":null,\"agentId\":\"a1b2c3\",\"tool_name\":\"Read\"}"
  # An empty or non-string snake_case marker does not hide a set camelCase one,
  # matching hq-cli's isChildHookPayload.
  "{\"hook_event_name\":\"PostToolUse\",\"session_id\":\"$SID\",\"subagent_type\":\"\",\"subagentType\":\"explorer\"}"
  "{\"hook_event_name\":\"PostToolUse\",\"session_id\":\"$SID\",\"parent_thread_id\":\"\",\"parentThreadId\":\"thread-parent\"}"
  "{\"hook_event_name\":\"Stop\",\"session_id\":\"$SID\",\"agent_transcript_path\":5,\"agentTranscriptPath\":\"/tmp/agent.jsonl\"}"
  "{\"hook_event_name\":\"Stop\",\"session_id\":\"$SID\",\"agent_transcript_path\":\"/tmp/agent.jsonl\"}"
  # Feedback f1d7a792 (Windows lane): a background general-purpose sub-worker's
  # Bash PostToolUse. Claude Code sends the parent's session_id and the parent's
  # own transcript_path, so agent_id is the only child marker.
  "{\"hook_event_name\":\"PostToolUse\",\"session_id\":\"$SID\",\"transcript_path\":\"/home/u/.claude/projects/-home-u-hq/$SID.jsonl\",\"cwd\":\"/home/u/hq\",\"permission_mode\":\"bypassPermissions\",\"agent_id\":\"a33fdaf425a99e25a\",\"agent_type\":\"general-purpose\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"echo hi\"},\"tool_response\":{\"stdout\":\"hi\"}}"
  # The same sub-worker on a Windows host.
  "{\"hook_event_name\":\"PostToolUse\",\"session_id\":\"$SID\",\"transcript_path\":\"C:\\\\Users\\\\u\\\\.claude\\\\projects\\\\C--home-u-hq\\\\$SID.jsonl\",\"cwd\":\"C:\\\\Users\\\\u\\\\hq\",\"agent_id\":\"a33fdaf425a99e25a\",\"agent_type\":\"general-purpose\",\"tool_name\":\"Bash\"}"
  # Grok child session: the adapter forwards subagent_type for every event in a
  # child. A parent session id next to it does not change that.
  "{\"hook_event_name\":\"PostToolUse\",\"tool_name\":\"Bash\",\"cwd\":\"/home/u/hq\",\"session_id\":\"$SID\",\"tool_input\":{\"command\":\"echo hi\"},\"subagent_type\":\"explorer\"}"
  "{\"hook_event_name\":\"PostToolUse\",\"tool_name\":\"Bash\",\"cwd\":\"/home/u/hq\",\"session_id\":\"$SID\",\"tool_input\":{\"command\":\"echo hi\"},\"subagent_type\":\"explorer\",\"parent_session_id\":\"grok-parent\"}"
  "{\"hook_event_name\":\"Stop\",\"session_id\":\"$SID\",\"stop_hook_active\":false,\"subagent_type\":\"explorer\",\"transcript_path\":\"/home/u/.grok/sessions/child.jsonl\"}"
  "{\"hookEventName\":\"PostToolUse\",\"sessionId\":\"$SID\",\"subagentType\":\"explorer\",\"parentSessionId\":\"grok-parent\"}"
  # Codex: the adapter re-dispatches SubagentStop as an Agent PostToolUse that
  # carries the child's agent_id; a child thread names its parent thread.
  "{\"hook_event_name\":\"PostToolUse\",\"session_id\":\"$SID\",\"tool_name\":\"Agent\",\"agent_id\":\"agent-1\",\"agent_type\":\"explorer\",\"tool_input\":{},\"tool_response\":\"completed result\"}"
  "{\"hook_event_name\":\"PostToolUse\",\"session_id\":\"$SID\",\"parent_thread_id\":\"thread-parent\",\"tool_name\":\"Bash\"}"
  "{\"hook_event_name\":\"Stop\",\"session_id\":\"$SID\",\"parentThreadId\":\"thread-parent\",\"stop_hook_active\":false}"
)
for payload in "${child_payloads[@]}"; do
  : > "$FAKE_CALLS"
  event="$(jq -r '.hook_event_name' <<<"$payload")"
  run_hook "$event" "$payload"
  ! grep -q 'relay-marker-42\|session conducting you' "$TMP/out" || fail "child payload received link text: $payload"
  [ ! -s "$TMP/out" ] && [ ! -s "$TMP/err" ] || fail "child payload emitted output: $payload"
  [ ! -s "$FAKE_CALLS" ] || fail "child payload reached hq-cli and could drain the queue: $payload"
  queued || fail "message was not left queued after child payload: $payload"
done
pass 'Claude, Grok, and Codex child payloads (including the f1d7a792 sub-worker) emit nothing and leave the message queued'

: > "$FAKE_CALLS"
run_hook SubagentStop "{\"hook_event_name\":\"SubagentStop\",\"session_id\":\"$SID\"}"
[ ! -s "$TMP/out" ] && [ ! -s "$FAKE_CALLS" ] && queued || fail 'SubagentStop delivered or drained the root message'
pass 'SubagentStop leaves the message queued'

: > "$FAKE_CALLS"
HQ_HOOK_AGENT_ID=a1b2c3 run_hook PostToolUse "{\"hook_event_name\":\"PostToolUse\",\"session_id\":\"$SID\"}"
[ ! -s "$TMP/out" ] && [ ! -s "$FAKE_CALLS" ] && queued || fail 'master-hook agent id did not suppress delivery'
pass 'HQ_HOOK_AGENT_ID from master-hook suppresses delivery'

ROOT_PAYLOAD="{\"hook_event_name\":\"PostToolUse\",\"session_id\":\"$SID\",\"agent_id\":null,\"transcript_path\":\"/home/u/.claude/projects/p/$SID.jsonl\",\"tool_name\":\"Read\"}"
HQ_HOOK_AGENT_ID= run_hook PostToolUse "$ROOT_PAYLOAD"
[ "$(grep -o 'relay-marker-42' "$TMP/out" | wc -l | tr -d ' ')" = 1 ] || fail 'root PostToolUse did not deliver the message exactly once'
jq -e '.hookSpecificOutput.additionalContext | contains("session conducting you")' "$TMP/out" >/dev/null || fail 'root output is not PostToolUse additionalContext'
[ ! -e "$QUEUE/pending/0001.msg" ] && [ -f "$QUEUE/delivered/0001.msg" ] || fail 'root delivery did not drain the message'
run_hook PostToolUse "$ROOT_PAYLOAD"
! grep -q 'relay-marker-42' "$TMP/out" || fail 'message was delivered a second time'
pass 'root PostToolUse delivers the message exactly once'

printf 'stop-marker-7' > "$QUEUE/pending/0002.msg"
run_hook Stop "{\"hook_event_name\":\"Stop\",\"session_id\":\"$SID\",\"stop_hook_active\":false}"
grep -q 'stop-marker-7' "$TMP/out" || fail 'root Stop did not deliver'
pass 'root Stop still delivers'

# Review C2: a resumed, forked, or launcher-spawned Grok root can carry a parent
# session id. Without subagent_type it is still the root and must receive its
# messages; treating it as a child would queue them forever with no signal.
# Also: a subagents folder higher up the transcript path is not a child.
root_payloads=(
  "{\"hook_event_name\":\"PostToolUse\",\"session_id\":\"$SID\",\"parent_session_id\":\"grok-parent\",\"tool_name\":\"Bash\"}"
  "{\"hookEventName\":\"PostToolUse\",\"sessionId\":\"$SID\",\"parentSessionId\":\"grok-parent\",\"toolName\":\"Shell\"}"
  "{\"hook_event_name\":\"Stop\",\"session_id\":\"$SID\",\"parentSessionId\":\"grok-parent\",\"stop_hook_active\":false}"
  "{\"hook_event_name\":\"PostToolUse\",\"session_id\":\"$SID\",\"transcript_path\":\"/home/u/subagents/.claude/projects/p/$SID.jsonl\",\"tool_name\":\"Read\"}"
)
n=0
for payload in "${root_payloads[@]}"; do
  n=$((n + 1))
  printf 'root-marker-%s' "$n" > "$QUEUE/pending/r$n.msg"
  event="$(jq -r '.hook_event_name // .hookEventName' <<<"$payload")"
  run_hook "$event" "$payload"
  grep -q "root-marker-$n" "$TMP/out" || fail "root payload did not deliver: $payload"
  [ ! -e "$QUEUE/pending/r$n.msg" ] || fail "root payload left the message queued: $payload"
done
pass 'roots with a parent session id and no subagent type still deliver'

# jq on Windows can end lines with CRLF. The root must still be recognised.
CRLF_BIN="$TMP/crlf-bin"
mkdir -p "$CRLF_BIN"
REAL_JQ="$(command -v jq)"
cat > "$CRLF_BIN/jq" <<FAKE
#!/usr/bin/env bash
"$REAL_JQ" "\$@" | awk '{ printf "%s\r\n", \$0 }'
exit "\${PIPESTATUS[0]}"
FAKE
chmod +x "$CRLF_BIN/jq"
printf 'crlf-marker-5' > "$QUEUE/pending/crlf.msg"
printf '%s' "{\"hook_event_name\":\"PostToolUse\",\"session_id\":\"$SID\",\"tool_name\":\"Read\"}" \
  | PATH="$CRLF_BIN:$PATH" "$LINK" PostToolUse > "$TMP/out" 2> "$TMP/err"
grep -q 'crlf-marker-5' "$TMP/out" || fail 'root payload did not deliver when jq emits CRLF line endings'
printf 'crlf-marker-6' > "$QUEUE/pending/crlf2.msg"
printf '%s' "{\"hook_event_name\":\"PostToolUse\",\"session_id\":\"$SID\",\"agent_id\":\"a1\"}" \
  | PATH="$CRLF_BIN:$PATH" "$LINK" PostToolUse > "$TMP/out" 2> "$TMP/err"
[ ! -s "$TMP/out" ] && [ -f "$QUEUE/pending/crlf2.msg" ] || fail 'child payload delivered when jq emits CRLF line endings'
rm -f "$QUEUE/pending/crlf2.msg"
pass 'CRLF jq output still delivers to the root and not to a child'

# Grok end to end: run the real adapter so the payload it rebuilds is the one
# the hook sees. A child tool call must not reach hq lanes link _deliver; the
# root's tool calls must, including a root whose payload names a parent session.
# The adapter resolves its HQ root from its own path, so it runs from a copy in
# a temporary HQ root and every hook write lands there, not in this checkout.
GHQ="$TMP/ghq"
mkdir -p "$GHQ/workspace/lanes-links/by-session"
for entry in "$ROOT"/* "$ROOT"/.[!.]*; do
  [ -e "$entry" ] || continue
  case "${entry##*/}" in .grok|workspace|.git) continue ;; esac
  ln -s "$entry" "$GHQ/${entry##*/}"
done
cp -R "$ROOT/.grok" "$GHQ/.grok"
GHQ="$(cd "$GHQ" && pwd -P)"
ADAPTER="$GHQ/.grok/hooks/hq-grok-hook-adapter.sh"
GSID="grok-link-root-only-$$"
GBIN="$TMP/gbin"
GCALLS="$TMP/gcalls"
mkdir -p "$GBIN"
cat > "$GBIN/hq" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GROK_FAKE_CALLS"
cat > /dev/null
case "$*" in
  "lanes link _deliver"*) jq -cn '{hookSpecificOutput:{hookEventName:"PostToolUse",additionalContext:"[conduct] The session conducting you sent this while you were working.\n\ngrok-marker-9"}}' ;;
esac
exit 0
FAKE
chmod +x "$GBIN/hq"
printf 'child cl-test worker\n' > "$GHQ/workspace/lanes-links/by-session/$GSID"
CURRENT="$ROOT/workspace/sessions/.current"
current_before="$(cat "$CURRENT" 2>/dev/null || printf '<absent>')"
run_grok() {
  ( cd "$GHQ" && printf '%s' "$1" | env -u CLAUDE_PROJECT_DIR -u HQ_HOOK_AGENT_ID PATH="$GBIN:$SAVED_PATH" \
      HQ_ALLOW_HQ_WORKTREE=1 HQ_PARENT_SESSION_ID=lane-launcher GROK_FAKE_CALLS="$GCALLS" "$ADAPTER" > "$TMP/gout" 2> "$TMP/gerr" ) || true
}
: > "$GCALLS"
run_grok "{\"hookEventName\":\"PostToolUse\",\"toolName\":\"Shell\",\"toolInput\":{\"command\":\"echo hi\"},\"cwd\":\"$GHQ\",\"sessionId\":\"$GSID\",\"parentSessionId\":\"grok-parent-$$\",\"subagentType\":\"explorer\"}"
! grep -q 'lanes link _deliver' "$GCALLS" || fail 'Grok child tool call reached hq lanes link _deliver'
! grep -q 'grok-marker-9' "$TMP/gout" || fail 'Grok child tool call received link text'
pass 'Grok child tool call (subagentType + parentSessionId) does not deliver'
: > "$GCALLS"
run_grok "{\"hookEventName\":\"PostToolUse\",\"toolName\":\"Shell\",\"toolInput\":{\"command\":\"echo hi\"},\"cwd\":\"$GHQ\",\"sessionId\":\"$GSID\"}"
grep -q 'lanes link _deliver --event PostToolUse' "$GCALLS" || fail "Grok root tool call did not reach hq lanes link _deliver (calls: $(tr '\n' ';' < "$GCALLS"))"
pass 'Grok root tool call still delivers, even with HQ_PARENT_SESSION_ID inherited from a lane launcher'
: > "$GCALLS"
run_grok "{\"hookEventName\":\"PostToolUse\",\"toolName\":\"Shell\",\"toolInput\":{\"command\":\"echo hi\"},\"cwd\":\"$GHQ\",\"sessionId\":\"$GSID\",\"parentSessionId\":\"grok-parent-$$\"}"
grep -q 'lanes link _deliver --event PostToolUse' "$GCALLS" || fail "Grok root with parentSessionId and no subagentType did not reach hq lanes link _deliver (calls: $(tr '\n' ';' < "$GCALLS"))"
pass 'Grok root with parentSessionId and no subagentType (resumed, forked, or launcher-spawned) still delivers'
[ "$(cat "$CURRENT" 2>/dev/null || printf '<absent>')" = "$current_before" ] || fail "Grok end-to-end run changed this checkout's workspace/sessions/.current"
[ ! -e "$ROOT/workspace/lanes-links/by-session/$GSID" ] && [ ! -e "$ROOT/workspace/sessions/$GSID" ] || fail 'Grok end-to-end run wrote session state into this checkout'
pass "Grok end-to-end run leaves this checkout's workspace untouched"

echo 'conduct-lanes-link-deliver-root-only: all checks passed'
