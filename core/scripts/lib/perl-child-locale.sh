#!/usr/bin/env bash
# hq-core: public
# perl-child-locale.sh -- run perl under LC_ALL=C without leaking it to children.
#
# Why perl runs under LC_ALL=C: Apple's system Perl 5.34 exits 9 with
#   panic: locale.c: 4486: Could not change LC_CTYPE locale to C.utf8
# when it inherits LC_ALL or LANG set to C.utf8 (not installed on macOS; the
# installed name is C.UTF-8). Pinning LC_ALL=C on the perl command avoids that.
#
# The catch: a perl program that execs or spawns a child (timeout wrappers that
# do `alarm; exec`, process-group runners that fork) hands LC_ALL=C to that
# child. A hook run through such a wrapper then sees ${#var} count bytes, `${s:0:2}`
# split a multibyte character, and sort order change. So a perl program that
# starts a child must put the caller's locale back before it execs.
#
# hq_perl_spawn <perl-program> [args...]
#   Runs `perl -e <program> args...` under LC_ALL=C and, inside perl and before
#   the program body, restores the caller's LC_ALL (unset stays unset, set-but-
#   empty stays empty) and drops the two carrier variables. Use it for every
#   perl program that execs or forks. Perl programs that start no child keep the
#   plain `LC_ALL=C perl ...` prefix.
#   HQ_PERL_BIN overrides the perl binary (default: perl on PATH).
#
# hq_perl_spawn_argv <perl-program>
#   For callers that build a command array and run it later through `env` or
#   another exec (a shell function cannot be exec'd there). Sets the global
#   array HQ_PERL_SPAWN_ARGV to: env <carriers> LC_ALL=C perl -e <program>.
#   Append the perl program arguments, e.g.
#     hq_perl_spawn_argv 'alarm shift; exec {$ARGV[0]} @ARGV'
#     cmd=("${HQ_PERL_SPAWN_ARGV[@]}" "$seconds" "${cmd[@]}")
#
# Safe to source more than once. Compatible with bash 3.2.

# shellcheck shell=bash

# Perl source prepended to the caller's program.
# shellcheck disable=SC2016 # perl program, single quotes on purpose
HQ_PERL_RESTORE_LOCALE='if ($ENV{HQ_PERL_LC_ALL_SET}) { $ENV{LC_ALL} = $ENV{HQ_PERL_LC_ALL}; } else { delete $ENV{LC_ALL}; } delete @ENV{qw(HQ_PERL_LC_ALL HQ_PERL_LC_ALL_SET)}; '

hq_perl_spawn() {
  local hq_perl_program="${1-}"
  shift || true
  # LC_ALL=C comes last on purpose: the carriers read the caller's LC_ALL first.
  # shellcheck disable=SC2097,SC2098
  HQ_PERL_LC_ALL="${LC_ALL-}" HQ_PERL_LC_ALL_SET="${LC_ALL+1}" LC_ALL=C \
    "${HQ_PERL_BIN:-perl}" -e "${HQ_PERL_RESTORE_LOCALE}${hq_perl_program}" "$@"
}

hq_perl_spawn_argv() {
  # shellcheck disable=SC2034 # read by the caller
  HQ_PERL_SPAWN_ARGV=(
    env "HQ_PERL_LC_ALL=${LC_ALL-}" "HQ_PERL_LC_ALL_SET=${LC_ALL+1}" LC_ALL=C
    "${HQ_PERL_BIN:-perl}" -e "${HQ_PERL_RESTORE_LOCALE}${1-}"
  )
}
