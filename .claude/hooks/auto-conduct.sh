#!/bin/bash
# auto-conduct.sh — SessionStart hook that opens fresh sessions in /conduct mode.
#
# Reads the `conduct:` block of the orchestrator settings. When
# `default_enabled: true`, the session gets the conductor core: the triage
# rule (inline for answers, lookups, reads, short skills; a lane for real work)
# and the pointer to the intent index. No engine is chosen here; /conduct
# resolves it at first dispatch.
#
# Settings file (first one that exists wins):
#   personal/settings/orchestrator.yaml   # per-machine override
#   core/settings/orchestrator.yaml       # shipped default (off)
#
#   conduct:
#     default_enabled: false
#
# Per-session override:
#   HQ_AUTO_CONDUCT=1            force on
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

case "${HQ_AUTO_CONDUCT:-}" in
  1|true|TRUE|on|ON|yes|YES) enabled="true" ;;
  0|false|FALSE|off|OFF|no|NO) exit 0 ;;
esac

case "$enabled" in
  true|TRUE|yes|YES|on|ON|1) ;;
  *) exit 0 ;;
esac

CORE="$HQ_ROOT/.claude/skills/conduct/conductor-core.md"
if [ -f "$CORE" ]; then
  # The always-on block lives in the conductor core doc between the inject
  # markers (one source of truth; the rest of the doc is for the skill).
  awk '/<!-- inject:start -->/ { on = 1; next } /<!-- inject:end -->/ { on = 0 } on' "$CORE"
else
  cat <<'EOT'
<auto-conduct>
Conduct mode is on (conduct.default_enabled). Triage each message: inline for answers, lookups, reads, status and one short skill; `/conduct <task>` for multi-file edits, builds, long-running or multi-repo work. The engine is chosen at first dispatch. Route by the intent index at core/settings/intent-index.yaml. Leave with `/conduct off`.
</auto-conduct>
EOT
fi
