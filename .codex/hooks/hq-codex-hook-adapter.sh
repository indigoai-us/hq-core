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

run_script() {
  local script="$1"
  local payload="$2"
  local mode="${3:-advisory}"

  [ -x "$script" ] || return 0

  local out err status
  out="$(mktemp)"
  err="$(mktemp)"
  printf '%s' "$payload" | HQ_ROOT="$HQ_ROOT" CLAUDE_PROJECT_DIR="$HQ_ROOT" "$script" >"$out" 2>"$err"
  status=$?

  append_stdout "$(cat "$out" 2>/dev/null || true)"
  append_stderr "$(cat "$err" 2>/dev/null || true)"
  rm -f "$out" "$err"

  if [ "$status" -eq 0 ]; then
    return 0
  fi

  if [ "$mode" = "advisory" ]; then
    append_stderr "WARNING: advisory script '$(basename "$script")' exited $status; continuing."
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
parts = []
for key in ("command", "patch", "input"):
    value = tool_input.get(key)
    if isinstance(value, str) and value:
        parts.append(value)
command = "\n".join(parts)
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

normalize_path() {
  local path="$1"
  case "$path" in
    /*) ;;
    *) path="$HQ_ROOT/$path" ;;
  esac
  python3 -c 'import os.path,sys; sys.stdout.write(os.path.realpath(sys.argv[1]))' "$path" 2>/dev/null || printf '%s' "$path"
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
# `.env.local`, `.envrc` correctly do NOT match — matching Claude's
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
    Stop|PreCompact)
      jq -n --arg msg "$STDOUT_ACCUM" '{systemMessage: $msg}'
      ;;
  esac
}

run_pre_tool_use() {
  local cmd read_path
  case "$TOOL_NAME" in
    Bash)
      cmd="$(json_get '.tool_input.command // empty')"
      [ -n "$cmd" ] && block_sensitive_read_if_needed "$cmd"
      run_hook "detect-secrets" "$HOOK_DIR/detect-secrets.sh" "$INPUT" "blocking"
      run_hook "block-core-writes-bash" "$HOOK_DIR/block-core-writes-bash.sh" "$INPUT" "blocking"
      run_hook "block-hq-root-git-mutation" "$HOOK_DIR/block-hq-root-git-mutation.sh" "$INPUT" "blocking"
      run_hook "block-on-active-run" "$HOOK_DIR/block-on-active-run.sh" "$INPUT" "blocking"
      run_hook "inject-policy-on-trigger" "$HOOK_DIR/inject-policy-on-trigger.sh" "$INPUT" "advisory"
      run_hook "block-unsafe-package-install" "$HOOK_DIR/block-unsafe-package-install.sh" "$INPUT" "blocking"
      ;;
    Read)
      read_path="$(json_get '.tool_input.file_path // .tool_input.path // empty')"
      [ -n "$read_path" ] && block_sensitive_read_if_needed "$read_path"
      ;;
    apply_patch|Edit|Write)
      local paths path payload
      paths="$(patch_paths)"
      [ -z "$paths" ] && return 0
      while IFS= read -r path; do
        [ -z "$path" ] && continue
        block_core_edit_if_needed "$path"
        block_template_edit_if_needed "$path"
        block_sensitive_read_if_needed "$path"
        payload="$(payload_for_path "$path")"
        run_hook "protect-core" "$HOOK_DIR/protect-core.sh" "$payload" "blocking"
        run_hook "block-core-writes" "$HOOK_DIR/block-core-writes.sh" "$payload" "blocking"
        run_hook "block-inline-story-impl" "$HOOK_DIR/block-inline-story-impl.sh" "$payload" "blocking"
        run_hook "block-on-active-run" "$HOOK_DIR/block-on-active-run.sh" "$payload" "blocking"
        run_hook "env-file-no-trailing-newline" "$HOOK_DIR/env-file-no-trailing-newline.sh" "$payload" "blocking"
        run_hook "inject-policy-on-trigger" "$HOOK_DIR/inject-policy-on-trigger.sh" "$payload" "advisory"
        run_hook "block-plans-dir-during-deep-plan" "$HOOK_DIR/block-plans-dir-during-deep-plan.sh" "$payload" "blocking"
        run_hook "route-company-skill-creation" "$HOOK_DIR/route-company-skill-creation.sh" "$payload" "blocking"
      done <<< "$paths"
      ;;
  esac
}

run_post_tool_use() {
  case "$TOOL_NAME" in
    Bash)
      run_hook "auto-checkpoint-trigger" "$HOOK_DIR/auto-checkpoint-trigger.sh" "$INPUT" "advisory"
      run_hook "auto-capture-registry" "$HOOK_DIR/auto-capture-registry.sh" "$INPUT" "advisory"
      run_hook "screenshot-resize-trigger" "$HOOK_DIR/screenshot-resize-trigger.sh" "$INPUT" "advisory"
      run_hook "journal-due" "$HOOK_DIR/journal-due.sh" "$INPUT" "advisory"
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
      run_script "$HOOK_DIR/master-sync.sh" "$INPUT" "advisory"
      while IFS= read -r path; do
        [ -z "$path" ] && continue
        payload="$(payload_for_path "$path")"
        # auto-mirror-company-skill MUST run before hq-autocommit so any newly-mirrored
        # skill files are picked up by autocommit (codex review P2 from prior #187 round).
        run_hook "auto-mirror-company-skill" "$HOOK_DIR/auto-mirror-company-skill.sh" "$payload" "advisory"
        run_hook "hq-autocommit" "$HOOK_DIR/hq-autocommit.sh" "$payload" "advisory"
        run_hook "journal-due" "$HOOK_DIR/journal-due.sh" "$payload" "advisory"
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
    run_hook "check-bridge-health" "$HOOK_DIR/check-claude-desktop-bridge-health.sh" "$INPUT" "advisory"
    run_hook "check-repo-active-runs" "$HOOK_DIR/check-repo-active-runs.sh" "$INPUT" "advisory"
    run_hook "inject-local-context" "$HOOK_DIR/inject-local-context.sh" "$INPUT" "advisory"
    run_hook "auto-startwork" "$HOOK_DIR/auto-startwork.sh" "$INPUT" "advisory"
    run_hook "check-core-yaml-parity" "$HOOK_DIR/check-core-yaml-parity.sh" "$INPUT" "advisory"
    run_hook "load-journal-index-on-start" "$HOOK_DIR/load-journal-index-on-start.sh" "$INPUT" "advisory"
    run_hook "check-hq-update" "$HOOK_DIR/check-hq-update.sh" "$INPUT" "advisory"
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
    run_hook "cleanup-mcp-processes" "$HOOK_DIR/cleanup-mcp-processes.sh" "$INPUT" "advisory"
    run_hook "context-warning-50" "$HOOK_DIR/context-warning-50.sh" "$INPUT" "advisory"
    run_hook "capture-estimates" "$HOOK_DIR/capture-estimates.sh" "$INPUT" "advisory"
    run_hook "enforce-capability-link-render" "$HOOK_DIR/enforce-capability-link-render.sh" "$INPUT" "advisory"
    ;;
  PreCompact)
    run_hook "precompact-thrashing-detector" "$HOOK_DIR/precompact-thrashing-detector.sh" "$INPUT" "advisory"
    run_hook "auto-checkpoint-precompact" "$HOOK_DIR/auto-checkpoint-precompact.sh" "$INPUT" "advisory"
    run_hook "journal-precompact" "$HOOK_DIR/journal-precompact.sh" "$INPUT" "advisory"
    ;;
esac

emit_context
exit 0
