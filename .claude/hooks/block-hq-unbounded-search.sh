#!/bin/bash
# hq-core: public
# block-hq-unbounded-search.sh — PreToolUse hook (Bash).
#
# Denies an unbounded recursive search rooted at the HQ root or at workspace
# itself: `find` without -maxdepth, and grep with -r, -R, --recursive or
# -d recurse. Forms covered: absolute paths, relative paths against the payload
# cwd (`find .`, `find workspace`, `grep -r x workspace`), no path at all (both
# default to the cwd), a literal `cd` earlier in the command, and commands in a
# compound, pipeline, $(...), backticks, <(...), sh -c or eval.
#
# Why: an unbounded `find <HQ>/workspace -name ...` runs the bundled bfs behind
# the shell `find`. One such run used 2.6-4.5 cores for about 3 minutes over at
# least 795,688 entries. bfs ignores .ignore, which only serves ripgrep.
# block-hq-glob guards the Glob tool only.
#
# Not denied: a subfolder root (`find workspace/reports -name x`), any find with
# -maxdepth, non-recursive grep, paths outside HQ, rg, and the words inside
# quoted text, comments or heredoc bodies. Words are split with shell quoting
# rules, so an echo argument or commit message is never read as a command.
#
# A path the parser cannot resolve (an unknown variable, a glob other than a
# trailing /*, a `cd` to either) passes. So do commands the shell only sees at
# run time: a script file, `python -c`, or a heredoc fed to a shell.
#
# This is a performance guard, not a security control. It fails open: bad JSON,
# a missing jq or perl, a parser crash, an oversized command, or a parse over
# 2 s all exit 0, because a crash here must not block every Bash call. It is
# deliberately not `safety` or `fail_closed` in the registry, so a timeout also
# passes. The registry prefilter (`find|grep|bfs`) keeps it off other commands.
# Exit 2 denies.
#
# jq extracts the fields once and hands them to perl on stdin, so a large
# command never meets an argv or env limit.

set -u

_uss_dir="${BASH_SOURCE[0]%/*}"
[ "$_uss_dir" = "${BASH_SOURCE[0]}" ] && _uss_dir=.
# Logical and physical root, plus HQ_ROOT when an adapter sets one.
HQ_USS_ROOTS="$(cd "$_uss_dir/../.." 2>/dev/null && pwd && pwd -P)" || exit 0
[ -n "${HQ_ROOT:-}" ] && HQ_USS_ROOTS="$HQ_USS_ROOTS
$HQ_ROOT"
HQ_USS_CWD="${HQ_HOOK_CWD:-$PWD}"
export HQ_USS_ROOTS HQ_USS_CWD

