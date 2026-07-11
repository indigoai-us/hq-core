#!/bin/bash
# hq-core: public
# hq-grok-hook-adapter.sh — route Grok lifecycle hooks through HQ's existing
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
# (.codex/), and Grok (.grok/ + optional user bridge from grok-trust.sh) all
# route through it.
#
# Project .grok/hooks may not load on some Grok builds (observed 0.2.93:
# project hooks never appear in `grok inspect`). core/scripts/grok-trust.sh
# installs a user-global bridge under ~/.grok/hooks/ that finds and execs
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
  [ -n "$cand" ] && [ -x "$cand/.claude/hooks/hook-gate.sh" ] && HQ_ROOT="$cand"
fi
if [ -z "$HQ_ROOT" ]; then
  HQ_ROOT="${CLAUDE_PROJECT_DIR:-${GROK_WORKSPACE_ROOT:-}}"
  [ -n "$HQ_ROOT" ] && [ ! -x "$HQ_ROOT/.claude/hooks/hook-gate.sh" ] && HQ_ROOT=""
fi
if [ -z "$HQ_ROOT" ]; then
  # Walk up from cwd (nested repos under HQ).
  walk="$CWD"
  while [ -n "$walk" ] && [ "$walk" != "/" ]; do
    if [ -x "$walk/.claude/hooks/hook-gate.sh" ]; then
      HQ_ROOT="$walk"
      break
    fi
    walk="$(dirname "$walk")"
  done
fi

GATE="${HQ_ROOT:+$HQ_ROOT/.claude/hooks/hook-gate.sh}"
HOOK_DIR="${HQ_ROOT:+$HQ_ROOT/.claude/hooks}"

# Fail-open outside HQ trees (never wedge non-HQ projects).
if [ -z "$HQ_ROOT" ] || [ ! -x "${GATE:-}" ]; then
  if [ "$EVENT" = "PreToolUse" ]; then
    echo '{"decision":"allow"}'
  fi
  exit 0
fi

# Map Grok tool names → Claude names HQ hooks key on.
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

# Claude-shaped payload for HQ hooks.
CLAUDE_JSON="$(jq -n \
  --arg t "$CTOOL" \
  --arg c "$CMD" \
  --arg f "$FP" \
  --arg body "$CONTENT" \
  --arg event "$EVENT" \
  --arg cwd "$CWD" \
  '{
    hook_event_name: $event,
    tool_name: $t,
    cwd: $cwd,
    tool_input: (
      {}
      + (if $c != "" then {command: $c} else {} end)
      + (if $f != "" then {file_path: $f} else {} end)
      + (if $body != "" then {content: $body, new_string: $body} else {} end)
    )
  }' 2>/dev/null)"

deny() {
  local reason="$1"
  # Compact JSON — Grok parsers accept pretty output, but tests and logs prefer one line.
  jq -c -n --arg r "$reason" '{decision:"deny", reason:$r}'
  exit 2
}

allow_pre() {
  echo '{"decision":"allow"}'
}

run_block() { # <hook-id> <hook-script> [payload]
  local id="$1" script="$2" payload="${3:-$CLAUDE_JSON}"
  [ -x "$script" ] || return 0
  local err st
  err="$(printf '%s' "$payload" | HQ_ROOT="$HQ_ROOT" CLAUDE_PROJECT_DIR="$HQ_ROOT" "$GATE" "$id" "$script" 2>&1 1>/dev/null)"
  st=$?
  if [ "$st" -ne 0 ]; then
    deny "$(printf '%s' "${err:-Blocked by HQ guard: $id}" | head -c 1200)"
  fi
}

run_advisory() { # <hook-id> <hook-script> [payload]
  local id="$1" script="$2" payload="${3:-$CLAUDE_JSON}"
  [ -x "$script" ] || return 0
  printf '%s' "$payload" | HQ_ROOT="$HQ_ROOT" CLAUDE_PROJECT_DIR="$HQ_ROOT" \
    "$GATE" "$id" "$script" >/dev/null 2>&1 || true
}

run_script_advisory() { # <script> [payload]
  local script="$1" payload="${2:-$CLAUDE_JSON}"
  [ -x "$script" ] || return 0
  printf '%s' "$payload" | HQ_ROOT="$HQ_ROOT" CLAUDE_PROJECT_DIR="$HQ_ROOT" \
    "$script" >/dev/null 2>&1 || true
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
  jq -n --arg path "$path" --arg event "$EVENT" --arg cwd "$CWD" '{
    hook_event_name: $event,
    tool_name: "Edit",
    cwd: $cwd,
    tool_input: {file_path: $path}
  }'
}

