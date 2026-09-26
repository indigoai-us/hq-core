#!/bin/bash
# Hosts like Claude Code export BASH_ENV to a user profile; each non-interactive
# bash on the hook path then pays nvm (~1-11s). Measured 2026-09-21 macOS:
# adapter 18-32s, bridge 28s, master-hook 4.5s; with BASH_ENV=/dev/null: 4.0s / 3.5s.
export BASH_ENV=/dev/null
# hq-core: public
# hq-grok-hook-adapter.sh - route Grok lifecycle hooks through HQ's existing
# .claude/hooks gate, so HQ guardrails enforce for Grok as they do for Claude
# and Codex.
#
# Grok differs from Claude in four ways this adapter bridges. Each claim below
# is checked against the hook reference embedded in the Grok binary
# (`strings -n 20 <grok> | grep -n additionalContext`), verified for 1.0.34.
#   1. Payload shape: camelCase (toolName / toolInput / hookEventName /
#      stopHookActive) plus Claude-compat snake_case. Tool names include Shell /
#      StrReplace / Read / Write and the alias set run_terminal_command /
#      search_replace / write.
#   2. Block protocol: PreToolUse blocks via stdout
#      {"decision":"deny","reason":...} (exit 2 also denies). HQ hooks signal
#      block via non-zero exit + stderr message.
#   3. Context: Grok delivers hookSpecificOutput.additionalContext from
#      settings-file command hooks on PreToolUse and PostToolUse, next to the
#      tool result. This adapter collects that field from the HQ hooks it runs
#      and returns it (hq monitor events, policy notes). A deny drops it, so
#      deny() folds it into the deny reason instead.
#   4. Stop protocol: Grok's Stop and SubagentStop gates CAN hold a turn open,
#      the same way Claude's can. run_stop translates an HQ Stop hook's
#      {"decision":"block","reason":...} (or its exit 2 + stderr) into Grok's
#      Stop block output, guarded by stopHookActive.
#
#      Which HQ gates actually hold a Grok turn today: the CLI checkpoint gate
#      and the conduct inbox backstop. enforce-humanize-before-send and
#      enforce-capability-link-render do NOT — they read the session transcript,
#      and Grok writes an ACP-style updates.jsonl
#      ({"method":"_x.ai/session/update",...}) rather than Claude's
#      {"type":"assistant",...} records, so their jq finds nothing and they exit
#      0. Verified by capturing a live Stop payload, 2026-09-26. The adapter
#      forwards transcript_path AND last_assistant_message (Grok supplies both
#      on a real turn end) so closing that gap is a change to those two hooks,
#      not another payload change here.
#
# Two events stay diagnostics-only, and this is a Grok limit, not an HQ choice:
#   - SessionStart is passive; Grok ignores its stdout entirely.
#   - UserPromptSubmit can only REJECT a prompt. An allowing hook's stdout,
#     additionalContext included, is discarded, and even a block reason is shown
#     to the operator rather than added to the model's context.
# Both still run their side-effect hooks (autocommit, checkpoints, policy eval),
# and this adapter routes their notes to bounded stderr diagnostics so they stay
# visible in the scrollback instead of vanishing.
#
# Canonical policy stays in .claude/hooks/. Claude settings.json, Codex
# (.codex/), and Grok (.grok/ + optional user bridge installed by hq reindex) all
# route through it.
#
# Project .grok/hooks may not load on some Grok builds (observed 0.2.93:
# project hooks never appear in `grok inspect`). `hq reindex` (hq-cli
# hook-trust step) installs a user-global bridge under ~/.grok/hooks/ that finds and execs
# this adapter when cwd is inside an HQ tree.
set -uo pipefail

INPUT_RAW="$(cat 2>/dev/null || echo '{}')"
jget() { printf '%s' "$INPUT_RAW" | jq -r "$1" 2>/dev/null || true; }

EVENT="$(jget '.hookEventName // .hook_event_name // empty')"
[ -z "$EVENT" ] && EVENT="${GROK_HOOK_EVENT:-}"
# Normalize event names (Grok docs use both pre_tool_use and PreToolUse).
# US-010: live hooks run via settings→master with HQ_HARNESS=grok.
# Pending decisions are recorded by turn-start (passive hooks cannot ask);
# organize is deferred to `hq mesh context organize`.
work_mesh_live_dispatch() {
  local event="$1" script="$2" payload="${3:-$CLAUDE_JSON}"
  local path="$HQ_ROOT/core/hooks/$event/$script"
  [ -f "$path" ] || return 0
  HQ_WORK_MESH_HARNESS=grok HQ_HARNESS=grok \
    run_hook "work-mesh-live" "$path" "$payload" "advisory" 2>/dev/null || \
  HQ_WORK_MESH_HARNESS=grok HQ_HARNESS=grok \
    bash "$path" "$event" <<<"$payload" >/dev/null 2>&1 || true
}

if [ "${HQ_WORK_MESH_FORCE_ADAPTER_DISPATCH:-}" = "1" ]; then
  case "$EVENT" in
    SessionStart) work_mesh_live_dispatch SessionStart 35-work-mesh-session-start.sh ;;
    UserPromptSubmit) work_mesh_live_dispatch UserPromptSubmit 35-work-mesh-turn-start.sh ;;
    Stop) work_mesh_live_dispatch Stop 70-work-mesh-turn-end.sh ;;
    SessionEnd) work_mesh_live_dispatch SessionEnd 35-work-mesh-session-end.sh ;;
    PostToolUse) work_mesh_live_dispatch PostToolUse 35-work-mesh-tool-writes.sh ;;
  esac
fi

case "$EVENT" in
  pre_tool_use|PreToolUse) EVENT=PreToolUse ;;
  post_tool_use|PostToolUse) EVENT=PostToolUse ;;
  session_start|SessionStart) EVENT=SessionStart ;;
  user_prompt_submit|UserPromptSubmit) EVENT=UserPromptSubmit ;;
  pre_compact|PreCompact) EVENT=PreCompact ;;
  stop|Stop) EVENT=Stop ;;
  session_end|SessionEnd) EVENT=SessionEnd ;;
  subagent_stop|SubagentStop) EVENT=SubagentStop ;;
  notification|Notification) EVENT=Notification ;;
  *) ;;
esac

GTOOL="$(jget '.toolName // .tool_name // empty')"
# If the runner omitted the event name but supplied a tool, treat as PreToolUse.
if [ -z "$EVENT" ] && [ -n "$GTOOL" ]; then
  EVENT=PreToolUse
fi
CWD="$(jget '.cwd // .workspaceRoot // empty')"
[ -z "$CWD" ] && CWD="$(pwd -P 2>/dev/null || pwd)"

