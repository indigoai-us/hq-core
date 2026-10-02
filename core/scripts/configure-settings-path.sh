#!/usr/bin/env bash
# Configure the literal PATH snapshot used by Claude Code hooks/subagents.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
DEFAULT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd -P)"
REPO_ROOT="${1:-$DEFAULT_ROOT}"
BASE_PATH="${2:-$PATH}"
FLAG_READER="$REPO_ROOT/core/scripts/setup-path-flag.cjs"

# An absent or unreadable flag keeps the pre-flag behavior. The registry read is
# bounded and default-off; it only selects the machine-local target when true.
HQ_BIN="${HQ_CLI_BIN:-}"
if [[ -z "$HQ_BIN" ]]; then
  HQ_BIN="$(command -v hq 2>/dev/null || true)"
fi
FLAG_ENABLED="false"
if command -v node >/dev/null 2>&1 && [[ -f "$FLAG_READER" ]]; then
  FLAG_ENABLED="$(HQ_CLI_BIN="$HQ_BIN" node "$FLAG_READER" 2>/dev/null || printf 'false')"
fi

LOCAL_PATH=""
PROJECT_PATH=""
if [[ -f "$REPO_ROOT/.claude/settings.local.json" ]]; then
  LOCAL_PATH="$(jq -r 'if type == "object" then .env.PATH // empty else empty end' "$REPO_ROOT/.claude/settings.local.json" 2>/dev/null || true)"
fi
if [[ -f "$REPO_ROOT/.claude/settings.json" ]]; then
  PROJECT_PATH="$(jq -r 'if type == "object" then .env.PATH // empty else empty end' "$REPO_ROOT/.claude/settings.json" 2>/dev/null || true)"
fi
PATH_INPUT="${LOCAL_PATH}${LOCAL_PATH:+:}${PROJECT_PATH}${PROJECT_PATH:+:}${BASE_PATH}"
CURRENT_PATH="$(bash "$REPO_ROOT/core/scripts/compose-settings-path.sh" "$PATH_INPUT" || printf '%s' "$PATH_INPUT")"
if [[ "$FLAG_ENABLED" == "true" ]]; then
  SETTINGS_FILE="$REPO_ROOT/.claude/settings.local.json"
  if [[ -f "$SETTINGS_FILE" ]]; then
    if ! UPDATED="$(jq --arg p "$CURRENT_PATH" 'if type == "object" then . else {} end | .env = ((.env // {}) + {PATH: $p})' "$SETTINGS_FILE" 2>/dev/null)"; then
      printf '%s\n' 'settings.local.json is invalid — PATH not configured'
      exit 0
    fi
  else
    UPDATED="$(jq -n --arg p "$CURRENT_PATH" '{env: {PATH: $p}}')"
  fi
  printf '%s\n' "$UPDATED" > "$SETTINGS_FILE"
  printf '%s\n' 'settings.local.json'
else
  SETTINGS_FILE="$REPO_ROOT/.claude/settings.json"
  if [[ -f "$SETTINGS_FILE" ]]; then
    UPDATED="$(jq --arg p "$CURRENT_PATH" '.env.PATH = $p' "$SETTINGS_FILE")"
    printf '%s\n' "$UPDATED" > "$SETTINGS_FILE"
    printf '%s\n' 'settings.json'
  else
    printf '%s\n' 'settings.json not found — PATH not configured'
  fi
fi
