#!/bin/bash
# hq-core: public
# hq-grok-hook-adapter.sh - route Grok lifecycle hooks through HQ's existing
# .claude/hooks gate, so HQ guardrails enforce for Grok as they do for Claude
# and Codex.
#
# Grok differs from Claude in three ways this adapter bridges:
#   1. Payload shape: camelCase (toolName / toolInput / hookEventName) plus
#      Claude-compat snake_case. Tool names include Shell / StrReplace / Read /
#      Write and the alias set run_terminal_command / search_replace / write.
#   2. Block protocol: PreToolUse blocks via stdout
#      {"decision":"deny","reason":...} (exit 2 also denies). HQ hooks signal
#      block via non-zero exit + stderr message.
#   3. Passive events: SessionStart / UserPromptSubmit / PostToolUse / Stop /
#      PreCompact cannot inject model context the way Claude/Codex do; they
#      still run side-effect hooks (autocommit, checkpoints, policy eval).
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
  export HQ_ROOT CLAUDE_PROJECT_DIR HQ_CHECKPOINT_RUNTIME
  . "$HQ_ROOT/core/scripts/hook-lib.sh" 2>/dev/null || true
  # Single-source dispatch: read .claude/settings.json live so Grok runs
  # exactly the hooks Claude runs (hqad_iter_settings / hqad_mode_for).
  . "$HQ_ROOT/core/scripts/lib/hook-adapter-core.sh" 2>/dev/null || true
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

# Claude-shaped payload for HQ hooks.
# Session identity: without a session_id the policy-injection dedupe collapses
# into the shared persistent default.txt ledger (fires once per machine, ever).
# Prefer whatever session field Grok supplies; else synthesize from the
# invoking process ($PPID - stable within a Grok session, distinct across).
SID="$(jget '.session_id // .sessionId // .conversationId // .threadId // empty')"
[ -z "$SID" ] && SID="grok-${GROK_SESSION_ID:-$PPID}"

CLAUDE_JSON="$(jq -n \
  --arg t "$CTOOL" \
  --arg c "$CMD" \
  --arg f "$FP" \
  --arg body "$CONTENT" \
  --arg event "$EVENT" \
  --arg cwd "$CWD" \
  --arg sid "$SID" \
  --arg prompt "$PROMPT" \
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
    )
  } + (if $prompt != "" then {prompt: $prompt} else {} end)' 2>/dev/null)"

deny() {
  local reason="$1"
  jq -c -n --arg r "$reason" '{decision:"deny", reason:$r}'
  exit 2
}

