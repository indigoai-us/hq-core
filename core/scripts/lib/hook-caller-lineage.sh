#!/usr/bin/env bash
# hq-core: public
# hook-caller-lineage.sh — tell a child (subagent) hook caller from a root one.
#
# Sourced by hooks. Never execute directly. Every function reads only the hook
# payload passed to it, prints nothing on bad input, and never fails the
# caller: a hook that cannot classify its caller keeps its fail-closed path.
#
# A payload comes from a child when it carries any of:
#   agent_id / agentId                      (Claude Code Task subagent)
#   parent_session_id / parentSessionId     (Grok and other hosts that give a
#   parent_thread_id / parentThreadId        child its own session or thread id)
#   agent_transcript_path / agentTranscriptPath
#   subagent_type / subagentType
#   transcript_path under a `subagents` folder
# conduct-lanes-link-deliver.sh uses the same predicate (PR 1419).

# The jq predicate, shared so every hook classifies callers the same way.
HOOK_CALLER_CHILD_JQ='def nonempty: type == "string" and length > 0;
((.agent_id // .agentId) | nonempty)
  or ((.parent_session_id // .parentSessionId // .parent_thread_id // .parentThreadId) | nonempty)
  or ((.agent_transcript_path // .agentTranscriptPath) | nonempty)
  or ((.subagent_type // .subagentType) | nonempty)
  or ((.transcript_path // .transcriptPath // "") | if type == "string" then test("[/\\\\]subagents[/\\\\]") else false end)'

# The same predicate without the parent id fields. A parent id names whose
# scope a caller wants, so it cannot also be the proof that the caller is a
# child: a root session payload that carries one must not inherit.
HOOK_CALLER_CHILD_MARKER_JQ='def nonempty: type == "string" and length > 0;
((.agent_id // .agentId) | nonempty)
  or ((.agent_transcript_path // .agentTranscriptPath) | nonempty)
  or ((.subagent_type // .subagentType) | nonempty)
  or ((.transcript_path // .transcriptPath // "") | if type == "string" then test("[/\\\\]subagents[/\\\\]") else false end)'

# hook_caller_is_child <payload-json>
#   Exit 0 when the payload comes from a child caller, 1 otherwise.
hook_caller_is_child() {
  local payload="${1:-}" out
  [ -n "$payload" ] || return 1
  out="$(printf '%s' "$payload" | jq -r "$HOOK_CALLER_CHILD_JQ" 2>/dev/null || true)"
  [ "$out" = true ]
}

# hook_caller_has_child_marker <payload-json>
#   Exit 0 when the payload marks a child caller by something other than a
#   parent id (agent id, subagent type, or a subagent transcript), 1 otherwise.
#   Scope inheritance from a reported parent session requires this.
hook_caller_has_child_marker() {
  local payload="${1:-}" out
  [ -n "$payload" ] || return 1
  out="$(printf '%s' "$payload" | jq -r "$HOOK_CALLER_CHILD_MARKER_JQ" 2>/dev/null || true)"
  [ "$out" = true ]
}

# hook_caller_parent_session_id <payload-json>
#   Print the parent session id the host reported for a child that runs under
#   its own session id. Prints nothing when there is none or it is not a
#   plain string. Callers must still validate it as a path segment.
hook_caller_parent_session_id() {
  local payload="${1:-}"
  [ -n "$payload" ] || return 0
  printf '%s' "$payload" | jq -r '
    (.parent_session_id // .parentSessionId // .parent_thread_id // .parentThreadId // "")
    | if type == "string" then . else "" end
  ' 2>/dev/null || true
}
