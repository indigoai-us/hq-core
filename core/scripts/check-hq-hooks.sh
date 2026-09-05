#!/usr/bin/env bash
# check-hq-hooks.sh — verify that the project hook configuration can load.
#
# This is deliberately a plain shell command, not a Claude hook: it remains
# available precisely when a Desktop or SDK runtime failed to load every hook.
#
# US-012: this script is now a thin wrapper over `hq doctor`. When a new-enough
# `hq` CLI is on PATH it maps `hq doctor --json` (scoped to the exact checks this
# script has always made — settings load and the policy-trigger ledger) back onto
# this command's PASS/FAIL header, its `HQ runtime enforcement:` line, and its 0/2
# exit codes, so existing callers and the personal-context.md app/SDK instruction
# keep working unchanged. It DEGRADES GRACEFULLY: when `hq` is absent or too old
# to have `hq doctor`, it falls back to the inline implementation below rather
# than failing — this checker has to stay useful precisely when the toolchain is
# suspect.
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

When a new-enough `hq` CLI is installed this delegates to `hq doctor`; otherwise
it runs an equivalent inline check.
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

# --- Runtime-aware recovery guidance ----------------------------------------
#
# The ledger ASSERTION itself is runtime-independent and stays byte-identical
# everywhere below: a present policy-trigger ledger => OBSERVED (exit 0), a
# missing one => NOT OBSERVED (exit 2). Only the *recovery guidance* differs by
# runtime.
#
# An agents-v2 (hermes) fleet box writes this SAME ledger through the SAME
# .claude hooks — dispatched by the on-box hq-agents-v2-hook-adapter.sh — but
# only during a live hermes turn (pre_llm_call, or a Bash pre_tool_call). So on
# such a box a freshly-provisioned tree legitimately has no ledger until the
# agent takes its first turn, and the Claude Desktop/SDK repair steps ("open the
# HQ root as the project", "settingSources: [project]") are wrong: they send the
# operator in a circle. Detect the box and print v2-appropriate steps instead.
#
# Detection (either signal): the runtime marker at
# ${HQ_RUNTIME_MARKER_FILE:-/var/lib/hq-agent/runtime.json} reads
# runtimeMode=="agents-v2" (written by activate-agents-v2.sh), OR the adapter is
# installed under the tree at .agents-v2-hooks/hq-agents-v2-hook-adapter.sh.
hq_runtime_mode() {
  local marker="${HQ_RUNTIME_MARKER_FILE:-/var/lib/hq-agent/runtime.json}"
  if [ -f "$marker" ] && command -v jq >/dev/null 2>&1 \
     && [ "$(jq -r '.runtimeMode // empty' "$marker" 2>/dev/null)" = "agents-v2" ]; then
    printf 'agents-v2'; return 0
  fi
  if [ -f "$HQ_ROOT/.agents-v2-hooks/hq-agents-v2-hook-adapter.sh" ]; then
    printf 'agents-v2'; return 0
  fi
  printf 'claude'
}

# The two-line explanation printed under "HQ runtime enforcement: NOT OBSERVED".
emit_runtime_off_explanation() {
  if [ "$(hq_runtime_mode)" = "agents-v2" ]; then
    echo "  The policy-trigger hook has not written a ledger yet this session. On an" >&2
    echo "  agents-v2 (hermes) box the on-box adapter writes this SAME ledger via the" >&2
    echo "  SAME .claude hooks, but only during a live turn — so a box with no live" >&2
    echo "  turn yet is expected to read NOT OBSERVED until the agent takes one." >&2
  else
    echo "  The policy-trigger hook did not run in this session. In the affected" >&2
    echo "  Claude Code app/SDK runtime, command hooks are not dispatched." >&2
  fi
}

# The trailing repair block printed on any FAIL.
emit_repair_guidance() {
  if [ "$(hq_runtime_mode)" = "agents-v2" ]; then
    cat >&2 <<'EOF'

This is an agents-v2 (hermes) fleet box. Hook enforcement runs through the
on-box adapter (.agents-v2-hooks/hq-agents-v2-hook-adapter.sh), which writes the
policy-trigger ledger through the same .claude hooks Claude Code uses — but only
on a live hermes turn (pre_llm_call, or a Bash pre_tool_call). To evidence the
ledger, drive one live turn and re-run this check right after it:

  1. Send the agent a live turn — a Slack @mention / DM, or `hq dm <agent>`.
  2. Re-run immediately afterward:
       bash core/scripts/check-hq-hooks.sh --root "$PWD" --require-ledger

If the ledger is still missing after a live turn, confirm the runtime is active
(runtimeMode=agents-v2 in /var/lib/hq-agent/runtime.json, the v2 unit up) and
that .agents-v2-hooks/hq-agents-v2-hook-adapter.sh is installed and executable.

If a SETTINGS issue is listed above (not the ledger), repair the shipped config:
  hq rescue -y --paths .claude

See core/docs/hq/HOOKS-NOT-FIRING.md for the complete recovery procedure.
EOF
  else
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
  fi
}

