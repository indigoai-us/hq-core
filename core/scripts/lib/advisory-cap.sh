#!/bin/bash
# advisory-cap.sh: shared hard wall-clock cap for advisory hooks.
#
# SOURCED, never executed. bash 3.2 safe. Used by .claude/hooks/master-hook.sh
# (kill-after and fail-open for advisory registry children) and by
# core/scripts/lib/hook-adapter-core.sh (hq_run_capped around advisory
# registry hooks on the Codex path).
#
# An advisory hook only adds context or warnings, so a capped run fails open:
# it exits 0 with no output. Safety guards and fail_closed guards are never
# capped here; they keep their own timeout handling.
#
# Kill switch: HQ_HOOK_ADVISORY_CAP=0 restores the previous behaviour.
# HQ_HOOK_ADVISORY_CAP_KILL_AFTER sets the SIGTERM to SIGKILL grace (default 2 s).
# shellcheck disable=SC2034 # HQ_RUN_CAPPED_* and HQ_LOAD1_CACHE are read by callers.

# 0 when the cap is on (the default).
hq_advisory_cap_enabled() {
  case "${HQ_HOOK_ADVISORY_CAP:-1}" in
    0|off|OFF|false|FALSE|no|NO) return 1 ;;
  esac
  return 0
}

# Grace in whole seconds between SIGTERM and SIGKILL. 1 to 9, default 2.
hq_advisory_cap_kill_after() {
  case "${HQ_HOOK_ADVISORY_CAP_KILL_AFTER:-}" in
    [1-9]) printf '%s' "$HQ_HOOK_ADVISORY_CAP_KILL_AFTER" ;;
    *) printf '2' ;;
  esac
}

# hq_advisory_cap_applies <event> <hook-id> <safety:0|1> <fail_closed:0|1>
# 0 when a registry child is advisory and may be capped. On PreToolUse only
# the known context hooks are advisory; every other PreToolUse child is
# treated as a guard and left alone. On other events a child without safety
# or fail_closed is advisory: once it has timed out its exit is not a verdict.
hq_advisory_cap_applies() {
  hq_advisory_cap_enabled || return 1
  [ "${3:-0}" = "1" ] && return 1
  [ "${4:-0}" = "1" ] && return 1
  case "$1" in
    PreToolUse)
      case "$2" in
        inject-policy-on-trigger|warn-cross-company-settings|surface-company-infra-policy) return 0 ;;
      esac
      return 1
      ;;
  esac
  return 0
}

# 1-minute load average, read once per process into HQ_LOAD1_CACHE ("-" when
# unknown). Call it in the current shell, never inside $( ), or the cache is
# lost and every journal row pays a fork.
HQ_LOAD1_CACHE=""
hq_load1() {
  local line="" rest=""
  if [ -z "$HQ_LOAD1_CACHE" ]; then
    if [ -r /proc/loadavg ]; then
      read -r line rest < /proc/loadavg 2>/dev/null || line=""
    elif command -v sysctl >/dev/null 2>&1; then
      line="$(sysctl -n vm.loadavg 2>/dev/null || true)"
      line="${line#\{ }"
      line="${line%% *}"
    fi
    case "$line" in
      ''|*[!0-9.]*) line="-" ;;
    esac
    HQ_LOAD1_CACHE="$line"
  fi
}

# Perl runner: <seconds> <kill-after> <argv...>. Runs argv in its own process
# group, sends TERM to the group at the cap, KILL after the grace, and exits
# 124 on expiry. The grace loop reaps the child as soon as it exits: until it
# is reaped the child stays in its process group, so on Linux the group probe
# would keep succeeding for the whole grace after the child had gone. WNOHANG
# falls back to 1 (its value on Linux, macOS, BSD and Cygwin) when POSIX.pm is
# not installed, so the handler never dies before the SIGKILL step.
# shellcheck disable=SC2016 # perl program intentionally uses single quotes.
HQ_ADVISORY_CAP_PERL='
my $t = shift; my $grace = shift;
my $pid = fork();
exit 128 unless defined $pid;
if ($pid == 0) { setpgrp(0, 0); exec {$ARGV[0]} @ARGV; exit 127; }
setpgrp($pid, $pid);
my $stop = sub {
  kill "TERM", -$pid;
  my $nohang = eval { require POSIX; POSIX::WNOHANG() } || 1;
  my $gone = 0;
  for (1 .. ($grace * 20)) {
    waitpid($pid, $nohang);
    unless (kill 0, -$pid) { $gone = 1; last; }
    select(undef, undef, undef, 0.05);
  }
  kill "KILL", -$pid unless $gone;
};
$SIG{ALRM} = sub { $stop->(); waitpid($pid, 0); exit 124; };
for my $sig (qw(TERM INT HUP)) {
  $SIG{$sig} = sub { $stop->(); waitpid($pid, 0); exit 128 + ($sig eq "TERM" ? 15 : $sig eq "INT" ? 2 : 1); };
}
alarm $t;
waitpid($pid, 0);
my $rc = $?;
alarm 0;
exit(($rc & 127) ? 128 + ($rc & 127) : ($rc >> 8));
'

