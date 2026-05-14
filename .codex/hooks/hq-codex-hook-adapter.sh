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

HQ_ROOT="$(git -C "$CWD" rev-parse --show-toplevel 2>/dev/null || pwd)"
HOOK_DIR="$HQ_ROOT/.claude/hooks"
GATE="$HOOK_DIR/hook-gate.sh"

if [ ! -x "$GATE" ]; then
  exit 0
fi

STDOUT_ACCUM=""
STDERR_ACCUM=""

append_stdout() {
  local text="$1"
  [ -z "$text" ] && return 0
  if [ -z "$STDOUT_ACCUM" ]; then
    STDOUT_ACCUM="$text"
  else
    STDOUT_ACCUM="${STDOUT_ACCUM}
${text}"
  fi
}

append_stderr() {
  local text="$1"
  [ -z "$text" ] && return 0
  if [ -z "$STDERR_ACCUM" ]; then
    STDERR_ACCUM="$text"
  else
    STDERR_ACCUM="${STDERR_ACCUM}
${text}"
  fi
}

run_hook() {
  local hook_id="$1"
  local script="$2"
  local payload="$3"
  local mode="${4:-blocking}"

  [ -x "$script" ] || return 0

  local out err status
  out="$(mktemp)"
  err="$(mktemp)"
  printf '%s' "$payload" | HQ_ROOT="$HQ_ROOT" "$GATE" "$hook_id" "$script" >"$out" 2>"$err"
  status=$?

  append_stdout "$(cat "$out" 2>/dev/null || true)"
  append_stderr "$(cat "$err" 2>/dev/null || true)"
  rm -f "$out" "$err"

  if [ "$status" -eq 0 ]; then
    return 0
  fi

  if [ "$mode" = "advisory" ]; then
    append_stderr "WARNING: advisory hook '$hook_id' exited $status; continuing."
    return 0
  fi

  [ -n "$STDERR_ACCUM" ] && printf '%s\n' "$STDERR_ACCUM" >&2
  exit "$status"
}

patch_paths() {
  printf '%s' "$INPUT" | python3 -c '
import json
import re
import sys

try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)

tool_input = data.get("tool_input") or {}
command = tool_input.get("command") or tool_input.get("patch") or ""
paths = []

for key in ("file_path", "path"):
    value = tool_input.get(key)
    if isinstance(value, str) and value:
        paths.append(value)

for line in command.splitlines():
    match = re.match(r"^\*\*\* (?:Add|Update|Delete) File: (.+)$", line)
    if match:
        paths.append(match.group(1).strip())
        continue
    match = re.match(r"^\*\*\* Move to: (.+)$", line)
    if match:
        paths.append(match.group(1).strip())

seen = set()
for path in paths:
    if path and path not in seen:
        seen.add(path)
        print(path)
'
}

payload_for_path() {
  local path="$1"
  printf '%s' "$INPUT" | jq --arg path "$path" '
    .tool_name = "Edit"
    | .tool_input = {file_path: $path}
  '
}

emit_context() {
  [ -z "$STDOUT_ACCUM" ] && return 0

  case "$HOOK_EVENT" in
    SessionStart|UserPromptSubmit)
      printf '%s\n' "$STDOUT_ACCUM"
      ;;
    PostToolUse)
      jq -n --arg ctx "$STDOUT_ACCUM" '{
        hookSpecificOutput: {
          hookEventName: "PostToolUse",
          additionalContext: $ctx
        }
      }'
      ;;
    Stop)
      jq -n --arg msg "$STDOUT_ACCUM" '{systemMessage: $msg}'
      ;;
  esac
}

run_pre_tool_use() {
  case "$TOOL_NAME" in
    Bash)
      run_hook "detect-secrets" "$HOOK_DIR/detect-secrets.sh" "$INPUT" "blocking"
      run_hook "block-on-active-run" "$HOOK_DIR/block-on-active-run.sh" "$INPUT" "blocking"
      ;;
    apply_patch|Edit|Write)
      local paths path payload
      paths="$(patch_paths)"
      [ -z "$paths" ] && return 0
      while IFS= read -r path; do
        [ -z "$path" ] && continue
        payload="$(payload_for_path "$path")"
        run_hook "protect-core" "$HOOK_DIR/protect-core.sh" "$payload" "blocking"
        run_hook "block-on-active-run" "$HOOK_DIR/block-on-active-run.sh" "$payload" "blocking"
      done <<< "$paths"
      ;;
  esac
}

run_post_tool_use() {
  case "$TOOL_NAME" in
    Bash)
      run_hook "auto-checkpoint-trigger" "$HOOK_DIR/auto-checkpoint-trigger.sh" "$INPUT" "advisory"
      run_hook "auto-capture-registry" "$HOOK_DIR/auto-capture-registry.sh" "$INPUT" "advisory"
      ;;
    apply_patch|Edit|Write)
      local paths path payload
      paths="$(patch_paths)"
      [ -z "$paths" ] && return 0
      while IFS= read -r path; do
        [ -z "$path" ] && continue
        payload="$(payload_for_path "$path")"
        run_hook "auto-checkpoint-trigger" "$HOOK_DIR/auto-checkpoint-trigger.sh" "$payload" "advisory"
      done <<< "$paths"
      ;;
    update_plan|ExitPlanMode)
      run_hook "native-plan-project-sync" "$HOOK_DIR/native-plan-project-sync.sh" "$INPUT" "advisory"
      ;;
  esac
}

case "$HOOK_EVENT" in
  SessionStart)
    run_hook "load-policies" "$HOOK_DIR/load-policies-for-session.sh" "$INPUT" "advisory"
    run_hook "inject-local-context" "$HOOK_DIR/inject-local-context.sh" "$INPUT" "advisory"
    run_hook "auto-startwork" "$HOOK_DIR/auto-startwork.sh" "$INPUT" "advisory"
    ;;
  UserPromptSubmit)
    run_hook "rewrite-resume-sentinel" "$HOOK_DIR/rewrite-resume-sentinel.sh" "$INPUT" "advisory"
    run_hook "route-deep-plan-to-skill" "$HOOK_DIR/route-deep-plan-to-skill.sh" "$INPUT" "advisory"
    run_hook "auto-session-project" "$HOOK_DIR/auto-session-project.sh" "$INPUT" "advisory"
    ;;
  PreToolUse)
    run_pre_tool_use
    ;;
  PostToolUse)
    run_post_tool_use
    ;;
  Stop)
    run_hook "observe-patterns" "$HOOK_DIR/observe-patterns.sh" "$INPUT" "advisory"
    ;;
esac

emit_context
exit 0
