#!/usr/bin/env bash
# hq-core: public
# session-brief-constants.sh — load watcher brief-constant VALUES for assembly
# and the parity harness (US-412). Values are byte-identical copies of the
# thirteen constants declared in hq-pro inbox-watcher-cli / channel-writing-formats.
#
# Runtime path (preferred):
#   <root>/core/knowledge/public/hq-core/agent-session-constants/<NAME>.txt
# Fixture path (tests / offline):
#   <repo>/core/scripts/tests/fixtures/agent-session/constants/<NAME>.txt

# shellcheck shell=bash

SESSION_BRIEF_CONSTANT_NAMES=(
  SLACK_VERIFIED_PREAMBLE
  SLACK_STRICT_UNTRUSTED_PREAMBLE
  DM_VERIFIED_PREAMBLE
  DM_STRICT_UNTRUSTED_PREAMBLE
  VERIFIED_MEMBER_REPLY_POSTURE
  REPLY_NO_PROMISES
  SLACK_FORMATTING
  SLACK_PROGRESSIVE_POSTS
  SLACK_DECISION_ASKING
  CHANNEL_VOICE
  TELEGRAM_FORMATTING
  EMAIL_FORMATTING
  DM_FORMATTING
)

# session_brief_constants_dir <root>
#   Resolve the constants directory under an HQ root (or fall back to the
#   scripts-relative fixtures tree when the knowledge copy is absent).
session_brief_constants_dir() {
  local root="${1:-}"
  local knowledge fixtures
  knowledge="${root}/core/knowledge/public/hq-core/agent-session-constants"
  if [ -d "$knowledge" ] && [ -f "$knowledge/SLACK_VERIFIED_PREAMBLE.txt" ]; then
    printf '%s' "$knowledge"
    return 0
  fi
  # Fall back to the lib's sibling fixtures (works when assembly runs from a
  # partial fixture root that still has scripts/lib but no knowledge copy).
  local here
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  fixtures="$(cd "$here/../tests/fixtures/agent-session/constants" 2>/dev/null && pwd)" || fixtures=""
  if [ -n "$fixtures" ] && [ -d "$fixtures" ]; then
    printf '%s' "$fixtures"
    return 0
  fi
  printf '%s' "$knowledge"
}

# session_brief_constant_value <root> <NAME>
#   Print the constant VALUE (no trailing newline stripping of content).
#   Returns 1 when the file is missing.
session_brief_constant_value() {
  local root="${1:-}" name="${2:-}" dir f
  [ -n "$name" ] || return 1
  dir="$(session_brief_constants_dir "$root")"
  f="${dir}/${name}.txt"
  [ -f "$f" ] || return 1
  # Preserve file bytes exactly (constants are single-line prose without a
  # required trailing newline; we still cat as-is).
  cat "$f"
}

# session_brief_constant_count <dir>
#   Count *.txt constant files under dir.
session_brief_constant_count() {
  local dir="${1:-}" n=0
  [ -d "$dir" ] || { printf '0'; return 0; }
  # Portable count without mapfile.
  n="$(find "$dir" -maxdepth 1 -type f -name '*.txt' 2>/dev/null | wc -l | tr -d '[:space:]')"
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  printf '%s' "$n"
}

# session_append_brief_posture <root> <channel> <verified:true|false> <system_txt_path>
#   Append ALL applicable brief constants into system.txt (contract destination).
#   Trust preambles, posture, voice, and channel formatting land here — never
#   in user.txt (user.txt is untrusted channel payload only).
session_append_brief_posture() {
  local root="${1:-}" channel="${2:-}" verified="${3:-false}" out="${4:-}"
  local val preamble_name=""
  [ -n "$out" ] || return 0

  case "$channel" in
    slack)
      if [ "$verified" = "true" ]; then
        preamble_name="SLACK_VERIFIED_PREAMBLE"
      else
        preamble_name="SLACK_STRICT_UNTRUSTED_PREAMBLE"
      fi
      ;;
    dm)
      if [ "$verified" = "true" ]; then
        preamble_name="DM_VERIFIED_PREAMBLE"
      else
        preamble_name="DM_STRICT_UNTRUSTED_PREAMBLE"
      fi
      ;;
  esac

  {
    printf '\n<!-- hq-section: brief-posture -->\n'

    if [ -n "$preamble_name" ]; then
      if val="$(session_brief_constant_value "$root" "$preamble_name" 2>/dev/null)"; then
        printf '%s\n' "$val"
      fi
    fi

    # Universal no-promises posture (all channels / trust levels).
    if val="$(session_brief_constant_value "$root" REPLY_NO_PROMISES 2>/dev/null)"; then
      printf '%s\n' "$val"
    fi

    # Verified-member reply posture only for verified senders.
    if [ "$verified" = "true" ]; then
      if val="$(session_brief_constant_value "$root" VERIFIED_MEMBER_REPLY_POSTURE 2>/dev/null)"; then
        printf '%s\n' "$val"
      fi
    fi

    # Voice profile (all channels).
    if val="$(session_brief_constant_value "$root" CHANNEL_VOICE 2>/dev/null)"; then
      printf '%s\n' "$val"
    fi

    case "$channel" in
      slack)
        if val="$(session_brief_constant_value "$root" SLACK_FORMATTING 2>/dev/null)"; then
          printf '%s\n' "$val"
        fi
        if val="$(session_brief_constant_value "$root" SLACK_PROGRESSIVE_POSTS 2>/dev/null)"; then
          printf '%s\n' "$val"
        fi
        if val="$(session_brief_constant_value "$root" SLACK_DECISION_ASKING 2>/dev/null)"; then
          printf '%s\n' "$val"
        fi
        ;;
      telegram)
        if val="$(session_brief_constant_value "$root" TELEGRAM_FORMATTING 2>/dev/null)"; then
          printf '%s\n' "$val"
        fi
        ;;
      email)
        if val="$(session_brief_constant_value "$root" EMAIL_FORMATTING 2>/dev/null)"; then
          printf '%s\n' "$val"
        fi
        ;;
      dm)
        if val="$(session_brief_constant_value "$root" DM_FORMATTING 2>/dev/null)"; then
          printf '%s\n' "$val"
        fi
        ;;
    esac
  } >> "$out"
}

# session_append_rehydration <out_user_txt> <rehydration_block>
#   Append a provided rehydration prefill to user.txt when non-empty.
session_append_rehydration() {
  local out="${1:-}" block="${2:-}"
  [ -n "$out" ] || return 0
  [ -n "$block" ] || return 0
  {
    printf '\n'
    printf '%s\n' "$block"
  } >> "$out"
}
