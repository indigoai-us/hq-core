#!/bin/sh
# hqd-hook-shim.sh — thin hook client for hqd (hq-anywhere-runtime US-010).
#
# Registered by `hq install --global` in place of master-hook.sh when the hq
# daemon is installed. Reads one hook payload (Claude Code or Codex) on stdin,
# forwards it to hqd over its Unix socket within one 3000ms budget, and maps
# the answer onto the runtime hook contract:
#   block   -> reasons on stderr, exit 2
#   context -> {"hookSpecificOutput":{"hookEventName":..,"additionalContext":..}}
#
# Ops: SessionStart -> session.open, PreToolUse -> policy.check,
#      SessionEnd -> session.close, every other event -> session.get.
#
# Daemon cannot answer: print exactly one stderr line naming the cause, then
#   timed out (busy)   "HQ daemon timed out after N ms (daemon busy) ..."
#   connect failed     "HQ daemon unreachable: could not connect (daemon not running) ..."
#   EOF / bad reply    "HQ daemon unreachable: connection closed or unreadable reply ..."
# and
#   PreToolUse writing a companies/ path -> exit 2 (never allow-by-default)
#   SessionStart                         -> bind personal (context), exit 0
#   anything else                        -> exit 0
#
# Usage: sh hqd-hook-shim.sh [Event] [--runtime claude|codex]
#   Event defaults to the payload's hook_event_name.
# Env:   HQ_HQD_SOCKET (socket path), HQ_REGISTRY_DIR (parent of daemon/),
#        HQ_HQD_SHIM_TIMEOUT_MS (whole budget, default 3000; SessionEnd,
#        whose hook budget is 3s, is capped at 1000),
#        HQ_HQD_SHIM_DEADLINE_MS (optional epoch-ms deadline from the caller,
#        e.g. master-hook; the budget shrinks to the time left before it),
#        HQ_HQD_SHIM_RETRY_BACKOFF_MS (default 150).
# One attempt: a timeout is never retried. Only a refused connect (daemon
# restarting) is tried again after the backoff, and only inside the same
# budget. Socket I/O is non-blocking with select() deadlines, so a daemon that
# accepts and then stops reading cannot hold the shim: Perl's deferred signals
# do not interrupt a write() that already sent part of a payload larger than
# the socket buffer (8 KB on macOS), so an alarm-only timeout could hang until
# the daemon read again. As a last resort a hard timer with the default
# SIGALRM action kills perl 250 ms after the budget, even while it is still
# loading modules.
# The daemon call (perl client) takes at most the budget + 250 ms (3.25 s by
# default); sh start-up and the module probe come on top of that.
# POSIX sh; the JSON and socket work runs in perl (core JSON::PP, Socket,
# Fcntl, Errno and Time::HiRes, present on macOS and mainstream Linux).

UNREACHABLE='HQ daemon unreachable: run hq daemon status'
CONNECT_FAIL='HQ daemon unreachable: could not connect (daemon not running): run hq daemon status'
SESSION_FALLBACK='{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"HQ session bound to company: personal (hqd unreachable; fail-closed default)"}}'

event=''
runtime="${HQ_HOOK_RUNTIME:-}"
if [ -z "$runtime" ]; then
  case "$0" in */codex-hook-shim.sh) runtime=codex ;; *) runtime=claude ;; esac
fi
while [ $# -gt 0 ]; do
  case "$1" in
    --runtime) runtime="${2:-claude}"; [ $# -ge 2 ] && shift; shift ;;
    --runtime=*) runtime="${1#--runtime=}"; shift ;;
    *) [ -z "$event" ] && event="$1"; shift ;;
  esac
done

if [ -n "${HQ_HQD_SOCKET:-}" ]; then
  sock="$HQ_HQD_SOCKET"
elif [ -n "${HQ_REGISTRY_DIR:-}" ]; then
  sock="$HQ_REGISTRY_DIR/daemon/hqd.sock"
else
  sock="${HOME:-}/.hq/daemon/hqd.sock"
