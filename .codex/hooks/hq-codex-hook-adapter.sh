#!/bin/bash
# hq-codex-hook-adapter.sh - route Codex lifecycle hooks through HQ's
# existing .claude/hooks gate.
#
# Codex and Claude Code use similar hook event names, but Codex reports file
# edits through apply_patch. This adapter normalizes Codex payloads into the
# Claude-shaped JSON expected by existing HQ hooks, preserving one canonical
# policy implementation.

set -uo pipefail

INPUT="$(cat 2>/dev/null || echo '{}')"

json_get() {
  local expr="$1"
  printf '%s' "$INPUT" | jq -r "$expr" 2>/dev/null || true
}

HOOK_EVENT="$(json_get '.hook_event_name // empty')"
TOOL_NAME="$(json_get '.tool_name // empty')"
CWD="$(json_get '.cwd // empty')"
[ -z "$CWD" ] && CWD="$(pwd)"

# Session identity: inject-policy-on-trigger dedupes per session_id; a payload
# without one falls into the shared, persistent default.txt ledger, so a policy
# fires once per MACHINE instead of once per session. When Codex's event lacks
# a session field, synthesize one from the invoking process ($PPID is the Codex
# process for this session - stable across its events, distinct across
# sessions) and stamp it into the payload every hook sees.
#
# $PPID is the LAST resort: Codex tool and hook processes do not always share a
# parent, and a drifting key silently defeats every per-session debounce and
# counter downstream (checkpoint nudges, journal reminders). Prefer any real
# Codex-supplied thread/session identifier first.
SESSION_ID="$(json_get '.session_id // .sessionId // .conversation_id // .conversationId // .thread_id // .threadId // empty')"
if [ -z "$SESSION_ID" ]; then
  SESSION_ID="codex-${CODEX_SESSION_ID:-${CODEX_THREAD_ID:-${CODEX_CONVERSATION_ID:-$PPID}}}"
  INPUT="$(printf '%s' "$INPUT" | jq --arg sid "$SESSION_ID" '. + {session_id: $sid}' 2>/dev/null || printf '%s' "$INPUT")"
fi

# Resolve the HQ root deterministically from this adapter's own location.
# The adapter always lives at <HQ_ROOT>/.codex/hooks/hq-codex-hook-adapter.sh,
# so two levels up is the HQ root regardless of where Codex runs the command.
#
# DEV-1765: do NOT derive HQ_ROOT from `git -C "$CWD" rev-parse --show-toplevel`.
# Every working repo is nested under the HQ root (repos/*, companies/*/knowledge),
# so when Codex's cwd is inside one of those, that command collapses HQ_ROOT to
# the NESTED repo. The gate then resolves to a path with no hook-gate.sh and the
# adapter exits 0 - silently bypassing EVERY Codex PreToolUse protection (the
# git-mutation guard, detect-secrets, core-write blocks, ...). A `cd <hq-root> &&
# git push` issued from a nested-repo cwd thus reached the remote unblocked under
# Codex while Claude blocked it. Self-location is immune to cwd.
self_src="${BASH_SOURCE[0]:-$0}"
self_dir="$(cd "$(dirname "$self_src")" 2>/dev/null && pwd -P || true)"
HQ_ROOT=""
if [ -n "$self_dir" ]; then
  cand="$(cd "$self_dir/../.." 2>/dev/null && pwd -P || true)"
  if [ -n "$cand" ] && [ -f "$cand/.claude/hooks/hook-gate.sh" ]; then
    HQ_ROOT="$cand"
  fi
fi
# Fallback only if self-location did not yield a valid HQ root (e.g. adapter run
# from an unexpected path): prefer the cwd's git toplevel, then cwd itself.
if [ -z "$HQ_ROOT" ]; then
  HQ_ROOT="$(git -C "$CWD" rev-parse --show-toplevel 2>/dev/null || printf '%s' "$CWD")"
fi
HOOK_DIR="$HQ_ROOT/.claude/hooks"
GATE="$HOOK_DIR/hook-gate.sh"

