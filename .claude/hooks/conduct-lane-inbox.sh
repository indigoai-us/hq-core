#!/usr/bin/env bash
# conduct-lane-inbox.sh — deliver queued messages into a RUNNING /conduct lane.
#
# A lane is a headless CLI process with stdin closed, so the conductor cannot
# speak to it once it starts. This hook is the delivery half of that channel: it
# drains the lane's drop box (core/scripts/conduct-inbox.sh) on the lane's own
# lifecycle events and hands the text to the model mid-turn.
#
# Delivery is mechanical. The lane is never asked to check for messages, so a
# lane deep in a long edit still receives one on its very next tool event.
#
# ────────────────────────────────────────────────────────────────────────────
# EVERY ENGINE TAKES THE MESSAGE THE SAME WAY: PostToolUse, via
# hookSpecificOutput.additionalContext, with Stop as the backstop for anything
# queued while the lane writes its final answer. Non-disruptive — the message
# simply appears before the model's next step, and the lane keeps the tool call
# it was about to make. SubagentStop is handled below but is NOT registered: a
# conductor's message is for the lane, not for a subagent the lane spawned.
#
# Grok used to be the exception, delivered on PreToolUse by DENYING the tool
# call so the message could ride the deny reason. That cost the lane a call
# every time, and it was built on a claim about Grok that is not true: the
# adapter now passes a hook's additionalContext through on PostToolUse, and
# Grok's Stop gate blocks like Claude's (Grok 1.0.34 hook reference). So the
# engine branch is gone, and PreToolUse is inert everywhere.
#
# THE RULE THAT SURVIVES, and the reason this file reasons about events at all:
# draining on an event that cannot reach the model DESTROYS the message. It
# moves out of the queue, the payload goes to a diagnostics stream nobody reads,
# and the operator believes a correction was delivered that the lane never saw.
# So: never drain unless this event can actually feed the text back to the
# model. The three events below are the ones that can, on all three engines.
# UserPromptSubmit and SessionStart are NOT among them under Grok, which is why
# this hook is not registered on either.
#
# THE GUARD MATTERS. This hook is registered with matcher `*`, so it runs on
# every tool call in every session on the machine. HQ_CONDUCT_RUN_DIR is set
# only by a /conduct lane launch, and a linked session is listed by id under
# workspace/conduct-links/by-session, so an ordinary session exits on those two
# tests without reading its payload — and, critically, without consuming a
# queue that belongs to someone else.

set -uo pipefail

# EVERY GUARD BELOW RUNS BEFORE THIS HOOK READS ITS PAYLOAD, and the dispatcher
# is still writing that payload into our stdin. Exiting with the pipe unread
# kills the writer with SIGPIPE; a dispatcher under `pipefail` that records the
# pipeline status then reports this hook as having failed with 141 even though
# it exited 0. On fleet boxes at hq-core 15.0.139 that refused an agent's first
# company read on a fresh session:
#   PROBE_FAIL - pre-bind: ... (rc=141): Hook 'conduct-lane-inbox' exited 141.
# hook-lib.sh now reads PIPESTATUS[1] so a current install is immune, but this
# hook must also be safe under an OLD dispatcher it cannot upgrade. Draining
# costs one read of an already-buffered payload, so bail out through this.
bail() { cat >/dev/null 2>&1 || true; exit "${1:-0}"; }

self_hq="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../.." 2>/dev/null && pwd)" || bail 0
[ -n "$self_hq" ] || bail 0

inbox_sh="$self_hq/core/scripts/conduct-inbox.sh"
[ -x "$inbox_sh" ] || bail 0

