#!/usr/bin/env bash
# Regression tests for the checkpoint Stop gate. The released CLI intentionally
# is not used here: a local shim supplies the gate-probe contract.

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

assert_block() {
  local value="$1"
  local session="$2"
  local label="$3"
  printf '%s' "$value" | grep -q '"decision":"block"' || fail "$label: no block decision: $value"
  printf '%s' "$value" | grep -qF "$session" || fail "$label: session id missing from reason: $value"
}

assert_codex_block() {
  local value="$1"
  local label="$2"
  printf '%s' "$value" | jq -e '
    .decision == "block" and .reason == "Hook re-prompted Codex"
  ' >/dev/null || fail "$label: expected Codex re-prompt marker, got: $value"
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

cat >"$SHIM_DIR/hq" <<'SHIM'
#!/usr/bin/env bash
printf '%s\n' "$@" >>"$HQ_SHIM_LOG"
# The in-tree hook and hq-session prefer the CLI-hosted implementation, probing
# `hq core --help` for the command name. Only advertise (and honor) those
# commands when HQ_SHIM_CLI_HAS_GATE=1, so every pre-existing case exercises the
# in-tree fallback exactly as before.
if [ "${1:-}" = "core" ] && [ "${2:-}" = "--help" ]; then
  [ "${HQ_SHIM_CLI_HAS_GATE:-}" = "1" ] && printf 'checkpoint-stop-gate\nhq-session\n'
  exit 0
fi
if [ "${1:-}" = "core" ] && [ "${2:-}" = "checkpoint-stop-gate" ] && [ "${HQ_SHIM_CLI_HAS_GATE:-}" = "1" ]; then
  cat >/dev/null 2>&1 || true
  printf '%s\n' "${HQ_SHIM_GATE_OUTPUT:-{\"decision\":\"block\",\"reason\":\"CLI-DELEGATED\"}}"
  exit 0
fi
if [ "${1:-}" = "core" ] && [ "${2:-}" = "checkpoint" ] && [ "${3:-}" = "--gate-probe" ]; then
  mkdir -p "$HQ_SHIM_ROOT/workspace/orchestrator/hook-state"
  runtime="${HQ_CHECKPOINT_RUNTIME:-other}"
  printf '%s' "${HQ_SHIM_VERDICT:-1}" >"$HQ_SHIM_ROOT/workspace/orchestrator/hook-state/checkpoint-gate-eligible-$runtime"
fi
SHIM
chmod +x "$SHIM_DIR/hq"

# A deliberately hq-free PATH lets the missing-CLI case be deterministic even
# on developer machines that have an unrelated hq binary installed.
for tool in cat jq mkdir tail tr date stat cksum awk rm; do
  tool_path="$(command -v "$tool" 2>/dev/null || true)"
  [ -n "$tool_path" ] || fail "required test utility is unavailable: $tool"
  ln -s "$tool_path" "$NO_HQ_DIR/$tool"
done

append_user() {
  local transcript="$1"
  local uuid="$2"
  printf '{"type":"user","uuid":"%s","message":{"content":"prompt"}}\n' "$uuid" >>"$transcript"
}

append_tool() {
  local transcript="$1"
  local id="$2"
  local name="$3"
  local command="$4"
  printf '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"%s","name":"%s","input":{"command":"%s"}}]}}\n' \
    "$id" "$name" "$command" >>"$transcript"
}

append_result() {
  local transcript="$1"
  local id="$2"
  local is_error="$3"
  printf '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"%s","is_error":%s}]}}\n' \
    "$id" "$is_error" >>"$transcript"
}

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

append_codex_js_object_tool() {
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
      input: ("const r = await tools.exec_command({cmd:" + ($command | tojson) + ",workdir:\"/tmp\"}); text(r.output);")
    }
  }' >>"$transcript"
}

append_codex_result() {
  local transcript="$1"
  local id="$2"
  jq -nc --arg id "$id" '{
    timestamp: "2026-08-02T00:00:02Z",
    type: "response_item",
    payload: {
      type: "custom_tool_call_output",
      call_id: $id,
      output: [{type: "input_text", text: "Script completed"}]
    }
  }' >>"$transcript"
}

new_transcript() {
  local label="$1"
  TRANSCRIPT="$TMP_ROOT/$label.jsonl"
  : >"$TRANSCRIPT"
}

set_verdict() {
  local verdict="$1"
  local runtime="${2:-codex}"
  printf '%s' "$verdict" >"$STATE_DIR/checkpoint-gate-eligible-$runtime"
}

clear_verdict() {
  rm -f "$STATE_DIR"/checkpoint-gate-eligible-*
}

reset_case() {
  rm -f "$STATE_DIR"/stop-gate-blocks-* "$STATE_DIR"/checkpoint-cli-last* \
    "$STATE_DIR"/codex-checkpoint-reprompt-* "$STATE_DIR"/cli-caps* "$SHIM_LOG"
  RUN_PATH="$SHIM_DIR:$PATH"
  RUN_GATE=""
  RUN_RUNTIME=""
  RUN_SIBLING=""
  RUN_EMAIL=""
  RUN_CLI_HAS_GATE=""
  RUN_DOMAINS=""
  RUN_TOKENS=""
}

