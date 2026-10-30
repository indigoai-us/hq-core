#!/bin/bash
# block-raw-temp-home.sh — PreToolUse hook (Bash).
#
# Blocks commands that point HOME at a fresh mktemp folder and points to
# core/scripts/with-temp-home.sh instead.
#
# Why: sessions running tests under a raw `HOME=$(mktemp -d)`
# left ~45 GB of temp homes behind. Each fresh home re-downloaded the Rust
# toolchain and the pnpm store (1.4-1.8 GB per run) and was never deleted.
# The wrapper keeps the real caches and deletes the temp home on exit.
#
# Blocks, when HOME is assigned in command position (a prefix assignment, a
# plain assignment, or after export/env/local/declare):
#   - HOME=$(mktemp…), HOME="$(mktemp…)", HOME=`mktemp…`
#   - the same with assignments or env before mktemp: HOME=$(TMPDIR=/x mktemp -d),
#     HOME=$(env -i mktemp -d), HOME=$(cd /tmp && mktemp -d)
#   - the two-step form: T=$(mktemp -d); HOME=$T (also "$T", ${T}, $T/sub)
#   - read from mktemp output: read T < <(mktemp -d), read T <<< "$(mktemp -d)",
#     mktemp -d | while read T; …, while read T; … done < <(mktemp -d),
#     mapfile/readarray from mktemp, for T in $(mktemp -d), then HOME=$T
#   - cd into a temp dir, then HOME=$PWD or HOME=$(pwd)
#   - xargs fed by mktemp, also through cat or tee:
#     mktemp -d | xargs -I{} sh -c 'HOME={} cmd', or HOME=$1 in the script
#   - HOME from echo, printf, realpath or readlink of a temp value,
#     printf -v HOME, set -- $(mktemp -d) then HOME=$1, and HOME+=
#   - the same inside bash -c / sh -c / eval strings and $(…) substitutions
#   - the same after timeout, nice, sudo or env with options that take a
#     value (timeout 600, env -u NAME, env -C dir, sudo -u user, nice -n 5)
#   - the same across backslash line continuations, which bash removes
#     before it splits words
#
# Does not block text that only quotes the pattern: commit messages, grep
# patterns, echo arguments, heredoc bodies and comments. Words are split with
# shell quoting rules, so an argument is never read as an assignment.
#
# Escape hatch, for a run that must start with empty caches:
#   - HQ_ALLOW_RAW_TEMP_HOME=1 as a prefix assignment of the same command,
#     for example `HQ_ALLOW_RAW_TEMP_HOME=1 HOME=$(mktemp -d) cargo test`;
#   - `export HQ_ALLOW_RAW_TEMP_HOME=1` as an earlier statement;
#   - HQ_ALLOW_RAW_TEMP_HOME=1 in the hook's own environment.
# The text appearing anywhere else (an echo argument, a comment) does not count.
#
# The command is parsed with perl. Without perl the hook falls back to a
# plain pattern match in bash. It joins continuations, drops heredoc bodies
# and comment lines, and blocks the one-step and two-step forms where HOME
# follows a separator or a space. It still blocks the pattern inside quoted
# text that has a space before HOME, and it misses the read, cd and xargs
# forms.
#
# Fails open and silent when the payload cannot be read. Exit 2 blocks.
# The registry prefilter (`mktemp`) keeps this hook off every other command.
#
# Backs policy hq-temp-home-use-wrapper.

set -uo pipefail

STDIN_JSON="$(cat 2>/dev/null || echo '{}')"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=core/scripts/hook-lib.sh
. "$ROOT/core/scripts/hook-lib.sh" 2>/dev/null || exit 0

[ "${HQ_ALLOW_RAW_TEMP_HOME:-}" = "1" ] && exit 0

CMD="$(printf '%s' "$STDIN_JSON" | hq_json_get tool_input.command 2>/dev/null)" || CMD=""
[ -z "$CMD" ] && CMD="$(printf '%s' "$STDIN_JSON" | hq_json_get tool_input.cmd 2>/dev/null)" || true
[ -z "$CMD" ] && exit 0

