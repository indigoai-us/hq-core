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
#   HQ_PROMPT_COMPANY_BIND=0   (keep the hint, skip the first-prompt company rebind)
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

. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/core/scripts/hook-lib.sh"

extract() {
  printf '%s' "$STDIN_JSON" | hq_json_get "$1"
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

# --- First-prompt company bind ----------------------------------------------
# SessionStart binds a session that starts at the HQ root to the device default
# company before any prompt is read. When the first prompt names exactly one
# other manifest company, rebind through hq-session.sh (the same path an
# explicit bind takes: scope capability, project/task clear, policy digest,
# Work Mesh registration). Every condition below must hold; any miss leaves the
# session as it was and the routing hint below stays the only effect.
#   - the router's first-touch marker was absent (checked above) AND the
#     transcript holds no earlier turn: at most one user line and no assistant
#     line (a resumed or forked session fails this)
#   - main thread, a valid session id, and no hq-spawn-intent handoff tag
#     (the start_session handoff owns that binding)
#   - meta.yaml says company_source: device_default, and the scope capability
#     (when present) names the same single company. Any explicit bind, spawn,
#     parent, session or cwd-registry binding is never replaced.
#   - only the first line of the prompt is scanned, and a company counts only
#     when named with a cue ("for X", "@X", "company X", "X company"); see
#     core/scripts/lib/prompt-company-mention.sh
#   - exactly one manifest company is named; several, or an overlap of names,
#     means no bind
# A scheduled-task run (the prompt opens with <scheduled-task ...>) has no
# person to bind a company, and its first line is the wrapper tag. It may also
# bind a session that SessionStart left unbound, from the run's cwd under
# companies/<slug>/, companies/<slug> paths in the task text, or a cue in the
# task's first line, when all of them name one company (source scheduled_task).
# Disable with HQ_PROMPT_COMPANY_BIND=0.
BIND_NOTICE=""
prompt_company_bind_first_prompt() {
  case "${HQ_PROMPT_COMPANY_BIND:-1}" in 0|false|FALSE|off|OFF|no|NO) return 0 ;; esac
  command -v jq >/dev/null 2>&1 || return 0
  local sid="$SESSION_ID" lib="$HQ_ROOT/core/scripts/lib/prompt-company-mention.sh"
  local hs="$HQ_ROOT/core/scripts/hq-session.sh" meta tp n tr cur src text slug caps out
  local sched=0 require="device_default" bind_source="prompt_mention"
  [ -f "$lib" ] && [ -f "$hs" ] || return 0
  case "$sid" in ''|.|..|*[!A-Za-z0-9._-]*) return 0 ;; esac
  [ -z "$(extract agent_id)" ] || return 0
  printf '%s' "$PROMPT" | grep -qi 'hq-spawn-intent' && return 0
  # First prompt, by transcript. Missing or unreadable transcript fails closed.
  tp="$(extract transcript_path)"
  [ -n "$tp" ] && [ -f "$tp" ] && [ -r "$tp" ] || return 0
  # Not verified whether Claude Code writes the current prompt to the transcript
  # before UserPromptSubmit fires, so accept either: at most one real user line
  # (the current prompt, if already written) and no assistant line at all. A
  # resumed or forked session carries prior turns, which always include
  # assistant lines, so it never counts as a first prompt.
  n="$(grep -c '"type":"user"' "$tp" 2>/dev/null || true)"
  tr="$(grep '"type":"user"' "$tp" 2>/dev/null | grep -c '"tool_result"' || true)"
  [ $(( ${n:-0} - ${tr:-0} )) -le 1 ] || return 0
  grep -q '"type":"assistant"' "$tp" 2>/dev/null && return 0
  # Binding state: only an unreplaced SessionStart device default may change,
  # or, for a scheduled-task run, a session with no binding at all.
  meta="$HQ_ROOT/workspace/sessions/$sid/meta.yaml"
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 0
  cur="$(awk '$1=="company_slug:"{sub(/^[^:]+:[[:space:]]*/,""); gsub(/^"|"$/,""); print; exit}' "$meta")"
  src="$(awk '$1=="company_source:"{sub(/^[^:]+:[[:space:]]*/,""); gsub(/^"|"$/,""); print; exit}' "$meta")"
  . "$lib" 2>/dev/null || return 0
  prompt_company_mention_is_scheduled_task "$PROMPT" && sched=1
  if [ "$src" = "device_default" ] && [ -n "$cur" ] && [ "$cur" != "personal" ]; then
    :
  elif [ "$sched" -eq 1 ] && [ -z "$cur" ] && [ -z "$src" ]; then
    # Unbound scheduled run; the capability check below must also find none.
    require="none"
  else
    return 0
  fi
  # A multi-company lock set recorded in meta.yaml is never replaced either.
  case "$(awk '$1=="company_slugs:"{sub(/^[^:]+:[[:space:]]*/,""); print; exit}' "$meta")" in *,*) return 0 ;; esac
  if [ -f "$HQ_ROOT/core/scripts/lib/session-scope-capability.sh" ] \
    && [ -f "$HQ_ROOT/workspace/sessions/$sid/scope-capability.json" ]; then
    . "$HQ_ROOT/core/scripts/lib/session-scope-capability.sh" 2>/dev/null || return 0
    caps="$(session_scope_read_companies "$HQ_ROOT" "$sid" 2>/dev/null | paste -sd, -)"
    [ "$caps" = "$cur" ] || return 0
  fi
  if [ "$sched" -eq 1 ]; then
    slug="$(prompt_company_mention_scheduled_task_resolve "$HQ_ROOT" "$(extract cwd)" "$PROMPT")"
    bind_source="scheduled_task"
  else
    text="$(prompt_company_mention_scan_text "$PROMPT")"
    slug="$(prompt_company_mention_resolve "$HQ_ROOT" "$text")"
  fi
  [ -n "$slug" ] && [ "$slug" != "$cur" ] || return 0
  # Lock wait is bounded (~1s) and the source is re-checked under the lock.
  out="$(env HQ_ROOT="$HQ_ROOT" HQ_HQ_SESSION_NO_CLI=1 HQ_SESSION_COMPANY_SOURCE="$bind_source" \
    HQ_SESSION_LOCK_TRIES=10 HQ_SESSION_REQUIRE_SOURCE="$require" \
    bash "$hs" --session-id "$sid" set company_slug "$slug" 2>&1)" || return 0
  if [ "$sched" -eq 1 ] && [ -z "$cur" ]; then
    BIND_NOTICE="HQ bound this scheduled-task session to company ${slug} because the task's folder or instructions point to it (no company was bound at start). Use only ${slug}; the company-binding step below is already done.${out:+
