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
# shellcheck source=core/scripts/lib/hook-command-scan.sh
. "$SCRIPT_DIR/lib/hook-command-scan.sh"
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
LOCAL_SETTINGS="$HQ_ROOT/.claude/settings.local.json"
LEDGER_DIR="$HQ_ROOT/workspace/orchestrator/policy-trigger-state"
ISSUES=()
SCANNED=()
ROOT_HAS_SPACE=0
case "$HQ_ROOT" in
  *[[:space:]]*) ROOT_HAS_SPACE=1 ;;
esac

# Every hook command is executed by /bin/sh, so an unquoted $CLAUDE_PROJECT_DIR
# is word-split. On a root whose path contains a space that truncates the
# script path and every hook dies as a non-blocking error nobody sees.
#
# The scan is quote-aware (core/scripts/lib/hook-command-scan.sh): it splits a
# command the way the shell would and flags only an expansion that really sits
# outside quotes. "$CLAUDE_PROJECT_DIR/..." and "${CLAUDE_PROJECT_DIR}/..." are
# split-safe, and so is a quoted token that merely contains the variable such as
# "--root=$CLAUDE_PROJECT_DIR". This checker diagnoses arbitrary field settings
# that may have drifted by hand or by merge, and calling a safe form broken
# would be exactly the confident misdiagnosis it exists to end. The shipped file
# is separately held to one canonical shape by hook-path-resolution.test.sh.

# Scan every command hook in one settings file. Claude Code merges
# .claude/settings.local.json over .claude/settings.json, so a hook command that
# lives only in the local overlay fails on a spaced root exactly like a shipped
# one. Appends to ISSUES; takes the file path and the label used in messages.
scan_hook_commands() {
  local file="$1" label="$2" commands unquoted relpath

  # One JSON-encoded command per line: a hook command may contain a newline, so
  # counting raw lines would report one broken command as several.
  commands="$(hook_scan_commands_json "$file")"

  unquoted="$(printf '%s\n' "$commands" | hook_scan_unquoted_commands | grep -c . || true)"
  if [ "$unquoted" -gt 0 ]; then
    if [ "$ROOT_HAS_SPACE" -eq 1 ]; then
      ISSUES+=("${unquoted} hook command(s) in ${label} reference \$CLAUDE_PROJECT_DIR without quotes and this HQ root contains a space, so /bin/sh splits the path and every one of those hooks is failing right now: $HQ_ROOT")
    else
      ISSUES+=("${unquoted} hook command(s) in ${label} reference \$CLAUDE_PROJECT_DIR without quotes; they break on any install path containing a space")
    fi
  fi

  # Only the scripts a command actually runs are required to exist. A guarded
  # optional path (`[ -f "$CLAUDE_PROJECT_DIR/personal/x.sh" ] && …`), a data
  # argument, or a file the hook creates at runtime is absent on a perfectly
  # healthy install, and failing those would make this checker cry wolf.
  while IFS= read -r relpath; do
    [ -n "$relpath" ] || continue
    if [ ! -e "$HQ_ROOT/$relpath" ]; then
      ISSUES+=("a hook command in ${label} runs a script that does not exist: $relpath")
    fi
  done <<EOF
$(printf '%s\n' "$commands" | hook_scan_required_relpaths | sort -u)
EOF
}

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

  scan_hook_commands "$SETTINGS" ".claude/settings.json"
  SCANNED+=(".claude/settings.json")
fi

# The local overlay is optional, so its absence is never an issue — but when it
# is present Claude Code loads its hooks too, and an unquoted command hiding
# there produces the same silent failure as one in the shipped file.
if [ -f "$LOCAL_SETTINGS" ]; then
  if ! command -v jq >/dev/null 2>&1; then
    ISSUES+=("jq is required to inspect .claude/settings.local.json")
  elif ! jq empty "$LOCAL_SETTINGS" >/dev/null 2>&1; then
    ISSUES+=(".claude/settings.local.json is not valid JSON")
  else
    scan_hook_commands "$LOCAL_SETTINGS" ".claude/settings.local.json"
    SCANNED+=(".claude/settings.local.json")
  fi
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
echo "  scanned: $(printf '%s, ' "${SCANNED[@]-none}" | sed 's/, $//')"
echo "  paths: every \$CLAUDE_PROJECT_DIR expansion is quoted, and every hook script it runs exists"
if [ "$REQUIRE_LEDGER" -eq 1 ]; then
  echo "  ledger: $LEDGER_STATE"
  if [ -n "$SESSION_ID" ]; then
    echo "  session: $SESSION_ID"
  fi
  echo "HQ runtime enforcement: OBSERVED (policy-trigger ledger present)"
else
  echo "  ledger: not checked (run with --require-ledger after a real Desktop/SDK session)"
fi
