#!/usr/bin/env bash
# hq-core: public
# provider-adapter-claude.sh — claude CLI adapter for hq-agent-session.
#
# System prompt: --append-system-prompt "$(cat system.txt)" (native).
# Resume: --resume <sessionId> when HQ_AGENT_SESSION_RESUME_ID is set (matrix).
# Flags parity with claude-runtime.ts:364:
#   --settings, --dangerously-skip-permissions, --permission-mode bypassPermissions
# Never uses --print / headless. User text from user.txt as positional prompt.
# Sets SESSION_SYSTEM_PROMPT_MODE=native.
#
# Render-only mode: HQ_AGENT_SESSION_RENDER_ONLY=1 writes argv to
# <runDir>/provider.argv (NUL-separated) and prints a shell-escaped line to
# <runDir>/provider.argv.txt without exec.
#
# CWD: HQ_SESSION_PROJECT_DIR when set, else company_dir.
#
# Settings: claude starts in the company project dir, so Claude Code does not
# load the HQ root .claude/settings.json. The --settings file therefore carries
# the root's guard hook events (see _provider_claude_write_settings), so Slack,
# DM and job sessions run the same credential and scope guards as an
# interactive session in the HQ root. Without them claude does not start.

# Hook events copied from the HQ root settings into the session's --settings.
#   SessionStart  binds claude's own session id to the dispatch company
#                 (HQ_SPAWN_COMPANY); the scope guard denies company paths for
#                 an unbound session id, and the wrapper's own SessionStart
#                 call binds only its run id.
#   PreToolUse    credential guard, cross-company scope guard, per-tool policy
#   PostToolUse   output redaction and per-tool policy injection
# Not copied: UserPromptSubmit (the wrapper already ran it and applied its
# block and updatedInput), Stop (its gates wait on monitors and checkpoints,
# which would stall a headless turn), and the remaining lifecycle events.
HQ_AGENT_SESSION_CLAUDE_HOOK_EVENTS='["SessionStart","PreToolUse","PostToolUse"]'

provider_adapter_claude() {
  local run_dir="${1:-}" company_dir="${2:-}"
  local system_file="$run_dir/system.txt"
  local user_file="$run_dir/user.txt"
  local settings_file="$run_dir/settings.json"
  local system_text user_text resume_id cwd
  local -a argv

  [ -f "$system_file" ] || { echo "hq-agent-session: missing system.txt" >&2; return 1; }
  [ -f "$user_file" ] || { echo "hq-agent-session: missing user.txt" >&2; return 1; }

  system_text="$(cat "$system_file")"
  user_text="$(cat "$user_file")"
  resume_id="${HQ_AGENT_SESSION_RESUME_ID:-}"

  # A refusal gets its own exit code so the wrapper does not read it as a
  # rejected --resume and delete the conversation's resume record.
  _provider_claude_write_settings "$settings_file" || return "${HQ_PROVIDER_REFUSED_RC:-78}"

  argv=(
    claude
    --settings "$settings_file"
    --dangerously-skip-permissions
    --permission-mode bypassPermissions
    --append-system-prompt "$system_text"
  )
  if [ -n "$resume_id" ]; then
    argv+=(--resume "$resume_id")
  fi
  argv+=(
    --
    "$user_text"
  )

  SESSION_SYSTEM_PROMPT_MODE="native"
  SESSION_RESUME_SUPPORTED="true"
  _provider_write_argv "$run_dir" "${argv[@]}"

  if [ "${HQ_AGENT_SESSION_RENDER_ONLY:-0}" = "1" ]; then
    return 0
  fi

  cwd="${HQ_SESSION_PROJECT_DIR:-${company_dir:?company dir required}}"
  (
    cd "$cwd" || exit 1
    "${argv[@]}" </dev/null
  )
}

# _provider_claude_hq_root
#   HQ_ROOT (exported by hq-agent-session), else the HQ tree this adapter
#   ships in.
_provider_claude_hq_root() {
  if [ -n "${HQ_ROOT:-}" ]; then
    printf '%s' "$HQ_ROOT"
    return 0
  fi
  (cd "$(dirname "${BASH_SOURCE[0]}")/../../.." 2>/dev/null && pwd -P)
}

