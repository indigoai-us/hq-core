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
# THE ENGINES DO NOT AGREE ON HOW A HOOK TALKS TO A MODEL, so which event
# carries the message depends on which engine the lane is running.
#
#   claude, codex   PostToolUse, via hookSpecificOutput.additionalContext.
#                   Non-disruptive: the message simply appears before the
#                   model's next step. Stop is also honoured as a backstop, so
#                   a message queued while the lane writes its final answer is
#                   still delivered instead of being dropped.
#
#   grok            PreToolUse ONLY, via a non-zero exit with the message on
#                   stderr, which .grok/hooks/hq-grok-hook-adapter.sh turns into
#                   {"decision":"deny","reason":<stderr>}. This is disruptive —
#                   it costs the lane the tool call it was about to make — but
#                   it is the only path that reaches the model at all. The Grok
#                   adapter says so in its own words: "Grok cannot inject
#                   context on any event", and it routes passive-hook stdout to
#                   stderr diagnostics. Its Stop cannot block either.
#
# CONSEQUENCE, and the reason this file is engine-aware rather than uniform:
# draining on an event that cannot reach the model DESTROYS the message. It
# moves out of the queue, the payload goes to a diagnostics stream nobody reads,
# and the operator believes a correction was delivered that the lane never saw.
# So the rule here is absolute: never drain unless this event, on this engine,
# can actually feed the text back to the model.
#
# THE GUARD MATTERS. This hook is registered with matcher `*`, so it runs on
# every tool call in every session on the machine. HQ_CONDUCT_RUN_DIR is set
# only by a /conduct lane launch, so an ordinary session exits on the first test
# having touched no disk — and, critically, without consuming a lane's queue.

set -uo pipefail

[ -n "${HQ_CONDUCT_RUN_DIR:-}" ] || exit 0

self_hq="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../.." 2>/dev/null && pwd)" || exit 0
[ -n "$self_hq" ] || exit 0

inbox_sh="$self_hq/core/scripts/conduct-inbox.sh"
[ -x "$inbox_sh" ] || exit 0
[ -d "$HQ_CONDUCT_RUN_DIR/inbox/pending" ] || exit 0

input="$(cat 2>/dev/null || printf '{}')"
hook_event="$(printf '%s' "$input" | jq -r '.hook_event_name // .hookEventName // ""' 2>/dev/null || true)"

# The lane exports its engine at launch. An unset value means a lane predating
# that export; treat it as the default engine (codex) rather than guessing the
# disruptive path, since delivering late is recoverable and denying a tool call
# on an engine that did not need it is not.
engine="$(printf '%s' "${HQ_CONDUCT_ENGINE:-codex}" | tr '[:upper:]' '[:lower:]')"

case "$engine" in
  grok) deliver_on="PreToolUse" ;;
  *)    deliver_on="PostToolUse Stop SubagentStop" ;;
esac

case " $deliver_on " in
  *" $hook_event "*) : ;;
  *) exit 0 ;;
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
  PreToolUse)
    # Grok only. The adapter reads stderr as the deny reason, so this is the
    # payload — not stdout. Say plainly that the tool call was interrupted to
    # carry a message, or the lane reads the denial as "this tool is forbidden"
    # and abandons a step it should simply retry.
    printf '%s\n\nYour tool call was not blocked on its merits — it was interrupted to hand you this message. Apply the instruction above, then continue, retrying that call if it is still the right next step.\n' \
      "$body" >&2
    exit 2
    ;;
  PostToolUse)
    jq -n --arg ctx "$body" '{
      hookSpecificOutput: {
        hookEventName: "PostToolUse",
        additionalContext: $ctx
      }
    }' 2>/dev/null || true
    ;;
  *)
    # Stop/SubagentStop on claude and codex: block the finish so the message is
    # acted on rather than delivered into a turn that has already ended.
    # Self-limiting — the drain consumed the queue, so the next Stop has nothing
    # to deliver and the lane finishes normally.
    jq -n --arg reason "$body" '{decision: "block", reason: $reason}' 2>/dev/null || true
    ;;
esac

exit 0
