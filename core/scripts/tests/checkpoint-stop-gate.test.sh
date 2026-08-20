#!/usr/bin/env bash
# Regression tests for the checkpoint Stop hook.
#
# SCOPE. As of 2026-08-20 this hook is a delegating shim: the gate logic — the
# checkpoint requirement, the reply demand, the loop guard and the opt-in
# company-scope gate — lives in the CLI as `hq core checkpoint-stop-gate`, and
# its behavior is covered by hq-cli's own suite
# (test/commands/checkpoint-stop-gate.test.ts) against the asset that actually
# runs. What remains hq-core's to prove, and what this file tests, is:
#
#   * delegation happens when the installed CLI provides the command, with the
#     hook payload passed through untouched and the CLI's decision emitted
#     verbatim;
#   * every path where the gate is unavailable is a SILENT allow — a missing
#     hq, a CLI too old to advertise the command, or the opt-out env var — so a
#     stale install can never strand a session at Stop;
#   * the capability probe is cached rather than re-run per turn;
#   * no gate logic has crept back into this file;
#   * registration: hook-gate routing, profile membership, and the Codex
#     adapter's Stop/SessionStart wiring.
#
# The local `hq` shim supplies the CLI contract; the released CLI is
# deliberately never used here.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
HOOK="$ROOT/.claude/hooks/checkpoint-stop-gate.sh"
ADAPTER="$ROOT/.codex/hooks/hq-codex-hook-adapter.sh"
REPROMPT_HOOK="$ROOT/.claude/hooks/inject-codex-checkpoint-reprompt.sh"
BASH_BIN="$(command -v bash)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "  ok — $*"; }

assert_empty() {
  local value="$1"
  local label="$2"
  [ -z "$value" ] || fail "$label: expected empty stdout, got: $value"
}

[ -x "$HOOK" ] || fail "checkpoint Stop hook is not executable: $HOOK"
[ -x "$ADAPTER" ] || fail "Codex hook adapter is not executable: $ADAPTER"

FIXTURE="$TMP_ROOT/hq"
STATE_DIR="$FIXTURE/workspace/orchestrator/hook-state"
SHIM_DIR="$TMP_ROOT/shim-bin"
NO_HQ_DIR="$TMP_ROOT/no-hq-bin"
SHIM_LOG="$TMP_ROOT/hq-shim.log"
mkdir -p "$FIXTURE/.claude/hooks" "$FIXTURE/.codex/hooks" "$FIXTURE/core/scripts/lib" "$STATE_DIR" "$SHIM_DIR" "$NO_HQ_DIR"
cp "$ROOT/core/scripts/hook-lib.sh" "$FIXTURE/core/scripts/hook-lib.sh"
# The adapter dispatches Stop hooks by reading settings.json through the shared
# lib; provide both so checkpoint-stop-gate is dispatched exactly as in Codex.
cp "$ROOT/core/scripts/lib/hook-adapter-core.sh" "$FIXTURE/core/scripts/lib/hook-adapter-core.sh"
cp "$ROOT/.claude/settings.json" "$FIXTURE/.claude/settings.json"
cp "$HOOK" "$FIXTURE/.claude/hooks/checkpoint-stop-gate.sh"
cp "$ROOT/.claude/hooks/hook-gate.sh" "$FIXTURE/.claude/hooks/hook-gate.sh"
cp "$ADAPTER" "$FIXTURE/.codex/hooks/hq-codex-hook-adapter.sh"
[ ! -f "$REPROMPT_HOOK" ] || cp "$REPROMPT_HOOK" "$FIXTURE/.claude/hooks/inject-codex-checkpoint-reprompt.sh"
chmod +x \
  "$FIXTURE/.claude/hooks/checkpoint-stop-gate.sh" \
  "$FIXTURE/.claude/hooks/hook-gate.sh" \
  "$FIXTURE/.codex/hooks/hq-codex-hook-adapter.sh"
[ ! -f "$FIXTURE/.claude/hooks/inject-codex-checkpoint-reprompt.sh" ] || \
  chmod +x "$FIXTURE/.claude/hooks/inject-codex-checkpoint-reprompt.sh"