# The scope gate resolves the caller email from the local Cognito token cache.
# Point every run at a file that never exists so the developer's real ~/.hq token
# cannot leak in and flip cases that predate the gate; the gate cases drive
# identity explicitly through RUN_EMAIL (or a crafted RUN_TOKENS file) instead.
# The gate is opt-in: RUN_DOMAINS feeds HQ_CHECKPOINT_SCOPE_GATE_DOMAINS, so a
# case only exercises it when it sets a domain. GATE_DOMAIN is the synthetic
# domain these tests gate on (never a real company domain).
ABSENT_TOKEN="$TMP_ROOT/absent-cognito-tokens.json"
GATE_DOMAIN="operator.example"

# session_meta <session_id> [company_slug]
#   Materialize workspace/sessions/<id>/meta.yaml under the fixture. Pass a slug
#   to bind the session; omit it to leave the session unbound.
session_meta() {
  local id="$1" slug="${2:-}" dir
  dir="$FIXTURE/workspace/sessions/$id"
  mkdir -p "$dir"
  if [ -n "$slug" ]; then
    printf 'session_id: "%s"\ncompany_slug: "%s"\n' "$id" "$slug" >"$dir/meta.yaml"
  else
    printf 'session_id: "%s"\n' "$id" >"$dir/meta.yaml"
  fi
}

# tenant <slug>  — create a real tenant directory so a binding to it counts.
tenant() { mkdir -p "$FIXTURE/companies/$1"; }

# b64url <string>  — base64url with padding stripped (JWT segment encoding).
b64url() { printf '%s' "$1" | base64 | tr '+/' '-_' | tr -d '=\n'; }

# mint_token <path> <idToken-payload-json> <accessToken-payload-json>
#   Write a Cognito-tokens.json whose id/access tokens carry the given claims,
#   with a far-future expiresAt so the reader accepts them.
mint_token() {
  local path="$1" id_payload="$2" acc_payload="$3"
  local hdr; hdr="$(b64url '{"alg":"none"}')"
  local id_tok acc_tok
  id_tok="$hdr.$(b64url "$id_payload").sig"
  acc_tok="$hdr.$(b64url "$acc_payload").sig"
  jq -nc --arg id "$id_tok" --arg acc "$acc_tok" \
    '{idToken:$id, accessToken:$acc, expiresAt: 9999999999999}' >"$path"
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

run_hook() {
  local session="$1"
  local transcript="$2"
  local stderr_path="$TMP_ROOT/hook.stderr"
  local payload
  payload="$(printf '{"session_id":"%s","transcript_path":"%s","stop_hook_active":false,"cwd":"%s"}' "$session" "$transcript" "$FIXTURE")"
  HOOK_STDERR=""
  HOOK_STDOUT="$(env \
    "CLAUDE_PROJECT_DIR=$FIXTURE" \
    "HQ_SHIM_LOG=$SHIM_LOG" \
    "HQ_SHIM_ROOT=$FIXTURE" \
    "HQ_SHIM_VERDICT=1" \
    "HQ_CHECKPOINT_GATE=$RUN_GATE" \
    "HQ_CHECKPOINT_RUNTIME=$RUN_RUNTIME" \
    "HQ_CHECKPOINT_SIBLING=$RUN_SIBLING" \
    "HQ_CHECKPOINT_CALLER_EMAIL=$RUN_EMAIL" \
    "HQ_COGNITO_TOKENS_FILE=${RUN_TOKENS:-$ABSENT_TOKEN}" \
    "HQ_CHECKPOINT_SCOPE_GATE_DOMAINS=$RUN_DOMAINS" \
    "HQ_SHIM_CLI_HAS_GATE=$RUN_CLI_HAS_GATE" \
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
    "HQ_SHIM_ROOT=$FIXTURE" \
    "HQ_SHIM_VERDICT=1" \
    "HQ_COGNITO_TOKENS_FILE=$ABSENT_TOKEN" \
    "HQ_CLI_CAPS_CACHE=$STATE_DIR/cli-caps-codex" \
    "PATH=$SHIM_DIR:$PATH" \
    "$BASH_BIN" "$FIXTURE/.codex/hooks/hq-codex-hook-adapter.sh" <<<"$payload" 2>"$stderr_path")"
  CODEX_STATUS=$?
  CODEX_STDERR="$(cat "$stderr_path")"
}

wait_for_probe() {
  local label="$1"
  local attempts=0
  while [ "$attempts" -lt 40 ]; do
    if grep -q -- '--gate-probe' "$SHIM_LOG" 2>/dev/null; then
      return 0
    fi
    sleep 0.05
    attempts=$((attempts + 1))
  done
  fail "$label: shim did not receive --gate-probe"
}

assert_allow() {
  local label="$1"
  [ "$HOOK_STATUS" -eq 0 ] || fail "$label: expected exit 0, got $HOOK_STATUS"
  assert_empty "$HOOK_STDOUT" "$label"
}

# 1. Eligible, final successful checkpoint call.
reset_case
set_verdict 1
new_transcript 1-ok
append_user "$TRANSCRIPT" u-ok
append_tool "$TRANSCRIPT" tu-1 Bash 'hq core checkpoint --idle'
append_result "$TRANSCRIPT" tu-1 false
run_hook s-ok "$TRANSCRIPT"
assert_allow "successful final checkpoint"
pass "successful final checkpoint allows"