fi
# Normalize numerically: "0", "00", "000" must not reach perl as a true string
# whose alarm(0) disables the timeout (a hung daemon would then outlast the
# hook budget, which Claude Code treats as non-blocking). A value above 60000 ms
# is capped, so the one attempt always fits in the 300s hook budget.
budget="${HQ_HQD_SHIM_TIMEOUT_MS:-3000}"
case "$budget" in *[!0-9]*) budget=3000 ;; esac
while :; do case "$budget" in 0?*) budget=${budget#0} ;; *) break ;; esac; done
case "$budget" in ''|0) budget=3000 ;; esac
[ "${#budget}" -le 5 ] && [ "$budget" -le 60000 ] || budget=60000
backoff="${HQ_HQD_SHIM_RETRY_BACKOFF_MS:-150}"
case "$backoff" in ''|*[!0-9]*) backoff=150 ;; esac
while :; do case "$backoff" in 0?*) backoff=${backoff#0} ;; *) break ;; esac; done
[ "${#backoff}" -le 4 ] && [ "$backoff" -le 5000 ] || backoff=5000
# Caller deadline (epoch ms). Anything that is not a plain 13-16 digit number
# is ignored, so a bad value can only leave the default budget in place.
deadline="${HQ_HQD_SHIM_DEADLINE_MS:-}"
case "$deadline" in
  *[!0-9]*) deadline='' ;;
  ?????????????|??????????????|???????????????|????????????????) ;;
  *) deadline='' ;;
esac

payload=''
while IFS= read -r payload_line || [ -n "$payload_line" ]; do
  payload=$payload$payload_line
  payload_line=''
done

