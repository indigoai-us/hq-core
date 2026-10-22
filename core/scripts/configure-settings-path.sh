#!/usr/bin/env bash
# Configure the literal PATH snapshot used by Claude Code hooks/subagents.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
DEFAULT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd -P)"
REPO_ROOT="${1:-$DEFAULT_ROOT}"
BASE_PATH="${2:-$PATH}"
# Machine-specific PATH is never part of the released settings.json.
# Do not depend on a remote flag: false/default/error must preserve that file.

SETTINGS_FILE="$REPO_ROOT/.claude/settings.local.json"
# Local settings must be an owned file, never imported through a link.
if [[ -L "$REPO_ROOT/.claude" || -L "$SETTINGS_FILE" ]]; then
  printf '%s\n' 'settings.local.json is a symlink — PATH not configured'
  exit 0
fi
# jq accepts a UTF-8 BOM but drops it on output. Treat that unsupported local
# representation as invalid instead of silently changing unrelated bytes.
if [[ -f "$SETTINGS_FILE" && "$(head -c 3 "$SETTINGS_FILE" 2>/dev/null || true)" == $'\xEF\xBB\xBF' ]]; then
  printf '%s\n' 'settings.local.json has a BOM — PATH not configured'
  exit 0
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
if [[ -e "$SETTINGS_FILE" && ! -f "$SETTINGS_FILE" ]]; then
  printf '%s\n' 'settings.local.json is not a regular file — PATH not configured'
  exit 0
fi
if [[ -f "$SETTINGS_FILE" && ! -w "$SETTINGS_FILE" ]]; then
  printf '%s\n' 'settings.local.json is unwritable — PATH not configured'
  exit 0
fi
if [[ -f "$SETTINGS_FILE" ]]; then
  if ! UPDATED="$(jq --arg p "$CURRENT_PATH" '
    if type != "object" or (.env != null and (.env | type) != "object")
    then error("invalid local settings")
    else .env = ((.env // {}) + {PATH: $p}) end
  ' "$SETTINGS_FILE" 2>/dev/null)"; then
    printf '%s\n' 'settings.local.json is invalid — PATH not configured'
    exit 0
  fi
else
  UPDATED="$(jq -n --arg p "$CURRENT_PATH" '{env: {PATH: $p}}')"
fi
# Publish only a complete replacement. Copying an existing file preserves its
# mode; a new local file keeps mktemp's private permissions. A failed copy,
# partial write or rename never truncates the existing settings.
# Existing Cloud92/96 default rules exclude .hq-* internal state. Reuse that
# reserved naming while an older sync consumer runs beside this Core helper.
TEMP_FILE="$(mktemp "$REPO_ROOT/.claude/.hq-settings.local.json.tmp.XXXXXX")" || {
  printf '%s\n' 'settings.local.json could not be staged — PATH not configured'
  exit 0
}
trap '[ -z "${TEMP_FILE:-}" ] || rm -f "$TEMP_FILE"' EXIT
if [[ -f "$SETTINGS_FILE" ]] && ! cp -p "$SETTINGS_FILE" "$TEMP_FILE"; then
  printf '%s\n' 'settings.local.json could not be staged — PATH not configured'
  exit 0
fi
# A file-size signal kills only the writer subshell, leaving this shell able
# to remove its failed staging file and report the skipped configuration.
if ! (printf '%s\n' "$UPDATED" > "$TEMP_FILE"); then
  printf '%s\n' 'settings.local.json is unwritable — PATH not configured'
  exit 0
fi
if ! mv -f "$TEMP_FILE" "$SETTINGS_FILE"; then
  printf '%s\n' 'settings.local.json could not be published — PATH not configured'
  exit 0
fi
TEMP_FILE=""
printf '%s\n' 'settings.local.json'
