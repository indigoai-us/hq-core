#!/usr/bin/env bash
# hq-core: public
# session-resume.sh — per-convKey provider session id records for hq-agent-session.
#
# Record path: $HOME/.hq/agent-session/resume/<sha256 of convKey>.json
# Body: { "provider", "sessionId", "updatedAt" } mode 600.
# TTL mirrors CONVERSATION_TTL_DAYS (30) in hq-pro conversation-store.
# Cross-provider reads discard the record; corrupt/expired never fatal.

# Mirror of CONVERSATION_TTL_DAYS (src/agents/conversations/conversation-store.ts:44)
CONVERSATION_TTL_DAYS="${CONVERSATION_TTL_DAYS:-30}"

# session_resume_sha256 <text> → hex digest on stdout
session_resume_sha256() {
  local text="${1-}"
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$text" | shasum -a 256 2>/dev/null | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$text" | sha256sum 2>/dev/null | awk '{print $1}'
  else
    # openssl is common on fleet boxes
    printf '%s' "$text" | openssl dgst -sha256 2>/dev/null | awk '{print $NF}'
  fi
}

# session_resume_dir → resume store directory (created mode 700)
session_resume_dir() {
  local d="${HOME:?HOME required}/.hq/agent-session/resume"
  mkdir -p "$d"
  chmod 700 "$d" 2>/dev/null || true
  printf '%s' "$d"
}

# session_resume_path <convKey> → absolute path of the record file
session_resume_path() {
  local conv_key="${1:-}"
  local hash
  [ -n "$conv_key" ] || return 1
  hash="$(session_resume_sha256 "$conv_key")"
  [ -n "$hash" ] || return 1
  printf '%s/%s.json' "$(session_resume_dir)" "$hash"
}

# session_resume_now_iso → UTC ISO-8601
session_resume_now_iso() {
  date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u +"%Y-%m-%dT%H:%M:%SZ"
}

# session_resume_iso_to_epoch <iso> → epoch seconds (or empty)
session_resume_iso_to_epoch() {
  local iso="${1:-}"
  [ -n "$iso" ] || return 1
  # GNU date
  date -u -d "$iso" +%s 2>/dev/null && return 0
  # BSD date (strip trailing Z)
  local bare="${iso%Z}"
  date -u -j -f "%Y-%m-%dT%H:%M:%S" "$bare" +%s 2>/dev/null && return 0
  return 1
}

# session_resume_write <convKey> <provider> <sessionId>
#   Writes record mode 600. Returns 0 on success.
session_resume_write() {
  local conv_key="${1:-}" provider="${2:-}" session_id="${3:-}"
  local path tmp updated
  [ -n "$conv_key" ] && [ -n "$provider" ] && [ -n "$session_id" ] || return 1
  path="$(session_resume_path "$conv_key")" || return 1
  updated="$(session_resume_now_iso)"
  tmp="${path}.tmp.$$"
  if ! jq -nc \
    --arg provider "$provider" \
    --arg sessionId "$session_id" \
    --arg updatedAt "$updated" \
    '{provider:$provider, sessionId:$sessionId, updatedAt:$updatedAt}' \
    > "$tmp" 2>/dev/null; then
    rm -f "$tmp"
    return 1
  fi
  mv -f "$tmp" "$path"
  chmod 600 "$path" 2>/dev/null || true
  return 0
}

# session_resume_delete <path> — best-effort remove
session_resume_delete() {
  local path="${1:-}"
  [ -n "$path" ] && [ -f "$path" ] && rm -f "$path" 2>/dev/null || true
}

# session_resume_read <convKey> <provider>
#   Prints sessionId on stdout when valid for this provider.
#   Cross-provider / TTL / malformed → delete record, print nothing, exit 0.
#   Never fatal (always exit 0 for the read contract; empty = no session).
session_resume_read() {
  local conv_key="${1:-}" provider="${2:-}"
  local path body rec_provider rec_sid rec_updated epoch now age_limit age
  if [ -z "$conv_key" ] || [ -z "$provider" ]; then
    return 0
  fi
  path="$(session_resume_path "$conv_key")" || return 0
  [ -f "$path" ] || return 0

  if ! body="$(cat "$path" 2>/dev/null)" || ! printf '%s' "$body" | jq -e . >/dev/null 2>&1; then
    session_resume_delete "$path"
    return 0
  fi

  rec_provider="$(printf '%s' "$body" | jq -r '.provider // empty' 2>/dev/null || true)"
  rec_sid="$(printf '%s' "$body" | jq -r '.sessionId // empty' 2>/dev/null || true)"
  rec_updated="$(printf '%s' "$body" | jq -r '.updatedAt // empty' 2>/dev/null || true)"

  if [ -z "$rec_provider" ] || [ -z "$rec_sid" ] || [ -z "$rec_updated" ]; then
    session_resume_delete "$path"
    return 0
  fi

  if [ "$rec_provider" != "$provider" ]; then
    # Cross-provider: discard so a later matching provider does not inherit
    session_resume_delete "$path"
    return 0
  fi

  epoch="$(session_resume_iso_to_epoch "$rec_updated" 2>/dev/null || true)"
  if [ -z "$epoch" ]; then
    session_resume_delete "$path"
    return 0
  fi
  now="$(date +%s 2>/dev/null || true)"
  case "$now" in ''|*[!0-9]*) now=0 ;; esac
  age_limit=$((CONVERSATION_TTL_DAYS * 86400))
  age=$((now - epoch))
  if [ "$age" -gt "$age_limit" ]; then
    session_resume_delete "$path"
    return 0
  fi

  printf '%s' "$rec_sid"
  return 0
}

# session_resume_capture_claude_session_id <transcript_path_file>
#   Reads the path written into HQ_AGENT_CLAUDE_TRANSCRIPT_PATH_FILE (a file
#   whose contents are the absolute path of the .jsonl transcript). Session id
#   is basename without .jsonl (parity with claude-transcript-reporter.ts).
#   Prints session id or empty; never fatal.
session_resume_capture_claude_session_id() {
  local path_file="${1:-}"
  local transcript base id
  [ -n "$path_file" ] && [ -f "$path_file" ] && [ -s "$path_file" ] || return 0
  transcript="$(tr -d '\r\n' < "$path_file" 2>/dev/null || true)"
  [ -n "$transcript" ] || return 0
  base="$(basename "$transcript")"
  # strip .jsonl / .json
  id="$base"
  case "$id" in
    *.jsonl) id="${id%.jsonl}" ;;
    *.json) id="${id%.json}" ;;
  esac
  # reject empty / path-like remnants
  case "$id" in
    ''|*'/'*|*'..'*) return 0 ;;
  esac
  printf '%s' "$id"
  return 0
}

# session_resume_supported <provider>
#   Echo "true" or "false" for matrix-aligned resume support.
session_resume_supported() {
  case "${1:-}" in
    claude|codex|grok) printf 'true' ;;
    *) printf 'false' ;;
  esac
}
