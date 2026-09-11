#!/usr/bin/env bash
# hq-core: public
# provider-adapters/grok.sh — fleet grok adapter (US-501/US-502).
#
# Reproduces grokRunInner across both workdir modes. Flags match
# workflow-runner.mjs grok spawn: JSON envelope, --always-approve
# (current CLI; --yolo was the old synonym), --output-format json.
#   cd <workdir> && K="$(cat /home/ec2-user/.grok/key 2>/dev/null || true)" \
#     && export XAI_API_KEY="$K" \
#     && /home/ec2-user/.grok/bin/grok -p <taskfile> \
#          --permission-mode bypassPermissions --always-approve --output-format json
#
# The key-file preamble `|| true` is LOAD-BEARING: subscription-mode boxes have
# no key file; without it the && chain short-circuits before grok is invoked.
# Prompt-by-file: task path is an argv token after `grok -p` — never "$(cat …)"
# of the task file. The key-file "$(cat …)" in the preamble is retained.

hq_adapter_id() {
  printf 'grok\n'
}

hq_adapter_capabilities() {
  cat <<'CAPS'
system_prompt=native
resume=native
hooks=absent
plan_mode=absent
durable_writes=native
telegram_eligible=yes
usage_source=unavailable
CAPS
}

# hq_adapter_build_invocation <task_file_path> <workdir_expression> <preflight on|off>
# Preflight mode does not change grok flags; both workdir expressions use the
# same autonomy posture (--always-approve + JSON envelope).
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

  # shellcheck disable=SC2016
  # Intentional: emit the load-bearing K="$(cat … || true)" preamble as literal
  # command text for the on-box shell (not evaluated at adapter build time).
  printf 'cd %s && K="$(cat /home/ec2-user/.grok/key 2>/dev/null || true)" && export XAI_API_KEY="$K" && /home/ec2-user/.grok/bin/grok -p %s --permission-mode bypassPermissions --always-approve --output-format json\n' \
    "$workdir" "$task"
}

hq_adapter_extract_reply() {
  local text
  text="$(cat)"
  if [[ -z "${text//[[:space:]]/}" ]]; then
    return 1
  fi
  # JSON envelope from --output-format json: emit only .text
  if command -v jq >/dev/null 2>&1 && printf '%s' "$text" | jq -e 'type == "object" and (.text | type == "string")' >/dev/null 2>&1; then
    printf '%s' "$text" | jq -r '.text'
    return 0
  fi
  printf '%s' "$text"
  return 0
}

hq_adapter_emit_usage() {
  printf 'usage_source=unavailable\n'
}