# Exit 3 = raw temp HOME found, 0 = clean.
# shellcheck disable=SC2016
RAW_TEMP_HOME_PL='
use strict; use warnings;
our %taint; my $global_allow = 0;
# Set while analyzing a command that xargs feeds a temp path, so $1, $0 and
# $@ in its sh -c script count as temp.
our $pos_taint = 0;
# Options of a command word that take the next word as their value.
my %argopt=(env=>qr/^-[uCS]$|^--(?:unset|chdir|split-string)$/,
  sudo=>qr/^-[ugCDhpRrtTU]$|^--(?:user|group|close-from|chdir|host|prompt|chroot|role|type|other-user)$/,
  timeout=>qr/^-[sk]$|^--(?:signal|kill-after)$/, nice=>qr/^-n$|^--adjustment$/);

sub read_bt { my ($s,$i)=@_; my $n=length $s;
  while ($i<$n) { my $c=substr($s,$i,1);
    if ($c eq "\\") { $i+=2; next } return $i+1 if $c eq "`"; $i++ } return $n }
sub read_dq { my ($s,$i,$subs)=@_; my $n=length $s;
  while ($i<$n) { my $c=substr($s,$i,1);
    if ($c eq "\\") { $i+=2; next }
    return $i+1 if $c eq "\"";
    if ($c eq "\$" && substr($s,$i+1,1) eq "(") { my $j=read_subst($s,$i+2,$subs); $i=$j; next }
    if ($c eq "`") { my $j=read_bt($s,$i+1); push @$subs, substr($s,$i+1,$j-$i-2) if $subs; $i=$j; next }
    $i++ } return $n }
sub read_subst { my ($s,$i,$subs)=@_; my $start=$i; my $depth=1; my $n=length $s;
  while ($i<$n) { my $c=substr($s,$i,1);
    if ($c eq "\\") { $i+=2; next }
    if ($c eq "\x27") { my $j=index($s,"\x27",$i+1); $i=$j<0?$n:$j+1; next }
    if ($c eq "\"") { $i=read_dq($s,$i+1,undef); next }
    if ($c eq "`") { $i=read_bt($s,$i+1); next }
    if ($c eq "(") { $depth++ }
    elsif ($c eq ")") { $depth--; if (!$depth) { push @$subs, substr($s,$start,$i-$start) if $subs; return $i+1 } }
    $i++ }
  push @$subs, substr($s,$start) if $subs; return $n }

