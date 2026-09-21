#!/bin/bash
# auto-conduct.sh — SessionStart hook that opens fresh sessions in /conduct mode.
#
# Reads the `conduct:` block of the orchestrator settings. When
# `default_enabled: true`, the session's conduct engine is persisted in
# workspace/sessions/<id>/meta.yaml and the assistant is told to run
# `/conduct <engine>` as its first action, so every task in the session is
# dispatched to detached worker lanes and the parent stays free.
#
# Settings file (first one that exists wins):
#   personal/settings/orchestrator.yaml   # per-machine override
#   core/settings/orchestrator.yaml       # shipped default (off)
#
#   conduct:
#     default_enabled: false
#     default_engine: codex   # codex | grok | claude
#
# Per-session override:
#   HQ_AUTO_CONDUCT=1            force on (uses default_engine, or codex)
#   HQ_AUTO_CONDUCT=0            force off
#   HQ_DISABLED_HOOKS=auto-conduct

set -euo pipefail

STDIN_JSON="$(cat 2>/dev/null || echo '{}')"
SOURCE="$(printf '%s' "$STDIN_JSON" | sed -nE 's/.*"source"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' | head -1)"
[ -z "$SOURCE" ] && SOURCE="startup"

# Only fresh sessions bootstrap. Resume/compact events already carry the mode
# in meta.yaml (or the user turned it off with /conduct off).
case "$SOURCE" in
  startup|"") ;;
  *) exit 0 ;;
esac

disabled_hooks=",${HQ_DISABLED_HOOKS:-},"
disabled_hooks="$(printf '%s' "$disabled_hooks" | tr -d '[:space:]')"
case "$disabled_hooks" in
  *,auto-conduct,*) exit 0 ;;
esac

HQ_ROOT="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

SETTINGS="$HQ_ROOT/core/settings/orchestrator.yaml"
if [ -f "$HQ_ROOT/personal/settings/orchestrator.yaml" ]; then
  SETTINGS="$HQ_ROOT/personal/settings/orchestrator.yaml"
fi

# Read one scalar key from the top-level `conduct:` block. Comments and quotes
# are stripped; the first match wins.
read_conduct_key() {
  local key="$1"
  [ -f "$SETTINGS" ] || return 0
  awk -v k="$key" '
    /^[^[:space:]#]/ { in_block = ($0 ~ /^conduct:[[:space:]]*(#.*)?$/) ; next }
    in_block && $0 ~ "^[[:space:]]+" k ":" {
      line = $0
      sub(/^[[:space:]]+[^:]+:[[:space:]]*/, "", line)
      sub(/[[:space:]]*#.*$/, "", line)
      gsub(/^["'\''"]|["'\''"]$/, "", line)
      print line
      exit
    }
  ' "$SETTINGS"
}

enabled="$(read_conduct_key default_enabled)"
engine="$(read_conduct_key default_engine)"

case "${HQ_AUTO_CONDUCT:-}" in
  1|true|TRUE|on|ON|yes|YES) enabled="true" ;;
  0|false|FALSE|off|OFF|no|NO) exit 0 ;;
esac

case "$enabled" in
  true|TRUE|yes|YES|on|ON|1) ;;
  *) exit 0 ;;
esac

case "$engine" in
  codex|grok|claude) ;;
  "") engine="codex" ;;
  *)
    echo "auto-conduct: unknown conduct.default_engine '$engine' (expected codex, grok, or claude); using codex" >&2
    engine="codex"
    ;;
esac

# Persist the engine so later turns see the mode even before /conduct runs.
# Best effort: a session the hook cannot resolve still gets the instruction.
SESSION_ID="${HQ_HOOK_SESSION_ID:-$(printf '%s' "$STDIN_JSON" | sed -nE 's/.*"session_id"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' | head -1)}"
if [ -n "$SESSION_ID" ] && [ -f "$HQ_ROOT/core/scripts/hq-session.sh" ]; then
  HQ_HQ_SESSION_NO_CLI=1 bash "$HQ_ROOT/core/scripts/hq-session.sh" --session-id "$SESSION_ID" \
    set conduct_engine "$engine" >/dev/null 2>&1 \
    || echo "auto-conduct: could not persist conduct_engine for session $SESSION_ID" >&2
fi

cat <<EOT
<auto-conduct>
Conduct mode is on by default for this HQ (orchestrator settings: conduct.default_enabled).
Run \`/conduct $engine\` now as the first session action, before any task work. If slash commands are unavailable in this runtime, execute the conduct skill with argument "$engine" instead. Every task in this session is then dispatched to detached worker lanes; the parent session only briefs, routes, and reports.
The user can leave the mode with \`/conduct off\`. Disable the default with \`HQ_AUTO_CONDUCT=0\`, \`HQ_DISABLED_HOOKS=auto-conduct\`, or \`conduct.default_enabled: false\` in personal/settings/orchestrator.yaml.
</auto-conduct>
EOT