# 2. Eligible tool turn without a checkpoint.
reset_case
set_verdict 1
new_transcript 2-missing
append_user "$TRANSCRIPT" u-missing
append_tool "$TRANSCRIPT" tu-2 Bash 'git status'
append_result "$TRANSCRIPT" tu-2 false
run_hook s-missing "$TRANSCRIPT"
assert_block "$HOOK_STDOUT" s-missing "missing checkpoint"
pass "missing checkpoint blocks"

# 3. A later tool invalidates an otherwise valid checkpoint.
reset_case
set_verdict 1
new_transcript 3-later-tool
append_user "$TRANSCRIPT" u-later-tool
append_tool "$TRANSCRIPT" tu-3a Bash 'hq core checkpoint --idle'
append_result "$TRANSCRIPT" tu-3a false
append_tool "$TRANSCRIPT" tu-3b Bash 'git status'
append_result "$TRANSCRIPT" tu-3b false
run_hook s-later-tool "$TRANSCRIPT"
assert_block "$HOOK_STDOUT" s-later-tool "later tool after checkpoint"
pass "later tool after checkpoint blocks"

# 4. A failed checkpoint does not satisfy the gate.
reset_case
set_verdict 1
new_transcript 4-failed-checkpoint
append_user "$TRANSCRIPT" u-failed-checkpoint
append_tool "$TRANSCRIPT" tu-4 Bash 'hq core checkpoint --idle'
append_result "$TRANSCRIPT" tu-4 true
run_hook s-failed-checkpoint "$TRANSCRIPT"
assert_block "$HOOK_STDOUT" s-failed-checkpoint "failed checkpoint"
pass "failed checkpoint blocks"

# 5. Environment-prefixed checkpoint invocations count.
reset_case
set_verdict 1
new_transcript 5-env-prefix
append_user "$TRANSCRIPT" u-env-prefix
append_tool "$TRANSCRIPT" tu-5 Bash 'HQ_ROOT=/x hq core checkpoint --idle'
append_result "$TRANSCRIPT" tu-5 false
run_hook s-env-prefix "$TRANSCRIPT"
assert_allow "environment-prefixed checkpoint"
pass "environment-prefixed checkpoint allows"

# 6. Claude Code enforces regardless of identity eligibility.
reset_case
set_verdict 0
new_transcript 6-ineligible
append_user "$TRANSCRIPT" u-ineligible
append_tool "$TRANSCRIPT" tu-6 Bash 'git status'
run_hook s-ineligible "$TRANSCRIPT"
assert_block "$HOOK_STDOUT" s-ineligible "Claude identity-independent enforcement"
pass "Claude Code ignores identity eligibility"

# 6b. Unknown runtimes are completely unaffected.
reset_case
set_verdict 1
RUN_RUNTIME=grok
new_transcript 6b-other-runtime
append_user "$TRANSCRIPT" u-other-runtime
append_tool "$TRANSCRIPT" tu-6b Bash 'git status'
run_hook s-other-runtime "$TRANSCRIPT"
assert_allow "unknown runtime"
pass "unknown runtime allows"

# 7. A missing verdict allows now and refreshes in the background.
reset_case
clear_verdict
RUN_RUNTIME=codex
new_transcript 7-refresh
append_user "$TRANSCRIPT" u-refresh
append_tool "$TRANSCRIPT" tu-7 Bash 'git status'
run_hook s-refresh "$TRANSCRIPT"
assert_allow "missing verdict"
wait_for_probe "missing verdict"
pass "missing verdict refreshes asynchronously"

# 8. Missing hq is an allow path and remains quiet.
reset_case
clear_verdict
RUN_PATH="$NO_HQ_DIR"
new_transcript 8-no-hq
append_user "$TRANSCRIPT" u-no-hq
append_tool "$TRANSCRIPT" tu-8 Bash 'git status'
run_hook s-no-hq "$TRANSCRIPT"
assert_allow "missing hq"
assert_empty "$HOOK_STDERR" "missing hq"
pass "missing hq allows quietly"

# 9. An unsatisfied turn remains blocked until a checkpoint succeeds.
reset_case
set_verdict 1
new_transcript 9-loop-cap
append_user "$TRANSCRIPT" u-loop-cap
append_tool "$TRANSCRIPT" tu-9 Bash 'git status'
run_hook s-loop-cap "$TRANSCRIPT"
assert_block "$HOOK_STDOUT" s-loop-cap "persistent gate first block"
run_hook s-loop-cap "$TRANSCRIPT"
assert_block "$HOOK_STDOUT" s-loop-cap "persistent gate second block"
run_hook s-loop-cap "$TRANSCRIPT"
assert_block "$HOOK_STDOUT" s-loop-cap "persistent gate third block"
append_tool "$TRANSCRIPT" tu-9-checkpoint Bash 'hq core checkpoint --idle'
append_result "$TRANSCRIPT" tu-9-checkpoint false
run_hook s-loop-cap "$TRANSCRIPT"
assert_allow "persistent gate after checkpoint"
pass "unsatisfied turn stays blocked until checkpoint succeeds"

# 10. The checkpoint sibling must never recursively gate itself.
reset_case
set_verdict 1
RUN_SIBLING=1
new_transcript 10-sibling
append_user "$TRANSCRIPT" u-sibling
run_hook s-sibling "$TRANSCRIPT"
assert_allow "checkpoint sibling"
pass "checkpoint sibling allows"