# hq_run_capped <seconds> <argv...>
# Runs argv with this shell's stdin under a hard wall-clock cap. argv[0] must
# be an executable path or a command on PATH, not a shell function.
# Sets HQ_RUN_CAPPED_RC (the child's exit, 124 on expiry) and
# HQ_RUN_CAPPED_TIMED_OUT (0 or 1). On expiry the child's output is dropped
# and the function returns 0. Otherwise the output is printed and the child's
# exit status is returned. With the kill switch off, an invalid cap, or no
# timer available, argv runs unbounded as before.
hq_run_capped() {
  local t="$1" grace buf rc=0
  shift
  HQ_RUN_CAPPED_RC=0
  HQ_RUN_CAPPED_TIMED_OUT=0
  case "$t" in ''|*[!0-9]*|0*) t="" ;; esac
  if [ -z "$t" ] || ! hq_advisory_cap_enabled; then
    "$@" || rc=$?
    HQ_RUN_CAPPED_RC=$rc
    return "$rc"
  fi
  grace="$(hq_advisory_cap_kill_after)"
  buf="$(mktemp "${TMPDIR:-/tmp}/hq-capped.XXXXXX" 2>/dev/null)" || buf=""
  if [ -z "$buf" ]; then
    "$@" || rc=$?
    HQ_RUN_CAPPED_RC=$rc
    return "$rc"
  fi
  # perl first: it signals the hook's own process group and exits 124 on
  # expiry. Git Bash cannot rely on perl alarm across exec, so it uses GNU
  # timeout, which ships there.
  local runner="" start="$SECONDS"
  case "$(uname -s 2>/dev/null)" in
    MINGW*|MSYS*|CYGWIN*) command -v timeout >/dev/null 2>&1 && runner=timeout ;;
    *)
      if command -v perl >/dev/null 2>&1; then runner=perl
      elif command -v timeout >/dev/null 2>&1; then runner=timeout
      fi
      ;;
  esac
  case "$runner" in
    perl)
      perl -e "$HQ_ADVISORY_CAP_PERL" "$t" "$grace" "$@" > "$buf" || rc=$?
      ;;
    timeout)
      # GNU timeout signals its whole process group but sends KILL only while
      # its direct child lives. The wrapper traps TERM so it outlives the hook
      # and the KILL step reaches a hook that ignores TERM. A trap handler is
      # not inherited, so the hook keeps the default TERM action. timeout
      # exits 137 when it had to send KILL.
      timeout -k "$grace" "$t" bash -c 'trap ":" TERM; "$@" <&0 & c=$!; while :; do wait "$c"; rc=$?; kill -0 "$c" 2>/dev/null || break; done; exit "$rc"' hq-capped "$@" > "$buf" || rc=$?
      [ "$rc" -ne 137 ] || [ "$((SECONDS - start))" -lt "$t" ] || rc=124
      ;;
    *)
      "$@" > "$buf" || rc=$?
      ;;
  esac
  HQ_RUN_CAPPED_RC=$rc
  if [ "$rc" -eq 124 ]; then
    HQ_RUN_CAPPED_TIMED_OUT=1
    rm -f "$buf" 2>/dev/null || true
    return 0
  fi
  cat "$buf" 2>/dev/null || true
  rm -f "$buf" 2>/dev/null || true
  return "$rc"
}