# Keep this integration fixture focused on Stop-decision propagation. The
# neighboring advisory Stop hooks are inert but present so the public adapter
# entrypoint runs exactly as it does in Codex.
for hook_name in \
  observe-patterns \
  cleanup-mcp-processes \
  context-warning-50 \
  capture-estimates \
  enforce-capability-link-render; do
  printf '#!/usr/bin/env bash\ncat >/dev/null\nexit 0\n' >"$FIXTURE/.claude/hooks/$hook_name.sh"
  chmod +x "$FIXTURE/.claude/hooks/$hook_name.sh"
done

# The shim stands in for the installed CLI. HQ_SHIM_CLI_HAS_GATE=1 makes it
# advertise (and honor) `checkpoint-stop-gate`; without it the shim models a CLI
# too old to host the gate. Every invocation is logged so a test can assert what
# the hook actually called, and the delegated command records its stdin so
# payload passthrough is provable.
cat >"$SHIM_DIR/hq" <<'SHIM'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$HQ_SHIM_LOG"
if [ "${1:-}" = "core" ] && [ "${2:-}" = "--help" ]; then
  [ "${HQ_SHIM_CLI_HAS_GATE:-}" = "1" ] && printf 'checkpoint-stop-gate\nhq-session\n'
  exit 0
fi
if [ "${1:-}" = "core" ] && [ "${2:-}" = "checkpoint-stop-gate" ] && [ "${HQ_SHIM_CLI_HAS_GATE:-}" = "1" ]; then
  cat >"${HQ_SHIM_STDIN_CAPTURE:-/dev/null}" 2>/dev/null || true
  # Braces in a `${VAR:-default}` default terminate the expansion early, so the
  # fallback decision is assigned on its own line rather than inline.
  shim_out="${HQ_SHIM_GATE_OUTPUT:-}"
  # @none models the CLI allowing the turn: exit 0 having printed nothing.
  [ "$shim_out" = "@none" ] && exit 0
  [ -n "$shim_out" ] || shim_out='{"decision":"block","reason":"CLI-DELEGATED"}'
  printf '%s\n' "$shim_out"
  exit 0
fi
exit 0
SHIM
chmod +x "$SHIM_DIR/hq"

# A deliberately hq-free PATH lets the missing-CLI case be deterministic even
# on developer machines that have an unrelated hq binary installed.
for tool in cat jq mkdir tail tr date stat cksum awk rm; do
  tool_path="$(command -v "$tool" 2>/dev/null || true)"
  [ -n "$tool_path" ] || fail "required test utility is unavailable: $tool"
  ln -s "$tool_path" "$NO_HQ_DIR/$tool"
done

append_codex_user() {
  local transcript="$1"
  jq -nc '{
    timestamp: "2026-08-02T00:00:00Z",
    type: "response_item",
    payload: {
      type: "message",
      role: "user",
      content: [{type: "input_text", text: "prompt"}]
    }
  }' >>"$transcript"
}

append_codex_tool() {
  local transcript="$1"
  local id="$2"
  local command="$3"
  jq -nc --arg id "$id" --arg command "$command" '{
    timestamp: "2026-08-02T00:00:01Z",
    type: "response_item",
    payload: {
      type: "custom_tool_call",
      call_id: $id,
      name: "exec",
      status: "completed",
      input: ("const r = await tools.exec_command(" + ({cmd: $command} | tojson) + "); text(r.output);")
    }
  }' >>"$transcript"
}

new_transcript() {
  local label="$1"
  TRANSCRIPT="$TMP_ROOT/$label.jsonl"
  : >"$TRANSCRIPT"
}

reset_case() {
  rm -f "$STATE_DIR"/checkpoint-cli-last* "$STATE_DIR"/codex-checkpoint-reprompt-* \
    "$STATE_DIR"/cli-caps* "$SHIM_LOG" "$TMP_ROOT"/stdin-capture
  RUN_PATH="$SHIM_DIR:$PATH"
  RUN_NO_CLI=""
  RUN_CLI_HAS_GATE=1
  RUN_GATE_OUTPUT=""
  RUN_STDIN_CAPTURE=""
}