# The shim follows the HQ Anywhere flag reader's default-on fail-safe. The
# local false/0 override keeps the shim inert; unreachable company writes remain blocked.
case "$0" in */*) SHIM_DIR=${0%/*} ;; *) SHIM_DIR=. ;; esac
if [ ! -f "$SHIM_DIR/hq-anywhere-runtime-flag.cjs" ] \
  || [ ! -f "$SHIM_DIR/hqd-hook-flag-cache-lib.sh" ]; then
  exit 0
fi
# shellcheck disable=SC2034 # The sourced flag-cache library uses this path.
FLAG_DIR=$SHIM_DIR
. "$SHIM_DIR/hqd-hook-flag-cache-lib.sh"
hqd_hook_flag_enabled
[ "$HQD_FLAG_ENABLED" = true ] || exit 0

# hqd runs only for people who turned HQ Anywhere on (hq-cli
# anywhereRuntimeAllowed: flag on AND person setting true). With no socket and
# no daemon "hqd.enabled" marker beside it, hqd is not meant to run on this
# machine, so there is nothing to enforce through it: stay inert. A socket file
# (live or stale) or the marker means hqd should answer, so an unreachable
# daemon still fails closed below.
if [ ! -e "$sock" ] && [ ! -e "${sock%/*}/hqd.enabled" ]; then
  exit 0
fi

# No usable perl (missing, or without the core modules the client loads): the
# payload cannot be parsed and hqd cannot be reached. A PreToolUse event may
# contain a relative company write that a string search cannot recognize, so
# fail closed for the whole event rather than guessing. The probe loads the
# same modules as the client perl below.
no_perl_fallback() {
  [ "${HQ_HQD_SHIM_REPORT_UNREACHABLE:-0}" != 1 ] || exit 75
  if [ -z "$event" ]; then
    # Codex invokes one shim command for all events without passing the event
    # as argv. Recover the event from the JSON text when Perl is unavailable.
    # This is deliberately a string match: parsing JSON here would require the
    # unavailable dependency we're handling.
    event_field=''
    case "$payload" in
      *'"hook_event_name"'*)
        event_field=${payload#*'"hook_event_name"'}
        case "$event_field" in *:*) event_field=${event_field#*:} ;; *) event_field='' ;; esac
        while [ -n "$event_field" ]; do
          case "$event_field" in [[:space:]]*) event_field=${event_field#?} ;; *) break ;; esac
        done
        case "$event_field" in
          '"PreToolUse"'*) event=PreToolUse ;;
          '"SessionStart"'*) event=SessionStart ;;
          '"UserPromptSubmit"'*) event=UserPromptSubmit ;;
          '"PostToolUse"'*) event=PostToolUse ;;
          '"Stop"'*) event=Stop ;;
          '"SessionEnd"'*) event=SessionEnd ;;
        esac ;;
    esac
  fi
  if [ -z "$event" ]; then
    case "$payload" in
      *'"tool_name"'*|*companies/*) event=PreToolUse ;;
    esac
  fi
  printf '%s\n' "$UNREACHABLE" >&2
  case "$event" in
    PreToolUse) exit 2 ;;
  esac
  exit 0
}
if ! command -v perl >/dev/null 2>&1 \
  || ! LC_ALL=C perl -MJSON::PP -MTime::HiRes -MSocket -MErrno -MFcntl -e 1 >/dev/null 2>&1; then
  no_perl_fallback
fi

# shellcheck disable=SC2016 # the perl program is single-quoted on purpose
out=$(printf '%s' "$payload" | HQD_SHIM_EVENT="$event" HQD_SHIM_RUNTIME="$runtime" \
  HQD_SHIM_SOCKET="$sock" HQD_SHIM_BUDGET_MS="$budget" HQD_SHIM_BACKOFF_MS="$backoff" \
  HQD_SHIM_DEADLINE_MS="$deadline" LC_ALL=C perl -e '
# Budget first, before any module loads, so the hard timer below covers them.
# The effective budget is the configured one (SessionEnd: at most 1000 ms),
# cut to the time left before the caller deadline when one is given.
our ($BUDGET_MS, $DEADLINE);
BEGIN {
  eval { require Time::HiRes; 1 } or exit 76;
  my $ev = $ENV{HQD_SHIM_EVENT} // "";
  $BUDGET_MS = 0 + ($ENV{HQD_SHIM_BUDGET_MS} // 0);
  $BUDGET_MS = 3000 unless $BUDGET_MS > 0;
  $BUDGET_MS = 1000 if $ev eq "SessionEnd" && $BUDGET_MS > 1000;
  my $now_ms = Time::HiRes::time() * 1000;
  my $dl = $ENV{HQD_SHIM_DEADLINE_MS} // "";
  if ($dl =~ /^[0-9]{13,16}\z/) {
    my $left = $dl - $now_ms;
    $BUDGET_MS = $left if $left < $BUDGET_MS;
    $BUDGET_MS = 0 if $BUDGET_MS < 0;
  }
  $DEADLINE = ($now_ms + $BUDGET_MS) / 1000;
  # Hard bound: the default SIGALRM action ends the process in the kernel, so
  # it fires even inside a blocked system call or a slow module load, where a
  # Perl-level handler (deferred signals) may never get to run.
  $SIG{ALRM} = "DEFAULT";
  Time::HiRes::alarm(($BUDGET_MS + 250) / 1000);
  for my $m (qw(JSON/PP.pm Socket.pm Errno.pm Fcntl.pm)) { eval { require $m; 1 } or exit 76; }
}
use strict; use warnings;
use JSON::PP (); use Socket (); use Errno ();
use Fcntl qw(F_GETFL F_SETFL O_NONBLOCK);
$SIG{PIPE} = "IGNORE";
my $json = JSON::PP->new->canonical;
my $payload = do { local $/; <STDIN> } // "";
my $p = eval { $json->decode($payload) };
$p = {} unless ref $p eq "HASH";
my $event = $ENV{HQD_SHIM_EVENT} || $p->{hook_event_name} || "";
my $runtime = $ENV{HQD_SHIM_RUNTIME} || "claude";
my $sid = $p->{session_id} // "";
my $cwd = $p->{cwd} // "";
my $tool = $p->{tool_name} // "";
my $input = ref $p->{tool_input} eq "HASH" ? $p->{tool_input} : {};
# A SessionEnd named only in the payload (Codex passes no argv) gets the same
# 1000 ms cap as one named on the command line.
if ($event eq "SessionEnd" && $BUDGET_MS > 1000) {
  $DEADLINE -= ($BUDGET_MS - 1000) / 1000;
  $BUDGET_MS = 1000;
  my $left = $DEADLINE - Time::HiRes::time();
  Time::HiRes::alarm(($left > 0 ? $left : 0) + 0.25);
}

# True when this tool call writes (or may write) a companies/ path.
sub absolute_path {
  my ($candidate, $base) = @_;
  my $path = $candidate =~ m{^/} ? $candidate : ($base || "/") . "/" . $candidate;
  my @parts;
  for my $part (split m{/+}, $path) {
    next if $part eq "" || $part eq ".";
    if ($part eq "..") { pop @parts if @parts; next; }
    push @parts, $part;
  }
  return "/" . join("/", @parts);
}
sub company_write {
  return 0 unless $tool =~ /^(?:Write|Edit|MultiEdit|NotebookEdit|apply_patch|Bash|shell|exec_command)$/;
  my @s = grep { defined && !ref } map { $input->{$_} } qw(file_path path notebook_path command cmd patch input);
  push @s, grep { defined && !ref } @{ $input->{command} } if ref $input->{command} eq "ARRAY";
  my $cwd = $p->{cwd} // "/";
  sub is_company_path {
    my ($candidate, $base) = @_;
    return 0 unless defined $candidate && !ref $candidate && length $candidate;
    my $absolute = absolute_path($candidate, $base);
    return $absolute =~ m{(?:^|/)companies/[^/]+(?:/|$)} ? 1 : 0;
  }
  for my $s (@s) {
    return 1 if $s =~ /(?:^|[\s\/"=])companies\//;
    return 1 if is_company_path($s, $cwd);
    next unless $tool =~ /^(?:Bash|shell|exec_command)$/;
    my $shell_cwd = $cwd;
    for my $segment (split /(?:&&|\|\||;|\n)/, $s) {
      if ($segment =~ /^\s*(?:builtin\s+)?cd\s+(?:--\s+)?(?:\x27([^\x27]*)\x27|"([^"]*)"|(\S+))/) {
        my $target = defined $1 ? $1 : defined $2 ? $2 : $3;
        $shell_cwd = absolute_path($target, $shell_cwd);
        return 1 if $shell_cwd =~ m{(?:^|/)companies$};
        return 1 if $shell_cwd =~ m{(?:^|/)companies/[^/]+(?:/|$)};
      }
    }
  }
  return 1 if $tool =~ /^(?:Bash|shell|exec_command)$/ && is_company_path($cwd, "/");
  return 0;
}

my %ctx_events = (SessionStart => 1, UserPromptSubmit => 1, PreToolUse => 1, PostToolUse => 1);
sub emit_context {
  my ($ctx) = @_;
  return unless defined $ctx && length $ctx && $ctx_events{$event};
  print $json->encode({ hookSpecificOutput => { hookEventName => $event, additionalContext => $ctx } });
}

# Exit protocol back to sh: 0 done, 2 block (stderr already written),
# 10/11/12 = could not connect, 20/21/22 = timed out, 30/31/32 = closed or
# unreadable reply; within each group: +0 company write (fail closed),
# +1 SessionStart, +2 anything else.
sub unreachable {
  my ($base) = @_;
  exit 75 if ($ENV{HQ_HQD_SHIM_REPORT_UNREACHABLE} // "") eq "1";
  exit $base if $event eq "PreToolUse" && company_write();
  exit $base + 1 if $event eq "SessionStart";
  exit $base + 2;
}

my ($op, %args);
if ($event eq "SessionStart") {
  $op = "session.open";
  %args = (runtime => $runtime, sessionId => ($sid || "unknown"), cwd => ($cwd || "/"));
} elsif ($event eq "PreToolUse") {
  $op = "policy.check";
  %args = (runtime => $runtime, event => $event, tool => ($tool || "unknown"), input => $input);
  $args{sessionId} = $sid if length $sid;
  $args{cwd} = $cwd if length $cwd;
} elsif ($event eq "SessionEnd") {
  $op = "session.close";
  %args = (runtime => $runtime, sessionId => ($sid || "unknown"));
} else {
  $op = "session.get";
  %args = (runtime => $runtime);
  $args{sessionId} = $sid if length $sid;
}

# One attempt inside one deadline ($DEADLINE, set in BEGIN). All socket I/O is
# non-blocking and waits in select() for at most the time left, so no system
# call can outlast the budget. A refused connect is the only case tried again
# (daemon restarting), after the backoff and only if time is left; a timeout is
# never retried. SessionEnd (3s hook budget) never retries.
my $budget_ms = $BUDGET_MS;
my $backoff_ms = 0 + ($ENV{HQD_SHIM_BACKOFF_MS} // 150);
$backoff_ms = 150 if $backoff_ms < 0;
my $connect_tries = $event eq "SessionEnd" ? 1 : 2;
sub time_left { my $t = $DEADLINE - Time::HiRes::time(); return $t > 0 ? $t : 0; }
# wait_io(<socket>, "r"|"w") -> 1 when ready, 0 when the deadline passed.
sub wait_io {
  my ($s, $dir) = @_;
  while (1) {
    my $left = time_left();
    return 0 if $left <= 0;
    my $bits = ""; vec($bits, fileno($s), 1) = 1;
    my ($r, $w) = $dir eq "r" ? ($bits, undef) : (undef, $bits);
    my $n = select($r, $w, undef, $left);
    return 1 if $n > 0;
    next if $n < 0 && $!{EINTR};
    return 0 if $n == 0;
    die "eof\n";
  }
}
sub hqd_request {
  my ($request) = @_;
  die "timeout\n" if time_left() <= 0;
  my $addr = Socket::pack_sockaddr_un($ENV{HQD_SHIM_SOCKET} // "");
  my $s;
  while (1) {
    socket($s, Socket::AF_UNIX(), Socket::SOCK_STREAM(), 0) or die "connect\n";
    my $flags = fcntl($s, F_GETFL, 0) or die "connect\n";
    fcntl($s, F_SETFL, $flags | O_NONBLOCK) or die "connect\n";
    last if connect($s, $addr);
    if ($!{EINPROGRESS} || $!{EINTR}) {
      wait_io($s, "w") or die "timeout\n";
      my $soerr = getsockopt($s, Socket::SOL_SOCKET(), Socket::SO_ERROR());
      die "connect\n" if !defined $soerr || unpack("i", $soerr) != 0;
      last;
    }
    # Linux answers EAGAIN, with the socket left unconnected, while the
    # daemon listen backlog is full; a blocking connect would wait for a
    # slot. Wait the same way, in short steps, until the deadline.
    die "connect\n" unless $!{EAGAIN} || $!{EWOULDBLOCK};
    close $s;
    die "timeout\n" if time_left() <= 0.02;
    Time::HiRes::sleep(0.02);
  }
  my $off = 0;
  while ($off < length $request) {
    my $n = syswrite($s, $request, length($request) - $off, $off);
    if (defined $n) { $off += $n; next; }
    die "eof\n" unless $!{EAGAIN} || $!{EWOULDBLOCK} || $!{EINTR};
    wait_io($s, "w") or die "timeout\n";
  }
  my $buf = "";
  while (index($buf, "\n") < 0) {
    my $n = sysread($s, $buf, 65536, length $buf);
    if (defined $n) {
      next if $n > 0;
      die "eof\n" unless length $buf;
      close $s;
      return $buf;    # reply without a trailing newline, as <$s> returned it
    }
    die "eof\n" unless $!{EAGAIN} || $!{EWOULDBLOCK} || $!{EINTR};
    wait_io($s, "r") or die "timeout\n";
  }
  close $s;
  return substr($buf, 0, index($buf, "\n") + 1);
}
my $request = $json->encode({ id => 1, op => $op, args => \%args }) . "\n";
my ($line, $fail);
for my $try (1 .. $connect_tries) {
  $line = eval { hqd_request($request) };
  my $err = defined $line ? "" : ($@ // "");
  $fail = $err eq "" ? "" : $err =~ /^timeout/ ? "timeout" : $err =~ /^connect/ ? "connect" : "eof";
  last unless $fail eq "connect" && $try < $connect_tries;
  last if time_left() * 1000 <= $backoff_ms;
  Time::HiRes::sleep($backoff_ms / 1000);
}
# The socket work is over and the rest is local, so stop the hard timer.
Time::HiRes::alarm(0);
if ($fail eq "timeout") { print int($budget_ms); unreachable(20); }
elsif ($fail eq "connect") { unreachable(10); }
elsif ($fail) { unreachable(30); }

my $r = eval { $json->decode($line) };
unreachable(30) unless ref $r eq "HASH";

if (!$r->{ok}) {
  my $msg = ref $r->{error} eq "HASH" ? ($r->{error}{message} // "error") : "error";
  if ($event eq "PreToolUse" && company_write()) {
    print STDERR "HQ policy check failed ($msg); refusing a write to a companies/ path\n";
    exit 2;
  }
  print STDERR "HQ daemon: $op failed: $msg\n";
  exit 0;
}
my $res = ref $r->{result} eq "HASH" ? $r->{result} : {};

if ($event eq "SessionStart") {
  my $co = ref $res->{session} eq "HASH" ? $res->{session}{company} : $res->{company};
  emit_context("HQ session bound to company: " . ($co // "personal") . " (via hqd)");
} elsif ($event eq "PreToolUse") {
  my $decision = $res->{decision} // "";
  if ($decision eq "block") {
    my @why = ref $res->{reasons} eq "ARRAY" ? @{ $res->{reasons} } : ();
    print STDERR join("\n", @why ? @why : ("blocked by HQ policy")), "\n";
    exit 2;
  }
  if ($decision ne "allow") {
    if (company_write()) {
      print STDERR "HQ policy check failed (invalid decision); refusing a write to a companies/ path\n";
      exit 2;
    }
    print STDERR "HQ daemon: policy.check returned an invalid decision\n";
    exit 0;
  }
  emit_context($res->{additionalContext});
}
exit 0;
')
rc=$?
# 76: a client module failed to load although the probe passed. The daemon
# was not consulted; master-hook falls back, other callers get the same
# answer as for a perl that died.
if [ "$rc" = 76 ]; then
  [ "${HQ_HQD_SHIM_REPORT_UNREACHABLE:-0}" != 1 ] || exit 75
  rc=255
fi

case "$rc" in
  0)
    [ -n "$out" ] && printf '%s\n' "$out"
    exit 0 ;;
  2) exit 2 ;;
  75) exit 75 ;;
  10|11|12)
    printf '%s\n' "$CONNECT_FAIL" >&2
    [ "$rc" = 11 ] && printf '%s\n' "$SESSION_FALLBACK"
    [ "$rc" = 10 ] && exit 2
    exit 0 ;;
  20|21|22)
    printf 'HQ daemon timed out after %s ms (daemon busy); retry in a few seconds, see ~/.hq/daemon/logs/daemon.log if it persists (hq daemon status only checks the PID)\n' "${out:-$budget}" >&2
    [ "$rc" = 21 ] && printf '%s\n' "$SESSION_FALLBACK"
    [ "$rc" = 20 ] && exit 2
    exit 0 ;;
  30|31|32)
    printf '%s\n' 'HQ daemon unreachable: connection closed or unreadable reply (daemon restarting?); retry, see ~/.hq/daemon/logs/daemon.log' >&2
    [ "$rc" = 31 ] && printf '%s\n' "$SESSION_FALLBACK"
    [ "$rc" = 30 ] && exit 2
    exit 0 ;;
  142)
    # The hard timer (SIGALRM, default action) ended perl past its budget, so
    # this is a timeout. The parsed payload is gone: judge a company write by
    # string match, as for a perl that died.
    [ "${HQ_HQD_SHIM_REPORT_UNREACHABLE:-0}" != 1 ] || exit 75
    printf 'HQ daemon timed out after %s ms (daemon busy); retry in a few seconds, see ~/.hq/daemon/logs/daemon.log if it persists (hq daemon status only checks the PID)\n' "$budget" >&2
    if [ -z "$event" ]; then
      case "$payload" in *'"PreToolUse"'*) event=PreToolUse ;; *'"SessionStart"'*) event=SessionStart ;; esac
    fi
    [ "$event" = SessionStart ] && printf '%s\n' "$SESSION_FALLBACK"
    if [ "$event" = PreToolUse ]; then
      case "$payload" in *companies*) exit 2 ;; esac
    fi
    exit 0 ;;
  *)
    # Perl died or exited with an unexpected code (255, a signal): the daemon
    # was not consulted. Fail closed for a PreToolUse that may touch companies/,
    # judged by string match since the parsed payload is gone.
    printf '%s\n' "$UNREACHABLE" >&2
    if [ -z "$event" ]; then
      case "$payload" in *'"PreToolUse"'*) event=PreToolUse ;; esac
    fi
    if [ "$event" = PreToolUse ]; then
      case "$payload" in *companies*) exit 2 ;; esac
    fi
    exit 0 ;;
esac