# 11. Operator opt-out wins over a positive verdict.
reset_case
set_verdict 1
RUN_GATE=0
new_transcript 11-gate-off
append_user "$TRANSCRIPT" u-gate-off
run_hook s-gate-off "$TRANSCRIPT"
assert_allow "HQ_CHECKPOINT_GATE=0"
pass "HQ_CHECKPOINT_GATE=0 allows"

# 12. Force-enforce skips the verdict cache.
reset_case
clear_verdict
RUN_GATE=1
new_transcript 12-force
append_user "$TRANSCRIPT" u-force
append_tool "$TRANSCRIPT" tu-12 Bash 'git status'
run_hook s-force "$TRANSCRIPT"
assert_block "$HOOK_STDOUT" s-force "HQ_CHECKPOINT_GATE=1"
pass "HQ_CHECKPOINT_GATE=1 enforces without verdict"

# 13. A stale positive verdict still enforces and asks the shim to refresh.
reset_case
set_verdict 1
RUN_RUNTIME=codex
touch -d '25 hours ago' "$STATE_DIR/checkpoint-gate-eligible-codex"
new_transcript 13-stale
append_user "$TRANSCRIPT" u-stale
append_tool "$TRANSCRIPT" tu-13 Bash 'git status'
run_hook s-stale "$TRANSCRIPT"
assert_codex_block "$HOOK_STDOUT" "stale verdict"
wait_for_probe "stale verdict"
pass "stale verdict enforces and refreshes"

# 14. A pure Q&A turn changed nothing, so the gate must stay out of the way.
reset_case
set_verdict 1
new_transcript 14-no-tools
append_user "$TRANSCRIPT" u-no-tools
run_hook s-no-tools "$TRANSCRIPT"
assert_allow "turn without tools"
pass "tool-free turn allows"

# 14b. A turn whose only tool call was the checkpoint itself is not "work".
# Without this the gate re-fires on its own satisfying call in some shapes.
reset_case
set_verdict 1
new_transcript 14b-checkpoint-only
append_user "$TRANSCRIPT" u-checkpoint-only
append_tool "$TRANSCRIPT" tu-14b Bash 'hq core checkpoint --session-id s-checkpoint-only --idle'
append_result "$TRANSCRIPT" tu-14b false
run_hook s-checkpoint-only "$TRANSCRIPT"
assert_allow "checkpoint-only turn"
pass "checkpoint-only turn allows"

# 14c. A gate probe is bookkeeping, not work: it must not demand a checkpoint.
reset_case
set_verdict 1
new_transcript 14c-probe-only
append_user "$TRANSCRIPT" u-probe-only
append_tool "$TRANSCRIPT" tu-14c Bash 'hq core checkpoint --gate-probe'
append_result "$TRANSCRIPT" tu-14c false
run_hook s-probe-only "$TRANSCRIPT"
assert_allow "gate-probe-only turn"
pass "gate-probe-only turn allows"

# 14d. One real tool alongside a checkpoint still counts as work, so a turn
# that did work and then failed to checkpoint must still block.
reset_case
set_verdict 1
new_transcript 14d-work-then-nothing
append_user "$TRANSCRIPT" u-work-then-nothing
append_tool "$TRANSCRIPT" tu-14d-a Bash 'hq core checkpoint --gate-probe'
append_result "$TRANSCRIPT" tu-14d-a false
append_tool "$TRANSCRIPT" tu-14d-b Bash 'git commit -m real-work'
append_result "$TRANSCRIPT" tu-14d-b false
run_hook s-work-then-nothing "$TRANSCRIPT"
assert_block "$HOOK_STDOUT" s-work-then-nothing "work turn without checkpoint"
pass "work alongside a probe still blocks"

# 14e. A non-Bash tool (no command string) is real work and must still block.
reset_case
set_verdict 1
new_transcript 14e-edit-only
append_user "$TRANSCRIPT" u-edit-only
append_tool "$TRANSCRIPT" tu-14e Edit ''
append_result "$TRANSCRIPT" tu-14e false
run_hook s-edit-only "$TRANSCRIPT"
assert_block "$HOOK_STDOUT" s-edit-only "edit-only turn"
pass "commandless tool call still blocks"

# 14f. The block message must carry the guidance the checkpoint depends on.
printf '%s' "$HOOK_STDOUT" | jq -r '.reason' | grep -qF -- '--trigger stop-gate' \
  || fail "block reason: missing the stop-gate command"
printf '%s' "$HOOK_STDOUT" | jq -r '.reason' | grep -qF -- '--idle' \
  || fail "block reason: missing the --idle alternative"
for flag in '--file' '--decision' '--learning' '--next'; do
  printf '%s' "$HOOK_STDOUT" | jq -r '.reason' | grep -qF -- "$flag" \
    || fail "block reason: missing guidance for $flag"
done
printf '%s' "$HOOK_STDOUT" | jq -r '.reason' | grep -qF 'worse than none' \
  || fail "block reason: missing the do-not-pad instruction"
# The two audiences must be named and separated: the checkpoint is a machine
# record for the sibling, never a substitute for replying to the user.
printf '%s' "$HOOK_STDOUT" | jq -r '.reason' | grep -qF 'running it does not count as having replied' \
  || fail "block reason: missing the checkpoint-is-not-a-reply rule"