run_hook() {
  local session="$1"
  local transcript="${2:-}"
  local stderr_path="$TMP_ROOT/hook.stderr"
  local payload
  payload="$(printf '{"session_id":"%s","transcript_path":"%s","stop_hook_active":false,"cwd":"%s"}' "$session" "$transcript" "$FIXTURE")"
  HOOK_STDERR=""
  HOOK_STDOUT="$(env \
    "CLAUDE_PROJECT_DIR=$FIXTURE" \
    "HQ_SHIM_LOG=$SHIM_LOG" \
    "HQ_SHIM_CLI_HAS_GATE=$RUN_CLI_HAS_GATE" \
    "HQ_SHIM_GATE_OUTPUT=$RUN_GATE_OUTPUT" \
    "HQ_SHIM_STDIN_CAPTURE=$RUN_STDIN_CAPTURE" \
    "HQ_CHECKPOINT_GATE_NO_CLI=$RUN_NO_CLI" \
    "HQ_CLI_CAPS_CACHE=$STATE_DIR/cli-caps" \
    "PATH=$RUN_PATH" \
    "$BASH_BIN" "$FIXTURE/.claude/hooks/checkpoint-stop-gate.sh" <<<"$payload" 2>"$stderr_path")"
  HOOK_STATUS=$?
  HOOK_STDERR="$(cat "$stderr_path")"
}

run_codex_stop() {
  local session="$1"
  local transcript="$2"
  local stderr_path="$TMP_ROOT/codex-hook.stderr"
  local payload
  payload="$(printf '{"hook_event_name":"Stop","session_id":"%s","transcript_path":"%s","stop_hook_active":false,"cwd":"%s"}' "$session" "$transcript" "$FIXTURE")"
  CODEX_STDERR=""
  CODEX_STDOUT="$(env \
    "HQ_ROOT=$FIXTURE" \
    "HQ_SHIM_LOG=$SHIM_LOG" \
    "HQ_SHIM_CLI_HAS_GATE=$RUN_CLI_HAS_GATE" \
    "HQ_SHIM_GATE_OUTPUT=$RUN_GATE_OUTPUT" \
    "HQ_CLI_CAPS_CACHE=$STATE_DIR/cli-caps-codex" \
    "PATH=$SHIM_DIR:$PATH" \
    "$BASH_BIN" "$FIXTURE/.codex/hooks/hq-codex-hook-adapter.sh" <<<"$payload" 2>"$stderr_path")"
  CODEX_STATUS=$?
  CODEX_STDERR="$(cat "$stderr_path")"
}

run_codex_session_start() {
  local session="$1"
  local source="$2"
  local stderr_path="$TMP_ROOT/codex-session-start.stderr"
  local payload
  payload="$(jq -nc --arg session "$session" --arg source "$source" --arg cwd "$FIXTURE" '{
    hook_event_name: "SessionStart",
    session_id: $session,
    source: $source,
    cwd: $cwd
  }')"
  CODEX_SESSION_STDERR=""
  CODEX_SESSION_STDOUT="$(env \
    "HQ_ROOT=$FIXTURE" \
    "PATH=$SHIM_DIR:$PATH" \
    "$BASH_BIN" "$FIXTURE/.codex/hooks/hq-codex-hook-adapter.sh" <<<"$payload" 2>"$stderr_path")"
  CODEX_SESSION_STATUS=$?
  CODEX_SESSION_STDERR="$(cat "$stderr_path")"
}

assert_allow() {
  local label="$1"
  [ "$HOOK_STATUS" -eq 0 ] || fail "$label: expected exit 0, got $HOOK_STATUS"
  assert_empty "$HOOK_STDOUT" "$label"
}

# ---------------------------------------------------------------------------
# Delegation
# ---------------------------------------------------------------------------

# 1. When the CLI advertises the command, the hook delegates and emits the
# CLI's decision verbatim.
reset_case
new_transcript 1-delegate
run_hook s-delegate "$TRANSCRIPT"
[ "$HOOK_STATUS" -eq 0 ] || fail "delegation: expected exit 0, got $HOOK_STATUS"
printf '%s' "$HOOK_STDOUT" | jq -e '.reason == "CLI-DELEGATED"' >/dev/null \
  || fail "delegation: hook did not emit the CLI decision: $HOOK_STDOUT"
