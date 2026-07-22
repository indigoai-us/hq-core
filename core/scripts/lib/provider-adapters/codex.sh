#!/usr/bin/env bash
# hq-core: public
# provider-adapters/codex.sh — fleet codex adapter (US-501).
#
# Reproduces BOTH renders of resolveRunAgentInner's default arm:
#   preflight on:  cd "${HQ_AGENT_COMPANY_DIR:?…}" && codex exec --skip-git-repo-check
#                  --dangerously-bypass-hook-trust <taskfile>
#   preflight off: cd <workdir> && codex exec --skip-git-repo-check <taskfile>
#
# Prompt-by-file: the task path is an argv token — never "$(cat …)".
# Sandbox/approval flags are intentionally ABSENT so the box config
# (approval_policy=never, sandbox_mode=danger-full-access) remains effective.

hq_adapter_id() {
  printf 'codex\n'
}

hq_adapter_capabilities() {
  cat <<'CAPS'
system_prompt=emulated
resume=native
hooks=native
plan_mode=native
durable_writes=native
telegram_eligible=yes
usage_source=cli
CAPS
}

# hq_adapter_build_invocation <task_file_path> <workdir_expression> <preflight on|off>
hq_adapter_build_invocation() {
  if [[ $# -ne 3 ]]; then
    echo "hq_adapter_build_invocation: requires <task_file> <workdir> <preflight on|off>" >&2
    return 1
  fi
  local task="$1" workdir="$2" preflight="$3"
  case "$preflight" in
    on|off) ;;
    *)
      echo "hq_adapter_build_invocation: preflight mode must be on|off (got: ${preflight:-<empty>})" >&2
      return 1
      ;;
  esac

  if [[ "$preflight" == "on" ]]; then
    # Match inbox-watcher-cli preflight branch: company-dir workdir + hook-trust bypass.
    # workdir is still honored when the caller passes the preflight expression.
    printf 'cd %s && codex exec --skip-git-repo-check --dangerously-bypass-hook-trust %s\n' \
      "$workdir" "$task"
  else
    printf 'cd %s && codex exec --skip-git-repo-check %s\n' \
      "$workdir" "$task"
  fi
}

# Read captured provider stdout from stdin; fail closed on empty/whitespace.
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
  printf 'usage_source=cli\n'
}