allow_pre() {
  echo '{"decision":"allow"}'
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

  if command -v hq_launch_shell_path >/dev/null 2>&1; then
    hq_launch_shell_path "$HQ_ROOT" "$GATE" "$payload" "$id" "$script" ${extra[@]+"${extra[@]}"} >"$out" 2>"$err" || status=$?
    if [ -n "${HQ_HOOK_LAST_CAUSE:-}" ] && command -v hq_hook_launch_warning_text >/dev/null 2>&1; then
      warning="$(hq_hook_launch_warning_text \
        "$payload" \
        "$HQ_ROOT" \
        "blocking" \
        "hook gate" \
        "$id" \
        "$GATE" \
        "$HQ_HOOK_LAST_CAUSE")"
    fi
  else
    printf '%s' "$payload" | bash "$GATE" "$id" "$script" ${extra[@]+"${extra[@]}"} >"$out" 2>"$err" || status=$?
  fi

  out_text="$(cat "$out" 2>/dev/null || true)"
  err_text="$(cat "$err" 2>/dev/null || true)"
  rm -f "$out" "$err"

  [ "$status" -eq 0 ] && return 0

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

  if command -v hq_launch_shell_path >/dev/null 2>&1; then
    hq_launch_shell_path "$HQ_ROOT" "$GATE" "$payload" "$id" "$script" >"$out" 2>"$err" || status=$?
    if [ -n "${HQ_HOOK_LAST_CAUSE:-}" ] && command -v hq_hook_launch_warning_text >/dev/null 2>&1; then
      warning="$(hq_hook_launch_warning_text \
        "$payload" \
        "$HQ_ROOT" \
        "advisory" \
        "hook gate" \
        "$id" \
        "$GATE" \
        "$HQ_HOOK_LAST_CAUSE")"
    fi
  else
    printf '%s' "$payload" | bash "$GATE" "$id" "$script" >"$out" 2>"$err" || status=$?
  fi

  out_text="$(cat "$out" 2>/dev/null || true)"
  err_text="$(cat "$err" 2>/dev/null || true)"
  rm -f "$out" "$err"

  if [ "$status" -ne 0 ]; then
    [ -n "$warning" ] && append_diag "$warning"
    if [ -n "$err_text" ]; then
      append_diag "$(compact_diag "$err_text")"
    elif [ -z "$warning" ]; then
      append_diag "WARNING: advisory hook '$id' exited $status; continuing."
    fi
    return 0
  fi

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
    printf '%s' "$payload" | "$script" >"$out" 2>"$err" || status=$?
  fi

  out_text="$(cat "$out" 2>/dev/null || true)"
  err_text="$(cat "$err" 2>/dev/null || true)"
  rm -f "$out" "$err"

  if [ "$status" -ne 0 ]; then
    [ -n "$warning" ] && append_diag "$warning"
    if [ -n "$err_text" ]; then
      append_diag "$(compact_diag "$err_text")"
    elif [ -z "$warning" ]; then
      append_diag "WARNING: advisory script '$label' exited $status; continuing."
    fi
    return 0
  fi

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
  local out err status err_text
  out="$(mktemp)"; err="$(mktemp)"; status=0
  printf '%s' "$payload" | bash "$script" "$event_arg" >"$out" 2>"$err" || status=$?
  err_text="$(cat "$err" 2>/dev/null || true)"
  rm -f "$out" "$err"
  [ "$status" -eq 0 ] && return 0
  if [ "$mode" = "advisory" ]; then
    [ -n "$err_text" ] && append_diag "$(compact_diag "$err_text")"
    return 0
  fi
  deny "$(compact_reason "${err_text:-Blocked by HQ company hook}")"
}

# Dispatch every settings.json-registered hook for (event, canonical tools)
# through Grok's protocol handlers. Reading settings.json live keeps Grok in
# lockstep with Claude (single-source dispatch). `tools` is a space-separated
# set of canonical tool names ("ANY" for non-tool events); records are
# de-duplicated across the set. Only PreToolUse can deny under Grok, which is
# exactly what hqad_mode_for returns "blocking" for.
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
            # Grok cannot inject context on any event, so surface a successful
            # advisory hook's stdout as bounded stderr diagnostics rather than
            # dropping it (preserves e.g. bridge-health / policy warnings).
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
    done < <(hqad_iter_settings "$event" "$tool")
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
  esac
}

run_session_start() {
  dispatch_settings_hooks "SessionStart" "ANY" "$CLAUDE_JSON"
}

run_user_prompt_submit() {
  dispatch_settings_hooks "UserPromptSubmit" "ANY" "$CLAUDE_JSON"
}

run_stop() {
  # checkpoint-stop-gate now runs under Grok too. Grok cannot hard-block a Stop
  # (only PreToolUse denies), so it runs advisory: its checkpoint side-effects
  # fire but the turn is not blocked.
  dispatch_settings_hooks "Stop" "ANY" "$CLAUDE_JSON"
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
  # Grok supports these lifecycle events natively; settings.json registers the
  # master-hook company/personal/pack fan-out on each (SessionEnd has live
  # listeners). Side-effect only — output is dropped, exit ignored by Grok.
  SessionEnd)       dispatch_settings_hooks "SessionEnd" "ANY" "$CLAUDE_JSON" ;;
  SubagentStop)     dispatch_settings_hooks "SubagentStop" "ANY" "$CLAUDE_JSON" ;;
  Notification)     dispatch_settings_hooks "Notification" "ANY" "$CLAUDE_JSON" ;;
  *) ;;
esac

emit_diag
exit 0
