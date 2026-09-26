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
# only by a /conduct lane launch, so an ordinary session exits on the first test
# having touched no disk — and, critically, without consuming a lane's queue.

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

[ -n "${HQ_CONDUCT_RUN_DIR:-}" ] || bail 0

self_hq="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../.." 2>/dev/null && pwd)" || bail 0
[ -n "$self_hq" ] || bail 0

inbox_sh="$self_hq/core/scripts/conduct-inbox.sh"
[ -x "$inbox_sh" ] || bail 0
[ -d "$HQ_CONDUCT_RUN_DIR/inbox/pending" ] || bail 0

# Past this point stdin is at EOF, so a plain `exit` is already SIGPIPE-safe.
input="$(cat 2>/dev/null || printf '{}')"
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

messages="$(bash "$inbox_sh" drain --run-dir "$HQ_CONDUCT_RUN_DIR" 2>/dev/null || true)"
[ -n "$messages" ] || exit 0

# The framing is load-bearing. Without it a bare instruction reads as if it came
# from the brief, and the lane cannot tell a mid-flight correction from its
# original orders — which is exactly when the difference matters most.
body="[conduct] Your conductor sent this while you were working. Treat it as a
new instruction from the operator, taking precedence over your brief where the
two conflict. Do not reply to the conductor; act on it and carry on.

$messages"

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