# Load diagnostics before checking the gate so a damaged HQ install is visible.
if [ -n "$HQ_ROOT" ]; then
  CLAUDE_PROJECT_DIR="$HQ_ROOT"
  HQ_CHECKPOINT_RUNTIME=codex
  export HQ_ROOT CLAUDE_PROJECT_DIR HQ_CHECKPOINT_RUNTIME
  . "$HQ_ROOT/core/scripts/hook-lib.sh" 2>/dev/null || true
  # Single-source dispatch: read .claude/settings.json live so Codex runs
  # exactly the hooks Claude runs (hqad_iter_settings / hqad_mode_for).
  . "$HQ_ROOT/core/scripts/lib/hook-adapter-core.sh" 2>/dev/null || true
fi

if [ -z "$HQ_ROOT" ] || [ ! -d "$HOOK_DIR" ] || [ ! -f "$GATE" ]; then
  if [ -n "$HQ_ROOT" ] && command -v hq_hook_launch_warning_text >/dev/null 2>&1; then
    warning="$(hq_hook_launch_warning_text \
      "$INPUT" "$HQ_ROOT" "advisory" "hook gate" "hook-gate" "$GATE" \
      "file is missing under HQ_ROOT")"
    [ -n "$warning" ] && printf '%s\n' "$warning" >&2
  fi
  exit 0
fi

# Shared python-free primitives (hq_normpath fallback in normalize_path).

STDOUT_ACCUM=""
STDOUT_CHUNKS=()
DIAG_ACCUM=""
STOP_BLOCK_REASON=""
PRE_TOOL_BLOCK_REASON=""

# Return the control object from a hook's stdout. A direct hook commonly emits
# one JSON document, while master-hook may emit plain context followed by one
# compact JSON result from a company/personal guard. Codex must honor that
# trailing result even though the combined stream is not itself valid JSON.
control_json_object() {
  local text="$1" parsed
  parsed="$(printf '%s' "$text" | jq -c 'select(type == "object")' 2>/dev/null || true)"
  if [ -z "$parsed" ]; then
    parsed="$(printf '%s\n' "$text" \
      | jq -Rrc 'fromjson? | select(type == "object")' 2>/dev/null \
      | tail -1)"
  fi
  printf '%s' "$parsed"
}

append_stdout() {
  local text="$1"
  [ -z "$text" ] && return 0
  if [ "$HOOK_EVENT" = "Stop" ]; then
    local block_reason control_json
    control_json="$(control_json_object "$text")"
    block_reason="$(printf '%s' "$control_json" | jq -r '
      if .decision == "block" and ((.reason? | type) == "string")
      then .reason
      else empty
      end
    ' 2>/dev/null || true)"
    [ -n "$block_reason" ] && STOP_BLOCK_REASON="$block_reason"
  fi
  if [ "$HOOK_EVENT" = "PreToolUse" ]; then
    local deny_reason control_json
    control_json="$(control_json_object "$text")"
    deny_reason="$(printf '%s' "$control_json" | jq -r '
      if (
        .decision == "block"
        or .permissionDecision == "deny"
        or .hookSpecificOutput.permissionDecision == "deny"
      ) then
        .reason
        // .permissionDecisionReason
        // .hookSpecificOutput.permissionDecisionReason
        // "Tool use denied by hook."
      else empty
      end
    ' 2>/dev/null || true)"
    [ -n "$deny_reason" ] && PRE_TOOL_BLOCK_REASON="$deny_reason"
  fi
  STDOUT_CHUNKS+=("$text")
  if [ -z "$STDOUT_ACCUM" ]; then
    STDOUT_ACCUM="$text"
  else
    STDOUT_ACCUM="${STDOUT_ACCUM}
${text}"
  fi
}