grep -qF 'core checkpoint-stop-gate' "$SHIM_LOG" \
  || fail "delegation: the CLI gate command was never invoked"
pass "delegates to the CLI-hosted gate and emits its decision verbatim"

# 2. An arbitrary CLI decision is passed through untouched — the hook never
# rewrites, filters, or second-guesses the gate's verdict.
reset_case
RUN_GATE_OUTPUT='{"decision":"block","reason":"ARBITRARY REASON TEXT"}'
new_transcript 2-passthrough
run_hook s-passthrough "$TRANSCRIPT"
printf '%s' "$HOOK_STDOUT" | jq -e '.reason == "ARBITRARY REASON TEXT"' >/dev/null \
  || fail "passthrough: decision was altered: $HOOK_STDOUT"
pass "the CLI decision is passed through unaltered"

# 3. The hook payload reaches the delegated command on stdin intact: the gate
# cannot decide anything without it, and the capability probe must not consume
# it.
reset_case
RUN_STDIN_CAPTURE="$TMP_ROOT/stdin-capture"
new_transcript 3-stdin
run_hook s-stdin-passthrough "$TRANSCRIPT"
[ -s "$RUN_STDIN_CAPTURE" ] || fail "payload passthrough: the CLI received no stdin"
jq -e --arg session s-stdin-passthrough --arg transcript "$TRANSCRIPT" '
  .session_id == $session and .transcript_path == $transcript
' "$RUN_STDIN_CAPTURE" >/dev/null \
  || fail "payload passthrough: stdin was not the hook payload: $(cat "$RUN_STDIN_CAPTURE")"
pass "the hook payload reaches the CLI gate on stdin intact"

# ---------------------------------------------------------------------------
# Fail-open: no gate available means no decision, never a stranded session
# ---------------------------------------------------------------------------

# 4. A CLI too old to advertise the command: the gate does not run and the turn
# ends normally. This is the behavior change of 2026-08-20 — the in-tree copy
# of the gate that used to run here has been removed.
reset_case
RUN_CLI_HAS_GATE=""
new_transcript 4-old-cli
run_hook s-old-cli "$TRANSCRIPT"
assert_allow "CLI without the gate command"
assert_empty "$HOOK_STDERR" "CLI without the gate command"
pass "a CLI too old for the gate allows silently"

# 5. Missing hq entirely is an allow path and remains quiet.
reset_case
RUN_PATH="$NO_HQ_DIR"
new_transcript 5-no-hq
run_hook s-no-hq "$TRANSCRIPT"
assert_allow "missing hq"
assert_empty "$HOOK_STDERR" "missing hq"
pass "a missing hq binary allows quietly"

# 6. HQ_CHECKPOINT_GATE_NO_CLI=1 skips delegation, which now means no gate at
# all — and it must not even probe the CLI.
reset_case
RUN_NO_CLI=1
new_transcript 6-no-cli-optout
run_hook s-no-cli-optout "$TRANSCRIPT"
assert_allow "HQ_CHECKPOINT_GATE_NO_CLI=1"
[ ! -s "$SHIM_LOG" ] || fail "HQ_CHECKPOINT_GATE_NO_CLI=1 still invoked the CLI: $(cat "$SHIM_LOG")"
pass "HQ_CHECKPOINT_GATE_NO_CLI=1 disables the gate without probing"

# 7. A transcript that is missing or unreadable is the CLI's problem, not the
# hook's: delegation still happens and the CLI's verdict stands.
reset_case
run_hook s-missing-transcript "$TMP_ROOT/does-not-exist.jsonl"
printf '%s' "$HOOK_STDOUT" | jq -e '.reason == "CLI-DELEGATED"' >/dev/null \
  || fail "missing transcript: hook did not delegate: $HOOK_STDOUT"
pass "the hook delegates regardless of transcript state"

# ---------------------------------------------------------------------------
# Capability probe caching
# ---------------------------------------------------------------------------

