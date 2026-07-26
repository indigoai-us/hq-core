#!/usr/bin/env bash
# hq-core: public
# provider-adapter-grok.sh — grok CLI adapter for hq-agent-session.
#
# System prompt: --system-prompt-override "$(cat system.txt)" (native).
# Resume: --resume <sessionId> when HQ_AGENT_SESSION_RESUME_ID is set (matrix).
# Keeps --yolo (and --no-auto-update) from user-data.ts fleet invocation.
# User text from user.txt via -p (single-turn). Never concatenates system
# text into the positional prompt argument.
# Sets SESSION_SYSTEM_PROMPT_MODE=native.
#
# CWD: HQ_SESSION_PROJECT_DIR when set, else company_dir.

provider_adapter_grok() {
  local run_dir="${1:-}" company_dir="${2:-}"
  local system_file="$run_dir/system.txt"
  local user_file="$run_dir/user.txt"
  local system_text user_text resume_id cwd
  local -a argv

  [ -f "$system_file" ] || { echo "hq-agent-session: missing system.txt" >&2; return 1; }
  [ -f "$user_file" ] || { echo "hq-agent-session: missing user.txt" >&2; return 1; }

  system_text="$(cat "$system_file")"
  user_text="$(cat "$user_file")"
  resume_id="${HQ_AGENT_SESSION_RESUME_ID:-}"

  # --output-format json is REQUIRED, not cosmetic. In `plain` (the CLI default)
  # a multi-step run interleaves each step's narration with the final answer on
  # one stdout stream, and the session captures that stream verbatim as the
  # reply — which is how whole transcripts (and a literal NO_REPLY sentinel)
  # shipped into Slack. The json envelope separates `.text` (the answer) from
  # `.thought` (reasoning), so we can deliver only the answer.
  argv=(
    grok
    -p
    "$user_text"
    --yolo
    --no-auto-update
    --output-format
    json
    --system-prompt-override
    "$system_text"
  )
  if [ -n "$resume_id" ]; then
    argv+=(--resume "$resume_id")
  fi

  SESSION_SYSTEM_PROMPT_MODE="native"
  SESSION_RESUME_SUPPORTED="true"

  if ! command -v _provider_write_argv >/dev/null 2>&1; then
    _provider_write_argv() {
      local rd="$1"; shift
      local f_lines="$rd/provider.argv.lines"
      : > "$f_lines"
      local a
      for a in "$@"; do printf '%s\n' "$a" >> "$f_lines"; done
      : > "$rd/provider.argv"
      for a in "$@"; do printf '%s\0' "$a" >> "$rd/provider.argv"; done
    }
  fi
  _provider_write_argv "$run_dir" "${argv[@]}"
  if [ -n "$resume_id" ]; then
    printf 'cli-flag:--resume\n' > "$run_dir/provider.systemPromptMechanism"
  else
    printf 'cli-flag:--system-prompt-override\n' > "$run_dir/provider.systemPromptMechanism"
  fi

  if [ "${HQ_AGENT_SESSION_RENDER_ONLY:-0}" = "1" ]; then
    return 0
  fi

  cwd="${HQ_SESSION_PROJECT_DIR:-${company_dir:?company dir required}}"
  local raw rc=0
  raw="$run_dir/provider.grok.json"
  (
    cd "$cwd" || exit 1
    "${argv[@]}" </dev/null
  ) >"$raw" || rc=$?

  # Emit ONLY the final assistant text on stdout — the session captures our
  # stdout as the reply body. `.thought` is deliberately dropped: it is the
  # model's private reasoning and must never reach a channel.
  if jq -e -s 'length == 1 and (.[0] | (type == "object" and (.text | type == "string")))' \
    "$raw" >/dev/null 2>&1; then
    jq -r -s '.[0].text' "$raw"
    # Surface the provider session id for resume without polluting the reply.
    local sid
    sid="$(jq -r -s '.[0].sessionId | if type == "string" then . else empty end' \
      "$raw" 2>/dev/null || true)"
    [ -n "$sid" ] && printf '%s\n' "$sid" > "$run_dir/provider.sessionId"
  else
    # The raw stream can contain private reasoning and control sentinels. Never
    # copy it to stderr or reply stdout when the envelope contract is broken.
    echo "hq-agent-session: grok output was not a valid json envelope; refusing output" >&2
    [ "$rc" -ne 0 ] || rc=1
  fi
  return "$rc"
}
