#!/usr/bin/env bash
# Deliver linked-session messages through hq-cli's per-engine output contract.
set -uo pipefail

# Messages are addressed to the root session of a link. Claude Code reports a
# subagent's tool calls and SubagentStop under the parent's session_id, so the
# session pointer alone would hand the root's message to the child. Any event
# that comes from a child (an agent_id, a parent thread field, a subagent_type,
# or a transcript under a subagents folder) returns before hq-cli is called,
# which leaves the queue untouched for the root's next PostToolUse or Stop.
# A parent session id alone is not a child marker: a resumed, forked, or
# launcher-spawned Grok root can carry parentSessionId, and Grok marks its real
# children with subagentType.
event="${1:-}"
case "$event" in
  PostToolUse|Stop) ;;
  *) exit 0 ;;
esac

payload="$(cat 2>/dev/null || true)"
[ -z "${HQ_HOOK_AGENT_ID:-}" ] || exit 0
fields="$(printf '%s' "$payload" | jq -r '
  def nonempty: type == "string" and length > 0;
  def present: . != null and . != "";
  (.session_id // .sessionId // "" | if type == "string" then . else "" end),
  (if ([.agent_id, .agentId] | any(present))
      or ([.parent_thread_id, .parentThreadId] | any(nonempty))
      or ([.agent_transcript_path, .agentTranscriptPath] | any(nonempty))
      or ([.subagent_type, .subagentType] | any(nonempty))
      or ((.transcript_path // .transcriptPath // "") | if type == "string" then test("[/\\\\]subagents[/\\\\][^/\\\\]+\\.jsonl$") else false end)
    then "child" else "root" end)
' 2>/dev/null || true)"
# jq on Windows can end each line with CR; strip it so a root still matches.
fields="${fields//$'\r'/}"
sid="${fields%%$'\n'*}"
[ "$fields" = "$sid"$'\n'root ] || exit 0
case "$sid" in
  ""|.|..) exit 0 ;;
esac
[[ "$sid" =~ ^[A-Za-z0-9._-]+$ ]] || exit 0

root="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd)}"
[ -f "$root/workspace/lanes-links/by-session/$sid" ] || exit 0
command -v hq >/dev/null 2>&1 || exit 0

run_bounded() {
  local seconds="$1"
  shift
  if command -v timeout >/dev/null 2>&1; then
    timeout --signal=TERM --kill-after=1s "${seconds}s" "$@"
  elif command -v gtimeout >/dev/null 2>&1; then
    gtimeout --signal=TERM --kill-after=1s "${seconds}s" "$@"
  elif command -v perl >/dev/null 2>&1; then
    perl -e '
      use POSIX qw(setpgid);
      my ($seconds, @command) = @ARGV;
      my $pid = fork();
      die "fork failed" unless defined $pid;
      if ($pid == 0) { setpgid(0, 0); exec @command; exit 127; }
      $SIG{ALRM} = sub { kill "TERM", -$pid; sleep 1; kill "KILL", -$pid; waitpid($pid, 0); exit 124; };
      alarm($seconds);
      waitpid($pid, 0);
      alarm(0);
      exit(($? & 127) ? 128 + ($? & 127) : ($? >> 8));
    ' "$seconds" "$@"
  else
    return 127
  fi
}

tmp="$(mktemp 2>/dev/null)" || exit 0
trap 'rm -f "$tmp"' EXIT
if run_bounded 2 env HQ_NO_SELF_UPDATE=1 HQ_NO_UPDATE_CHECK=1 HQ_ROOT="$root" hq lanes link _deliver --event "$event" < <(printf '%s' "$payload") >"$tmp" 2>/dev/null; then
  cat "$tmp" 2>/dev/null || true
fi
exit 0