# Codex parses a hook's stdout as ONE JSON document whenever it starts with
# "{", and rejects the whole thing if anything trails the object. HQ's child
# hooks are a mix of shapes: auto-session-project emits a Claude-style
# {"hookSpecificOutput": {"additionalContext": "..."}} object, while
# inject-policy-on-trigger emits bare text. Concatenating them produced
# JSON-then-text, so Codex failed the event ("UserPromptSubmit Failed") and
# dropped BOTH payloads — no session-project context and no policy reminders
# ever reached a Codex session. Flatten every chunk to its plain-text context
# so the caller can wrap the result in exactly one object.
context_text() {
  local chunk extracted out=""
  for chunk in ${STDOUT_CHUNKS[@]+"${STDOUT_CHUNKS[@]}"}; do
    extracted=""
    case "$chunk" in
      '{'*)
        extracted="$(printf '%s' "$chunk" | jq -r '
          .hookSpecificOutput.additionalContext
          // .additionalContext
          // .systemMessage
          // empty
        ' 2>/dev/null || true)"
        ;;
    esac
    # Not JSON, or JSON carrying no context field: pass the chunk through as-is.
    [ -z "$extracted" ] && extracted="$chunk"
    if [ -z "$out" ]; then
      out="$extracted"
    else
      out="${out}
${extracted}"
    fi
  done
  printf '%s' "$out"
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

run_hook() {
  local hook_id="$1"
  local script="$2"
  local payload="$3"
  local mode="${4:-blocking}"
  shift 4 2>/dev/null || shift $#
  local extra=("$@")

  local out err status out_text err_text warning
  out="$(mktemp)"
  err="$(mktemp)"
  status=0
  warning=""

  if command -v hq_launch_shell_path >/dev/null 2>&1; then
    hq_launch_shell_path "$HQ_ROOT" "$GATE" "$payload" "$hook_id" "$script" ${extra[@]+"${extra[@]}"} >"$out" 2>"$err" || status=$?
    if [ -n "${HQ_HOOK_LAST_CAUSE:-}" ] && command -v hq_hook_launch_warning_text >/dev/null 2>&1; then
      warning="$(hq_hook_launch_warning_text \
        "$payload" \
        "$HQ_ROOT" \
        "$mode" \
        "hook gate" \
        "$hook_id" \
        "$GATE" \
        "$HQ_HOOK_LAST_CAUSE")"
    fi
  else
    printf '%s' "$payload" | bash "$GATE" "$hook_id" "$script" ${extra[@]+"${extra[@]}"} >"$out" 2>"$err" || status=$?
  fi

  out_text="$(cat "$out" 2>/dev/null || true)"
  err_text="$(cat "$err" 2>/dev/null || true)"
  append_stdout "$out_text"
  rm -f "$out" "$err"

  if [ "$status" -eq 0 ]; then
    return 0
  fi

  if [ "$mode" = "advisory" ]; then
    [ -n "$warning" ] && append_diag "$warning"
    if [ -n "$err_text" ]; then
      append_diag "$(compact_diag "$err_text")"
    elif [ -z "$warning" ]; then
      append_diag "WARNING: advisory hook '$hook_id' exited $status; continuing."
    fi
    return 0
  fi

  emit_diag
  [ -n "$warning" ] && printf '%s\n' "$warning" >&2
  if [ -n "$err_text" ]; then
    printf '%s\n' "$err_text" >&2
  elif [ -z "$warning" ]; then
    printf "Hook '%s' exited %s.\n" "$hook_id" "$status" >&2
  fi
  exit "$status"
}

run_script() {
  local script="$1"
  local payload="$2"
  local mode="${3:-advisory}"

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
        "$mode" \
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
  append_stdout "$out_text"
  rm -f "$out" "$err"

  if [ "$status" -eq 0 ]; then
    return 0
  fi

  if [ "$mode" = "advisory" ]; then
    [ -n "$warning" ] && append_diag "$warning"
    if [ -n "$err_text" ]; then
      append_diag "$(compact_diag "$err_text")"
    elif [ -z "$warning" ]; then
      append_diag "WARNING: advisory script '$label' exited $status; continuing."
    fi
    return 0
  fi

  emit_diag
  [ -n "$warning" ] && printf '%s\n' "$warning" >&2
  if [ -n "$err_text" ]; then
    printf '%s\n' "$err_text" >&2
  elif [ -z "$warning" ]; then
    printf "Script '%s' exited %s.\n" "$label" "$status" >&2
  fi
  exit "$status"
}

