#!/usr/bin/env bash
# Deliver linked-session messages through hq-cli's per-engine output contract.
set -uo pipefail

event="${1:-}"
case "$event" in
  PostToolUse|Stop|SubagentStop) ;;
  *) exit 0 ;;
esac

payload="$(cat 2>/dev/null || true)"
sid="$(printf '%s' "$payload" | jq -er '.session_id // .sessionId // empty | strings' 2>/dev/null || true)"
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
