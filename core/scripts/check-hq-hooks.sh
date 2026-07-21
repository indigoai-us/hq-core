#!/usr/bin/env bash
# check-hq-hooks.sh — verify that the project hook configuration can load.
#
# This is deliberately a plain shell command, not a Claude hook: it remains
# available precisely when a Desktop or SDK runtime failed to load every hook.
#
# Usage:
#   bash core/scripts/check-hq-hooks.sh [--root <hq-root>] [--require-ledger]

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: check-hq-hooks.sh [--root <hq-root>] [--require-ledger]

Checks the tracked project settings required for HQ hooks. --require-ledger
also verifies that a policy-trigger ledger exists after a real session.
EOF
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
HQ_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd -P)"
REQUIRE_LEDGER=0

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
  if find "$LEDGER_DIR" -type f -name '*.txt' -print -quit 2>/dev/null | grep -q .; then
    LEDGER_STATE="present"
  else
    LEDGER_STATE="missing"
    ISSUES+=("policy-trigger ledger was not found under workspace/orchestrator/policy-trigger-state")
  fi
fi

if [ "${#ISSUES[@]}" -gt 0 ]; then
  echo "HQ hook health: FAIL" >&2
  printf '  - %s\n' "${ISSUES[@]}" >&2
  cat >&2 <<'EOF'

Repair the shipped project configuration:
  hq rescue -y --paths .claude

For Claude Desktop, open the HQ root itself as the project (not a parent or a
child folder), then start a new session.

For an SDK launch, set both project root and settings source:
  const hqRoot = "/absolute/path/to/HQ";
  query({ prompt: "...", options: { cwd: hqRoot, settingSources: ["project"] } });

After a real Desktop/SDK session, verify that the policy-trigger hook ran:
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
else
  echo "  ledger: not checked (run with --require-ledger after a real Desktop/SDK session)"
fi