# Resolve HQ root from this adapter's location:
#   <HQ_ROOT>/.grok/hooks/hq-grok-hook-adapter.sh
self_src="${BASH_SOURCE[0]:-$0}"
self_dir="$(cd "$(dirname "$self_src")" 2>/dev/null && pwd -P || true)"
HQ_ROOT=""
if [ -n "$self_dir" ]; then
  cand="$(cd "$self_dir/../.." 2>/dev/null && pwd -P || true)"
  [ -n "$cand" ] && [ -f "$cand/.claude/hooks/hook-gate.sh" ] && HQ_ROOT="$cand"
fi
if [ -z "$HQ_ROOT" ]; then
  HQ_ROOT="${CLAUDE_PROJECT_DIR:-${GROK_WORKSPACE_ROOT:-}}"
  [ -n "$HQ_ROOT" ] && [ ! -f "$HQ_ROOT/.claude/hooks/hook-gate.sh" ] && HQ_ROOT=""
fi
if [ -z "$HQ_ROOT" ]; then
  # Walk up from cwd (nested repos under HQ).
  walk="$CWD"
  while [ -n "$walk" ] && [ "$walk" != "/" ]; do
    if [ -f "$walk/.claude/hooks/hook-gate.sh" ]; then
      HQ_ROOT="$walk"
      break
    fi
    walk="$(dirname "$walk")"
  done
fi

GATE="${HQ_ROOT:+$HQ_ROOT/.claude/hooks/hook-gate.sh}"
HOOK_DIR="${HQ_ROOT:+$HQ_ROOT/.claude/hooks}"

if [ -n "$HQ_ROOT" ]; then
  CLAUDE_PROJECT_DIR="$HQ_ROOT"
  HQ_CHECKPOINT_RUNTIME=grok
  HQ_WORK_MESH_HARNESS=grok
  HQ_HARNESS=grok
  export HQ_ROOT CLAUDE_PROJECT_DIR HQ_CHECKPOINT_RUNTIME HQ_WORK_MESH_HARNESS HQ_HARNESS
  . "$HQ_ROOT/core/scripts/hook-lib.sh" 2>/dev/null || true
  # Single-source dispatch: read .claude/settings.json live so Grok runs
  # exactly the hooks Claude runs (hqad_iter_settings / hqad_mode_for).
  . "$HQ_ROOT/core/scripts/lib/hook-adapter-core.sh" 2>/dev/null || true
  # Share the existing profile gate in-process so each registry hook does not
  # start another hook-gate.sh process.
  . "$GATE" --lib 2>/dev/null || true
fi

# Fail-open outside HQ trees (never wedge non-HQ projects). Gate presence is
# checked with -f, not -x: HQ Sync strips exec bits, and the gate is invoked
# via bash below so a stripped bit must not silently disable enforcement.
if [ -z "$HQ_ROOT" ] || [ ! -f "${GATE:-}" ]; then
  if [ -n "$HQ_ROOT" ] && command -v hq_hook_launch_warning_text >/dev/null 2>&1; then
    warning="$(hq_hook_launch_warning_text \
      "$INPUT_RAW" "$HQ_ROOT" "advisory" "hook gate" "hook-gate" "$GATE" \
      "file is missing under HQ_ROOT")"
    [ -n "$warning" ] && printf '%s\n' "$warning" >&2
  fi
  if [ "$EVENT" = "PreToolUse" ]; then
    echo '{"decision":"allow"}'
  fi
  exit 0
fi

DIAG_ACCUM=""
CONTEXT_ACCUM=""

# Grok delivers additionalContext only on these events (Grok 1.0.34 hook docs).
event_delivers_context() {
  case "$EVENT" in PreToolUse|PostToolUse) return 0 ;; esac
  return 1
}

# Collect hookSpecificOutput.additionalContext from one hook's stdout. Accepts
# one JSON document or several (one per line). Prints nothing and returns 1
# when the event cannot carry context or the stdout has none.
collect_context() {
  local text="$1" ctx
  event_delivers_context || return 1
  [ -n "$text" ] || return 1
  ctx="$(printf '%s' "$text" | jq -rs '
    [ .[] | objects | .hookSpecificOutput?.additionalContext? // empty
      | strings | select(length > 0) ] | join("\n\n")' 2>/dev/null)" \
    || ctx="$(printf '%s\n' "$text" | jq -rR '
      fromjson? | objects | .hookSpecificOutput?.additionalContext? // empty
      | strings | select(length > 0)' 2>/dev/null)" || ctx=""
  [ -n "$ctx" ] || return 1
  if [ -z "$CONTEXT_ACCUM" ]; then
    CONTEXT_ACCUM="$ctx"
  else
    CONTEXT_ACCUM="${CONTEXT_ACCUM}

${ctx}"
  fi
  return 0
}

STOP_BLOCK_REASON=""
STOP_BLOCK_SOURCE=""
STOP_BLOCK_COUNT=0

# Accumulate rather than keep the first. Every Stop gate that blocks has already
# had its side effects by the time we read its decision — conduct-lane-inbox in
# particular has DRAINED its queue — so discarding a later reason destroys the
# message it just consumed. Grok caps Stop feedback at 10,000 characters, which
# is ample for the handful of gates that can fire at once.
append_stop_block() { # <hook-id> <reason>
  local id="$1" reason="$2"
  [ -n "$reason" ] || return 1
  if [ -z "$STOP_BLOCK_REASON" ]; then
    STOP_BLOCK_REASON="$reason"
    STOP_BLOCK_SOURCE="$id"
  else
    STOP_BLOCK_REASON="${STOP_BLOCK_REASON}

${reason}"
    STOP_BLOCK_SOURCE="${STOP_BLOCK_SOURCE}, ${id}"
  fi
  STOP_BLOCK_COUNT=$((STOP_BLOCK_COUNT + 1))
  return 0
}


# Grok's Stop and SubagentStop gates keep the agent working on
# {"decision":"block","reason":...} or on exit 2 with the feedback on stderr
# (Grok 1.0.34 hook reference, "Stop Decision Control"). So on these two events a
# hook's block is control flow, not a diagnostic, and the adapter reads it out.
event_is_stop_gate() {
  case "$EVENT" in Stop|SubagentStop) return 0 ;; esac
  return 1
}

