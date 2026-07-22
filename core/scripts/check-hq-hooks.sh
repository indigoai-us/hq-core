#!/usr/bin/env bash
# check-hq-hooks.sh — verify that the project hook configuration can load.
#
# This is deliberately a plain shell command, not a Claude hook: it remains
# available precisely when a Desktop or SDK runtime failed to load every hook.
#
# Usage:
#   bash core/scripts/check-hq-hooks.sh [--root <hq-root>] [--require-ledger] [--session-id <id>]

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: check-hq-hooks.sh [--root <hq-root>] [--require-ledger] [--session-id <id>]

Checks the tracked project settings required for HQ hooks. --require-ledger
also verifies that a policy-trigger ledger exists after a real session. This
command is deliberately hook-independent: use it to make a non-dispatching
Claude Code app/SDK runtime visible instead of silently assuming enforcement.
With --session-id, checks that exact session's ledger rather than any earlier
session's ledger. --session-id implies --require-ledger.
EOF
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
HQ_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd -P)"
REQUIRE_LEDGER=0
SESSION_ID=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --root)
      [ "$#" -ge 2 ] || { echo "--root requires a path" >&2; usage >&2; exit 64; }
      HQ_ROOT="$2"
      shift 2
      ;;
    --require-ledger)
      REQUIRE_LEDGER=1
      shift
      ;;
    --session-id)
      [ "$#" -ge 2 ] || { echo "--session-id requires an id" >&2; usage >&2; exit 64; }
      SESSION_ID="$2"
      REQUIRE_LEDGER=1
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "unknown argument: $1" >&2
      usage >&2
      exit 64
      ;;
  esac
done

if [ ! -d "$HQ_ROOT" ]; then
  echo "HQ hook health: FAIL" >&2
  echo "  - HQ root does not exist: $HQ_ROOT" >&2
  exit 2
fi
HQ_ROOT="$(cd "$HQ_ROOT" && pwd -P)"

SETTINGS="$HQ_ROOT/.claude/settings.json"
LEDGER_DIR="$HQ_ROOT/workspace/orchestrator/policy-trigger-state"
ISSUES=()

if [ ! -f "$SETTINGS" ]; then
  ISSUES+=(".claude/settings.json is missing")
elif ! command -v jq >/dev/null 2>&1; then
  ISSUES+=("jq is required to inspect .claude/settings.json")
elif ! jq empty "$SETTINGS" >/dev/null 2>&1; then
  ISSUES+=(".claude/settings.json is not valid JSON")
else
  for event in SessionStart PreToolUse; do
    if ! jq -e --arg event "$event" '
      [
        .hooks[$event][]?.hooks[]?
        | select(.type == "command" and (.command | type == "string") and (.command | length > 0))
      ] | length > 0
    ' "$SETTINGS" >/dev/null 2>&1; then
      ISSUES+=("${event} has no command hook in .claude/settings.json")
    fi
  done
fi

LEDGER_STATE="not checked"
if [ "$REQUIRE_LEDGER" -eq 1 ]; then
  if [ -n "$SESSION_ID" ]; then
    LEDGER_CANDIDATE="$LEDGER_DIR/$SESSION_ID.txt"
  else
    LEDGER_CANDIDATE=""
  fi
  if { [ -n "$LEDGER_CANDIDATE" ] && [ -f "$LEDGER_CANDIDATE" ]; } || \
     { [ -z "$LEDGER_CANDIDATE" ] && find "$LEDGER_DIR" -type f -name '*.txt' -print -quit 2>/dev/null | grep -q .; }; then
    LEDGER_STATE="present"
  else
    LEDGER_STATE="missing"
    if [ -n "$SESSION_ID" ]; then
      ISSUES+=("policy-trigger ledger was not found for session $SESSION_ID under workspace/orchestrator/policy-trigger-state")
    else
      ISSUES+=("policy-trigger ledger was not found under workspace/orchestrator/policy-trigger-state")
    fi
  fi
fi

if [ "${#ISSUES[@]}" -gt 0 ]; then
  echo "HQ hook health: FAIL" >&2
  if [ "$REQUIRE_LEDGER" -eq 1 ] && [ "$LEDGER_STATE" = "missing" ]; then
    echo "HQ runtime enforcement: NOT OBSERVED" >&2
    echo "  The policy-trigger hook did not run in this session. In the affected" >&2
    echo "  Claude Code app/SDK runtime, command hooks are not dispatched." >&2
  fi
  printf '  - %s\n' "${ISSUES[@]}" >&2
  cat >&2 <<'EOF'

Repair the shipped project configuration:
  hq rescue -y --paths .claude

For Claude Desktop, open the HQ root itself as the project (not a parent or a
child folder), then start a new session.

For an SDK launch, set both project root and settings source:
  const hqRoot = "/absolute/path/to/HQ";
  query({ prompt: "...", options: { cwd: hqRoot, settingSources: ["project"] } });

After a real terminal CLI session, verify that the policy-trigger hook ran:
  bash core/scripts/check-hq-hooks.sh --root "$PWD" --require-ledger

See core/docs/hq/HOOKS-NOT-FIRING.md for the complete recovery procedure.
EOF
  exit 2
fi

echo "HQ hook health: PASS"
echo "  root: $HQ_ROOT"
echo "  settings: SessionStart and PreToolUse command hooks present"
if [ "$REQUIRE_LEDGER" -eq 1 ]; then
  echo "  ledger: $LEDGER_STATE"
  if [ -n "$SESSION_ID" ]; then
    echo "  session: $SESSION_ID"
  fi
  echo "HQ runtime enforcement: OBSERVED (policy-trigger ledger present)"
else
  echo "  ledger: not checked (run with --require-ledger after a real Desktop/SDK session)"
fi
