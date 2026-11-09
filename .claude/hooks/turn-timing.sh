#!/usr/bin/env bash
# Local diagnostics only. No payloads, network, or new per-child clock reads.
# Opt-in because portable locking/rotation adds a process per dispatch.
TURN_TIMING_BUFFER=""
TURN_TIMING_ROWS=0
TURN_TIMING_FINISHED=0
TURN_TIMING_SESSION=""
turn_timing_row() { # kind, name, started-ms, elapsed-ms
  [ -n "$TURN_TIMING_SESSION" ] || return 0
  [ "$TURN_TIMING_ROWS" -lt 256 ] || return 0
  local kind="$1" name="${2##*/}" started="$3" elapsed="$4" source='-'
  case "$kind" in start|child|end) ;; *) return 0 ;; esac
  case "$name" in ''|*[!A-Za-z0-9._-]*) return 0 ;; esac
  [ "${#name}" -le 128 ] || return 0
  [[ "$started" =~ ^[0-9]{1,16}$ && "$elapsed" =~ ^[0-9]{1,12}$ ]] || return 0
  [ "${EVENT:-}" != SessionStart ] || [ "${MATCH_KEY:-}" != compact ] || source=compact
  TURN_TIMING_BUFFER+="1"$'\t'"$TURN_TIMING_SESSION"$'\t'"$MASTER_INVOCATION_ID"$'\t'"$EVENT"$'\t'"$kind"$'\t'"$name"$'\t'"$started"$'\t'"$elapsed"$'\t'"$source"$'\n'
  TURN_TIMING_ROWS=$((TURN_TIMING_ROWS + 1))
}
turn_timing_init() {
  [ "${HQ_TURN_TIMING:-0}" = 1 ] || return 0
  [ -n "${SESSION_ID:-}" ] || return 0
  case "${EVENT:-}" in SessionStart|UserPromptSubmit|PreToolUse|PostToolUse|Stop|PreCompact|PostCompact) ;; *) return 0 ;; esac
  if [ -z "${PAYLOAD_AGENT_ID:-}" ]; then
    TURN_TIMING_SESSION="${MASTER_SESSION_HASH:-}"
    [ -n "$TURN_TIMING_SESSION" ] || TURN_TIMING_SESSION="$(master_timeout_sha256 "$SESSION_ID")"
  else
    TURN_TIMING_SESSION="$(master_timeout_sha256 "$SESSION_ID" "${PAYLOAD_AGENT_ID:-}")"
  fi
  case "$TURN_TIMING_SESSION" in ''|*[!a-f0-9]*) TURN_TIMING_SESSION=''; return 0 ;; esac
  TURN_TIMING_STARTED="${MASTER_DISPATCH_STARTED_MS:-$MASTER_STARTED_MS}"
  turn_timing_row start "$EVENT" "$TURN_TIMING_STARTED" 0
}
turn_timing_finish() {
  [ "$TURN_TIMING_FINISHED" = 0 ] || return 0
  TURN_TIMING_FINISHED=1
  [ -n "$TURN_TIMING_SESSION" ] || return 0
  master_now_ms >/dev/null
  local elapsed=$((MASTER_NOW_MS - TURN_TIMING_STARTED))
  [ "$elapsed" -ge 0 ] || elapsed=0
  TURN_TIMING_ROWS=0
  turn_timing_row end "$EVENT" "$TURN_TIMING_STARTED" "$elapsed"
  # One locked append per dispatch; two 1 MiB generations at most.
  # Locks release on process death. Busy writers drop diagnostic samples.
  (umask 077; LC_ALL=C perl -e '
    use strict; use warnings; use Fcntl qw(:DEFAULT :flock);
    my $dir = shift; exit if -l $dir;
    mkdir $dir, 0700 unless -d $dir; exit unless -d $dir;
    my $lock = "$dir/lock"; exit if -l $lock || (-e $lock && !-f $lock);
    sysopen(my $guard, $lock, O_WRONLY|O_CREAT|O_NONBLOCK, 0600) or exit;
    exit unless -f $guard;
    flock($guard, LOCK_EX|LOCK_NB) or exit;
    my $file = "$dir/events.tsv"; my $old = "$file.1";
    exit if -l $file || -l $old || (-e $file && !-f $file) || (-e $old && !-f $old);
    local $/; my $data = <STDIN>; exit unless defined $data;
    exit if length($data) > 131072;
    my $size = -s $file || 0;
    if ($size + length($data) > 1048576) {
      rename $file, $old or exit if -e $file;
    }
    sysopen(my $out, $file, O_WRONLY|O_CREAT|O_APPEND|O_NONBLOCK, 0600) or exit;
    exit unless -f $out;
    print {$out} $data;
  ' "$REPO_ROOT/workspace/.turn-timing" <<<"$TURN_TIMING_BUFFER") >/dev/null 2>&1 || true
  return 0
}