# Run master-hook.sh (the company/personal/pack fan-out) for an event. Not
# gate-wrapped; master-hook resolves the active company from session meta and
# fan-outs to core/personal/pack/company hooks. Advisory except on PreToolUse,
# where a company guard's non-zero exit must deny the tool.
run_master_hook() {
  local event_arg="$1" payload="$2" mode="${3:-advisory}"
  local script="$HOOK_DIR/master-hook.sh"
  [ -f "$script" ] || return 0

  local out err status out_text err_text
  out="$(mktemp)"; err="$(mktemp)"; status=0
  printf '%s' "$payload" | bash "$script" "$event_arg" >"$out" 2>"$err" || status=$?
  out_text="$(cat "$out" 2>/dev/null || true)"
  err_text="$(cat "$err" 2>/dev/null || true)"
  append_stdout "$out_text"
  rm -f "$out" "$err"

  [ "$status" -eq 0 ] && return 0
  if [ "$mode" = "advisory" ]; then
    [ -n "$err_text" ] && append_diag "$(compact_diag "$err_text")"
    return 0
  fi
  emit_diag
  [ -n "$err_text" ] && printf '%s\n' "$err_text" >&2
  exit "$status"
}

# Dispatch every settings.json-registered hook for (event, canonical tools)
# through this adapter's protocol handlers. Reading settings.json live is what
# keeps Codex in lockstep with Claude (single-source dispatch). `tools` is a
# space-separated set of canonical tool names ("ANY" for non-tool events);
# records are de-duplicated across the set so an apply_patch (Edit+Write) does
# not double-run a shared hook.
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
          mode="$(hqad_mode_for "$event" "$b")"
          if [ -n "$rest" ]; then
            # shellcheck disable=SC2086
            run_hook "$a" "$b" "$payload" "$mode" $rest
          else
            run_hook "$a" "$b" "$payload" "$mode"
          fi
          ;;
        master)
          [ -n "$skip_master" ] && continue
          run_master_hook "$a" "$payload" "$(hqad_mode_for "$event" "")"
          ;;
        script)
          run_script "$a" "$payload" "advisory"
          ;;
      esac
    done < <(hqad_iter_settings "$event" "$tool")
  done
}

