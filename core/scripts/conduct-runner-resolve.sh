#!/bin/sh
# hq-core: public
# conduct-runner-resolve.sh — print which runner a /conduct session uses.
#
# Usage:
#   sh core/scripts/conduct-runner-resolve.sh [--runner <value>] [--session-id <id>] [--root <dir>]
#
# Prints one word on stdout: `subagent` or `runner`.
#   subagent  default. Lanes are standing role workers on resumable Agent
#             subagents or conduct child sessions; no runner record is written.
#   runner    advanced. Lanes run as detached runners through /conduct-runners.
#
# Resolution order, first value found wins:
#   1. --runner <value>
#   2. the session pin conduct_runner (core/scripts/hq-session.sh get conduct_runner)
#   3. conduct.runner in personal/settings/orchestrator.yaml
#   4. conduct.runner in core/settings/orchestrator.yaml
#   5. subagent
#
# The legacy values `mixed` and `lane` are read as `runner` for one release,
# with one warning line on stderr. Any other value exits 2.
#
# The HQ root comes from --root, then HQ_ROOT, then CLAUDE_PROJECT_DIR, then
# the directory two levels above this script.

set -eu

die() { printf 'conduct-runner-resolve: %s\n' "$*" >&2; exit 2; }

flag="" sid="" root=""
while [ $# -gt 0 ]; do
  case "$1" in
    --runner) [ $# -ge 2 ] || die "--runner needs a value"; flag="$2"; shift 2 ;;
    --session-id) [ $# -ge 2 ] || die "--session-id needs a value"; sid="$2"; shift 2 ;;
    --root) [ $# -ge 2 ] || die "--root needs a value"; root="$2"; shift 2 ;;
    -h|--help) sed -n '3,24p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

if [ -z "$root" ]; then
  root="${HQ_ROOT:-${CLAUDE_PROJECT_DIR:-}}"
  [ -n "$root" ] || root="$(cd "$(dirname "$0")/../.." && pwd)"
fi

# conduct.runner from one orchestrator.yaml: the first `  runner:` line inside
# the top-level `conduct:` block, quotes and trailing comments removed.
yaml_runner() {
  [ -f "$1" ] || return 0
  awk '/^conduct:/ {on=1; next}
       on && /^[^ #]/ {on=0}
       on && /^  runner:/ {v=$2; gsub(/["'\'']/, "", v); print v; exit}' "$1"
}

session_pin() {
  helper="$root/core/scripts/hq-session.sh"
  [ -f "$helper" ] || return 0
  if [ -n "$sid" ]; then
    bash "$helper" --session-id "$sid" get conduct_runner 2>/dev/null || true
  else
    bash "$helper" get conduct_runner 2>/dev/null || true
  fi
}

value="$flag" source="--runner"
if [ -z "$value" ]; then value="$(session_pin)"; source="session pin conduct_runner"; fi
if [ -z "$value" ]; then value="$(yaml_runner "$root/personal/settings/orchestrator.yaml")"; source="personal/settings/orchestrator.yaml"; fi
if [ -z "$value" ]; then value="$(yaml_runner "$root/core/settings/orchestrator.yaml")"; source="core/settings/orchestrator.yaml"; fi
if [ -z "$value" ]; then value="subagent"; source="built-in default"; fi

case "$value" in
  subagent|runner) printf '%s\n' "$value" ;;
  mixed|lane)
    printf 'conduct-runner-resolve: conduct runner "%s" from %s is a legacy value, read as "runner"; set subagent or runner\n' "$value" "$source" >&2
    printf 'runner\n' ;;
  *) die "unknown conduct runner \"$value\" from $source (use subagent or runner)" ;;
esac
