#!/usr/bin/env bash
# hq-heal.sh — Spawn a fresh Claude Code session with the /hq-heal skill loaded.
#
# Use this when the current Claude session is wedged (autocompact thrashing,
# hook storm, MCP crash) and cannot itself invoke /hq-heal. Run from a new
# terminal in the HQ root.
#
# Usage:
#   bash .claude/skills/hq-heal/hq-heal.sh "<error text>"             # interactive heal
#   bash .claude/skills/hq-heal/hq-heal.sh --last-session             # heal from most recent dead JSONL
#   bash .claude/skills/hq-heal/hq-heal.sh --class autocompact "..."  # force classifier
#   bash .claude/skills/hq-heal/hq-heal.sh --bare "<error text>"      # spawn with --bare (no hooks/MCPs)
#   bash .claude/skills/hq-heal/hq-heal.sh --resume                   # continue last heal session
#   bash .claude/skills/hq-heal/hq-heal.sh --dry-run "<error text>"   # diagnose only, no fix
#   bash .claude/skills/hq-heal/hq-heal.sh --no-bug "<error text>"    # skip the /hq-bug filing
#   bash .claude/skills/hq-heal/hq-heal.sh --allow-core "<err>"       # permit core/ edits when fix requires it
#
# Companion to .claude/skills/hq-heal/SKILL.md.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Script lives at .claude/skills/hq-heal/ — HQ root is three levels up.
HQ_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"

usage() {
  sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

# --- Parse flags -------------------------------------------------------------

BARE=0
RESUME=0
DRY_RUN=0
CLASS=""
LAST_SESSION=0
NO_BUG=0
ALLOW_CORE=0
ERR_TEXT=""

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help)         usage 0 ;;
    --bare)            BARE=1; shift ;;
    --resume|-c)       RESUME=1; shift ;;
    --dry-run)         DRY_RUN=1; shift ;;
    --last-session)    LAST_SESSION=1; shift ;;
    --class)           CLASS="${2:-}"; shift 2 ;;
    --no-bug)          NO_BUG=1; shift ;;
    --allow-core)      ALLOW_CORE=1; shift ;;
    --)                shift; ERR_TEXT="$*"; break ;;
    -*)                echo "unknown flag: $1" >&2; usage 2 ;;
    *)                 ERR_TEXT="$*"; break ;;
  esac
done

# --- Sanity checks -----------------------------------------------------------

if ! command -v claude >/dev/null 2>&1; then
  echo "hq-heal: 'claude' CLI not found on PATH" >&2
  echo "Install Claude Code first (https://claude.com/claude-code), then retry." >&2
  exit 127
fi

if [ ! -f "${HQ_ROOT}/.claude/skills/hq-heal/SKILL.md" ]; then
  echo "hq-heal: SKILL.md missing at .claude/skills/hq-heal/SKILL.md" >&2
  echo "Expected HQ_ROOT: ${HQ_ROOT}" >&2
  exit 1
fi

# Resume mode: re-attach to the most recent claude conversation in this dir.
if [ "$RESUME" -eq 1 ]; then
  cd "$HQ_ROOT"
  exec claude --continue
fi

# --- Compose the slash-command invocation -----------------------------------

# Build /hq-heal arg string. Order: --class, --dry-run, --last-session, --no-bug, --allow-core, then free text.
HEAL_ARGS=""
[ -n "$CLASS" ]            && HEAL_ARGS+=" --class ${CLASS}"
[ "$DRY_RUN" -eq 1 ]       && HEAL_ARGS+=" --dry-run"
[ "$LAST_SESSION" -eq 1 ]  && HEAL_ARGS+=" --last-session"
[ "$NO_BUG" -eq 1 ]        && HEAL_ARGS+=" --no-bug"
[ "$ALLOW_CORE" -eq 1 ]    && HEAL_ARGS+=" --allow-core"
[ -n "$ERR_TEXT" ]         && HEAL_ARGS+=" ${ERR_TEXT}"

# Trim leading space.
HEAL_ARGS="${HEAL_ARGS# }"

# The first user message tells Claude to invoke the skill.
PROMPT="/hq-heal ${HEAL_ARGS}"

# --- Build the claude command ------------------------------------------------

CLAUDE_ARGS=()
if [ "$BARE" -eq 1 ]; then
  # --bare skips hooks, MCPs, auto-memory, plugin sync, CLAUDE.md auto-discovery.
  # Useful when hooks or MCPs themselves are the failure mode. We still need
  # CLAUDE.md context for the heal skill to know about HQ structure, so
  # explicitly --add-dir the HQ root.
  CLAUDE_ARGS+=(--bare --add-dir "$HQ_ROOT")
fi

# Always run from HQ root so .claude/skills/hq-heal/ resolves.
cd "$HQ_ROOT"

# Print what we're about to do (full prose — this is a launcher, not chat).
cat <<EOF
hq-heal launcher
================
HQ root:    $HQ_ROOT
Mode:       $([ "$BARE" -eq 1 ] && echo "bare (hooks + MCPs disabled)" || echo "normal")
Dry-run:    $([ "$DRY_RUN" -eq 1 ] && echo "yes" || echo "no")
Allow-core: $([ "$ALLOW_CORE" -eq 1 ] && echo "yes (core/ edits permitted via HQ_BYPASS_CORE_PROTECT=1)" || echo "no")
File bug:   $([ "$NO_BUG" -eq 1 ] && echo "no (--no-bug)" || echo "yes (auto-files via /hq-bug)")
Class:      ${CLASS:-auto}
Source:     $([ "$LAST_SESSION" -eq 1 ] && echo "--last-session (scan most recent JSONL)" || echo "free-text argument")
Prompt:     ${PROMPT:0:120}$([ ${#PROMPT} -gt 120 ] && echo " …")

Spawning fresh Claude session now. The session will:
  1. Classify the error
  2. Run a targeted diagnostics recipe
  3. Propose a numbered fix (you confirm before anything destructive)
  4. Write a heal report under workspace/reports/hq-heal/
  5. File an HQ bug via /hq-bug (unless --no-bug or --dry-run)

If you want to abort, Ctrl-C this terminal; the report writes only on completion.

EOF

# --- Spawn -------------------------------------------------------------------

exec claude "${CLAUDE_ARGS[@]}" "$PROMPT"
