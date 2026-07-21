#!/usr/bin/env bash
# hq-core: public
# session-system-prompt.sh — assemble system.txt / user.txt for hq-agent-session.
#
# Five sections in fixed order, each introduced by:
#   <!-- hq-section: NAME -->
# charter, agent-contract, company-charter, channel-format, policies.
#
# user.txt carries only UNTRUSTED-framed channel payload (never section markers).

# session_extract_channel_section <formats_file> <channel>
#   Print the body under a heading that matches the channel name (case-insensitive).
#   Heading forms accepted: "## channel", "## Channel", "# channel".
session_extract_channel_section() {
  local file="${1:-}" channel="${2:-}"
  [ -f "$file" ] || return 0
  [ -n "$channel" ] || return 0
  awk -v ch="$channel" '
    BEGIN { IGNORECASE=1; want=tolower(ch); grabbing=0 }
    /^#{1,3}[[:space:]]+/ {
      line=$0
      sub(/^#{1,3}[[:space:]]+/, "", line)
      gsub(/[[:space:]]+$/, "", line)
      # Strip trailing punctuation from heading text
      gsub(/[:.]+$/, "", line)
      if (tolower(line) == want) { grabbing=1; next }
      if (grabbing) exit
    }
    grabbing { print }
  ' "$file"
}

# session_emit_section <name> <source_path>
#   Emit delimiter + body (or empty body if missing). Logs skip to stderr.
session_emit_section() {
  local name="${1:-}" src="${2:-}"
  printf '<!-- hq-section: %s -->\n' "$name"
  if [ -n "$src" ] && [ -f "$src" ]; then
    # Preserve file bytes; ensure trailing newline between sections.
    cat "$src"
    # Ensure section ends with a newline for stable assembly.
    local last
    last="$(tail -c1 "$src" 2>/dev/null || true)"
    [ -z "$last" ] || [ "$last" = $'\n' ] || printf '\n'
  else
    if [ -n "$src" ]; then
      echo "[hq-agent-session] skipped $src" >&2
    fi
    # Empty body: still a blank line after delimiter for stability.
    printf '\n'
  fi
}

# session_assemble_system_prompt <root> <companySlug> <channel> <out_file>
#   Write deterministic system.txt to out_file. Prints byte size on stdout.
session_assemble_system_prompt() {
  local root="${1:-}" company="${2:-}" channel="${3:-}" out="${4:-}"
  local tmp charter agent_contract company_charter formats policies_placeholder
  tmp="$(mktemp)"
  charter="$root/AGENTS.md"
  agent_contract="$root/personal/knowledge/public/agent-capabilities/hq-agent-contract.md"
  company_charter="$root/companies/$company/CLAUDE.md"
  formats="$root/core/knowledge/public/hq-core/channel-writing-formats.md"
  # policies: empty placeholder filled by a later story (US-045 / US-406)
  policies_placeholder=""

  {
    session_emit_section "charter" "$charter"
    session_emit_section "agent-contract" "$agent_contract"
    session_emit_section "company-charter" "$company_charter"
    # channel-format body extracted from the formats doc
    printf '<!-- hq-section: channel-format -->\n'
    if [ -f "$formats" ]; then
      session_extract_channel_section "$formats" "$channel"
      printf '\n'
    else
      echo "[hq-agent-session] skipped $formats" >&2
      printf '\n'
    fi
    session_emit_section "policies" "$policies_placeholder"
  } > "$tmp"

  mv "$tmp" "$out"
  # Byte size (portable: wc -c may pad; strip spaces)
  wc -c < "$out" | tr -d '[:space:]'
}

# session_write_user_txt <messageText> <out_file>
#   Write UNTRUSTED-framed channel payload only. Never includes hq-section markers.
session_write_user_txt() {
  local text="${1-}" out="${2:-}"
  {
    printf '%s\n' '<UNTRUSTED_CHANNEL_MESSAGE source="channel">'
    # messageText may be empty; still emit framing.
    printf '%s\n' "$text"
    printf '%s\n' '</UNTRUSTED_CHANNEL_MESSAGE>'
  } > "$out"
}
