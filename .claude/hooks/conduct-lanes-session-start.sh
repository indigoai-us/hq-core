#!/usr/bin/env bash
# SessionStart conduct bootstrap, delegated to hq-cli's authoritative policy.
set -uo pipefail

payload="$(cat 2>/dev/null || true)"
root="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd)}"
command -v hq >/dev/null 2>&1 || exit 0
hq_bin="$(command -v hq)"

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

tmp="$(mktemp -d 2>/dev/null)" || exit 0
trap 'rm -rf "$tmp"' EXIT

if ! run_bounded 1 env HQ_NO_SELF_UPDATE=1 HQ_NO_UPDATE_CHECK=1 "$hq_bin" --version >"$tmp/version" 2>/dev/null; then
  exit 0
fi
version="$(sed -nE 's/^([0-9]+)\.([0-9]+)\.([0-9]+).*$/\1 \2 \3/p' "$tmp/version" | head -1)"
set -- $version
[ "$#" -eq 3 ] || exit 0
[ "$1" -gt 5 ] || { [ "$1" -eq 5 ] && { [ "$2" -gt 345 ] || { [ "$2" -eq 345 ] && [ "$3" -ge 63 ]; }; }; } || exit 0

if run_bounded 2 env HQ_NO_SELF_UPDATE=1 HQ_NO_UPDATE_CHECK=1 HQ_ROOT="$root" "$hq_bin" lanes session-start < <(printf '%s' "$payload") >"$tmp/stdout" 2>/dev/null; then
  cat "$tmp/stdout" 2>/dev/null || true
fi
exit 0