# Prints "<kind>\t<target>" and exits 3 on a denied search, otherwise exit 0.
# shellcheck disable=SC2016
_USS_PL='
use strict; use warnings;
$SIG{ALRM}=sub { exit 0 }; alarm 2;
local $/; my $in=<STDIN>; $in//="";
my $nul=index($in,"\0"); exit 0 if $nul<0;
my ($cwd0,$cmd)=(substr($in,0,$nul),substr($in,$nul+1));
exit 0 if $cmd eq "" || length($cmd)>200000;
$cwd0=$ENV{HQ_USS_CWD}//"" if $cwd0 eq "";
my %target;
for my $r (split /\n/, $ENV{HQ_USS_ROOTS}//"") { next unless $r=~m{^/}; $r=~s{/+$}{}; next if $r eq ""; $target{$r}=1; $target{"$r/workspace"}=1 }
exit 0 unless %target;
my $H=$ENV{HOME}//"";

sub read_bt { my ($s,$i)=@_; my $n=length $s;
  while ($i<$n) { my $c=substr($s,$i,1);
    if ($c eq "\\") { $i+=2; next } return $i+1 if $c eq "`"; $i++ } return $n }
sub read_subst { my ($s,$i,$subs,$idx)=@_; my $start=$i; my $depth=1; my $n=length $s;
  while ($i<$n) { my $c=substr($s,$i,1);
    if ($c eq "\\") { $i+=2; next }
    if ($c eq "\x27") { my $j=index($s,"\x27",$i+1); $i=$j<0?$n:$j+1; next }
    if ($c eq "\"") { $i=read_dq($s,$i+1,undef,0); next }
    if ($c eq "`") { $i=read_bt($s,$i+1); next }
    if ($c eq "(") { $depth++ }
    elsif ($c eq ")") { $depth--; if (!$depth) { push @$subs,[$idx,substr($s,$start,$i-$start)] if $subs; return $i+1 } }
    $i++ }
  push @$subs,[$idx,substr($s,$start)] if $subs; return $n }
sub read_dq { my ($s,$i,$subs,$idx)=@_; my $n=length $s;
  while ($i<$n) { my $c=substr($s,$i,1);
    if ($c eq "\\") { $i+=2; next }
    return $i+1 if $c eq "\"";
    if ($c eq "\$" && substr($s,$i+1,1) eq "(") { $i=read_subst($s,$i+2,$subs,$idx); next }
    if ($c eq "`") { my $j=read_bt($s,$i+1); push @$subs,[$idx,substr($s,$i+1,$j-$i-2)] if $subs; $i=$j; next }
    $i++ } return $n }

# Splits into segments {w=>[raw words],piped,stdin}. Redirections and their
# targets are dropped. Heredoc bodies and comments are skipped. Each $(...) body
# is kept with the index of its segment, so it sees the cwd of that point. A
# bare ( or ) becomes its own segment so a cd inside a subshell stays there.
sub tokenize { my ($s)=@_; my @segs=({w=>[]}); my @subs; my $w; my $skip=0; my @hd; my $n=length $s; my $i=0;
  my $flush=sub { if (defined $w) { if ($skip) { $skip=0 } else { push @{$segs[-1]{w}},$w } undef $w } };
  my $seg=sub { $flush->(); $skip=0; push @segs,{w=>[]} if @{$segs[-1]{w}} };
  while ($i<$n) { my $c=substr($s,$i,1); my $idx=$#segs;
    if ($c eq "\n") { $seg->(); $i++;
      while (@hd) { my ($d,$strip)=@{shift @hd};
        while ($i<$n) { my $e=index($s,"\n",$i); my $l=$e<0?substr($s,$i):substr($s,$i,$e-$i);
          $i=$e<0?$n:$e+1; $l=~s/^\t+// if $strip; last if $l eq $d } }
      next }
    if ($c eq " " || $c eq "\t") { $flush->(); $i++; next }
    if (($c eq "<" || $c eq ">") && substr($s,$i+1,1) eq "(") {
      $w//=""; my $j=read_subst($s,$i+2,\@subs,$idx); $w.=substr($s,$i,$j-$i); $i=$j; next }
    if (substr($s,$i,3) eq "<<<") { $flush->(); $segs[-1]{stdin}=1; $skip=1; $i+=3; next }
    if (substr($s,$i,2) eq "<<") { $flush->(); $segs[-1]{stdin}=1; $i+=2; my $strip=0; if (substr($s,$i,1) eq "-") { $strip=1; $i++ }
      $i++ while $i<$n && substr($s,$i,1)=~/[ \t]/;
      my $st=$i;
      while ($i<$n && substr($s,$i,1)!~/[\s;&|<>()]/) { my $d=substr($s,$i,1);
        if ($d eq "\x27") { my $j=index($s,"\x27",$i+1); $i=$j<0?$n:$j+1 }
        elsif ($d eq "\"") { $i=read_dq($s,$i+1,undef,0) } else { $i++ } }
      my $d=substr($s,$st,$i-$st); $d=~s/[\x27"\\]//g; push @hd,[$d,$strip] if length $d; next }
    if ($c eq "&" && substr($s,$i+1,1) eq ">") { $flush->(); $skip=1; $i+=2; $i++ if substr($s,$i,1) eq ">"; next }
    if ($c eq "<" || $c eq ">") {
      if (defined $w && $w=~/^[0-9]+$/) { undef $w } else { $flush->() }
      $segs[-1]{stdin}=1 if $c eq "<";
      $i++; $i++ if substr($s,$i,1)=~/[>&|]/; $skip=1; next }
    if ($c eq "|") { my $two=substr($s,$i+1,1); $seg->(); if ($two eq "|") { $i+=2; next }
      $segs[-1]{piped}=1; $i+=($two eq "&")?2:1; next }
    if ($c=~/[;&]/) { $seg->(); $i++; next }
    if ($c=~/[()]/) { $seg->(); push @{$segs[-1]{w}},$c; push @segs,{w=>[]}; $i++; next }
    if ($c eq "#" && !defined $w) { my $e=index($s,"\n",$i); $i=$e<0?$n:$e; next }
    if ($c eq "\\" && substr($s,$i+1,1) eq "\n") { $i+=2; next }
    $w//="";
    if ($c eq "\\") { $w.=substr($s,$i,2); $i+=2; next }
    if ($c eq "\x27") { my $j=index($s,"\x27",$i+1); $j=$n-1 if $j<0; $w.=substr($s,$i,$j-$i+1); $i=$j+1; next }
    if ($c eq "\"") { my $j=read_dq($s,$i+1,\@subs,$idx); $w.=substr($s,$i,$j-$i); $i=$j; next }
    if ($c eq "`") { my $j=read_bt($s,$i+1); push @subs,[$idx,substr($s,$i+1,$j-$i-2)]; $w.=substr($s,$i,$j-$i); $i=$j; next }
    if ($c eq "\$" && substr($s,$i+1,1) eq "(") { my $j=read_subst($s,$i+2,\@subs,$idx); $w.=substr($s,$i,$j-$i); $i=$j; next }
    $w.=$c; $i++ }
  $flush->(); return (\@segs,\@subs) }

# Removes shell quoting from one raw word.
sub unq { my ($r)=@_; my $o=""; my $i=0; my $n=length $r;
  while ($i<$n) { my $c=substr($r,$i,1);
    if ($c eq "\\") { $o.=substr($r,$i+1,1) if $i+1<$n; $i+=2; next }
    if ($c eq "\x27") { my $j=index($r,"\x27",$i+1); $j=$n if $j<0; $o.=substr($r,$i+1,$j-$i-1); $i=$j+1; next }
    if ($c eq "\"") { $i++;
      while ($i<$n) { my $d=substr($r,$i,1); last if $d eq "\"";
        if ($d eq "\\" && $i+1<$n) { my $e=substr($r,$i+1,1); $o.=($e=~/["\\\$`]/)?$e:"\\$e"; $i+=2; next }
        $o.=$d; $i++ }
      $i++; next }
    $o.=$c; $i++ }
  return $o }

# Absolute path of a raw path word, or undef when it cannot be known here.
sub resolve { my ($w,$cwd)=@_; my $p=unq($w); return undef if $p eq "";
  if (length $H) { $p=~s{^~(?=/|$)}{$H}; $p=~s/\$HOME(?![A-Za-z0-9_])|\$\{HOME\}/$H/g }
  if (defined $cwd) { $p=~s/\$PWD(?![A-Za-z0-9_])|\$\{PWD\}|\$\(pwd\)|`pwd`/$cwd/g }
  $p=~s{/\*$}{/}; $p="." if $p eq "*";
  return undef if $p=~/[\$`*?\[\]{}<>]/;
  if ($p!~m{^/}) { return undef unless defined $cwd; $p="$cwd/$p" }
  my @o; for my $x (split m{/+},$p) { next if $x eq "" || $x eq "."; if ($x eq "..") { pop @o; next } push @o,$x }
  return "/".join("/",@o) }

sub cmdname { my $x=unq($_[0]); $x=~s{.*/}{}; return $x }

# Options of a wrapper command that take the next word as their value.
my %argopt=(env=>qr/^-[uCS]$|^--(?:unset|chdir|split-string)$/,
  sudo=>qr/^-[ugCDhpRrtTU]$|^--(?:user|group|close-from|chdir|host|prompt|chroot|role|type|other-user)$/,
  timeout=>qr/^-[sk]$|^--(?:signal|kill-after)$/, gtimeout=>qr/^-[sk]$|^--(?:signal|kill-after)$/,
  nice=>qr/^-n$|^--adjustment$/, caffeinate=>qr/^-[tw]$/, stdbuf=>qr/^-[ioe]$/,
  xargs=>qr/^-[IJLnPRSsEda]$|^--(?:arg-file|eof|delimiter|max-lines|max-args|max-procs|max-chars|replace)$/);

# Skips assignments, keywords and wrappers. Returns the command word index and
# whether xargs supplies more arguments. Index -1: not a real run of the command.
sub head { my ($w)=@_; my ($k,$xa,$cur,$dur)=(0,0,"",0);
  while ($k<@$w) { my $x=$w->[$k];
    if ($x=~/^[A-Za-z_][A-Za-z0-9_]*\+?=/) { $k++; next }
    my $u=cmdname($x);
    if ($u=~/^(?:if|then|else|elif|while|until|do|!|\{|\}|time|exec|nohup|sudo|env|command|builtin|nice|timeout|gtimeout|caffeinate|stdbuf|xargs)$/) {
      return (-1,0) if $u eq "command" && $k<$#$w && unq($w->[$k+1])=~/^-[vV]$/;
      $xa=1 if $u eq "xargs"; $cur=$u; $dur=($u=~/timeout$/)?1:0; $k++; next }
    if (length $cur && $u=~/^-/) { $k++; $k++ if $argopt{$cur} && $u=~$argopt{$cur}; next }
    if ($dur && $u=~/^[0-9]+(?:\.[0-9]+)?[smhd]?$/) { $dur=0; $k++; next }
    last }
  return ($k,$xa) }

# Root operands of an unbounded find, as raw words. None when bounded.
sub find_roots { my ($w,$k,$xa)=@_; my @raw=@$w[$k+1..$#$w]; my @a=map { unq($_) } @raw;
  for my $x (@a) { return () if $x eq "-maxdepth" || $x=~/^-{1,2}(?:help|version)$/ }
  my @ops; my $i=0;
  while ($i<@a) { my $x=$a[$i];
    if ($x eq "--" || $x=~/^-(?:[HLPEXdsx]+|O[0-9a-z.]*)$/) { $i++; next }
    if ($x=~/^-[DS]$/) { $i+=2; next }
    if ($x eq "-f") { push @ops,$raw[$i+1] if $i+1<@raw; $i+=2; next }
    last if $x=~/^-./ || $x=~/^[(),!]$/;
    push @ops,$raw[$i]; $i++ }
  return @ops if @ops;
  return $xa ? () : ("."); }

# Path operands of a recursive grep, as raw words. None when not recursive.
sub grep_roots { my ($w,$k,$xa,$seg)=@_; my @raw=@$w[$k+1..$#$w]; my ($rec,$pat,$end,@ops)=(0,0,0); my $i=0;
  while ($i<@raw) { my $x=unq($raw[$i]);
    if ($end || $x eq "-" || $x!~/^-/) { push @ops,$raw[$i]; $i++; next }
    if ($x eq "--") { $end=1; $i++; next }
    if ($x=~/^--([^=]+)(=(.*))?$/s) { my ($name,$has,$val)=($1,$2,$3);
      if ($name=~/^(?:recursive|dereference-recursive)$/) { $rec=1 }
      elsif ($name eq "directories") { if (!defined $has) { $val=unq($raw[$i+1]//""); $i++ } $rec=1 if $val eq "recurse" }
      elsif ($name=~/^(?:regexp|file)$/) { $pat=1; $i++ unless defined $has }
      elsif ($name=~/^(?:max-count|after-context|before-context|context|label|include|exclude|exclude-dir|exclude-from|devices|binary-files)$/) { $i++ unless defined $has }
      $i++; next }
    my @c=split //,substr($x,1);
    for my $j (0..$#c) { my $c=$c[$j];
      $rec=1 if $c=~/[rR]/;
      if ($c=~/[efmABCDd]/) { my $v=join("",@c[$j+1..$#c]);
        if ($v eq "") { $v=unq($raw[$i+1]//""); $i++ unless $c eq "C" && $v!~/^[0-9]+$/ }
        $pat=1 if $c=~/[ef]/; $rec=1 if $c eq "d" && $v eq "recurse"; last } }
    $i++ }
  return () unless $rec;
  if (!$pat) { return () unless @ops; shift @ops }
  return @ops if @ops;
  return () if $xa || $seg->{piped} || $seg->{stdin};
  return (".") }

sub denied { my ($cwd,@words)=@_;
  for my $x (@words) { my $p=resolve($x,$cwd); return $p if defined $p && $target{$p} } return undef }

# Returns [kind,target] for the first denied search, or undef.
sub analyze { my ($s,$cwd,$depth)=@_; return undef if $depth>4;
  my ($segs,$subs)=tokenize($s); my %by; push @{$by{$_->[0]}},$_->[1] for @$subs; my @stack;
  for my $si (0..$#$segs) { my $seg=$segs->[$si]; my @w=@{$seg->{w}};
    for my $body (@{$by{$si}||[]}) { my $hit=analyze($body,$cwd,$depth+1); return $hit if $hit }
    next unless @w;
    if ($w[0] eq "(") { push @stack,$cwd; next }
    if ($w[0] eq ")") { $cwd=pop @stack if @stack; next }
    my ($k,$xa)=head(\@w); next if $k<0 || $k>$#w;
    my $cw=cmdname($w[$k]);
    if ($cw=~/^(?:find|gfind|bfs)$/) { my $t=denied($cwd,find_roots(\@w,$k,$xa)); return ["find without -maxdepth",$t] if defined $t }
    elsif ($cw=~/^(?:grep|egrep|fgrep|ggrep)$/) { my $t=denied($cwd,grep_roots(\@w,$k,$xa,$seg)); return ["recursive grep",$t] if defined $t }
    elsif ($cw eq "cd" || $cw eq "pushd") { my $to;
      for my $x (@w[$k+1..$#w]) { my $u=unq($x); next if $u eq "--" || $u=~/^-[LPe@]+$/; $to=$x; last }
      if (!defined $to) { $cwd=length $H ? $H : undef } elsif (unq($to) eq "-") { undef $cwd } else { $cwd=resolve($to,$cwd) } }
    elsif ($cw eq "popd") { undef $cwd }
    elsif ($cw=~/^(?:bash|sh|zsh|dash|ksh)$/) {
      for my $j ($k+1..$#w-1) { if ($w[$j]=~/^-[A-Za-z]*c[A-Za-z]*$/) { my $hit=analyze(unq($w[$j+1]),$cwd,$depth+1); return $hit if $hit; last } } }
    elsif ($cw eq "eval" && $k<$#w) { my $hit=analyze(join(" ",map { unq($_) } @w[$k+1..$#w]),$cwd,$depth+1); return $hit if $hit } }
  return undef }

my $start=$cwd0=~m{^/} ? resolve("/$cwd0",undef) : undef;
my $hit=analyze($cmd,$start,0);
exit 0 unless $hit;
print "$hit->[0]\t$hit->[1]\n";
exit 3;
'

_uss_filter='if (.tool_name // "Bash") == "Bash"
  then ([.cwd // "", "\u0000", (.tool_input.command // .tool_input.cmd // "")] | join(""))
  else empty end'

_uss_hit="$(jq -j "$_uss_filter" 2>/dev/null | LC_ALL=C perl -e "$_USS_PL" 2>/dev/null)"
[ "$?" -eq 3 ] || exit 0

printf 'BLOCKED: unbounded recursive search: %s over %s\n\n' "${_uss_hit%%	*}" "${_uss_hit#*	}" >&2
printf '%s\n' \
  'This tree is too large to walk. The shell find runs bundled bfs, which ignores' \
  '.ignore; one run over workspace took 2.6-4.5 cores for about 3 minutes.' \
  '' \
  'Do this instead:' \
  '  qmd query "<terms>"                                  search indexed content' \
  '  find workspace/reports -maxdepth 3 -name "<name>"    a named subfolder, with -maxdepth' \
  '  rg "<pattern>" workspace/reports                     rg honours .ignore' >&2
exit 2