printf '%s' "$HOOK_STDOUT" | jq -r '.reason' | grep -qF 'It never sees your chat reply' \
  || fail "block reason: missing the sibling-audience explanation"
# Ordering: checkpoint FIRST, complete reply as the turn's final post-tool-call
# message — the app folds pre-tool-call text into collapsed sub-messages.
printf '%s' "$HOOK_STDOUT" | jq -r '.reason' | grep -qF 'run the checkpoint FIRST, then deliver your COMPLETE user-facing reply' \
  || fail "block reason: missing the checkpoint-first ordering"
printf '%s' "$HOOK_STDOUT" | jq -r '.reason' | grep -qF 'final post-checkpoint message' \
  || fail "block reason: missing the final-message placement rule"
pass "block reason carries checkpoint guidance"

# 15. An unreadable or missing transcript is always an allow path.
reset_case
set_verdict 1
run_hook s-missing-transcript "$TMP_ROOT/does-not-exist.jsonl"
assert_allow "missing transcript"
mkdir "$TMP_ROOT/not-a-transcript"
run_hook s-unusable-transcript "$TMP_ROOT/not-a-transcript"
assert_allow "unusable transcript path"
pass "missing or unusable transcript allows"

# 16. Registration is routed through hook-gate and all profiles contain it.
grep -qF 'hook-gate.sh\" checkpoint-stop-gate \"$CLAUDE_PROJECT_DIR/.claude/hooks/checkpoint-stop-gate.sh\"' \
  "$ROOT/.claude/settings.json" || fail "settings.json has no checkpoint Stop-gate registration"
for profile in standard strict; do
  profile_body="$(sed -n "/is_in_${profile}_profile()/,/^}/p" "$ROOT/.claude/hooks/hook-gate.sh")"
  printf '%s' "$profile_body" | grep -q 'checkpoint-stop-gate' || fail "$profile hook profile omits checkpoint-stop-gate"
done
[ -x "$HOOK" ] || fail "checkpoint Stop hook is not executable"
pass "registration and profile membership are present"

# 17. An ineligible Codex identity is unaffected through the adapter.
reset_case
set_verdict 0
new_transcript 17-codex-ineligible
append_codex_user "$TRANSCRIPT"
append_codex_tool "$TRANSCRIPT" tu-17-ineligible 'git status'
append_codex_result "$TRANSCRIPT" tu-17-ineligible
run_codex_stop s-codex-ineligible "$TRANSCRIPT"
[ "$CODEX_STATUS" -eq 0 ] || fail "Codex ineligible identity: adapter exited $CODEX_STATUS: $CODEX_STDERR"
assert_empty "$CODEX_STDOUT" "Codex ineligible identity"
pass "Codex ineligible identity allows through the adapter"

# 18. Codex receives only the exact synthetic continuation marker at Stop.
reset_case
set_verdict 1
new_transcript 17-codex-missing
append_codex_user "$TRANSCRIPT"
append_codex_tool "$TRANSCRIPT" tu-17 'git status'
append_codex_result "$TRANSCRIPT" tu-17
run_codex_stop s-codex-missing "$TRANSCRIPT"
[ "$CODEX_STATUS" -eq 0 ] || fail "Codex missing checkpoint: adapter exited $CODEX_STATUS: $CODEX_STDERR"
printf '%s' "$CODEX_STDOUT" | jq -e '
  .decision == "block"
  and .reason == "Hook re-prompted Codex"
' >/dev/null || fail "Codex missing checkpoint: expected one block decision, got: $CODEX_STDOUT"
pass "Codex Stop block uses the exact synthetic continuation marker"

# 19. The adapter must not invent a continuation after a final checkpoint.
reset_case
set_verdict 1
new_transcript 18-codex-checkpointed
append_codex_user "$TRANSCRIPT"
append_codex_tool "$TRANSCRIPT" tu-18 'hq core checkpoint --session-id s-codex-checkpointed --idle'
append_codex_result "$TRANSCRIPT" tu-18
printf '%s' "$(date +%s)" >"$STATE_DIR/checkpoint-cli-last-s-codex-checkpointed"
run_codex_stop s-codex-checkpointed "$TRANSCRIPT"
[ "$CODEX_STATUS" -eq 0 ] || fail "Codex final checkpoint: adapter exited $CODEX_STATUS: $CODEX_STDERR"
assert_empty "$CODEX_STDOUT" "Codex final checkpoint"
pass "Codex final checkpoint allows through the adapter"

# 20. A checkpoint-looking Codex tool call without the CLI success stamp fails.
reset_case
set_verdict 1
new_transcript 19-codex-unstamped
append_codex_user "$TRANSCRIPT"
append_codex_tool "$TRANSCRIPT" tu-19 'hq core checkpoint --session-id s-codex-unstamped --idle'
append_codex_result "$TRANSCRIPT" tu-19
run_codex_stop s-codex-unstamped "$TRANSCRIPT"
[ "$CODEX_STATUS" -eq 0 ] || fail "Codex unstamped checkpoint: adapter exited $CODEX_STATUS: $CODEX_STDERR"
printf '%s' "$CODEX_STDOUT" | jq -e '
  .decision == "block" and .reason == "Hook re-prompted Codex"
' >/dev/null || fail "Codex unstamped checkpoint: expected block decision, got: $CODEX_STDOUT"
pass "Codex checkpoint requires a fresh CLI success stamp"