$out}"
  elif [ "$sched" -eq 1 ]; then
    BIND_NOTICE="HQ bound this scheduled-task session to company ${slug} because the task's folder or instructions point to it (it had been bound to the device default ${cur}). Disregard any company context, policies or knowledge that SessionStart loaded for ${cur}; they do not apply to this session. Use only ${slug}; the company-binding step below is already done.${out:+
$out}"
  else
    BIND_NOTICE="HQ bound this session to company ${slug} because the first message names it (it had been bound to the device default ${cur}). Disregard any company context, policies or knowledge that SessionStart loaded for ${cur}; they do not apply to this session. Use only ${slug}; the company-binding step below is already done.${out:+
$out}"
  fi
}
prompt_company_bind_first_prompt

# Telemetry — fire-and-forget.
LOG_DIR="$HQ_ROOT/workspace/learnings"
mkdir -p "$LOG_DIR" 2>/dev/null || true
printf '{"ts":"%s","event":"nl-router-first-touch","session":"%s"}\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${SESSION_ID:-unknown}" \
  >> "$LOG_DIR/natural-language-router.jsonl" 2>/dev/null || true

# additionalContext — single-line JSON value.
IFS= read -r -d '' ROUTING_JSON <<'JSONOUT' || true
{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":"<natural-language-routing>\nNATURAL LANGUAGE MODE — first message of the session, and the user did not open with an explicit slash command.\n\nDo not wait to be told which command to run. Apply the routing contract in `core/policies/natural-language-mode.md`:\n  1. Infer the user's underlying intent from their plain-language prompt.\n  2. ANCHOR before company/project/repo work (hard prerequisite): bind the company (mention → cwd → repo's owning company in `companies/manifest.yaml` → handoff), then read the policy files under `companies/{co}/policies/` + the active repo's policy files under `.claude/policies/` + the manifest infra fields + `workspace/threads/handoff.json`. An HQ-root start has no cwd signal, so do this explicitly. Never guess or cross company credentials. Carveout: HQ-core/builder, global, and read-only multi-company search need no company anchor.\n  3. Map intent → the right HQ skill (startwork, strategize, brainstorm, plan/deep-plan, run-project, execute-task, investigate, diagnose, review, land, deploy, learn, adr, checkpoint, handoff, hqwork, …). The full Intent Map is in the policy.\n  4. Announce the inferred route in one short line — e.g. \"Reading this as a debugging task → running /investigate.\" — then PROCEED in this turn for cheap/reversible routes.\n  5. For heavy/irreversible routes (run-project, execute-task, land, land-batch, deploy, hq-share, hq-files, newcompany, new-hire, designate-team, promote, accept, update-hq) announce the route AND stop for an explicit go. This composes with — never weakens — the charter's irreversible-action rules.\n\nIf two routes are genuinely plausible and the difference matters, ask ONE tight question via the structured picker (one question per call). Otherwise default to action.\n\nThis nudge fires once per session. Mid-session, keep durable memory alive: journal findings, keep the work-session/project folder current, and log decisions/new knowledge so they survive compaction.\n</natural-language-routing>"}}
JSONOUT

if [ -n "$BIND_NOTICE" ]; then
  # Built with jq so the notice reaches the model as a JSON-quoted string.
  printf '%s' "$ROUTING_JSON" | jq -c --arg n "$BIND_NOTICE" \
    '.hookSpecificOutput.additionalContext = ("<company-bound-from-first-message>\n" + $n + "\n</company-bound-from-first-message>\n" + .hookSpecificOutput.additionalContext)'
else
  printf '%s' "$ROUTING_JSON"
fi

exit 0