run_pre_tool_use() {
  case "$CTOOL" in
    Bash)
      [ -n "$CMD" ] && block_sensitive_if_needed "$CMD"
      run_block detect-secrets              "$HOOK_DIR/detect-secrets.sh"
      run_block block-core-writes-bash      "$HOOK_DIR/block-core-writes-bash.sh"
      run_block block-hq-root-git-mutation  "$HOOK_DIR/block-hq-root-git-mutation.sh"
      run_block block-on-active-run         "$HOOK_DIR/block-on-active-run.sh"
      run_advisory inject-policy-on-trigger "$HOOK_DIR/inject-policy-on-trigger.sh"
      run_block block-unsafe-package-install "$HOOK_DIR/block-unsafe-package-install.sh"
      run_advisory surface-company-infra-policy "$HOOK_DIR/surface-company-infra-policy.sh"
      ;;
    Read)
      [ -n "$FP" ] && block_sensitive_if_needed "$FP"
      run_advisory warn-cross-company-settings "$HOOK_DIR/warn-cross-company-settings.sh"
      ;;
    Write|Edit)
      if [ -z "$FP" ]; then
        allow_pre
        return 0
      fi
      block_sensitive_if_needed "$FP"
      local payload
      payload="$(payload_for_path "$FP")"
      run_block protect-core                   "$HOOK_DIR/protect-core.sh" "$payload"
      run_block block-core-writes              "$HOOK_DIR/block-core-writes.sh" "$payload"
      run_block block-inline-story-impl        "$HOOK_DIR/block-inline-story-impl.sh" "$payload"
      run_block block-on-active-run            "$HOOK_DIR/block-on-active-run.sh" "$payload"
      run_block env-file-no-trailing-newline   "$HOOK_DIR/env-file-no-trailing-newline.sh" "$payload"
      run_advisory inject-policy-on-trigger    "$HOOK_DIR/inject-policy-on-trigger.sh" "$payload"
      run_block block-plans-dir-during-deep-plan "$HOOK_DIR/block-plans-dir-during-deep-plan.sh" "$payload"
      run_block route-company-skill-creation   "$HOOK_DIR/route-company-skill-creation.sh" "$payload"
      run_block validate-policy-frontmatter    "$HOOK_DIR/validate-policy-frontmatter.sh" "$payload"
      ;;
    Grep)
      run_block block-hq-grep "$HOOK_DIR/block-hq-grep.sh"
      ;;
    Glob)
      run_block block-hq-glob "$HOOK_DIR/block-hq-glob.sh"
      ;;
  esac
  allow_pre
}

run_post_tool_use() {
  case "$CTOOL" in
    Bash)
      run_advisory auto-checkpoint-trigger  "$HOOK_DIR/auto-checkpoint-trigger.sh"
      run_advisory auto-capture-registry    "$HOOK_DIR/auto-capture-registry.sh"
      run_advisory screenshot-resize-trigger "$HOOK_DIR/screenshot-resize-trigger.sh"
      run_advisory journal-due              "$HOOK_DIR/journal-due.sh"
      ;;
    Write|Edit)
      if [ -n "$FP" ]; then
        local payload
        payload="$(payload_for_path "$FP")"
        run_advisory auto-checkpoint-trigger   "$HOOK_DIR/auto-checkpoint-trigger.sh" "$payload"
        run_script_advisory "$HOOK_DIR/master-sync.sh" "$payload"
        run_advisory auto-mirror-company-skill "$HOOK_DIR/auto-mirror-company-skill.sh" "$payload"
        run_advisory hq-autocommit             "$HOOK_DIR/hq-autocommit.sh" "$payload"
        run_advisory journal-due               "$HOOK_DIR/journal-due.sh" "$payload"
      fi
      ;;
  esac
}

run_session_start() {
  # Mirrors Codex/Claude SessionStart ordering (migrate → inject → checks).
  run_script_advisory "$HQ_ROOT/core/scripts/migrate-policy-triggers.sh"
  run_advisory inject-policy-on-trigger       "$HOOK_DIR/inject-policy-on-trigger.sh"
  run_advisory check-bridge-health            "$HOOK_DIR/check-claude-desktop-bridge-health.sh"
  run_advisory check-repo-active-runs         "$HOOK_DIR/check-repo-active-runs.sh"
  run_advisory inject-local-context           "$HOOK_DIR/inject-local-context.sh"
  run_advisory auto-startwork                 "$HOOK_DIR/auto-startwork.sh"
  run_advisory check-core-yaml-parity         "$HOOK_DIR/check-core-yaml-parity.sh"
  run_advisory load-journal-index-on-start    "$HOOK_DIR/load-journal-index-on-start.sh"
  run_advisory check-hq-update                "$HOOK_DIR/check-hq-update.sh"
}

run_user_prompt_submit() {
  run_advisory rewrite-resume-sentinel  "$HOOK_DIR/rewrite-resume-sentinel.sh"
  run_advisory route-deep-plan-to-skill "$HOOK_DIR/route-deep-plan-to-skill.sh"
  run_advisory auto-session-project     "$HOOK_DIR/auto-session-project.sh"
  run_advisory inject-policy-on-trigger "$HOOK_DIR/inject-policy-on-trigger.sh"
}

run_stop() {
  run_advisory observe-patterns                 "$HOOK_DIR/observe-patterns.sh"
  run_advisory cleanup-mcp-processes            "$HOOK_DIR/cleanup-mcp-processes.sh"
  run_advisory context-warning-50               "$HOOK_DIR/context-warning-50.sh"
  run_advisory capture-estimates                "$HOOK_DIR/capture-estimates.sh"
  run_advisory enforce-capability-link-render   "$HOOK_DIR/enforce-capability-link-render.sh"
}

run_precompact() {
  run_advisory precompact-thrashing-detector "$HOOK_DIR/precompact-thrashing-detector.sh"
  run_advisory auto-checkpoint-precompact    "$HOOK_DIR/auto-checkpoint-precompact.sh"
  run_advisory journal-precompact            "$HOOK_DIR/journal-precompact.sh"
}

case "$EVENT" in
  SessionStart)       run_session_start ;;
  UserPromptSubmit)   run_user_prompt_submit ;;
  PreToolUse)         run_pre_tool_use ;;
  PostToolUse)        run_post_tool_use ;;
  Stop)               run_stop ;;
  PreCompact)         run_precompact ;;
  *)
    # Unknown / passive events: no-op (fail-open).
    if [ "$EVENT" = "PreToolUse" ]; then allow_pre; fi
    ;;
esac
exit 0
