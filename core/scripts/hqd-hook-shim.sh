#!/bin/sh
# hqd-hook-shim.sh — thin hook client for hqd (hq-anywhere-runtime US-010).
#
# Registered by `hq install --global` in place of master-hook.sh when the hq
# daemon is installed. Reads one hook payload (Claude Code or Codex) on stdin,
# forwards it to hqd over its Unix socket with a 500ms budget, and maps the
# answer onto the runtime hook contract:
#   block   -> reasons on stderr, exit 2
#   context -> {"hookSpecificOutput":{"hookEventName":..,"additionalContext":..}}
#
# Ops: SessionStart -> session.open, PreToolUse -> policy.check,
#      SessionEnd -> session.close, every other event -> session.get.
#
# Daemon unreachable (no socket, refused, or past the budget): print exactly
# one stderr line "HQ daemon unreachable: run hq daemon status", then
#   PreToolUse writing a companies/ path -> exit 2 (never allow-by-default)
#   SessionStart                         -> bind personal (context), exit 0
#   anything else                        -> exit 0
#
# Usage: sh hqd-hook-shim.sh [Event] [--runtime claude|codex]
#   Event defaults to the payload's hook_event_name.
# Env:   HQ_HQD_SOCKET (socket path), HQ_REGISTRY_DIR (dir holding hqd.sock),
#        HQ_HQD_SHIM_TIMEOUT_MS (default 500).
# POSIX sh; the JSON and socket work runs in perl (core JSON::PP and
# IO::Socket::UNIX, present on macOS and mainstream Linux).

UNREACHABLE='HQ daemon unreachable: run hq daemon status'

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
  sock="$HQ_REGISTRY_DIR/hqd.sock"
else
  sock="${HOME:-}/.hq/hqd.sock"
fi
budget="${HQ_HQD_SHIM_TIMEOUT_MS:-500}"
case "$budget" in ''|*[!0-9]*) budget=500 ;; esac

payload=''
while IFS= read -r payload_line || [ -n "$payload_line" ]; do
  payload=$payload$payload_line
  payload_line=''
done

# The shim is inert until the hq-flags gate is explicitly enabled. Lookup
# failures default off; no environment variable can turn this feature on.
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

# No perl: the payload cannot be parsed and hqd cannot be reached. A
# PreToolUse event may contain a relative company write that a string search
# cannot recognize, so fail closed for the whole event rather than guessing.
if ! command -v perl >/dev/null 2>&1 \
  || ! perl -MJSON::PP -MIO::Socket::UNIX -e 1 >/dev/null 2>&1; then
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
  HQD_SHIM_SOCKET="$sock" HQD_SHIM_BUDGET_MS="$budget" perl -e '
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
# 10 unreachable + company write, 11 unreachable + SessionStart, 12 unreachable.
sub unreachable {
  exit 75 if ($ENV{HQ_HQD_SHIM_REPORT_UNREACHABLE} // "") eq "1";
  exit 10 if $event eq "PreToolUse" && company_write();
  exit 11 if $event eq "SessionStart";
  exit 12;
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

my $line;
my $ok = eval {
  local $SIG{ALRM} = sub { die "timeout\n" };
  Time::HiRes::alarm(($ENV{HQD_SHIM_BUDGET_MS} || 500) / 1000);
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
unreachable() unless $ok;

my $r = eval { $json->decode($line) };
unreachable() unless ref $r eq "HASH";

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
  10)
    printf '%s\n' "$UNREACHABLE" >&2
    exit 2 ;;
  11)
    printf '%s\n' "$UNREACHABLE" >&2
    printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"HQ session bound to company: personal (hqd unreachable; fail-closed default)"}}'
    exit 0 ;;
  *)
    printf '%s\n' "$UNREACHABLE" >&2
    exit 0 ;;
esac