# 8. `hq core --help` costs seconds of node startup, so the positive probe is
# cached and not repeated on the next turn.
reset_case
new_transcript 8-cache
run_hook s-cache-first "$TRANSCRIPT"
[ -s "$STATE_DIR/cli-caps" ] || fail "probe cache: no cache file was written"
: >"$SHIM_LOG"
run_hook s-cache-second "$TRANSCRIPT"
printf '%s' "$HOOK_STDOUT" | jq -e '.reason == "CLI-DELEGATED"' >/dev/null \
  || fail "probe cache: second run did not delegate: $HOOK_STDOUT"
grep -qF 'core --help' "$SHIM_LOG" \
  && fail "probe cache: --help was re-run despite a cached result"
pass "the capability probe is cached across turns"

# 9. A failed probe is never persisted, so a transient failure cannot pin the
# gate off for the life of the cache.
reset_case
RUN_CLI_HAS_GATE=""
new_transcript 9-negative-cache
run_hook s-negative-cache "$TRANSCRIPT"
assert_allow "negative probe"
[ ! -s "$STATE_DIR/cli-caps" ] || \
  fail "probe cache: an empty/failed probe was persisted: $(cat "$STATE_DIR/cli-caps")"
pass "a failed capability probe is not cached"

# ---------------------------------------------------------------------------
# No gate logic in the shim
# ---------------------------------------------------------------------------

# 10. The gate body must not creep back in. hq-cli owns the logic; a second
# copy here is what this refactor removed, and the drift it caused is why.
hook_body="$(grep -v '^[[:space:]]*#' "$HOOK" || true)"
for marker in \
  'trigger stop-gate' \
  'real_user' \
  'checkpoint_command' \
  'company_slug' \
  'HQ_CHECKPOINT_SCOPE_GATE_DOMAINS' \
  'checkpoint-block-count' \
  'checkpoint-reply-nudge'; do
  printf '%s' "$hook_body" | grep -qF -- "$marker" \
    && fail "gate logic has returned to the shim (found: $marker) — it belongs in hq-cli"
done
printf '%s' "$hook_body" | grep -q 'decision' \
  && fail "the shim emits its own Stop decision — only the CLI may decide"
[ "$(wc -l <"$HOOK")" -lt 120 ] \
  || fail "the shim has grown past a delegating wrapper ($(wc -l <"$HOOK") lines)"
pass "the shim carries no gate logic of its own"

# ---------------------------------------------------------------------------
# Registration
# ---------------------------------------------------------------------------

# 11. Registration is routed through hook-gate and all profiles contain it.
grep -qF 'hook-gate.sh\" checkpoint-stop-gate \"$CLAUDE_PROJECT_DIR/.claude/hooks/checkpoint-stop-gate.sh\"' \
  "$ROOT/.claude/settings.json" || fail "settings.json has no checkpoint Stop-gate registration"
for profile in standard strict; do
  profile_body="$(sed -n "/is_in_${profile}_profile()/,/^}/p" "$ROOT/.claude/hooks/hook-gate.sh")"
  printf '%s' "$profile_body" | grep -q 'checkpoint-stop-gate' || fail "$profile hook profile omits checkpoint-stop-gate"
done
[ -x "$HOOK" ] || fail "checkpoint Stop hook is not executable"
pass "registration and profile membership are present"

# ---------------------------------------------------------------------------
# Codex adapter wiring (hq-core owns the adapter; the CLI owns the verdict)
# ---------------------------------------------------------------------------

# 12. A Stop block from the CLI gate propagates through the Codex adapter
# unchanged, including the synthetic continuation marker Codex expects.
reset_case
RUN_GATE_OUTPUT='{"decision":"block","reason":"Hook re-prompted Codex"}'
new_transcript 12-codex-block
append_codex_user "$TRANSCRIPT"
append_codex_tool "$TRANSCRIPT" tu-12 'git status'
run_codex_stop s-codex-block "$TRANSCRIPT"
[ "$CODEX_STATUS" -eq 0 ] || fail "Codex block: adapter exited $CODEX_STATUS: $CODEX_STDERR"
printf '%s' "$CODEX_STDOUT" | jq -e '
  .decision == "block" and .reason == "Hook re-prompted Codex"
' >/dev/null || fail "Codex block: expected one block decision, got: $CODEX_STDOUT"
pass "a CLI Stop block propagates through the Codex adapter"