# 21. A Codex Q&A turn changed nothing, so the adapter must let it through too.
reset_case
set_verdict 1
new_transcript 20-codex-no-tools
append_codex_user "$TRANSCRIPT"
run_codex_stop s-codex-no-tools "$TRANSCRIPT"
[ "$CODEX_STATUS" -eq 0 ] || fail "Codex tool-free turn: adapter exited $CODEX_STATUS: $CODEX_STDERR"
assert_empty "$CODEX_STDOUT" "Codex tool-free turn"
pass "Codex tool-free turn allows through the adapter"

# 22. An old stamp from an earlier turn cannot satisfy a new Codex checkpoint.
reset_case
set_verdict 1
new_transcript 21-codex-stale-stamp
append_codex_user "$TRANSCRIPT"
append_codex_tool "$TRANSCRIPT" tu-21 'hq core checkpoint --session-id s-codex-stale --idle'
append_codex_result "$TRANSCRIPT" tu-21
printf '%s' "$(($(date +%s) - 121))" >"$STATE_DIR/checkpoint-cli-last-s-codex-stale"
run_codex_stop s-codex-stale "$TRANSCRIPT"
[ "$CODEX_STATUS" -eq 0 ] || fail "Codex stale stamp: adapter exited $CODEX_STATUS: $CODEX_STDERR"
printf '%s' "$CODEX_STDOUT" | jq -e '
  .decision == "block" and .reason == "Hook re-prompted Codex"
' >/dev/null || fail "Codex stale stamp: expected block decision, got: $CODEX_STDOUT"
pass "Codex checkpoint rejects a stale CLI success stamp"

# 23. Codex exec wrappers may use JavaScript object literals, not strict JSON.
reset_case
set_verdict 1
new_transcript 22-codex-js-object
append_codex_user "$TRANSCRIPT"
append_codex_js_object_tool "$TRANSCRIPT" tu-22 \
  'hq core checkpoint --session-id s-codex-js-object --idle'
append_codex_result "$TRANSCRIPT" tu-22
printf '%s' "$(date +%s)" >"$STATE_DIR/checkpoint-cli-last-s-codex-js-object"
run_codex_stop s-codex-js-object "$TRANSCRIPT"
[ "$CODEX_STATUS" -eq 0 ] || fail "Codex JavaScript object checkpoint: adapter exited $CODEX_STATUS: $CODEX_STDERR"
assert_empty "$CODEX_STDOUT" "Codex JavaScript object checkpoint"
pass "Codex JavaScript object-literal exec wrapper allows through the adapter"

# 24. SessionStart preloads marker handling at startup and after compact.
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

# 25. A successful checkpoint clears the stored continuation instruction.
reset_case
set_verdict 1
new_transcript 24-codex-state-cleanup
append_codex_user "$TRANSCRIPT"
append_codex_tool "$TRANSCRIPT" tu-24-missing 'git status'
append_codex_result "$TRANSCRIPT" tu-24-missing
run_codex_stop s-codex-state-cleanup "$TRANSCRIPT"
[ -s "$STATE_DIR/codex-checkpoint-reprompt-s-codex-state-cleanup" ] || \
  fail "Codex Stop did not persist the checkpoint continuation instruction"
append_codex_tool "$TRANSCRIPT" tu-24-checkpoint 'hq core checkpoint --session-id s-codex-state-cleanup --idle'
append_codex_result "$TRANSCRIPT" tu-24-checkpoint
printf '%s' "$(date +%s)" >"$STATE_DIR/checkpoint-cli-last-s-codex-state-cleanup"
run_codex_stop s-codex-state-cleanup "$TRANSCRIPT"
[ "$CODEX_STATUS" -eq 0 ] || fail "Codex state cleanup: adapter exited $CODEX_STATUS: $CODEX_STDERR"
assert_empty "$CODEX_STDOUT" "Codex state cleanup"
[ ! -e "$STATE_DIR/codex-checkpoint-reprompt-s-codex-state-cleanup" ] || \
  fail "Codex successful checkpoint left stale continuation state"
pass "Codex successful checkpoint clears continuation state"

# 26. The continuation guidance is Codex-only and registered in hook profiles.
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

# ---------------------------------------------------------------------------
# Company-scope gate (opt-in via HQ_CHECKPOINT_SCOPE_GATE_DOMAINS).
# ---------------------------------------------------------------------------
assert_company_block() {
  local value="$1" session="$2" label="$3"
  printf '%s' "$value" | grep -q '"decision":"block"' \
    || fail "$label: no block decision: $value"
  printf '%s' "$value" | jq -r '.reason' | grep -qF 'has not declared its scope' \
    || fail "$label: reason is not the scope block: $value"
  printf '%s' "$value" | jq -r '.reason' | grep -qF "$session" \
    || fail "$label: session id missing from reason: $value"
  printf '%s' "$value" | jq -r '.reason' | grep -qF 'set company_slug' \
    || fail "$label: missing the bind command: $value"
}

# 27. A configured-domain caller whose session is unbound is blocked even on an
# idle turn that the checkpoint gate would happily allow.
reset_case
set_verdict 1
RUN_DOMAINS="$GATE_DOMAIN"
RUN_EMAIL="operator@$GATE_DOMAIN"
session_meta s-scope-unbound
new_transcript 27-scope-unbound
append_user "$TRANSCRIPT" u-scope-unbound
run_hook s-scope-unbound "$TRANSCRIPT"
assert_company_block "$HOOK_STDOUT" s-scope-unbound "gated unbound session"
printf '%s' "$HOOK_STDOUT" | jq -r '.reason' | grep -qF -- '--trigger stop-gate' \
  && fail "scope block leaked the checkpoint reason: $HOOK_STDOUT"