# Read a Stop/SubagentStop block decision out of one hook's stdout. HQ hooks and
# master-hook both emit a single compact object; master-hook may print plain
# context first, so fall back to the last JSON line. Every block is kept, in the
# order the hooks ran; see append_stop_block for why first-wins is unsafe here.
collect_stop_block() { # <hook-id> <stdout-text>
  local id="$1" text="$2" obj reason
  event_is_stop_gate || return 1
  [ -n "$text" ] || return 1
  # Bash prefilter: a Stop event fans out to ~10 hooks, and paying two jq
  # processes for each one's stdout is most of what the parse costs. Only a
  # document that mentions a decision can carry a block.
  case "$text" in *'"decision"'*) : ;; *) return 1 ;; esac
  obj="$(printf '%s' "$text" | jq -c 'select(type == "object")' 2>/dev/null || true)"
  if [ -z "$obj" ]; then
    obj="$(printf '%s\n' "$text" \
      | jq -Rrc 'fromjson? | select(type == "object")' 2>/dev/null | tail -1)"
  fi
  [ -n "$obj" ] || return 1
  reason="$(printf '%s' "$obj" | jq -r '
    if .decision == "block"
    then (if (.reason? | type) == "string" and (.reason | length) > 0
          then .reason else "Blocked by HQ Stop gate" end)
    else empty end' 2>/dev/null || true)"
  [ -n "$reason" ] || return 1
  append_stop_block "$id" "$reason"
}

# Exit 2 on a Stop gate blocks with stderr as the feedback (same reference).
# Only 2 — every other non-zero exit is a fail-open failure that must not hold a
# turn, which is what keeps a crashing hook from stranding a session.
collect_stop_block_stderr() { # <hook-id> <status> <stderr-text>
  local id="$1" status="$2" text="$3"
  event_is_stop_gate || return 1
  [ "$status" = "2" ] || return 1
  [ -n "$text" ] || return 1
  append_stop_block "$id" "$text"
}

append_diag() {
  local text="$1"
  [ -z "$text" ] && return 0
  if [ -z "$DIAG_ACCUM" ]; then
    DIAG_ACCUM="$text"
  else
    DIAG_ACCUM="${DIAG_ACCUM}
${text}"
  fi
}

compact_diag() {
  if command -v hq_text_compact >/dev/null 2>&1; then
    hq_text_compact 420 "$1"
  else
    printf '%s' "$1"
  fi
}

emit_diag() {
  [ -z "$DIAG_ACCUM" ] && return 0
  if command -v hq_text_compact >/dev/null 2>&1; then
    printf '%s\n' "$(hq_text_compact 420 "$DIAG_ACCUM")" >&2
  else
    printf '%s\n' "$DIAG_ACCUM" >&2
  fi
}

compact_stop_reason() {
  if command -v hq_text_compact >/dev/null 2>&1; then
    hq_text_compact 8000 "$1"
  else
    printf '%s' "$1"
  fi
}

compact_reason() {
  if command -v hq_text_compact >/dev/null 2>&1; then
    hq_text_compact 1200 "$1"
  else
    printf '%s' "$1"
  fi
}

# Map Grok tool names -> Claude names HQ hooks key on.
case "$GTOOL" in
  run_terminal_command|Shell|Bash|bash)           CTOOL=Bash ;;
  search_replace|StrReplace|Edit|MultiEdit)       CTOOL=Edit ;;
  write|Write)                                    CTOOL=Write ;;
  read_file|Read)                                 CTOOL=Read ;;
  grep|Grep)                                      CTOOL=Grep ;;
  list_dir|Glob|ListDir)                          CTOOL=Glob ;;
  web_search|WebSearch)                           CTOOL=WebSearch ;;
  spawn_subagent|Task)                            CTOOL=Task ;;
  apply_patch)                                    CTOOL=Edit ;;
  *)                                              CTOOL="${GTOOL:-Unknown}" ;;
esac

CMD="$(jget '.toolInput.command // .tool_input.command // empty')"
FP="$(jget '.toolInput.file_path // .toolInput.path // .toolInput.target_file // .tool_input.file_path // .tool_input.path // .tool_input.target_file // empty')"
CONTENT="$(jget '.toolInput.content // .toolInput.new_string // .tool_input.content // .tool_input.new_string // empty')"
PROMPT="$(jget '.prompt // .userPrompt // .content // empty')"
TOOL_RESPONSE="$(printf '%s' "$INPUT_RAW" | jq -c '.toolResponse // .tool_response // .toolOutput // .tool_output // null' 2>/dev/null || printf 'null')"
RUN_IN_BACKGROUND="$(jget '.toolInput.run_in_background // .tool_input.run_in_background // false')"

# Claude-shaped payload for HQ hooks.
# Session identity: without a session_id the policy-injection dedupe collapses
# into the shared persistent default.txt ledger (fires once per machine, ever).
# Prefer whatever session field Grok supplies; else synthesize from the
# invoking process ($PPID - stable within a Grok session, distinct across).
SID="$(jget '.session_id // .sessionId // .conversationId // .threadId // empty')"
[ -z "$SID" ] && SID="${GROK_SESSION_ID:-}"
[ -z "$SID" ] && SID="grok-${PPID}"
export HQAD_EVENT_SESSION_ID="$SID"
PARENT_SID="$(jget '.parent_session_id // .parentSessionId // empty')"
[ -z "$PARENT_SID" ] && PARENT_SID="${HQ_PARENT_SESSION_ID:-}"

# Stop/SubagentStop control inputs. stopHookActive is true once a previous stop
# gate has already forced a continuation this turn; every HQ Stop gate that can
# block (enforce-humanize-before-send, enforce-capability-link-render, the CLI
# checkpoint gate) reads it as `stop_hook_active` to block at most once per
# chain, so failing to forward it would turn each of them into an unguarded
# blocker under Grok. `reason` distinguishes a real turn end ("end_turn") from
# the extra observe-only Stop that fires at session close.
# Parsed only on the two events that carry them: each jget is a jq process, and
# PreToolUse runs on every tool call.
STOP_HOOK_ACTIVE=false
STOP_REASON=""
TRANSCRIPT_PATH=""
LAST_ASSISTANT=""
case "$EVENT" in
  Stop|SubagentStop)
    STOP_HOOK_ACTIVE="$(jget '.stopHookActive // .stop_hook_active // empty')"
    [ "$STOP_HOOK_ACTIVE" = "true" ] || STOP_HOOK_ACTIVE="false"
    STOP_REASON="$(jget '.reason // empty')"
    # Grok supplies both on the Stop envelope (verified by capturing a live
    # payload, 2026-09-26). Claude-shaped hooks key on transcript_path; the
    # last assistant message rides alongside because Grok hands it over
    # directly and reading it costs nothing.
    TRANSCRIPT_PATH="$(jget '.transcriptPath // .transcript_path // empty')"
    LAST_ASSISTANT="$(jget '.lastAssistantMessage // .last_assistant_message // empty')"
    ;;
  SessionEnd)
    TRANSCRIPT_PATH="$(jget '.transcriptPath // .transcript_path // empty')"
    ;;