# 13. An allow from the CLI gate stays an allow through the adapter — it must
# not invent a continuation.
reset_case
RUN_GATE_OUTPUT="@none"
new_transcript 13-codex-allow
append_codex_user "$TRANSCRIPT"
append_codex_tool "$TRANSCRIPT" tu-13 'hq core checkpoint --session-id s-codex-allow --idle'
run_codex_stop s-codex-allow "$TRANSCRIPT"
[ "$CODEX_STATUS" -eq 0 ] || fail "Codex allow: adapter exited $CODEX_STATUS: $CODEX_STDERR"
printf '%s' "$CODEX_STDOUT" | jq -e 'has("decision") | not' >/dev/null 2>&1 \
  || [ -z "$(printf '%s' "$CODEX_STDOUT" | tr -d '[:space:]')" ] \
  || fail "Codex allow: adapter invented a decision: $CODEX_STDOUT"
pass "a CLI allow stays an allow through the Codex adapter"

# 14. SessionStart preloads marker handling at startup and after compact.
reset_case
run_codex_session_start s-codex-guidance startup
[ "$CODEX_SESSION_STATUS" -eq 0 ] || fail "Codex startup guidance: adapter exited $CODEX_SESSION_STATUS: $CODEX_SESSION_STDERR"
printf '%s' "$CODEX_SESSION_STDOUT" | jq -e --arg session s-codex-guidance '
  .hookSpecificOutput.hookEventName == "SessionStart"
  and (.hookSpecificOutput.additionalContext | contains("Hook re-prompted Codex"))
  and (.hookSpecificOutput.additionalContext | contains($session))
  and (.hookSpecificOutput.additionalContext | contains("codex-checkpoint-reprompt-" + $session))
' >/dev/null || fail "Codex startup guidance missing: $CODEX_SESSION_STDOUT"
run_codex_session_start s-codex-guidance compact
[ "$CODEX_SESSION_STATUS" -eq 0 ] || fail "Codex compact guidance: adapter exited $CODEX_SESSION_STATUS: $CODEX_SESSION_STDERR"
printf '%s' "$CODEX_SESSION_STDOUT" | jq -e '
  .hookSpecificOutput.hookEventName == "SessionStart"
  and (.hookSpecificOutput.additionalContext | contains("Hook re-prompted Codex"))
' >/dev/null || fail "Codex compact guidance missing: $CODEX_SESSION_STDOUT"
grep -qF 'matcher = "startup|resume|clear|compact"' "$ROOT/.codex/config.toml" || \
  fail "Codex SessionStart registration does not include compact"
pass "Codex SessionStart guidance is injected at startup and compact"

# 15. The continuation guidance is Codex-only and registered in hook profiles.
[ "$(git -C "$ROOT" ls-files --stage .claude/hooks/inject-codex-checkpoint-reprompt.sh | awk '{print $1}')" = "100755" ] || \
  fail "Codex checkpoint re-prompt hook is not tracked as executable: $REPROMPT_HOOK"
for profile in standard strict; do
  profile_body="$(sed -n "/is_in_${profile}_profile()/,/^}/p" "$ROOT/.claude/hooks/hook-gate.sh")"
  printf '%s' "$profile_body" | grep -q 'inject-codex-checkpoint-reprompt' || \
    fail "$profile hook profile omits inject-codex-checkpoint-reprompt"
done
session_start_body="$(sed -n '/^  SessionStart)/,/^    ;;/p' "$ADAPTER")"
printf '%s' "$session_start_body" | grep -qF 'run_hook "inject-codex-checkpoint-reprompt"' || \
  fail "Codex adapter does not preload checkpoint guidance at SessionStart"
user_prompt_body="$(sed -n '/^  UserPromptSubmit)/,/^    ;;/p' "$ADAPTER")"
if printf '%s' "$user_prompt_body" | grep -qF 'run_hook "inject-codex-checkpoint-reprompt"'; then
  fail "Codex adapter must not proxy checkpoint guidance through UserPromptSubmit"
fi
if grep -qF 'inject-codex-checkpoint-reprompt' "$ROOT/.claude/settings.json"; then
  fail "Codex checkpoint re-prompt hook must not be registered for Claude Code"
fi
pass "checkpoint continuation guidance is registered only through Codex"

echo "checkpoint Stop gate: ok"
