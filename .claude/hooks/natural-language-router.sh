#!/bin/bash
# natural-language-router.sh — UserPromptSubmit hook (wired in .claude/settings.json).
#
# Natural Language Mode, first-touch nudge. On the FIRST user prompt of a
# session, if the user did NOT open with an explicit slash command (startwork,
# goals, idea, brainstorm, prd, run-project, or any other /command), inject a
# routing reminder so the assistant infers intent and routes to the right HQ
# skill instead of waiting to be told which command to run.
#
# Design (per owner spec):
#   - Fires only on the FIRST prompt of a session (idempotent via marker file).
#   - Skips if the prompt opens with an explicit slash command — the user has
#     already declared their path; explicit commands are honored literally.
#   - Mid-session is intentionally NOT this hook's job. Durable memory mid-flight
#     (journaling, work-session/project folders, decision/knowledge logs that
#     survive compaction) is governed by the natural-language-mode policy plus
#     the journal / auto-session-project / auto-checkpoint hooks.
#
# Disable with:
#   HQ_NL_ROUTER=0
#   HQ_DISABLED_HOOKS=natural-language-router
#
# Trigger: UserPromptSubmit
# Exit: 0 always (additive context only).

set -uo pipefail

case "${HQ_NL_ROUTER:-1}" in
  0|false|FALSE|off|OFF|no|NO) exit 0 ;;
esac

disabled=",${HQ_DISABLED_HOOKS:-},"
disabled="$(printf '%s' "$disabled" | tr -d '[:space:]')"
case "$disabled" in
  *,natural-language-router,*) exit 0 ;;
esac

STDIN_JSON="$(cat 2>/dev/null || echo '{}')"

extract() {
  printf '%s' "$STDIN_JSON" | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
    sys.stdout.write(str(d.get(sys.argv[1], "")))
except Exception:
    pass
' "$1" 2>/dev/null || echo ""
}

PROMPT="$(extract prompt)"
SESSION_ID="$(extract session_id)"

HQ_ROOT="${HQ_ROOT:-${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}}"
STATE_DIR="$HQ_ROOT/workspace/orchestrator/policy-trigger-state"
mkdir -p "$STATE_DIR" 2>/dev/null || true
MARKER="$STATE_DIR/${SESSION_ID:-default}.nl-router-fired"

# Only the first prompt of the session. Marker present → already past first
# touch; do nothing.
[ -e "$MARKER" ] && exit 0

# Consume the first-touch slot now, unconditionally, so we never re-fire later
# in the session (even if we skip injection below).
printf '%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$MARKER" 2>/dev/null || true

# Trim leading whitespace for the slash-command test.
TRIMMED="$(printf '%s' "$PROMPT" | sed -E 's/^[[:space:]]+//')"

# Explicit slash command at the very start → user declared their path. Skip.
# Matches `/word` (startwork, goals, idea, brainstorm, prd, run-project, hqwork,
# any namespaced co:skill, etc.).
if printf '%s' "$TRIMMED" | grep -Eq '^/[a-zA-Z][a-zA-Z0-9:_-]*'; then
  exit 0
fi

# Empty / whitespace-only prompt → nothing to route.
[ -z "$TRIMMED" ] && exit 0

# Telemetry — fire-and-forget.
LOG_DIR="$HQ_ROOT/workspace/learnings"
mkdir -p "$LOG_DIR" 2>/dev/null || true
printf '{"ts":"%s","event":"nl-router-first-touch","session":"%s"}\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${SESSION_ID:-unknown}" \
  >> "$LOG_DIR/natural-language-router.jsonl" 2>/dev/null || true

# additionalContext — single-line JSON value.
cat <<'JSONOUT'
{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":"<natural-language-routing>\nNATURAL LANGUAGE MODE — first message of the session, and the user did not open with an explicit slash command.\n\nDo not wait to be told which command to run. Apply the routing contract in `core/policies/natural-language-mode.md`:\n  1. Infer the user's underlying intent from their plain-language prompt.\n  2. ANCHOR before company/project/repo work (hard prerequisite): bind the company (mention → cwd → repo's owning company in `companies/manifest.yaml` → handoff), then read the policy files under `companies/{co}/policies/` + the active repo's policy files under `.claude/policies/` + the manifest infra fields + `workspace/threads/handoff.json`. An HQ-root start has no cwd signal, so do this explicitly. Never guess or cross company credentials. Carveout: HQ-core/builder, global, and read-only multi-company search need no company anchor.\n  3. Map intent → the right HQ skill (startwork, strategize, brainstorm, plan/deep-plan, run-project, execute-task, investigate, diagnose, review, land, deploy, learn, adr, checkpoint, handoff, hqwork, …). The full Intent Map is in the policy.\n  4. Announce the inferred route in one short line — e.g. \"Reading this as a debugging task → running /investigate.\" — then PROCEED in this turn for cheap/reversible routes.\n  5. For heavy/irreversible routes (run-project, execute-task, land, land-batch, deploy, hq-share, hq-files, newcompany, new-hire, designate-team, promote, accept, update-hq) announce the route AND stop for an explicit go. This composes with — never weakens — the charter's irreversible-action rules.\n\nIf two routes are genuinely plausible and the difference matters, ask ONE tight question via the structured picker (one question per call). Otherwise default to action.\n\nThis nudge fires once per session. Mid-session, keep durable memory alive: journal findings, keep the work-session/project folder current, and log decisions/new knowledge so they survive compaction.\n</natural-language-routing>"}}
JSONOUT

exit 0