# _provider_claude_write_settings <settingsFile>
#   Writes {"hooks": {...}} with the HQ_AGENT_SESSION_CLAUDE_HOOK_EVENTS groups
#   from <hqRoot>/.claude/settings.json and <hqRoot>/.claude/settings.local.json,
#   concatenated in that order the way Claude Code merges the two files
#   (`hq rescue` can leave empty event arrays in settings.json and move the
#   master-hook lines into settings.local.json; see restore-hook-settings.sh).
#   Each command string is kept once per event. Each command is prefixed with
#   CLAUDE_PROJECT_DIR=<hqRoot> because Claude Code sets CLAUDE_PROJECT_DIR to
#   the directory it started in (the company project dir), and the root
#   commands locate master-hook.sh through it. The root is single-quoted, so
#   any path is safe in the command string.
#   Fails closed: returns 1, and leaves no settings file, when neither file
#   parses as a JSON object or the merged hooks carry no PreToolUse command.
_provider_claude_write_settings() {
  local settings_file="${1:-}" root tmp f
  local -a sources=()
  rm -f "$settings_file"
  root="$(_provider_claude_hq_root)" || root=""
  if [ -z "$root" ]; then
    echo "hq-agent-session: HQ root not resolved; refusing to start claude without the HQ guard hooks" >&2
    return 1
  fi
  if ! command -v jq >/dev/null 2>&1; then
    echo "hq-agent-session: jq is required to load the HQ guard hooks; refusing to start claude" >&2
    return 1
  fi
  for f in "$root/.claude/settings.json" "$root/.claude/settings.local.json"; do
    [ -f "$f" ] || continue
    if jq -e 'type == "object"' "$f" >/dev/null 2>&1; then
      sources+=("$f")
    else
      echo "hq-agent-session: ignoring unreadable settings file: $f" >&2
    fi
  done
  if [ "${#sources[@]}" -eq 0 ]; then
    echo "hq-agent-session: HQ root settings not found ($root/.claude/settings.json, settings.local.json); refusing to start claude without the HQ guard hooks" >&2
    return 1
  fi
  tmp="${settings_file}.tmp"
  # Each command string is kept once per event (Claude Code runs identical
  # commands once), even when the two files register it under a different
  # matcher or with a different timeout. A group left with no hooks is dropped.
  if ! jq -s --arg root "$root" --arg sq "'" \
    --argjson events "$HQ_AGENT_SESSION_CLAUDE_HOOK_EVENTS" '
      ($sq + ($root | gsub($sq; $sq + "\\" + $sq + $sq)) + $sq) as $quoted
      | ("CLAUDE_PROJECT_DIR=" + $quoted + "; export CLAUDE_PROJECT_DIR; ") as $prefix
      | [.[] | if (.hooks | type) == "object" then .hooks else {} end] as $all
      # disableAllHooks is pinned false: --settings outranks the project
      # settings in the agent cwd, so a project file cannot switch the guards off.
      | {disableAllHooks: false, hooks: (reduce $events[] as $event ({};
          ([$all[] | .[$event] | select(type == "array") | .[] | select(type == "object")]
            | reduce .[] as $g ({seen: {}, out: []};
                if ($g.hooks | type) == "array" then
                  (reduce $g.hooks[] as $h ({seen: .seen, keep: []};
                    if ($h | type) == "object" and $h.type == "command" and ($h.command | type) == "string" then
                      if .seen[$h.command] then . else (.seen[$h.command] = true | .keep += [$h]) end
                    else .keep += [$h] end)) as $r
                  | .seen = $r.seen
                  | if ($r.keep | length) > 0 then .out += [$g | .hooks = $r.keep] else . end
                else .out += [$g] end)
            | .out) as $groups
          | if ($groups | length) > 0 then
              .[$event] = [$groups[]
                | if (.hooks | type) == "array" then
                    .hooks |= map(
                      if type == "object" and .type == "command" and (.command | type) == "string"
                      then .command = $prefix + .command else . end)
                  else . end]
            else . end))}
      | if ([.hooks.PreToolUse[]?.hooks[]? | select(.type == "command")] | length) > 0
        then . else error("no PreToolUse command hooks") end
    ' "${sources[@]}" > "$tmp" 2>/dev/null; then
    rm -f "$tmp"
    echo "hq-agent-session: no HQ guard hooks in ${sources[*]}; refusing to start claude" >&2
    return 1
  fi
  mv "$tmp" "$settings_file"
}

# _provider_write_argv <runDir> <args...>
_provider_write_argv() {
  local run_dir="$1"
  shift
  local f_nul="$run_dir/provider.argv"
  local f_txt="$run_dir/provider.argv.txt"
  : > "$f_nul"
  : > "$f_txt"
  local a first=1
  for a in "$@"; do
    printf '%s\0' "$a" >> "$f_nul"
    if [ "$first" -eq 1 ]; then
      printf '%s' "$a" >> "$f_txt"
      first=0
    else
      # shell-escape for fixture comparison of non-multiline short args;
      # multiline values are represented as $'...'
      case "$a" in
        *$'\n'*|*$'\t'*|*\'*)
          printf " \$'%s'" "$(printf '%s' "$a" | sed -e "s/'/'\\\\''/g")" >> "$f_txt"
          ;;
        *' '*|*'|'*)
          printf " '%s'" "$a" >> "$f_txt"
          ;;
        *)
          printf ' %s' "$a" >> "$f_txt"
          ;;
      esac
    fi
  done
  printf '\n' >> "$f_txt"
  # Also write one-arg-per-line form (escaped) for stable fixtures.
  local f_lines="$run_dir/provider.argv.lines"
  : > "$f_lines"
  for a in "$@"; do
    printf '%s\n' "$a" >> "$f_lines"
  done
}