esac

CLAUDE_JSON="$(jq -n \
  --arg t "$CTOOL" \
  --arg c "$CMD" \
  --arg f "$FP" \
  --arg body "$CONTENT" \
  --arg event "$EVENT" \
  --arg cwd "$CWD" \
  --arg sid "$SID" \
  --arg prompt "$PROMPT" \
  --arg run_background "$RUN_IN_BACKGROUND" \
  --arg stop_active "$STOP_HOOK_ACTIVE" \
  --arg transcript "$TRANSCRIPT_PATH" \
  --arg last_assistant "$LAST_ASSISTANT" \
  --argjson response "$TOOL_RESPONSE" \
  '{
    hook_event_name: $event,
    tool_name: $t,
    cwd: $cwd,
    session_id: $sid,
    tool_input: (
      {}
      + (if $c != "" then {command: $c} else {} end)
      + (if $f != "" then {file_path: $f} else {} end)
      + (if $body != "" then {content: $body, new_string: $body} else {} end)
      + (if $run_background == "true" then {run_in_background: true} else {} end)
    )
  } + (if $prompt != "" then {prompt: $prompt} else {} end)
    + (if $response != null then {tool_response: $response} else {} end)
    + (if ($event == "Stop" or $event == "SubagentStop")
       then {stop_hook_active: ($stop_active == "true")} else {} end)
    + (if $transcript != "" then {transcript_path: $transcript} else {} end)
    + (if $last_assistant != "" then {last_assistant_message: $last_assistant} else {} end)' 2>/dev/null)"

deny() {
  local reason="$1"
  # Grok drops additionalContext on a deny. Context already collected (for
  # example hq monitor events a drain removed from the inbox) rides in the
  # deny reason instead, so it still reaches the model.
  if [ -n "$CONTEXT_ACCUM" ]; then
    reason="${reason}

${CONTEXT_ACCUM}"
  fi
  jq -c -n --arg r "$reason" '{decision:"deny", reason:$r}'
  exit 2
}

allow_pre() {
  if [ -n "$CONTEXT_ACCUM" ]; then
    jq -c -n --arg c "$CONTEXT_ACCUM" \
      '{decision:"allow", hookSpecificOutput:{hookEventName:"PreToolUse", additionalContext:$c}}'
  else
    echo '{"decision":"allow"}'
  fi
}

emit_post_context() {
  [ -n "$CONTEXT_ACCUM" ] || return 0
  jq -c -n --arg c "$CONTEXT_ACCUM" \
    '{hookSpecificOutput:{hookEventName:"PostToolUse", additionalContext:$c}}'
}