# TWO WAYS IN. A lane is named by the environment its launcher exported. A
# LINKED session (core/scripts/conduct-link.sh) was already running when it
# joined a conductor, so nothing could be exported into it; it is found by the
# session id in the payload instead, through workspace/conduct-links/by-session.
# That registry is empty on a machine with no open link, and the test below is
# one directory listing, so an ordinary session still leaves without reading
# its payload.
# hook-registry.json lists this script twice per event, because its prefilters
# are ANDed and the two ways in have different cheap tests: the lane entry is
# gated on the HQ_CONDUCT_RUN_DIR env var, the `--link` entry on the by-session
# directory existing. Inside a lane the `--link` entry stands down so one event
# never drains twice.
if [ "${1:-}" = "--link" ] && [ -n "${HQ_CONDUCT_RUN_DIR:-}" ]; then bail 0; fi
role="lane"
run_dir="${HQ_CONDUCT_RUN_DIR:-}"
input=""
if [ -z "$run_dir" ]; then
  by_session="${HQ_CONDUCT_LINKS_DIR:-$self_hq/workspace/conduct-links}/by-session"
  [ -d "$by_session" ] && [ -n "$(ls -A "$by_session" 2>/dev/null)" ] || bail 0
  input="$(cat 2>/dev/null || printf '{}')"
  sid="$(printf '%s' "$input" | jq -r '.session_id // .sessionId // ""' 2>/dev/null || true)"
  case "$sid" in ""|.|..|*[!A-Za-z0-9._-]*) exit 0 ;; esac
  [ -f "$by_session/$sid" ] || exit 0
  read -r role link child < "$by_session/$sid" || exit 0
  link_dir="$(dirname "$by_session")/$link"
  case "$role" in
    child)     run_dir="$link_dir/children/$child"; link_meta="$run_dir/meta.json" ;;
    conductor) run_dir="$link_dir/up";              link_meta="$link_dir/meta.json" ;;
    *) exit 0 ;;
  esac
  [ -d "$run_dir/inbox/pending" ] || exit 0
else
  [ -d "$run_dir/inbox/pending" ] || bail 0
  # Past this point stdin is at EOF, so a plain `exit` is already SIGPIPE-safe.
  input="$(cat 2>/dev/null || printf '{}')"
fi
hook_event="$(printf '%s' "$input" | jq -r '.hook_event_name // .hookEventName // ""' 2>/dev/null || true)"

deliver_on="PostToolUse Stop SubagentStop"

case " $deliver_on " in
  *" $hook_event "*) : ;;
  *) exit 0 ;;
esac

# A Stop whose decision the engine throws away cannot carry this message, and
# draining on it would destroy the message rather than delay it. Grok fires one
# such Stop at session close; its adapter sets this to 0 for that fire. An unset
# value means an engine that always delivers, so claude and codex are unchanged.
case "$hook_event" in
  Stop|SubagentStop)
    [ "${HQ_STOP_DECISION_DELIVERABLE:-1}" = "0" ] && exit 0
    ;;
esac

messages="$(bash "$inbox_sh" drain --run-dir "$run_dir" 2>/dev/null || true)"
[ -n "$messages" ] || exit 0

# The framing is load-bearing. Without it a bare instruction reads as if it came
# from the brief, and the lane cannot tell a mid-flight correction from its
# original orders — which is exactly when the difference matters most.
case "$role" in
  conductor)
    body="[conduct] Sessions you are conducting reported while you were working.
Each report names the session it came from. Relay what the operator needs to
know, and answer a session with: bash core/scripts/conduct-link.sh send --child <name> --text '...'

$messages"
    ;;
  child)
    body="[conduct] The session conducting you sent this while you were working.
Treat it as a new instruction from the operator, taking precedence over your
current task where the two conflict. When you have something to tell the
conductor - a result, a blocker, a question - send it with:
bash core/scripts/conduct-link.sh report --state <working|blocked|idle|done> --text '...'

$messages"
    ;;
  *)
    body="[conduct] Your conductor sent this while you were working. Treat it as a
new instruction from the operator, taking precedence over your brief where the
two conflict. Do not reply to the conductor; act on it and carry on.

$messages"
    ;;
esac

case "$hook_event" in
  PostToolUse)
    jq -n --arg ctx "$body" '{
      hookSpecificOutput: {
        hookEventName: "PostToolUse",
        additionalContext: $ctx
      }
    }' 2>/dev/null || true
    ;;
  *)
    # Stop/SubagentStop: block the finish so the message is acted on rather than
    # delivered into a turn that has already ended. Self-limiting — the drain
    # consumed the queue, so the next Stop has nothing to deliver and the lane
    # finishes normally. This is why the hook does not read stop_hook_active:
    # the queue, not a flag, is what stops it repeating.
    jq -n --arg reason "$body" '{decision: "block", reason: $reason}' 2>/dev/null || true
    ;;
esac

exit 0
