#!/bin/sh
# hqd-hook-shim.sh — thin hook client for hqd (hq-anywhere-runtime US-010).
#
# Registered by `hq install --global` in place of master-hook.sh when the hq
# daemon is installed. Reads one hook payload (Claude Code or Codex) on stdin,
# forwards it to hqd over its Unix socket with a 3000ms budget per attempt (one
# retry after a short backoff on a timeout or failed connect), and maps the
# answer onto the runtime hook contract:
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
#        HQ_HQD_SHIM_TIMEOUT_MS (per attempt, default 3000;
#        SessionEnd, whose hook budget is 3s, is capped at 1000 with no retry),
#        HQ_HQD_SHIM_RETRY_BACKOFF_MS (default 150).
# Worst case added latency is 2 x budget + backoff = 6.15s by default, inside
# the 300s PreToolUse hook budget registered by build-claude-plugin.sh and
# build-codex-pack.sh.
# POSIX sh; the JSON and socket work runs in perl (core JSON::PP and
# IO::Socket::UNIX, present on macOS and mainstream Linux).

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
# is capped, so two attempts always fit in the 300s hook budget.
budget="${HQ_HQD_SHIM_TIMEOUT_MS:-3000}"
case "$budget" in *[!0-9]*) budget=3000 ;; esac
while :; do case "$budget" in 0?*) budget=${budget#0} ;; *) break ;; esac; done
case "$budget" in ''|0) budget=3000 ;; esac
[ "${#budget}" -le 5 ] && [ "$budget" -le 60000 ] || budget=60000
backoff="${HQ_HQD_SHIM_RETRY_BACKOFF_MS:-150}"
case "$backoff" in ''|*[!0-9]*) backoff=150 ;; esac
while :; do case "$backoff" in 0?*) backoff=${backoff#0} ;; *) break ;; esac; done
[ "${#backoff}" -le 4 ] && [ "$backoff" -le 5000 ] || backoff=5000

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

# No perl: the payload cannot be parsed and hqd cannot be reached. A
# PreToolUse event may contain a relative company write that a string search
# cannot recognize, so fail closed for the whole event rather than guessing.
if ! command -v perl >/dev/null 2>&1 \
  || ! LC_ALL=C perl -MJSON::PP -MIO::Socket::UNIX -e 1 >/dev/null 2>&1; then
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
fi

# shellcheck disable=SC2016 # the perl program is single-quoted on purpose
out=$(printf '%s' "$payload" | HQD_SHIM_EVENT="$event" HQD_SHIM_RUNTIME="$runtime" \
  HQD_SHIM_SOCKET="$sock" HQD_SHIM_BUDGET_MS="$budget" HQD_SHIM_BACKOFF_MS="$backoff" LC_ALL=C perl -e '
use strict; use warnings;
use JSON::PP (); use IO::Socket::UNIX (); use Time::HiRes ();
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

# SessionEnd has a 3s hook budget: one short attempt, no retry.
my $budget_ms = 0 + ($ENV{HQD_SHIM_BUDGET_MS} // 0);
$budget_ms = 3000 unless $budget_ms > 0;
my $attempts = 2;
if ($event eq "SessionEnd") { $budget_ms = 1000 if $budget_ms > 1000; $attempts = 1; }
my $backoff_ms = 0 + ($ENV{HQD_SHIM_BACKOFF_MS} // 150);
$backoff_ms = 150 if $backoff_ms < 0;
my ($line, $fail);
for my $try (1 .. $attempts) {
  $line = undef; $fail = "";
  my $ok = eval {
    local $SIG{ALRM} = sub { die "timeout\n" };
    Time::HiRes::alarm($budget_ms / 1000);
    my $s = IO::Socket::UNIX->new(Type => IO::Socket::UNIX::SOCK_STREAM(), Peer => $ENV{HQD_SHIM_SOCKET})
      or die "connect\n";
    print {$s} $json->encode({ id => 1, op => $op, args => \%args }), "\n";
    $line = <$s>;
    Time::HiRes::alarm(0);
    close $s;
    defined $line or die "eof\n";
    1;
  };
  Time::HiRes::alarm(0);
  if ($ok) { $fail = ""; last; }
  my $err = $@ // "";
  $fail = $err =~ /^timeout/ ? "timeout" : $err =~ /^connect/ ? "connect" : "eof";
  # Retry once, only for a timeout (daemon busy) or a failed connect (daemon
  # restarting). An EOF is a daemon that already answered by closing.
  last if $try >= $attempts || $fail eq "eof";
  Time::HiRes::sleep($backoff_ms / 1000);
}
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