pass "gated unbound session blocks with the scope instruction"

# 28. A binding to a REAL tenant (dir exists) via meta.yaml clears the gate.
reset_case
set_verdict 1
RUN_DOMAINS="$GATE_DOMAIN"
RUN_EMAIL="operator@$GATE_DOMAIN"
tenant acme
session_meta s-scope-bound acme
new_transcript 28-scope-bound
append_user "$TRANSCRIPT" u-scope-bound
run_hook s-scope-bound "$TRANSCRIPT"
assert_allow "gated bound session (real tenant)"
pass "binding a real tenant via meta.yaml allows"

# 28b. A scope-capability.json binding to a real tenant also satisfies the gate.
reset_case
set_verdict 1
RUN_DOMAINS="$GATE_DOMAIN"
RUN_EMAIL="operator@$GATE_DOMAIN"
tenant acme
mkdir -p "$FIXTURE/workspace/sessions/s-scope-cap"
printf '{"company_slug":"acme"}' >"$FIXTURE/workspace/sessions/s-scope-cap/scope-capability.json"
new_transcript 28b-scope-cap
append_user "$TRANSCRIPT" u-scope-cap
run_hook s-scope-cap "$TRANSCRIPT"
assert_allow "gated scope-capability binding (real tenant)"
pass "binding a real tenant via scope-capability.json allows"

# 28c. The reserved `personal` scope satisfies the gate with no tenant dir.
reset_case
set_verdict 1
RUN_DOMAINS="$GATE_DOMAIN"
RUN_EMAIL="operator@$GATE_DOMAIN"
session_meta s-scope-personal personal
new_transcript 28c-scope-personal
append_user "$TRANSCRIPT" u-scope-personal
run_hook s-scope-personal "$TRANSCRIPT"
assert_allow "gated personal binding"
pass "binding the reserved personal scope allows"

# 29. An email whose domain is not in the configured list is exempt.
reset_case
set_verdict 1
RUN_DOMAINS="$GATE_DOMAIN"
RUN_EMAIL='someone@other.example'
session_meta s-other-unbound
new_transcript 29-other-unbound
append_user "$TRANSCRIPT" u-other-unbound
run_hook s-other-unbound "$TRANSCRIPT"
assert_allow "non-configured domain"
pass "a caller outside the configured domains is exempt"

# 29b. With no domains configured the gate never applies, even to a would-match
# address. This is the release-shipped default: company-agnostic, off.
reset_case
set_verdict 1
RUN_EMAIL="operator@$GATE_DOMAIN"
session_meta s-nodomains-unbound
new_transcript 29b-nodomains
append_user "$TRANSCRIPT" u-nodomains
run_hook s-nodomains "$TRANSCRIPT"
assert_allow "gate off by default"
pass "no configured domains means the gate is off"

# 29c. Exact domain-suffix match: a look-alike that merely extends the domain is
# not a member. operator.example vs operator.example.evil.
reset_case
set_verdict 1
RUN_DOMAINS="$GATE_DOMAIN"
RUN_EMAIL="operator@$GATE_DOMAIN.evil"
session_meta s-suffix-unbound
new_transcript 29c-suffix
append_user "$TRANSCRIPT" u-suffix
run_hook s-suffix "$TRANSCRIPT"
assert_allow "suffix look-alike domain"
pass "a domain that only extends a configured one is not gated"

# 30. The operator kill switch disables the scope gate too.
reset_case
set_verdict 1
RUN_DOMAINS="$GATE_DOMAIN"
RUN_EMAIL="operator@$GATE_DOMAIN"
RUN_GATE=0
session_meta s-scope-killswitch
new_transcript 30-scope-killswitch
append_user "$TRANSCRIPT" u-scope-killswitch
run_hook s-scope-killswitch "$TRANSCRIPT"
assert_allow "gated with HQ_CHECKPOINT_GATE=0"
pass "HQ_CHECKPOINT_GATE=0 disables the scope gate"

# 31. A binding to an unknown slug (no tenant dir, not personal) does NOT satisfy
# the gate — a typo or invented company cannot silently pass it.
reset_case
set_verdict 1
RUN_DOMAINS="$GATE_DOMAIN"
RUN_EMAIL="operator@$GATE_DOMAIN"
session_meta s-badslug made-up-co
new_transcript 31-badslug
append_user "$TRANSCRIPT" u-badslug
run_hook s-badslug "$TRANSCRIPT"
assert_company_block "$HOOK_STDOUT" s-badslug "unknown-tenant binding"
pass "a binding to a non-existent tenant does not satisfy the gate"

# 32. When the session did work AND is unbound, the scope gate takes precedence
# over the checkpoint gate so the operator declares a scope first.
reset_case
set_verdict 1
RUN_DOMAINS="$GATE_DOMAIN"
RUN_EMAIL="operator@$GATE_DOMAIN"
session_meta s-scope-work-unbound
new_transcript 32-scope-work-unbound
append_user "$TRANSCRIPT" u-scope-work-unbound
append_tool "$TRANSCRIPT" tu-32 Bash 'git status'
append_result "$TRANSCRIPT" tu-32 false
run_hook s-scope-work-unbound "$TRANSCRIPT"
assert_company_block "$HOOK_STDOUT" s-scope-work-unbound "gated work turn unbound"
pass "scope gate precedes checkpoint gate for unbound work turns"