# Collect edit-target paths from an apply_patch/Edit/Write payload: explicit
# file_path/path fields plus "*** Add/Update/Delete File:" and "*** Move to:"
# markers inside the patch text. jq+sed+awk - python-free (hooks-no-python).
patch_paths() {
  {
    printf '%s' "$INPUT" | jq -r '
      (.tool_input // {}) as $ti
      | [$ti.file_path?, $ti.path?]
      | .[] | select(type == "string" and . != "")' 2>/dev/null
    printf '%s' "$INPUT" | jq -r '
      (.tool_input // {}) as $ti
      | [$ti.command?, $ti.patch?, $ti.input?]
      | map(select(type == "string" and . != ""))
      | join("\n")' 2>/dev/null \
      | sed -nE 's/^\*\*\* (Add|Update|Delete) File: (.+)$/\2/p; s/^\*\*\* Move to: (.+)$/\1/p'
  } | awk '{gsub(/^[ \t]+|[ \t\r]+$/, "")} NF && !seen[$0]++'
}

payload_for_path() {
  local path="$1"
  printf '%s' "$INPUT" | jq --arg path "$path" '
    .tool_name = "Edit"
    | .tool_input = {file_path: $path}
  '
}

normalize_path() {
  local path="$1"
  case "$path" in
    /*) ;;
    *) path="$HQ_ROOT/$path" ;;
  esac
  # realpath ships with coreutils (Linux, Git Bash) and modern macOS; fall
  # back to the lexical normalizer, then the raw path (python-free).
  realpath "$path" 2>/dev/null || hq_normpath "$path" 2>/dev/null || printf '%s' "$path"
}

block_core_edit_if_needed() {
  local path="$1"

  case "${HQ_BYPASS_CORE_PROTECT:-}" in
    1|true|TRUE|yes|YES) return 0 ;;
  esac

  local core_dir core_real target
  core_dir="$HQ_ROOT/core"
  core_real="$(normalize_path "$core_dir")"
  target="$(normalize_path "$path")"

  case "$target" in
    "$core_dir"/*|"$core_real"/*)
      printf 'Edits to core/ are denied by hq-codex-hook-adapter.sh (%s).\n' "$path" >&2
      exit 2
      ;;
  esac
}

block_template_edit_if_needed() {
  local path="$1"
  local template_dir template_real target
  template_dir="$HQ_ROOT/companies/_template"
  template_real="$(normalize_path "$template_dir")"
  target="$(normalize_path "$path")"
  case "$target" in
    "$template_dir"/*|"$template_real"/*)
      printf 'Edits to companies/_template/ are denied by hq-codex-hook-adapter.sh (%s).\n' "$path" >&2
      exit 2
      ;;
  esac
}

# Token-boundary regex deny for sensitive home-dir paths (mirrors the
# `.claude/settings.local.json` Read deny). Matches both absolute $HOME/
# and ~/ forms. START and END charsets are symmetric so write-redirect
# bypasses like `echo x >~/.env`, `cat<~/.env`, `|~/.env`, `;~/.env`
# are all caught. The `.env` token uses an END boundary so `.env.schema`,
# `.env.local`, `.envrc` correctly do NOT match - matching Claude's
# literal `Read(~/.env)` deny rather than a `~/.env*` glob.
block_sensitive_read_if_needed() {
  local text="$1"
  [ -z "$text" ] && return 0

  local home_real="${HOME%/}"
  local BND='($|[[:space:]"'"'"'=:;|<>])'
  local STA='(^|[[:space:]"'"'"'=:;|<>])'
  local alt="\\.ssh(/|${BND})|\\.aws/credentials${BND}|\\.aws/config${BND}|\\.gnupg(/|${BND})|\\.env${BND}|\\.netrc${BND}|\\.zshrc${BND}|\\.zprofile${BND}|\\.zshenv${BND}|\\.bashrc${BND}|\\.bash_profile${BND}"
  local abs_re="${STA}${home_real}/(${alt})"
  local tilde_re="${STA}~/(${alt})"

  if printf '%s' "$text" | grep -Eq "${abs_re}|${tilde_re}"; then
    printf 'Sensitive home-dir path access denied by hq-codex-hook-adapter.sh.\n' >&2
    exit 2
  fi
}

emit_context() {
  [ -z "$STDOUT_ACCUM" ] && return 0

  # A PreToolUse hook may return a structured denial with status 0. Preserve
  # that as Codex control flow; treating it as display context would allow the
  # operation the hook explicitly refused.
  if [ "$HOOK_EVENT" = "PreToolUse" ] && [ -n "$PRE_TOOL_BLOCK_REASON" ]; then
    jq -n --arg reason "$PRE_TOOL_BLOCK_REASON" '{
      decision: "block",
      reason: $reason,
      hookSpecificOutput: {
        hookEventName: "PreToolUse",
        permissionDecision: "deny",
        permissionDecisionReason: $reason
      }
    }'
    return 0
  fi

  # Stop decisions are control flow, not display context. Codex requires one
  # top-level JSON document; wrapping the gate's decision in `systemMessage`
  # would show the instruction but still let the turn end.
  if [ "$HOOK_EVENT" = "Stop" ] && [ -n "$STOP_BLOCK_REASON" ]; then
    jq -n --arg reason "$STOP_BLOCK_REASON" '{decision: "block", reason: $reason}'
    return 0
  fi

  local ctx
  ctx="$(context_text)"
  [ -z "$ctx" ] && return 0

  case "$HOOK_EVENT" in
    SessionStart|UserPromptSubmit|PostToolUse)
      jq -n --arg ctx "$ctx" --arg ev "$HOOK_EVENT" '{
        hookSpecificOutput: {
          hookEventName: $ev,
          additionalContext: $ctx
        }
      }'
      ;;
    Stop|PreCompact)
      jq -n --arg msg "$ctx" '{systemMessage: $msg}'
      ;;
  esac
}

run_pre_tool_use() {
  local cmd read_path grep_path glob_path
  case "$TOOL_NAME" in
    spawn_agent)
      # Codex's native collaboration tool is Claude's canonical `Agent`
      # operation under a provider-specific name. Rewrite the payload as well
      # as the settings matcher key so instance-local Agent hooks enforce the
      # same decision on both runtimes.
      local agent_payload
      agent_payload="$(printf '%s' "$INPUT" | jq -c '.tool_name = "Agent"' 2>/dev/null)"
      [ -n "$agent_payload" ] || agent_payload="$INPUT"
      dispatch_settings_hooks "PreToolUse" "Agent" "$agent_payload"
      ;;
    Bash)
      cmd="$(json_get '.tool_input.command // empty')"
      [ -n "$cmd" ] && block_sensitive_read_if_needed "$cmd"
      dispatch_settings_hooks "PreToolUse" "Bash" "$INPUT"
      ;;
    Read)
      read_path="$(json_get '.tool_input.file_path // .tool_input.path // empty')"
      [ -n "$read_path" ] && block_sensitive_read_if_needed "$read_path"
      dispatch_settings_hooks "PreToolUse" "Read" "$INPUT"
      ;;
    Grep)
      grep_path="$(json_get '.tool_input.path // empty')"
      [ -n "$grep_path" ] && block_sensitive_read_if_needed "$grep_path"
      dispatch_settings_hooks "PreToolUse" "Grep" "$INPUT"
      ;;
    Glob)
      glob_path="$(json_get '.tool_input.path // empty')"
      [ -n "$glob_path" ] && block_sensitive_read_if_needed "$glob_path"
      dispatch_settings_hooks "PreToolUse" "Glob" "$INPUT"
      ;;
    apply_patch|Edit|Write)
      local paths path payload canon
      # Edit's hook set is a strict subset of Write's, so apply_patch (generic)
      # maps to Write to cover both without dedup-ordering hazards.
      case "$TOOL_NAME" in
        Edit) canon="Edit" ;;
        *) canon="Write" ;;
      esac
      paths="$(patch_paths)"
      [ -z "$paths" ] && return 0
      while IFS= read -r path; do
        [ -z "$path" ] && continue
        # Inline guards mirror Claude's native permission denies (not in the
        # settings.json hooks block), so they stay hard-coded here.
        block_core_edit_if_needed "$path"
        block_template_edit_if_needed "$path"
        block_sensitive_read_if_needed "$path"
        payload="$(payload_for_path "$path")"
        dispatch_settings_hooks "PreToolUse" "$canon" "$payload"
      done <<< "$paths"
      ;;
    *)
      # Provider, plugin, and MCP tools are an open set. Forward their native
      # name unchanged so custom settings/master hooks can match them without
      # requiring a release of this adapter for every new tool.
      [ -n "$TOOL_NAME" ] && dispatch_settings_hooks "PreToolUse" "$TOOL_NAME" "$INPUT"
      ;;
  esac
}

run_post_tool_use() {
  case "$TOOL_NAME" in
    spawn_agent)
      # spawn_agent returns launch metadata while the child is still running,
      # not the completed Agent result expected by journal-autocapture. Keep
      # the acknowledgement provider-native; SubagentStop carries lifecycle
      # completion, and native/custom post hooks can still match spawn_agent.
      dispatch_settings_hooks "PostToolUse" "spawn_agent" "$INPUT"
      ;;
    Bash)
      # Adapter-only supplement (not registered in settings.json for Claude):
      # capture resource-registry entries from bash commands. Kept so faithful
      # settings mirroring does not drop it; reconcile into settings.json if
      # Claude should run it too.
      run_hook "auto-capture-registry" "$HOOK_DIR/auto-capture-registry.sh" "$INPUT" "advisory"
      dispatch_settings_hooks "PostToolUse" "Bash" "$INPUT"
      ;;
    apply_patch|Edit|Write)
      local paths path payload canon
      case "$TOOL_NAME" in
        Edit) canon="Edit" ;;
        *) canon="Write" ;;  # Edit's hooks ⊂ Write's; apply_patch -> Write
      esac
      paths="$(patch_paths)"
      [ -z "$paths" ] && return 0
      # Per-path so hq-autocommit/auto-mirror/journal see each file; skip the
      # company fan-out here and run it once for the whole edit event below.
      while IFS= read -r path; do
        [ -z "$path" ] && continue
        payload="$(payload_for_path "$path")"
        dispatch_settings_hooks "PostToolUse" "$canon" "$payload" skip_master
      done <<< "$paths"
      run_master_hook "PostToolUse" "$INPUT" "advisory"
      ;;
    update_plan|ExitPlanMode)
      # Codex's native plan tool (update_plan) maps to Claude's ExitPlanMode.
      dispatch_settings_hooks "PostToolUse" "ExitPlanMode" "$INPUT"
      ;;
    web_search|WebSearch)
      # If this Codex build reports web searches as a tool event, dispatch the
      # WebSearch-matched hooks (journal-autocapture). Rewrite the tool_name to
      # the canonical "WebSearch" the hook keys on (payload already carries the
      # query + tool_response); otherwise the record would be empty.
      local ws_payload
      ws_payload="$(printf '%s' "$INPUT" | jq -c '.tool_name = "WebSearch"' 2>/dev/null)"
      [ -n "$ws_payload" ] || ws_payload="$INPUT"
      dispatch_settings_hooks "PostToolUse" "WebSearch" "$ws_payload"
      ;;
    *)
      [ -n "$TOOL_NAME" ] && dispatch_settings_hooks "PostToolUse" "$TOOL_NAME" "$INPUT"
      ;;
  esac
}

case "$HOOK_EVENT" in
  SessionStart)
    # Codex-only supplement: nudge Codex to honor HQ checkpoint cadence. No
    # Claude analog, so it is not in settings.json. Runs before the mirrored
    # SessionStart hooks (migrate -> inject -> ... in settings.json order).
    run_hook "inject-codex-checkpoint-reprompt" "$HOOK_DIR/inject-codex-checkpoint-reprompt.sh" "$INPUT" "advisory"
    dispatch_settings_hooks "SessionStart" "ANY" "$INPUT"
    ;;
  UserPromptSubmit)
    dispatch_settings_hooks "UserPromptSubmit" "ANY" "$INPUT"
    ;;
  PreToolUse)
    run_pre_tool_use
    ;;
  PostToolUse)
    run_post_tool_use
    ;;
  Stop)
    # checkpoint-stop-gate emits decision:block; emit_context translates that to
    # Codex's Stop block protocol. The gate is fail-open, so launch failures
    # stay advisory.
    dispatch_settings_hooks "Stop" "ANY" "$INPUT"
    ;;
  PreCompact)
    dispatch_settings_hooks "PreCompact" "ANY" "$INPUT"
    ;;
  # Codex supports these lifecycle events natively; settings.json registers the
  # master-hook company/personal/pack fan-out on each (SessionEnd has live
  # listeners). Side-effect only — emit_context has no shape for them, so their
  # output is dropped and the exit code is ignored by Codex.
  SessionEnd)
    dispatch_settings_hooks "SessionEnd" "ANY" "$INPUT"
    ;;
  SubagentStop)
    # Codex reports completion here, separately from spawn_agent's asynchronous
    # launch acknowledgement. Feed the completed lifecycle payload through the
    # Agent-matched PostToolUse hooks (not its master entry, which belongs to
    # the native SubagentStop event below) so journal-autocapture records a real
    # result exactly once.
    agent_payload="$(printf '%s' "$INPUT" | jq -c '
      .tool_name = "Agent"
      | .tool_input = ((.tool_input // {}) + {
          description: (
            .tool_input.description
            // .task_name
            // .agent_type
            // .agent_id
            // "agent"
          )
        })
      | .tool_response = (
          .tool_response
          // .result
          // .last_assistant_message
          // .output
          // {
            status: (.status // "completed"),
            agent_id: (.agent_id // "")
          }
        )
    ' 2>/dev/null || true)"
    [ -n "$agent_payload" ] && dispatch_settings_hooks "PostToolUse" "Agent" "$agent_payload" skip_master
    dispatch_settings_hooks "SubagentStop" "ANY" "$INPUT"
    ;;
esac

emit_diag
emit_context
exit 0
