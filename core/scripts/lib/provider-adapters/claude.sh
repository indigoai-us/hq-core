#!/usr/bin/env bash
# hq-core: public
# provider-adapters/claude.sh — fleet claude adapter (US-501/US-503).
#
# Thin shim over the installed pty dispatch wrapper
# (/usr/local/bin/hq-agent-claude-dispatch.sh). Does NOT emit `claude -p`,
# Agent SDK references, or permission flags — those live inside the wrapper
# (buildClaudeDispatchScript). Matches claudeRunInner:
#   cd <workdir> && HQ_AGENT_CLAUDE_TASKFILE=<taskfile> [transcript env] <wrapper>
#
# Optional 4th arg: transcript-path-file expression (watcher injects
# HQ_AGENT_CLAUDE_TRANSCRIPT_PATH_FILE). Turn bound: default timeout 280s;
# refuse overrides at or above the dispatch supervisor's 300s idle timeout.

# Default turn bound (src/agents/claude-runtime.ts).
HQ_ADAPTER_CLAUDE_DEFAULT_TIMEOUT=280
# Dispatch supervisor idle timeout — overrides at/above this fail closed.
HQ_ADAPTER_CLAUDE_MAX_TIMEOUT=300
HQ_ADAPTER_CLAUDE_DISPATCH_PATH="/usr/local/bin/hq-agent-claude-dispatch.sh"

hq_adapter_id() {
  printf 'claude\n'
}

hq_adapter_capabilities() {
  cat <<'CAPS'
system_prompt=native
resume=emulated
hooks=native
plan_mode=absent
durable_writes=native
telegram_eligible=no
usage_source=transcript
CAPS
}

# hq_adapter_build_invocation <task_file_path> <workdir_expression> <preflight on|off>
#                [transcript_path_file_expression]
hq_adapter_build_invocation() {
  if [[ $# -lt 3 ]] || [[ $# -gt 4 ]]; then
    echo "hq_adapter_build_invocation: requires <task_file> <workdir> <preflight on|off> [transcript_path_file]" >&2
    return 1
  fi
  local task="$1" workdir="$2" preflight="$3" transcript_expr="${4:-}"
  case "$preflight" in
    on|off) ;;
    *)
      echo "hq_adapter_build_invocation: preflight mode must be on|off (got: ${preflight:-<empty>})" >&2
      return 1
      ;;
  esac

  local timeout="${HQ_AGENT_CLAUDE_TIMEOUT_SECONDS:-$HQ_ADAPTER_CLAUDE_DEFAULT_TIMEOUT}"
  # Refuse overrides that would race/exceed the dispatch supervisor idle timeout.
  if [[ "$timeout" =~ ^[0-9]+$ ]] && [[ "$timeout" -ge "$HQ_ADAPTER_CLAUDE_MAX_TIMEOUT" ]]; then
    echo "hq_adapter_build_invocation: HQ_AGENT_CLAUDE_TIMEOUT_SECONDS=$timeout must be < $HQ_ADAPTER_CLAUDE_MAX_TIMEOUT" >&2
    return 1
  fi
  if ! [[ "$timeout" =~ ^[0-9]+$ ]]; then
    echo "hq_adapter_build_invocation: HQ_AGENT_CLAUDE_TIMEOUT_SECONDS must be an integer (got: $timeout)" >&2
    return 1
  fi

  local transcript_seg=""
  if [[ -n "$transcript_expr" ]]; then
    # Byte-match watcher injection: space + KEY='expr' between taskfile and wrapper.
    transcript_seg=" HQ_AGENT_CLAUDE_TRANSCRIPT_PATH_FILE='${transcript_expr}'"
  fi

  # Preflight does not change claude flags; workdir expression varies.
  # Emit timeout so the effective bound is visible and overrideable < 300.
  printf 'cd %s && HQ_AGENT_CLAUDE_TIMEOUT_SECONDS=%s HQ_AGENT_CLAUDE_TASKFILE=%s%s %s\n' \
    "$workdir" "$timeout" "$task" "$transcript_seg" "$HQ_ADAPTER_CLAUDE_DISPATCH_PATH"
}

# Consume dispatch wrapper STDOUT only — never read RUN_DIR (deleted on EXIT).
hq_adapter_extract_reply() {
  local text
  text="$(cat)"
  if [[ -z "${text//[[:space:]]/}" ]]; then
    return 1
  fi
  printf '%s' "$text"
  return 0
}

hq_adapter_emit_usage() {
  printf 'usage_source=transcript\n'
}