# 32b. A mixed-case configured address still matches (email is lowercased).
reset_case
set_verdict 1
RUN_DOMAINS="$GATE_DOMAIN"
RUN_EMAIL="Operator@Operator.EXAMPLE"
session_meta s-scope-mixedcase
new_transcript 32b-scope-mixedcase
append_user "$TRANSCRIPT" u-scope-mixedcase
run_hook s-scope-mixedcase "$TRANSCRIPT"
assert_company_block "$HOOK_STDOUT" s-scope-mixedcase "mixed-case configured domain"
pass "a mixed-case configured address is gated"

# 32c. A delegated/outpost token carrying BOTH a service `email` and an operator
# `custom:delegatedEmail` must resolve to the operator (delegated) identity, so a
# delegated operator is gated rather than exempted by the service email.
reset_case
set_verdict 1
RUN_DOMAINS="$GATE_DOMAIN"
RUN_TOKENS="$TMP_ROOT/delegated-token.json"
mint_token "$RUN_TOKENS" \
  "$(jq -nc --arg d "operator@$GATE_DOMAIN" '{"custom:delegatedEmail":$d,"email":"svc@other.example"}')" \
  "$(jq -nc '{"email":"svc@other.example"}')"
session_meta s-delegated-unbound
new_transcript 32c-delegated
append_user "$TRANSCRIPT" u-delegated
run_hook s-delegated-unbound "$TRANSCRIPT"
assert_company_block "$HOOK_STDOUT" s-delegated-unbound "delegated identity precedence"
pass "the delegated email claim is preferred over the service email"

# ---------------------------------------------------------------------------
# CLI delegation: the in-tree hook is a thin fallback that prefers the
# CLI-hosted gate (`hq core checkpoint-stop-gate`) when the installed CLI
# advertises it, and runs the in-tree body otherwise.
# ---------------------------------------------------------------------------

# 33. When the CLI advertises the command, the hook delegates and emits the
# CLI's output verbatim — the in-tree body never runs. The session is unbound
# and the caller is gated, which WOULD scope-block in the body: proof of deleg.
reset_case
set_verdict 1
RUN_CLI_HAS_GATE=1
RUN_DOMAINS="$GATE_DOMAIN"
RUN_EMAIL="operator@$GATE_DOMAIN"
session_meta s-delegate
new_transcript 33-delegate
append_user "$TRANSCRIPT" u-delegate
run_hook s-delegate "$TRANSCRIPT"
printf '%s' "$HOOK_STDOUT" | jq -e '.reason == "CLI-DELEGATED"' >/dev/null \
  || fail "prefer-CLI: hook did not delegate to hq core: $HOOK_STDOUT"
printf '%s' "$HOOK_STDOUT" | grep -qF 'has not declared its scope' \
  && fail "prefer-CLI: in-tree body ran instead of delegating: $HOOK_STDOUT"
pass "delegates to the CLI-hosted gate when the installed CLI provides it"

# 34. With the same CLI advertising the command, HQ_CHECKPOINT_GATE_NO_CLI=1
# forces the in-tree body (so tests and operators can pin the fallback).
reset_case
set_verdict 1
RUN_CLI_HAS_GATE=1
new_transcript 34-force-intree
append_user "$TRANSCRIPT" u-force-intree
append_tool "$TRANSCRIPT" tu-34 Bash 'git status'
append_result "$TRANSCRIPT" tu-34 false
HOOK_STDOUT="$(env \
  "CLAUDE_PROJECT_DIR=$FIXTURE" "HQ_SHIM_LOG=$SHIM_LOG" "HQ_SHIM_ROOT=$FIXTURE" \
  "HQ_SHIM_VERDICT=1" "HQ_SHIM_CLI_HAS_GATE=1" "HQ_CHECKPOINT_GATE_NO_CLI=1" \
  "HQ_COGNITO_TOKENS_FILE=$ABSENT_TOKEN" "PATH=$SHIM_DIR:$PATH" \
  "$BASH_BIN" "$FIXTURE/.claude/hooks/checkpoint-stop-gate.sh" \
  <<<"$(printf '{"session_id":"s-force-intree","transcript_path":"%s","stop_hook_active":false,"cwd":"%s"}' "$TRANSCRIPT" "$FIXTURE")" 2>/dev/null)"
printf '%s' "$HOOK_STDOUT" | jq -r '.reason' | grep -qF -- '--trigger stop-gate' \
  || fail "HQ_CHECKPOINT_GATE_NO_CLI=1 did not run the in-tree checkpoint body: $HOOK_STDOUT"
printf '%s' "$HOOK_STDOUT" | jq -e '.reason == "CLI-DELEGATED"' >/dev/null \
  && fail "HQ_CHECKPOINT_GATE_NO_CLI=1 still delegated to the CLI: $HOOK_STDOUT"
pass "HQ_CHECKPOINT_GATE_NO_CLI=1 forces the in-tree fallback body"

echo "checkpoint Stop gate: ok"