# --- Modern path: delegate to `hq doctor` -----------------------------------
#
# The doctor is a strict superset of this checker (Codex/Grok parity, exec bits,
# three-profile membership, fixture coverage) and reports the tree's known Codex
# drift as FAIL on an otherwise-healthy tree. Adopting its whole verdict would
# break every existing caller, so the wrapper maps only the SCOPED slice that
# corresponds to this checker's original checks: settings load (present, valid
# JSON, no word-splitting $CLAUDE_PROJECT_DIR, referenced scripts exist) and,
# under --require-ledger, the policy-trigger ledger. This mapping is the shell
# twin of deriveCheckHqHooksVerdict() in hq-cli's src/lib/doctor/compat.ts; the
# agreement test there pins the two together.

# The `hq doctor --json` check ids that make up this checker's settings scope.
DOCTOR_SETTINGS_SCOPE='["hooks.settings-present","hooks.settings-valid-json","hooks.claude.settings-local-valid-json","hooks.claude.unquoted-project-dir","hooks.claude.script-missing"]'
DOCTOR_RUNTIME_CHECK_ID="hooks.runtime.enforcement"

# Render this checker's contract from a validated `hq doctor --json` document,
# scoped to the settings-load + ledger concerns, then exit. Mirrors
# deriveCheckHqHooksVerdict() in compat.ts.
render_from_doctor() {
  local json="$1"
  local settings_issues runtime_status runtime_message
  local -a issues=()

  settings_issues="$(printf '%s' "$json" | jq -r --argjson scope "$DOCTOR_SETTINGS_SCOPE" '
    .results[]
    | select((.checkId as $c | $scope | index($c)) and (.status == "FAIL" or .status == "UNKNOWN"))
    | .message
  ')"
  runtime_status="$(printf '%s' "$json" | jq -r --arg id "$DOCTOR_RUNTIME_CHECK_ID" '
    first(.results[] | select(.checkId == $id) | .status) // empty
  ')"
  runtime_message="$(printf '%s' "$json" | jq -r --arg id "$DOCTOR_RUNTIME_CHECK_ID" '
    first(.results[] | select(.checkId == $id) | .message) // empty
  ')"

  if [ -n "$settings_issues" ]; then
    while IFS= read -r line; do
      [ -n "$line" ] && issues+=("$line")
    done <<EOF
$settings_issues
EOF
  fi

  local runtime_obs="NOT CHECKED"
  if [ "$REQUIRE_LEDGER" -eq 1 ]; then
    if [ "$runtime_status" = "PASS" ]; then
      runtime_obs="OBSERVED"
    else
      runtime_obs="NOT OBSERVED"
      if [ -n "$runtime_message" ]; then
        issues+=("$runtime_message")
      elif [ -n "$SESSION_ID" ]; then
        issues+=("policy-trigger ledger was not found for session $SESSION_ID under workspace/orchestrator/policy-trigger-state")
      else
        issues+=("policy-trigger ledger was not found under workspace/orchestrator/policy-trigger-state")
      fi
    fi
  fi

  if [ "${#issues[@]}" -gt 0 ]; then
    echo "HQ hook health: FAIL" >&2
    if [ "$REQUIRE_LEDGER" -eq 1 ] && [ "$runtime_obs" = "NOT OBSERVED" ]; then
      echo "HQ runtime enforcement: NOT OBSERVED" >&2
      emit_runtime_off_explanation
    fi
    printf '  - %s\n' "${issues[@]}" >&2
    emit_repair_guidance
    exit 2
  fi

  echo "HQ hook health: PASS"
  echo "  root: $HQ_ROOT"
  echo "  checked via: hq doctor (scoped to hook load + policy-trigger ledger)"
  if [ "$REQUIRE_LEDGER" -eq 1 ]; then
    echo "  ledger: present"
    if [ -n "$SESSION_ID" ]; then
      echo "  session: $SESSION_ID"
    fi
    echo "HQ runtime enforcement: OBSERVED (policy-trigger ledger present)"
  else
    echo "  ledger: not checked (run with --require-ledger after a real Desktop/SDK session)"
  fi
  exit 0
}

# Try the modern path. Returns non-zero (without exiting) to request the inline
# fallback: `hq` missing, `jq` missing, `hq doctor` absent/too old, or its JSON
# not the versioned document this wrapper understands.
try_doctor() {
  command -v hq >/dev/null 2>&1 || return 1
  command -v jq >/dev/null 2>&1 || return 1

  local -a doctor_args=(doctor --json)
  if [ -n "$SESSION_ID" ]; then
    doctor_args+=(--session-id "$SESSION_ID")
  fi

  # `hq doctor` resolves the tree by walking up from the working directory, so
  # run it with the working directory set to the requested root. A non-zero exit
  # (e.g. an old CLI's "unknown command", or "not inside an HQ tree") must not
  # abort this script under `set -e`, so swallow it and validate the output.
  local json=""
  json="$( cd "$HQ_ROOT" && hq "${doctor_args[@]}" 2>/dev/null )" || true
  printf '%s' "$json" | jq -e '.schemaVersion and (.results | type == "array")' >/dev/null 2>&1 || return 1

  render_from_doctor "$json"
}

# --- Inline fallback: the original, self-contained implementation -----------
#
# Kept verbatim so this checker still works when `hq` is unavailable — the whole
# reason it exists as a plain shell command. Also the implementation the hq-core
# regression suite (core/scripts/tests/hook-health-check.test.sh) exercises.

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

run_inline() {
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
      emit_runtime_off_explanation
    fi
    printf '  - %s\n' "${ISSUES[@]}" >&2
    emit_repair_guidance
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
  exit 0
}

# Prefer `hq doctor`; fall back to the inline checker when it is unavailable.
try_doctor || run_inline
