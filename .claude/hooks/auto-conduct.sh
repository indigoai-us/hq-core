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
#   core/settings/orchestrator.yaml       # shipped default (on since v16)
#
#   conduct:
#     default_enabled: true
#
# Per-session override:
#   HQ_AUTO_CONDUCT=1            force on (also the only way an unattended
#                                session gets conduct mode; its brief then
#                                names the engine with `/conduct <engine>`)
#   HQ_AUTO_CONDUCT=0            force off
#   HQ_DISABLED_HOOKS=auto-conduct
#
# Unattended sessions: a local bot (`hq bot run` launches `claude -p` /
# `grok -p` with the HQ root as cwd), a fleet box turn (pty claude, codex
# exec, grok -p under hq-agent-session), an Outpost job, a scheduled task, or
# any `claude -p` marked headless. These fire SessionStart with source=startup
# like a person's terminal does, but there is nobody to answer the engine
# question and nothing should spawn lanes from a bot turn. The hook no-ops
# when it sees one of the markers below unless HQ_AUTO_CONDUCT=1 is set.

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

# Unattended detection. Explicit flags first, then the markers each runtime
# already exports on a bot or box turn:
#   HQ_UNATTENDED / HQ_SESSION_UNATTENDED  HQ-wide unattended flags
#   CLAUDE_HEADLESS=1                       detached `claude -p` launchers
#   HQ_BOT_AGENT_UID                        local personal bot turn (hq bot run)
#   HQ_MACHINE_CREDS_FILE                   local company bot / machine identity
#   HQ_AGENT_CLAUDE_TASKFILE                fleet box claude dispatch
#   HQ_AGENT_COMPANY_DIR, HQ_AGENT_STATUS_FILE  fleet box session runner
#                                           (inherited by codex exec / grok -p)
is_unattended() {
  case "${HQ_UNATTENDED:-}${HQ_SESSION_UNATTENDED:-}${CLAUDE_HEADLESS:-}" in
    *1*|*true*|*TRUE*|*yes*|*YES*|*on*|*ON*) return 0 ;;
  esac
  [ -n "${HQ_BOT_AGENT_UID:-}" ] && return 0
  [ -n "${HQ_MACHINE_CREDS_FILE:-}" ] && return 0
  [ -n "${HQ_AGENT_CLAUDE_TASKFILE:-}" ] && return 0
  [ -n "${HQ_AGENT_COMPANY_DIR:-}" ] && return 0
  [ -n "${HQ_AGENT_STATUS_FILE:-}" ] && return 0
  return 1
}

case "${HQ_AUTO_CONDUCT:-}" in
  1|true|TRUE|on|ON|yes|YES) enabled="true" ;;
  0|false|FALSE|off|OFF|no|NO) exit 0 ;;
  *) if is_unattended; then exit 0; fi ;;
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