# Splits into segments of words. With $piped, $piped->[i] is 1 when segment i
# reads the previous segment through a pipe.
sub tokenize { my ($s,$subs,$piped)=@_; my @segs=([]); my @pl=(0); my $w; my @hd; my $n=length $s; my $i=0;
  my $flush=sub { if (defined $w) { push @{$segs[-1]}, $w; undef $w } };
  my $seg=sub { $flush->(); if (@{$segs[-1]}) { push @segs, []; push @pl, 0 } $pl[-1]=1 if $_[0] };
  while ($i<$n) { my $c=substr($s,$i,1);
    if ($c eq "\n") { $seg->(); $i++;
      while (@hd) { my ($d,$strip)=@{shift @hd};
        while ($i<$n) { my $e=index($s,"\n",$i); my $l=$e<0?substr($s,$i):substr($s,$i,$e-$i);
          $i=$e<0?$n:$e+1; $l=~s/^\t+// if $strip; last if $l eq $d } }
      next }
    if ($c eq " " || $c eq "\t") { $flush->(); $i++; next }
    if (($c eq "<" || $c eq ">") && substr($s,$i+1,1) eq "(") {
      $w //= ""; my $j=read_subst($s,$i+2,$subs); $w.=substr($s,$i,$j-$i); $i=$j; next }
    if ($c eq "|") { if (substr($s,$i+1,1) eq "|") { $seg->(0); $i+=2; next }
      $seg->(1); $i+=(substr($s,$i+1,1) eq "&")?2:1; next }
    if ($c =~ /[;&()]/) { $seg->(0); $i++; next }
    if ($c eq "#" && !defined $w) { my $e=index($s,"\n",$i); $i=$e<0?$n:$e; next }
    if (substr($s,$i,3) eq "<<<") { $flush->(); $w="<<<"; $i+=3; next }
    if ($c eq "<" && substr($s,$i,2) eq "<<" && substr($s,$i,3) ne "<<<") {
      $flush->(); $i+=2; my $strip=0; if (substr($s,$i,1) eq "-") { $strip=1; $i++ }
      $i++ while $i<$n && substr($s,$i,1) =~ /[ \t]/;
      my $st=$i;
      while ($i<$n && substr($s,$i,1) !~ /[\s;&|<>()]/) { my $d=substr($s,$i,1);
        if ($d eq "\x27") { my $j=index($s,"\x27",$i+1); $i=$j<0?$n:$j+1 }
        elsif ($d eq "\"") { $i=read_dq($s,$i+1,undef) } else { $i++ } }
      my $d=substr($s,$st,$i-$st); $d=~s/[\x27"\\]//g; push @hd, [$d,$strip] if length $d; next }
    if ($c eq "\\" && substr($s,$i+1,1) eq "\n") { $i+=2; next }
    $w //= "";
    if ($c eq "\\") { $w.=substr($s,$i,2); $i+=2; next }
    if ($c eq "\x27") { my $j=index($s,"\x27",$i+1); $j=$n-1 if $j<0; $w.=substr($s,$i,$j-$i+1); $i=$j+1; next }
    if ($c eq "\"") { my $j=read_dq($s,$i+1,$subs); $w.=substr($s,$i,$j-$i); $i=$j; next }
    if ($c eq "`") { my $j=read_bt($s,$i+1); push @$subs, substr($s,$i+1,$j-$i-2); $w.=substr($s,$i,$j-$i); $i=$j; next }
    if ($c eq "\$" && substr($s,$i+1,1) eq "(") { my $j=read_subst($s,$i+2,$subs); $w.=substr($s,$i,$j-$i); $i=$j; next }
    if ($c eq "\$" && substr($s,$i+1,1) eq "{") { my $j=index($s,"}",$i); $j=$n-1 if $j<0; $w.=substr($s,$i,$j-$i+1); $i=$j+1; next }
    $w.=$c; $i++ }
  $flush->(); @$piped=@pl if $piped; return @segs }

sub dequote { my ($r)=@_;
  return $1 if $r =~ /^\x27(.*)\x27$/s;
  if ($r =~ /^"(.*)"$/s) { my $v=$1; $v=~s/\\(["\\\$`])/$1/g; return $v }
  return $r }

# Skips prefix assignments and wrapper words. Returns the index of the command
# word and the assignments seen. A double-quoted NAME=value after env counts,
# because env sets it.
sub prefix { my ($w)=@_; my ($k,$kw,$cur,$dur,@as)=(0,0,"",0);
  while ($k<@$w) { my $x=$w->[$k];
    if ($x =~ /^([A-Za-z_][A-Za-z0-9_]*)\+?=(.*)$/s) { push @as,[$1,$2]; $k++; next }
    if ($cur eq "env" && $x =~ /^"([A-Za-z_][A-Za-z0-9_]*)=(.*)"$/s) { push @as,[$1,"\"$2\""]; $k++; next }
    if ($x =~ /^(?:export|local|declare|typeset|readonly|env|command|sudo|nohup|time|timeout|nice|exec|do|then|else|elif|if|while|until|!|\{|\})$/) { $kw=1; $cur=$x; $dur=($x eq "timeout"); $k++; next }
    if ($kw && $x =~ /^-/) { $k++; $k++ if $argopt{$cur} && $x =~ $argopt{$cur}; next }
    if ($dur && $x =~ /^[0-9]+(?:\.[0-9]+)?[smhd]?$/) { $dur=0; $k++; next }
    last }
  return ($k,\@as) }

sub cmdname { my $x=dequote($_[0]); $x=~s{.*/}{}; return $x }

# True when a segment prints a temp path: mktemp itself, pwd after a cd into
# a temp dir, or echo, printf, realpath or readlink of a temp value.
sub seg_out { my ($w)=@_; my ($k)=prefix($w); return 0 unless $k<@$w;
  my $cw=cmdname($w->[$k]);
  return 1 if $cw =~ /^g?mktemp$/;
  return 1 if $cw eq "pwd" && $taint{PWD};
  if ($cw =~ /^(?:echo|printf|realpath|readlink)$/) { for my $x (@$w[$k+1..$#$w]) { return 1 if is_temp($x) } }
  return 0 }
sub out_temp { my ($body)=@_; my @subs;
  for my $seg (tokenize($body,\@subs)) { return 1 if @$seg && seg_out($seg) } return 0 }

sub is_temp { my ($v)=@_;
  return 1 if $v =~ /(?:\$\(|`)\s*(?:(?:command|env)\s+|[A-Za-z_][A-Za-z0-9_]*=(?:"[^"]*"|\x27[^\x27]*\x27|[^\s"\x27]*)\s+)*(?:\S*\/)?mktemp(?:[\s)`]|$)/;
  if ($v =~ /^"?\$\{?([A-Za-z_][A-Za-z0-9_]*|[0-9@*])/) { my $n=$1;
    return 1 if $taint{$n} || ($pos_taint && $n =~ /^[0-9@*]$/) }
  if ($v =~ /\$\(|`/) { my @subs; tokenize($v,\@subs); for my $sub (@subs) { return 1 if out_temp($sub) } }
  return 0 }

# True when segment $si reads a temp path on stdin: from a pipe, a process
# substitution or a here-string. A pipe through cat, tee, head, tail, sort or
# uniq passes the temp path on.
sub input_temp { my ($segs,$pl,$si,$k)=@_; my $w=$segs->[$si];
  for my $j ($k+1..$#$w) { my $x=$w->[$j];
    return 1 if $x =~ /^<\((.*)\)$/s && out_temp($1);
    return 1 if $x eq "<<<" && $j<$#$w && is_temp($w->[$j+1]);
    return 1 if $x =~ /^<<<(.+)$/s && is_temp($1) }
  if ($pl->[$si]) { my $p=$si-1; $p-- while $p>=0 && !@{$segs->[$p]};
    if ($p>=0) { my $pw=$segs->[$p]; return 1 if seg_out($pw);
      my ($pk)=prefix($pw);
      return 1 if $pk<@$pw && cmdname($pw->[$pk]) =~ /^(?:cat|tee|head|tail|sort|uniq)$/ && input_temp($segs,$pl,$p,$pk) } }
  return 0 }

# xargs fed a temp path: put $(mktemp) in place of the -I/-J/-i placeholder
# and analyze the command xargs runs, with $1 and friends marked temp.
sub xargs_temp { my ($w,$k,$depth)=@_; my $j=$k+1; my $ph;
  while ($j<@$w) { my $x=dequote($w->[$j]);
    if ($x eq "--") { $j++; last }
    last unless $x =~ /^-/;
    if ($x =~ /^-[IJ]$/) { $ph=dequote($w->[$j+1] // ""); $j+=2; next }
    if ($x =~ /^-[IJ](.+)$/s) { $ph=$1; $j++; next }
    if ($x =~ /^(?:-i|--replace)(?:=?(.*))$/s) { $ph=length($1//"")?$1:"{}"; $j++; next }
    $j++; $j++ if $x =~ /^-[aEdLnPsRS]$|^--(?:arg-file|eof|delimiter|max-lines|max-args|max-procs|max-chars)$/ }
  return 0 unless $j<@$w;
  my $cmd=join(" ", @$w[$j..$#$w]);
  $cmd =~ s/\Q$ph\E/\$(mktemp)/g if defined $ph && length $ph;
  local $pos_taint=1;
  return analyze($cmd,$depth+1) }

sub analyze { my ($s,$depth)=@_; return 0 if $depth>4;
  my @subs; my @pl; my @segs=tokenize($s,\@subs,\@pl);
  for my $sub (@subs) { return 1 if analyze($sub,$depth+1) }
  # A loop fed by a temp path (done < <(mktemp -d)) feeds the reads inside it.
  my $loop_in=0;
  for my $si (0..$#segs) { my $w=$segs[$si]; $loop_in=1 if @$w && $w->[0] eq "done" && input_temp(\@segs,\@pl,$si,0) }
  for my $si (0..$#segs) { my @w=@{$segs[$si]}; next unless @w;
    my ($k,$asr)=prefix(\@w); my @as=@$asr;
    my $allow = $global_allow || scalar grep { $_->[0] eq "HQ_ALLOW_RAW_TEMP_HOME" && dequote($_->[1]) eq "1" } @as;
    for my $a (@as) { my ($name,$val)=@$a; my $t=is_temp($val);
      return 1 if $name eq "HOME" && $t && !$allow;
      $taint{$name}=1 if $t }
    $global_allow=1 if $k==@w && $w[0] eq "export" && grep { $_->[0] eq "HQ_ALLOW_RAW_TEMP_HOME" && dequote($_->[1]) eq "1" } @as;
    next unless $k<@w;
    my $cw=cmdname($w[$k]);
    if ($cw eq "cd" || $cw eq "pushd") {
      for my $x (@w[$k+1..$#w]) { next if $x =~ /^-/; if (is_temp($x)) { $taint{PWD}=1 } elsif ($x =~ m{^/}) { $taint{PWD}=0 } last } }
    elsif ($cw =~ /^(?:read|mapfile|readarray)$/) {
      next unless $loop_in || input_temp(\@segs,\@pl,$si,$k);
      my @names; my $j=$k+1;
      while ($j<@w) { my $x=$w[$j];
        last if $x =~ /^(?:[0-9]*[<>]|&>)/;
        # Options that take a value differ: read -t is a timeout, mapfile -t
        # takes none.
        if ($x =~ ($cw eq "read" ? qr/^-[dinNptu]$/ : qr/^-[dnOsuCc]$/)) { $j+=2; next }
        push @names, $x if $x =~ /^[A-Za-z_][A-Za-z0-9_]*$/; $j++ }
      @names=("REPLY","MAPFILE") unless @names;
      $taint{$_}=1 for @names }
    elsif (($cw eq "for" || $cw eq "select") && $k+2<@w && $w[$k+2] eq "in") {
      for my $x (@w[$k+3..$#w]) { if (is_temp($x)) { $taint{$w[$k+1]}=1; last } } }
    elsif ($cw eq "set") { for my $x (@w[$k+1..$#w]) { $pos_taint=1 if is_temp($x) } }
    elsif ($cw eq "printf" && $k+2<@w && $w[$k+1] eq "-v" && dequote($w[$k+2]) eq "HOME") {
      for my $x (@w[$k+3..$#w]) { return 1 if is_temp($x) && !$allow } }
    elsif ($cw eq "xargs") { return 1 if input_temp(\@segs,\@pl,$si,$k) && xargs_temp(\@w,$k,$depth) }
    elsif ($cw =~ /^(?:bash|sh|zsh|dash|ksh)$/) {
      for my $j ($k+1..$#w-1) { if ($w[$j] =~ /^-[A-Za-z]*c[A-Za-z]*$/) { return 1 if analyze(dequote($w[$j+1]),$depth+1); last } } }
    elsif ($cw eq "eval" && $k<$#w) { return 1 if analyze(join(" ", map { dequote($_) } @w[$k+1..$#w]),$depth+1) } }
  return 0 }

exit(analyze($ENV{HQ_RTH_CMD} // "", 0) ? 3 : 0);
'

# No-perl fallback: a pattern match over the command text, after joining
# continuations and dropping heredoc bodies and comment lines. Returns 0 when
# a raw temp HOME is found.
raw_temp_home_fallback() {
  local s="$1" bsnl=$'\\\n' text="" line l delim="" strip=0 rest name
  local names=" " d st hp dq sq
  local hd_re='(^|[^<])<<(-?)[[:space:]]*["'"'"']?([A-Za-z_][A-Za-z0-9_]*)'
  local pre='(^|[[:space:];&|({"])((export|local|declare|readonly)[[:space:]]+)?'
  local mk='"?(\$\(|`)[[:space:]]*(((env|command)([[:space:]]+-[^[:space:]]*)*|[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*)[[:space:]]+)*([^[:space:]]*/)?g?mktemp([[:space:])`]|$)'
  local as_re="${pre}([A-Za-z_][A-Za-z0-9_]*)\\+?=${mk}"
  s="${s//"$bsnl"/}"
  while IFS= read -r line || [ -n "$line" ]; do
    if [ -n "$delim" ]; then
      l="$line"
      [ "$strip" = 1 ] && l="${l#"${l%%[!	]*}"}"
      [ "$l" = "$delim" ] && delim=""
      continue
    fi
    case "${line#"${line%%[![:space:]]*}"}" in '#'*) continue ;; esac
    # A << inside quotes or after a comment # does not start a heredoc.
    if [[ $line =~ $hd_re ]]; then
      d="${BASH_REMATCH[3]}"; st=0; [ "${BASH_REMATCH[2]}" = "-" ] && st=1
      hp=" ${line%%<<*}"; dq="${hp//[!\"]/}"; sq="${hp//[!\']/}"
      case "$hp" in *[[:space:]]'#'*) ;; *)
        if [ $(( ${#dq} % 2 )) = 0 ] && [ $(( ${#sq} % 2 )) = 0 ]; then
          delim="$d"; strip="$st"
        fi ;;
      esac
    fi
    text="$text$line"$'\n'
  done <<< "$s"
  # One-step form, and names assigned from mktemp for the two-step form.
  rest="$text"
  while [[ $rest =~ $as_re ]]; do
    name="${BASH_REMATCH[4]}"
    [ "$name" = "HOME" ] && return 0
    names="$names$name "
    rest="${rest#*"${BASH_REMATCH[0]}"}"
  done
  for name in $names; do
    printf '%s' "$text" | grep -Eq "(^|[[:space:];&|({\"])HOME\\+?=\"?\\\$\\{?${name}([^A-Za-z0-9_]|\$)" && return 0
  done
  return 1
}

if command -v perl >/dev/null 2>&1; then
  rc=0
  HQ_RTH_CMD="$CMD" perl -e "$RAW_TEMP_HOME_PL" 2>/dev/null || rc=$?
  [ "$rc" -eq 3 ] || exit 0
else
  raw_temp_home_fallback "$CMD" || exit 0
fi

cat >&2 <<'EOF'
BLOCKED: raw temp HOME (HOME set from mktemp).

A fresh empty HOME makes Rust and pnpm re-download 1.4-1.8 GB per run, and
nothing deletes the folder afterwards. This fills the disk.

Use the wrapper instead. It shares the real caches and removes the temp
home when the command exits:

  bash core/scripts/with-temp-home.sh -- <command> [args...]

Inside the command the temp home is $HOME (also $HQ_TEMP_HOME).
Add --keep to leave it in place for debugging.

Need empty caches on purpose? Prefix the command itself with
HQ_ALLOW_RAW_TEMP_HOME=1 and delete the folder yourself when done.
EOF
exit 2