run_block() { # <hook-id> <hook-script> [payload] [extra-gate-args...]
  local id="$1" script="$2" payload="${3:-$CLAUDE_JSON}"
  shift 3 2>/dev/null || shift $#
  local extra=("$@")
  local out err status out_text err_text warning reason
  out="$(mktemp)"
  err="$(mktemp)"
  status=0
  warning=""

  if command -v hqad_launch_registered_hook >/dev/null 2>&1; then
    hqad_launch_registered_hook "$HQ_ROOT" "$EVENT" "$payload" "$id" "$script" ${extra[@]+"${extra[@]}"} >"$out" 2>"$err" || status=$?
    if [ -n "${HQ_HOOK_LAST_CAUSE:-}" ] && command -v hq_hook_launch_warning_text >/dev/null 2>&1; then
      warning="$(hq_hook_launch_warning_text \
        "$payload" \
        "$HQ_ROOT" \
        "blocking" \
        "hook" \
        "$id" \
        "$script" \
        "$HQ_HOOK_LAST_CAUSE")"
    fi
  else
    printf '%s' "$payload" | bash "$GATE" "$id" "$script" ${extra[@]+"${extra[@]}"} >"$out" 2>"$err" || status=$?
  fi

  out_text="$(cat "$out" 2>/dev/null || true)"
  err_text="$(cat "$err" 2>/dev/null || true)"
  rm -f "$out" "$err"

  if [ "$status" -eq 0 ]; then
    reason="$(printf '%s' "$out_text" | jq -r '
      if .hookSpecificOutput?.permissionDecision? == "deny" then
        (.hookSpecificOutput.permissionDecisionReason // "Blocked by HQ guard")
      elif .permissionDecision? == "deny" then
        (.permissionDecisionReason // "Blocked by HQ guard")
      elif .decision? == "deny" or .decision? == "block" then
        (.reason // "Blocked by HQ guard")
      else empty end
    ' 2>/dev/null || true)"
    if [ -n "$reason" ]; then deny "$(compact_reason "$reason")"; fi
    collect_context "$out_text" || true
    return 0
  fi

  reason="$err_text"
  if [ -n "$warning" ]; then
    if [ -n "$reason" ]; then
      reason="${warning}
${reason}"
    else
      reason="$warning"
    fi
  fi
  [ -z "$reason" ] && reason="Blocked by HQ guard: $id"
  deny "$(compact_reason "$reason")"
}

run_advisory() { # <hook-id> <hook-script> [payload] [stdout_mode]
  local id="$1" script="$2" payload="${3:-$CLAUDE_JSON}" stdout_mode="${4:-drop}"
  local out err status out_text err_text warning
  out="$(mktemp)"
  err="$(mktemp)"
  status=0
  warning=""

  if command -v hqad_launch_registered_hook >/dev/null 2>&1; then
    hqad_launch_registered_hook "$HQ_ROOT" "$EVENT" "$payload" "$id" "$script" >"$out" 2>"$err" || status=$?
    if [ -n "${HQ_HOOK_LAST_CAUSE:-}" ] && command -v hq_hook_launch_warning_text >/dev/null 2>&1; then
      warning="$(hq_hook_launch_warning_text \
        "$payload" \
        "$HQ_ROOT" \
        "advisory" \
        "hook" \
        "$id" \
        "$script" \
        "$HQ_HOOK_LAST_CAUSE")"
    fi
  else
    printf '%s' "$payload" | bash "$GATE" "$id" "$script" >"$out" 2>"$err" || status=$?
  fi

  out_text="$(cat "$out" 2>/dev/null || true)"
  err_text="$(cat "$err" 2>/dev/null || true)"
  rm -f "$out" "$err"

  # Stop/SubagentStop: a decision on stdout wins over the exit code, so read
  # stdout before branching on status (Grok 1.0.34 hook reference). Both calls
  # return 1 immediately on every other event, so this costs nothing elsewhere.
  collect_stop_block "$id" "$out_text" && return 0

  if [ "$status" -ne 0 ]; then
    collect_stop_block_stderr "$id" "$status" "$err_text" && return 0
    [ -n "$warning" ] && append_diag "$warning"
    if [ -n "$err_text" ]; then
      append_diag "$(compact_diag "$err_text")"
    elif [ -z "$warning" ]; then
      append_diag "WARNING: advisory hook '$id' exited $status; continuing."
    fi
    return 0
  fi

  collect_context "$out_text" && return 0
  if [ "$stdout_mode" = "diag" ] && [ -n "$out_text" ]; then
    append_diag "$(compact_diag "$out_text")"
  fi
}

run_script_advisory() { # <script> [payload] [stdout_mode]
  local script="$1" payload="${2:-$CLAUDE_JSON}" stdout_mode="${3:-drop}"
  local out err status out_text err_text warning label
  out="$(mktemp)"
  err="$(mktemp)"
  label="$(basename "$script")"
  status=0
  warning=""

  if command -v hq_launch_shell_path >/dev/null 2>&1; then
    hq_launch_shell_path "$HQ_ROOT" "$script" "$payload" >"$out" 2>"$err" || status=$?
    if [ -n "${HQ_HOOK_LAST_CAUSE:-}" ] && command -v hq_hook_launch_warning_text >/dev/null 2>&1; then
      warning="$(hq_hook_launch_warning_text \
        "$payload" \
        "$HQ_ROOT" \
        "advisory" \
        "script" \
        "$label" \
        "$script" \
        "$HQ_HOOK_LAST_CAUSE")"
    fi
  else
    # PIPESTATUS[1]: a hook that exits before reading stdin kills the payload
    # writer with SIGPIPE, and `pipefail` would report that 141 as the hook's
    # own status. Same contract as hq_launch_shell_path above.
    printf '%s' "$payload" | "$script" >"$out" 2>"$err"
    status=${PIPESTATUS[1]}
  fi

  out_text="$(cat "$out" 2>/dev/null || true)"
  err_text="$(cat "$err" 2>/dev/null || true)"
  rm -f "$out" "$err"

  # Stop/SubagentStop: a decision on stdout wins over the exit code, so read
  # stdout before branching on status (Grok 1.0.34 hook reference). Both calls
  # return 1 immediately on every other event, so this costs nothing elsewhere.
  collect_stop_block "$label" "$out_text" && return 0

  if [ "$status" -ne 0 ]; then
    collect_stop_block_stderr "$label" "$status" "$err_text" && return 0
    [ -n "$warning" ] && append_diag "$warning"
    if [ -n "$err_text" ]; then
      append_diag "$(compact_diag "$err_text")"
    elif [ -z "$warning" ]; then
      append_diag "WARNING: advisory script '$label' exited $status; continuing."
    fi
    return 0
  fi

  collect_context "$out_text" && return 0
  if [ "$stdout_mode" = "diag" ] && [ -n "$out_text" ]; then
    append_diag "$(compact_diag "$out_text")"
  fi
}

# Token-boundary deny for sensitive home paths (mirrors Codex adapter + Claude Read deny).
block_sensitive_if_needed() {
  local text="$1"
  [ -z "$text" ] && return 0
  local home_real="${HOME%/}"
  local BND='($|[[:space:]"'"'"'=:;|<>])'
  local STA='(^|[[:space:]"'"'"'=:;|<>])'
  local alt="\\.ssh(/|${BND})|\\.aws/credentials${BND}|\\.aws/config${BND}|\\.gnupg(/|${BND})|\\.env${BND}|\\.netrc${BND}|\\.zshrc${BND}|\\.zprofile${BND}|\\.zshenv${BND}|\\.bashrc${BND}|\\.bash_profile${BND}"
  local abs_re="${STA}${home_real}/(${alt})"
  local tilde_re="${STA}~/(${alt})"
  if printf '%s' "$text" | grep -Eq "${abs_re}|${tilde_re}"; then
    deny "Sensitive home-dir path access denied by hq-grok-hook-adapter.sh."
  fi
}

payload_for_path() {
  local path="$1"
  jq -n --arg path "$path" --arg event "$EVENT" --arg cwd "$CWD" --arg sid "$SID" '{
    hook_event_name: $event,
    tool_name: "Edit",
    cwd: $cwd,
    session_id: $sid,
    tool_input: {file_path: $path}
  }'
}

# Claude-shaped payload for a tool whose interesting fields are NOT command/
# file/content (e.g. WebSearch's query, spawn_subagent's prompt). Passes the
# full native toolInput/toolResponse through with a canonical tool_name so
# journal-autocapture keys correctly and records real content instead of blanks.
payload_passthrough() {
  local canon="$1"
  printf '%s' "$INPUT_RAW" | jq -c \
    --arg tn "$canon" --arg event "$EVENT" --arg cwd "$CWD" --arg sid "$SID" '{
      hook_event_name: $event,
      tool_name: $tn,
      cwd: $cwd,
      session_id: $sid,
      tool_input: (.toolInput // .tool_input // {}),
      tool_response: (.toolResponse // .tool_response // .toolOutput // .tool_output // null)
    }' 2>/dev/null
}

# Grok's list_dir supplies an explicit `target_directory` (a scoped path); it is
# NOT a Claude-style Glob with a pattern. The generic CLAUDE_JSON only carries
# command/file_path/content, so a list_dir reached block-hq-glob.sh with an
# empty tool_input: pattern resolved to "null" and, with no path, the guard
# fell back to the cwd (the HQ root) and wrongly blocked the scoped listing as
# an "unscoped Glob from HQ root" (harness-analysis 2026-08-10, 13 events).
# Build a Glob-shaped payload that carries the scoped path (and pattern, if any)
# so the guard tests the real target: a scoped dir passes, and a listing whose
# target IS the HQ root still blocks.
payload_for_glob() {
  local path="$1" pattern="$2"
  jq -n --arg path "$path" --arg pattern "$pattern" \
    --arg event "$EVENT" --arg cwd "$CWD" --arg sid "$SID" '{
    hook_event_name: $event,
    tool_name: "Glob",
    cwd: $cwd,
    session_id: $sid,
    tool_input: (
      {}
      + (if $path != "" then {path: $path} else {} end)
      + (if $pattern != "" then {pattern: $pattern} else {} end)
    )
  }'
}

# Per-session debounce for the expensive advisory policy-injection scan on
# PreToolUse. inject-policy-on-trigger dedupes emitted policies per session, so
# re-running its full facts-derive + all-policy awk scan on EVERY tool call is
# almost pure latency after the first call (measured 3.3s median, 17.8s p95, and
# 30s fail-open timeouts over the bridge — harness-analysis 2026-08-10). The
# BLOCK hooks that actually enforce (detect-secrets, block-core-writes-bash,
# block-hq-root-git-mutation, block-on-active-run, block-unsafe-package-install)
# are NEVER debounced and still run on every call; policy surfacing also still
# runs in full on SessionStart and every UserPromptSubmit. Window is overridable
# via HQ_GROK_POLICY_DEBOUNCE_SECS (0 disables). Fail-open: if the hook-lib
# debounce primitives are unavailable, we simply run every time (slower, never
# wrong).
HQ_GROK_POLICY_DEBOUNCE_SECS="${HQ_GROK_POLICY_DEBOUNCE_SECS:-20}"
run_advisory_debounced() { # <hook-id> <hook-script> [payload]
  local id="$1" script="$2" payload="${3:-$CLAUDE_JSON}"
  if [ "${HQ_GROK_POLICY_DEBOUNCE_SECS}" -gt 0 ] 2>/dev/null \
    && command -v hq_hook_state_dir >/dev/null 2>&1 \
    && command -v hq_hook_within_window >/dev/null 2>&1; then
    local state_dir stamp
    state_dir="$(hq_hook_state_dir "$HQ_ROOT")"
    stamp="${state_dir}/grok-debounce-${id}-$(hq_hook_safe_session_key "$SID").stamp"
    if hq_hook_within_window "$stamp" "$HQ_GROK_POLICY_DEBOUNCE_SECS"; then
      return 0
    fi
    hq_hook_stamp_now "$stamp"
  fi
  run_advisory "$id" "$script" "$payload"
}

# Grok-specific per-hook overrides for the settings-driven dispatcher. Returns 0
# when it fully handles the hook (dispatcher skips generic handling), 1 to fall
# through. Two hooks need Grok-specific invocation:
#   - inject-policy-on-trigger on PreToolUse uses the debounced runner so a burst
#     of tool calls does not re-surface the same policy repeatedly.
#   - block-hq-glob needs the canonicalized target payload so a relative target
#     that resolves to the HQ root is caught in every spelling.
hqad_gate_override() {
  local id="$1" script="$2" payload="$3" event="$4"
  case "$id" in
    inject-policy-on-trigger)
      if [ "$event" = "PreToolUse" ] && declare -F run_advisory_debounced >/dev/null 2>&1; then
        run_advisory_debounced "$id" "$script" "$payload"
        return 0
      fi
      return 1
      ;;
    block-hq-glob)
      [ "$event" = "PreToolUse" ] || return 1
      local gpath gpattern gpayload
      gpath="$(jget '.toolInput.target_directory // .tool_input.target_directory // .toolInput.path // .tool_input.path // empty')"
      gpattern="$(jget '.toolInput.pattern // .tool_input.pattern // empty')"
      [ "$gpath" = "null" ] && gpath=""
      [ "$gpattern" = "null" ] && gpattern=""
      if [ -z "$gpath" ]; then
        case "$GTOOL" in
          list_dir|ListDir)
            deny "BLOCKED: list_dir needs target_directory. Pass target_directory scoped to a subdirectory (not HQ root). Example: target_directory=\"core/\" or target_directory=\"workspace/\"."
            ;;
          *)
            deny "BLOCKED: Glob needs a path. Pass path scoped to a subdirectory (not HQ root). Example: Glob pattern=\"*.md\" path=\"core/\"."
            ;;
        esac
      fi
      if [ -n "$gpath" ]; then
        case "$gpath" in
          /*|[A-Za-z]:/*|[A-Za-z]:\\*) : ;;
          *) gpath="$CWD/$gpath" ;;
        esac
        command -v hq_normpath >/dev/null 2>&1 && gpath="$(hq_normpath "$gpath")"
      fi
      gpayload="$(payload_for_glob "$gpath" "$gpattern")"
      run_block block-hq-glob "$script" "$gpayload"
      return 0
      ;;
  esac
  return 1
}

# Run master-hook.sh (company/personal/pack fan-out) for an event. Advisory
# except on PreToolUse, where a company guard's non-zero exit denies the tool.
run_master() {
  local event_arg="$1" payload="${2:-$CLAUDE_JSON}" mode="${3:-advisory}"
  local script="$HOOK_DIR/master-hook.sh"
  [ -f "$script" ] || return 0
  local out err status err_text out_text
  out="$(mktemp)"; err="$(mktemp)"; status=0
  printf '%s' "$payload" | bash "$script" "$event_arg" >"$out" 2>"$err" || status=$?
  out_text="$(cat "$out" 2>/dev/null || true)"
  err_text="$(cat "$err" 2>/dev/null || true)"
  rm -f "$out" "$err"
  # A Stop gate registered under master-hook (checkpoint-stop-gate, the conduct
  # inbox backstop) emits its block in master's merged JSON result.
  collect_stop_block "master-hook:$event_arg" "$out_text" && return 0
  if [ "$status" -eq 0 ]; then
    collect_context "$out_text" || true
    return 0
  fi
  if [ "$mode" = "advisory" ]; then
    collect_stop_block_stderr "master-hook:$event_arg" "$status" "$err_text" && return 0
    [ -n "$err_text" ] && append_diag "$(compact_diag "$err_text")"
    return 0
  fi
  deny "$(compact_reason "${err_text:-Blocked by HQ company hook}")"
}

# Dispatch every settings.json-registered hook for (event, canonical tools)
# through Grok's protocol handlers. Reading settings.json live keeps Grok in
# lockstep with Claude (single-source dispatch). `tools` is a space-separated
# set of canonical tool names ("ANY" for non-tool events); records are
# de-duplicated across the set. "blocking" mode — the mode in which a hook's
# non-zero exit denies — applies to PreToolUse only, which is exactly what
# hqad_mode_for returns it for. Stop and SubagentStop also gate under Grok, but
# they gate on the decision a hook WRITES, which run_stop reads out of advisory
# dispatch; see emit_stop_decision.
dispatch_settings_hooks() {
  local event="$1" tools="$2" payload="$3" skip_master="${4:-}"
  command -v hqad_iter_settings >/dev/null 2>&1 || return 0
  local tool kind a b rest key mode seen="|"
  for tool in $tools; do
    while IFS=$'\t' read -r kind a b rest; do
      [ -n "$kind" ] || continue
      key="$kind:$a:$b:$rest"
      case "$seen" in *"|$key|"*) continue ;; esac
      seen="$seen$key|"
      case "$kind" in
        gate)
          # Grok-specific per-hook handling (glob canonicalization, policy
          # debounce) intercepts here; everything else runs generically.
          if hqad_gate_override "$a" "$b" "$payload" "$event"; then
            continue
          fi
          mode="$(hqad_mode_for "$event" "$b")"
          if [ "$mode" = "blocking" ]; then
            # shellcheck disable=SC2086
            run_block "$a" "$b" "$payload" $rest
          else
            # A successful advisory hook's additionalContext goes to the model
            # on PreToolUse/PostToolUse; any other stdout becomes bounded
            # stderr diagnostics (e.g. bridge-health / policy warnings).
            run_advisory "$a" "$b" "$payload" "diag"
          fi
          ;;
        master)
          [ -n "$skip_master" ] && continue
          run_master "$a" "$payload" "$(hqad_mode_for "$event" "")"
          ;;
        script)
          run_script_advisory "$a" "$payload"
          ;;
      esac
    done < <(hqad_iter_settings "$event" "$tool" "$payload")
  done
}

run_pre_tool_use() {
  case "$CTOOL" in
    Bash)
      [ -n "$CMD" ] && block_sensitive_if_needed "$CMD"
      dispatch_settings_hooks "PreToolUse" "Bash" "$CLAUDE_JSON"
      ;;
    Read)
      [ -n "$FP" ] && block_sensitive_if_needed "$FP"
      dispatch_settings_hooks "PreToolUse" "Read" "$CLAUDE_JSON"
      ;;
    Write|Edit)
      if [ -z "$FP" ]; then
        allow_pre
        return 0
      fi
      block_sensitive_if_needed "$FP"
      local payload canon
      payload="$(payload_for_path "$FP")"
      # Edit's hook set is a strict subset of Write's; a Grok write maps to
      # Write (adds route-company-skill-creation), a str-replace edit to Edit.
      case "$CTOOL" in
        Edit) canon="Edit" ;;
        *) canon="Write" ;;
      esac
      dispatch_settings_hooks "PreToolUse" "$canon" "$payload"
      ;;
    Grep)
      dispatch_settings_hooks "PreToolUse" "Grep" "$CLAUDE_JSON"
      ;;
    Glob)
      # block-hq-glob needs a canonicalized target payload; hqad_gate_override
      # rebuilds it. Other Glob-matched hooks run generically.
      dispatch_settings_hooks "PreToolUse" "Glob" "$CLAUDE_JSON"
      ;;
  esac
  allow_pre
}

run_post_tool_use() {
  case "$CTOOL" in
    Bash)
      # Adapter-only supplement (not registered in settings.json for Claude):
      # capture resource-registry entries from bash commands.
      run_advisory auto-capture-registry "$HOOK_DIR/auto-capture-registry.sh"
      dispatch_settings_hooks "PostToolUse" "Bash" "$CLAUDE_JSON"
      ;;
    WebSearch)
      # Grok web_search -> Claude WebSearch (journal-autocapture). Pass the full
      # toolInput (the query lives there, not in command/file/content).
      dispatch_settings_hooks "PostToolUse" "WebSearch" "$(payload_passthrough WebSearch)"
      ;;
    Task)
      # Grok spawn_subagent -> Claude Agent-matched hooks (journal-autocapture).
      # Canonical tool_name Agent + full toolInput (the prompt/metadata).
      dispatch_settings_hooks "PostToolUse" "Agent" "$(payload_passthrough Agent)"
      ;;
    Read)
      # Grok read_file -> Claude Read (record-policy-retrieval: a pulled policy
      # is the usage signal retirement keys on). Passive; never blocks.
      if [ -n "$FP" ]; then
        dispatch_settings_hooks "PostToolUse" "Read" "$(payload_for_path "$FP")" skip_master
        run_master "PostToolUse" "$CLAUDE_JSON" advisory
      fi
      ;;
    Write|Edit)
      if [ -n "$FP" ]; then
        local payload canon
        payload="$(payload_for_path "$FP")"
        case "$CTOOL" in
          Edit) canon="Edit" ;;
          *) canon="Write" ;;
        esac
        # Per-path so hq-autocommit/auto-mirror/journal see each file; run the
        # company fan-out once for the whole edit event.
        dispatch_settings_hooks "PostToolUse" "$canon" "$payload" skip_master
        run_master "PostToolUse" "$CLAUDE_JSON" advisory
      fi
      ;;
    *)
      # Every remaining tool (Grep, list_dir, and any Grok tool this adapter has
      # no special payload shape for). PostToolUse hooks registered with matcher
      # `*` — conduct-lane-inbox is the live one — must fire on these too, or a
      # lane that spends a stretch doing nothing but greps never gets its queued
      # messages until the turn ends. Claude dispatches PostToolUse on every
      # tool; this is that parity.
      dispatch_settings_hooks "PostToolUse" "$CTOOL" "$CLAUDE_JSON"
      ;;
  esac
  emit_post_context
}

write_skill_catalog() {
  [ -n "$HQ_ROOT" ] && [ -n "$SID" ] || return 0
  local dest dir skills phys
  dest="$HQ_ROOT/workspace/sessions/$SID/skill-catalog.txt"
  dir="$(dirname "$dest")"
  skills="$HQ_ROOT/.agents/skills"
  [ -d "$skills" ] || return 0
  phys="$(cd "$skills" 2>/dev/null && pwd -P)" || return 0
  [ -n "$phys" ] || return 0
  mkdir -p "$dir" 2>/dev/null || return 0
  {
    echo "# Canonical HQ skills: .agents/skills/ (not .claude/skills/)."
    echo "# Invoke with /name. Paths are relative to HQ root."
    # .agents/skills may be a symlink (often to .claude/skills). Follow it for
    # discovery, but emit canonical .agents/skills/ paths.
    find "$phys" -mindepth 2 -maxdepth 3 -name SKILL.md 2>/dev/null \
      | LC_ALL=C sort \
      | while IFS= read -r f; do
          rel=".agents/skills/${f#"$phys"/}"
          name="$(basename "$(dirname "$f")")"
          printf '%s\t%s\n' "$name" "$rel"
        done
  } >"$dest" 2>/dev/null || true
}

run_session_start() {
  # SessionStart is passive under Grok: it ignores the hook's stdout entirely,
  # so there is no way to hand the model a bind nudge here. Bind from a safe
  # source instead, before the first company-path tool (inherit parent /
  # HQ_SPAWN_COMPANY / already-written meta).
  if [ -n "$HQ_ROOT" ] && [ -n "$SID" ]; then
    # shellcheck source=../../core/scripts/lib/session-scope-capability.sh
    . "$HQ_ROOT/core/scripts/lib/session-scope-capability.sh" 2>/dev/null || true
    # shellcheck source=../../core/scripts/lib/session-auto-bind.sh
    . "$HQ_ROOT/core/scripts/lib/session-auto-bind.sh" 2>/dev/null || true
    if command -v session_auto_bind_apply >/dev/null 2>&1; then
      session_auto_bind_apply "$HQ_ROOT" "$SID" "$PARENT_SID" || true
    fi
    write_skill_catalog
  fi
  dispatch_settings_hooks "SessionStart" "ANY" "$CLAUDE_JSON"
}

run_user_prompt_submit() {
  # UserPromptSubmit can only REJECT a prompt under Grok. An allowing hook's
  # stdout and additionalContext are discarded, and a block reason is shown to
  # the operator rather than added to the model's context — so nothing written
  # here reaches the model either way. The hooks run for their side effects;
  # their notes surface as stderr diagnostics.
  dispatch_settings_hooks "UserPromptSubmit" "ANY" "$CLAUDE_JSON"
}

# Third loop guard on the Stop gate, behind Grok's own ceiling (8 continuations
# per turn, then the turn is forced to end) and behind each HQ gate's own
# stop_hook_active check. It counts the blocks THIS adapter emitted since the
# last free stop, so a gate whose condition never clears — one whose remedy the
# lane cannot perform, say — cannot spin a Grok turn all the way to Grok's cap.
# Reset happens whenever a Stop arrives with stopHookActive false, which is the
# first stop of every fresh chain. 0 disables the adapter-level cap and leaves
# only Grok's.
HQ_GROK_STOP_BLOCK_MAX="${HQ_GROK_STOP_BLOCK_MAX:-3}"

stop_block_counter_path() {
  command -v hq_hook_state_dir >/dev/null 2>&1 || return 1
  command -v hq_hook_safe_session_key >/dev/null 2>&1 || return 1
  local state_dir key
  state_dir="$(hq_hook_state_dir "$HQ_ROOT" 2>/dev/null)" || return 1
  [ -n "$state_dir" ] || return 1
  key="$(hq_hook_safe_session_key "$SID" 2>/dev/null)" || return 1
  printf '%s/grok-stop-blocks-%s.count' "$state_dir" "$key"
}

# 0 = the adapter may emit another Stop block. Fail-open: with no usable state
# dir we defer to Grok's own cap rather than refuse to gate at all.
stop_block_allowed() {
  [ "${HQ_GROK_STOP_BLOCK_MAX}" -gt 0 ] 2>/dev/null || return 0
  local path count
  path="$(stop_block_counter_path)" || return 0
  if [ "$STOP_HOOK_ACTIVE" != "true" ]; then
    printf '0' >"$path" 2>/dev/null || true
    return 0
  fi
  count="$(cat "$path" 2>/dev/null || printf '0')"
  case "$count" in ''|*[!0-9]*) count=0 ;; esac
  [ "$count" -lt "$HQ_GROK_STOP_BLOCK_MAX" ]
}

stop_block_record() {
  local path count
  path="$(stop_block_counter_path)" || return 0
  count="$(cat "$path" 2>/dev/null || printf '0')"
  case "$count" in ''|*[!0-9]*) count=0 ;; esac
  printf '%s' "$((count + 1))" >"$path" 2>/dev/null || true
}

# Grok fires an extra observe-only Stop at session close (reason
# "channel_closed" / "shutdown") whose decision it parses and discards. Verified
# against a live payload: that fire also carries no lastAssistantMessage, while
# a real turn end carries reason "end_turn" and the message text.
stop_decision_is_deliverable() {
  case "$STOP_REASON" in ''|end_turn) return 0 ;; esac
  return 1
}

# Translate a collected HQ Stop block into Grok's Stop block output.
#
# additionalContext is deliberately NOT emitted here. On Stop it is not passive
# context: Grok treats it as non-error feedback that ALSO keeps the agent
# working. Relaying a hook's incidental note would silently turn a diagnostic
# into a continuation, so Stop-hook stdout that is not a block decision stays in
# the stderr diagnostics stream. HQ Stop gates that want the turn held already
# say so with decision:block, which is the path this honors.
emit_stop_decision() {
  event_is_stop_gate || return 0
  [ -n "$STOP_BLOCK_REASON" ] || return 0
  # There is no turn left to continue on the session-close fire, so do not
  # pretend to hold one. Hooks were already told via HQ_STOP_DECISION_DELIVERABLE.
  stop_decision_is_deliverable || return 0
  if ! stop_block_allowed; then
    append_diag "WARNING: HQ Stop gate '${STOP_BLOCK_SOURCE:-unknown}' asked to hold the turn again after ${HQ_GROK_STOP_BLOCK_MAX} consecutive blocks; letting it end. Reason: $(compact_diag "$STOP_BLOCK_REASON")"
    return 0
  fi
  jq -c -n --arg r "$(compact_stop_reason "$STOP_BLOCK_REASON")" '{decision:"block", reason:$r}'
  stop_block_record
}

run_stop() {
  # Grok's Stop and SubagentStop gates can hold the turn open, so the HQ Stop
  # gates that block under Claude block here too. Dispatch stays advisory: that
  # is the mode in which a hook's non-zero exit fails open, and a Stop block is
  # carried by the decision the hook writes, not by its exit status.
  #
  # HQ_STOP_DECISION_DELIVERABLE is the contract a consuming hook needs before
  # it destroys anything. Grok fires an extra Stop at session close whose
  # decision it parses and discards, and a hook that DRAINS a queue on that fire
  # moves the message out of the queue into nothing — the operator then believes
  # a correction landed that the model never saw. Unset means an engine that
  # always delivers, so Claude and Codex are unaffected.
  if stop_decision_is_deliverable; then
    export HQ_STOP_DECISION_DELIVERABLE=1
  else
    export HQ_STOP_DECISION_DELIVERABLE=0
  fi
  dispatch_settings_hooks "$EVENT" "ANY" "$CLAUDE_JSON"
  emit_stop_decision
}

run_precompact() {
  dispatch_settings_hooks "PreCompact" "ANY" "$CLAUDE_JSON"
}

case "$EVENT" in
  SessionStart)     run_session_start ;;
  UserPromptSubmit) run_user_prompt_submit ;;
  PreToolUse)       run_pre_tool_use ;;
  PostToolUse)      run_post_tool_use ;;
  Stop)             run_stop ;;
  PreCompact)       run_precompact ;;
  # SubagentStop is a real gate in Grok (it fires inside the subagent with the
  # same decision control as Stop), so it goes through run_stop.
  SubagentStop)     run_stop ;;
  # Grok supports these lifecycle events natively; settings.json registers the
  # master-hook company/personal/pack fan-out on each (SessionEnd has live
  # listeners). Side-effect only — output is dropped, exit ignored by Grok.
  SessionEnd)       dispatch_settings_hooks "SessionEnd" "ANY" "$CLAUDE_JSON" ;;
  Notification)     dispatch_settings_hooks "Notification" "ANY" "$CLAUDE_JSON" ;;
  *) ;;
esac

emit_diag
exit 0
