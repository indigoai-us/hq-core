#!/usr/bin/env bash
# session-title-config.sh — resolve the session auto-naming settings.
#
# Prints three lines to stdout:
#   enabled=true|false
#   mode=full|auto
#   desktop_autoname=ignore-first|respect
#
# Resolution, first match wins: env HQ_SESSION_TITLE / HQ_DISABLED_HOOKS, then
# personal/settings/session-title.yaml, then core/settings/session-title.yaml,
# then the built-in defaults (enabled=true, mode=full).
#
# Deliberately grep/sed only — no python3, no node. This runs inside the
# SessionStart/UserPromptSubmit hook path, which must stay dependency-free on
# machines that have neither (see core/scripts/tests/hooks-no-python.test.sh).
#
# Usage: session-title-config.sh [--root <hq-root>]
set -uo pipefail

HQ_ROOT="${HQ_ROOT:-${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}}"
while [ $# -gt 0 ]; do
  case "$1" in
    --root) HQ_ROOT="${2:-$HQ_ROOT}"; shift 2 ;;
    *)      shift ;;
  esac
done

ENABLED="true"
MODE="full"
DESKTOP_AUTONAME="ignore-first"

# Read a top-level scalar key from a simple YAML file. Ignores comments,
# indented keys, and inline trailing comments. Good enough for flat settings;
# these files are documented as flat.
yaml_scalar() {
  local file="$1" key="$2" line=""
  [ -f "$file" ] || return 1
  line="$(grep -E "^${key}:[[:space:]]*" "$file" 2>/dev/null | head -n 1)" || return 1
  [ -n "$line" ] || return 1
  line="${line#*:}"
  line="$(printf '%s' "$line" | sed -E 's/[[:space:]]*#.*$//; s/^[[:space:]]+//; s/[[:space:]]+$//; s/^["'"'"']//; s/["'"'"']$//')"
  [ -n "$line" ] || return 1
  printf '%s' "$line"
}

# Lowest precedence first, so later reads overwrite earlier ones.
for f in "$HQ_ROOT/core/settings/session-title.yaml" \
         "$HQ_ROOT/personal/settings/session-title.yaml"; do
  v="$(yaml_scalar "$f" enabled)" && [ -n "$v" ] && ENABLED="$v"
  v="$(yaml_scalar "$f" mode)"    && [ -n "$v" ] && MODE="$v"
  v="$(yaml_scalar "$f" desktop_autoname)" && [ -n "$v" ] && DESKTOP_AUTONAME="$v"
done

case "$ENABLED" in
  0|false|FALSE|False|off|OFF|no|NO) ENABLED="false" ;;
  *)                                 ENABLED="true"  ;;
esac
case "$MODE" in
  auto|AUTO|hook|deterministic) MODE="auto" ;;
  *)                            MODE="full" ;;
esac
case "$DESKTOP_AUTONAME" in
  respect|RESPECT|off|OFF|false|FALSE|no|NO) DESKTOP_AUTONAME="respect" ;;
  *)                                         DESKTOP_AUTONAME="ignore-first" ;;
esac

# Env wins over every file.
case "${HQ_SESSION_TITLE:-}" in
  0|false|FALSE|off|OFF|no|NO) ENABLED="false" ;;
  auto|AUTO)                   MODE="auto"     ;;
esac
case "${HQ_DISABLED_HOOKS:-}" in
  *session-title*) ENABLED="false" ;;
esac

printf 'enabled=%s\nmode=%s\ndesktop_autoname=%s\n' "$ENABLED" "$MODE" "$DESKTOP_AUTONAME"
