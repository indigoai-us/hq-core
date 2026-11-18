#!/usr/bin/env bash
# hq-core: public
# Regression: a write behind `sudo <options>` must be checked like the bare
# command. The command-name lookup skipped the word `sudo` and then took
# sudo's first option as the command, so `sudo -u nobody cp evil.sh
# .claude/hooks/x.sh` resolved to `-u` and was allowed (only a bare
# `sudo cp ...` was blocked).
#
# block-core-writes-bash.sh is frozen (merged-write-guard-shadow.test.sh), so
# its own lookup is unchanged. hook-lib's shared resolver
# (hq_shell_record_executable) now skips sudo's options and their values, and
# hq_strip_tokens_containing_literals, whose output that guard parses, turns
# sudo's options into NAME=value words that the guard's lookup already skips.
#
# This suite is not replayed by block-guard-hooks-parity.test.sh: that harness
# pins main's hook-lib.sh.

set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
HOOK="$ROOT/.claude/hooks/block-core-writes-bash.sh"

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not available"; exit 0; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/.claude/hooks" "$TMP/core"
printf '{}' > "$TMP/.claude/settings.local.json"

PASS=0
FAIL=0

# run <expected_exit> <command> <label>
run() {
  local expect="$1" cmd="$2" label="$3" rc=0 payload
  payload=$(jq -n --arg cmd "$cmd" '{tool_input: {command: $cmd}}')
  printf '%s' "$payload" | (cd "$TMP" && CLAUDE_PROJECT_DIR="$TMP" bash "$HOOK") >/dev/null 2>&1 || rc=$?
  if [ "$rc" -eq "$expect" ]; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1))
    echo "FAIL [$label]: expected exit $expect, got $rc -- cmd: $cmd" >&2
  fi
}

# --- guard: every sudo option form still reaches the write -------------------
run 2 "sudo cp evil.sh .claude/hooks/x.sh"                'bare sudo cp blocked'
run 2 "sudo -u nobody cp evil.sh .claude/hooks/x.sh"      'sudo -u <user> cp blocked'
run 2 "sudo -E cp evil.sh .claude/hooks/x.sh"             'sudo -E cp blocked'
run 2 "sudo -n -u root cp evil.sh .claude/hooks/x.sh"     'sudo -n -u root cp blocked'
run 2 "sudo -- cp evil.sh .claude/hooks/x.sh"             'sudo -- cp blocked'
run 2 "sudo -nE cp evil.sh .claude/hooks/x.sh"            'combined short flags blocked'
run 2 "sudo -nu root cp evil.sh .claude/hooks/x.sh"       'combined flags ending in a value option blocked'
run 2 "sudo -uroot cp evil.sh .claude/hooks/x.sh"         'attached option value blocked'
run 2 "sudo --user=root cp evil.sh .claude/hooks/x.sh"    '--user=<user> blocked'
run 2 "sudo --user root cp evil.sh .claude/hooks/x.sh"    '--user <user> blocked'
run 2 "sudo --preserve-env=PATH cp evil.sh .claude/hooks/x.sh" '--preserve-env=<list> blocked'
run 2 "sudo -u root -- cp evil.sh .claude/hooks/x.sh"     'options then -- blocked'
run 2 "sudo -C 3 rm -rf core/"                            'sudo -C <fd> rm blocked'
run 2 "sudo -g wheel mv a .claude/hooks/x"                'sudo -g <group> mv blocked'
run 2 "FOO=1 sudo -u root rm -rf core/"                   'assignment before sudo blocked'
run 2 "env sudo -u root touch .claude/hooks/x"            'env before sudo blocked'
run 2 "true; sudo -g wheel mv a .claude/hooks/x"          'sudo after ; blocked'
run 2 "true &&sudo -u root cp a .claude/hooks/x"          'sudo glued to && blocked'
# shellcheck disable=SC2016 # literal shell text for the guard
run 2 'echo $(sudo -u nobody cp evil.sh .claude/hooks/x.sh)' 'sudo with options inside $(...) blocked'

# --- review of #1905: -D/--chdir and -R/--chroot, -a/-c values, bare -h ------
# -D and -R take a value, so the value is not the command. They change only
# the sudo child's directory, and no `cd` is modelled for them (review 3 of
# #1905: an injected `cd` cleared a protected cwd from an earlier `cd`). A
# relative target is checked against the caller's directory, so a protected
# DIR with a bare relative target is allowed, the same as on main.
run 0 "sudo -D .claude/hooks cp evil x.sh"                'sudo -D <protected dir> relative target: same as main'
run 0 "sudo -D.claude/hooks cp evil x.sh"                 'sudo -D<protected dir> attached: same as main'
run 0 "sudo --chdir .claude/hooks cp evil x.sh"           'sudo --chdir <protected dir>: same as main'
run 0 "sudo --chdir=.claude/hooks cp evil x.sh"           'sudo --chdir=<protected dir>: same as main'
run 0 "sudo -nD .claude/hooks cp evil x.sh"               'combined flags ending in -D: same as main'
run 0 "sudo -D '.claude/hooks' cp evil x.sh"              'quoted -D dir: same as main'
run 0 "sudo -D .claude/hooks -- cp evil x.sh"             'sudo -D <dir> --: same as main'
run 0 "sudo -R .claude/hooks cp evil x.sh"                'sudo -R <protected dir>: same as main'
run 0 "sudo --chroot=.claude/hooks cp evil x.sh"          'sudo --chroot=<protected dir>: same as main'
# shellcheck disable=SC2016 # literal shell text for the guard
run 0 'echo $(sudo -D .claude/hooks cp evil x.sh)'        'sudo -D inside $(...): same as main'
# The value is skipped, so the write after it is still checked.
run 2 "sudo -D . cp evil core/x"                          'sudo -D . with a protected relative target blocked'
run 2 "sudo -D .claude/hooks cp evil .claude/hooks/x.sh"  'sudo -D <dir> then a protected target blocked'
run 2 "sudo --chdir=sub -u root cp evil core/x"           'sudo --chdir=<dir> -u root then a protected target blocked'
run 0 "sudo -D /tmp cp evil x.sh"                         'sudo -D outside the tree with a relative target allowed'
# -a and -c read a value; it is not the command.
run 2 "sudo -a type cp evil .claude/hooks/x.sh"           'sudo -a <type> cp blocked'
run 2 "sudo -c cls cp evil .claude/hooks/x.sh"            'sudo -c <class> cp blocked'
run 2 "sudo --auth-type type cp evil .claude/hooks/x.sh"  'sudo --auth-type <type> cp blocked'
run 2 "sudo --login-class cls cp evil .claude/hooks/x.sh" 'sudo --login-class <class> cp blocked'
# -h takes only an attached value, so the next word is not consumed.
run 2 "sudo -h cp evil .claude/hooks/x.sh"                'bare -h does not consume the command'
run 2 "sudo -h -u root cp evil .claude/hooks/x.sh"        'bare -h then -u <user> blocked'
run 2 "sudo -nh cp evil .claude/hooks/x.sh"               'cluster ending in h does not consume the command'
run 2 "sudo -hhost cp evil .claude/hooks/x.sh"            '-h<host> attached blocked'
# A user-written HQ_SUDO_OPTION=1 is an ordinary assignment and hides nothing.
run 2 "HQ_SUDO_OPTION=1 cp evil .claude/hooks/x.sh"       'user HQ_SUDO_OPTION=1 before cp blocked'
run 2 "sudo HQ_SUDO_OPTION=1 cp evil .claude/hooks/x.sh"  'user HQ_SUDO_OPTION=1 after sudo blocked'
run 2 "sudo -u root HQ_SUDO_OPTION=1 cp evil .claude/hooks/x.sh" 'user HQ_SUDO_OPTION=1 after sudo options blocked'

# Review 2 of #1905: an outside DIR must not mark the whole command as running
# outside the project. sudo -D/-R changes only the sudo child's directory, and
# the guard turns off relative-path checks for a command with an outside cd,
# so an absolute (or ..) DIR gets no modelled cd. Main blocks each of these.
run 2 "sudo -D /tmp cp evil x.sh; cp evil.sh .claude/hooks/x.sh"        'outside -D then a protected write blocked'
run 2 "sudo -D /tmp true && cp evil.sh .claude/hooks/x.sh"              'outside -D && a protected write blocked'
run 2 "sudo -D /tmp ls; rm -rf core/"                                   'outside -D then rm core/ blocked'
run 2 "sudo -R /tmp true; cp evil.sh .claude/hooks/x.sh"                'outside -R then a protected write blocked'
run 2 "sudo --chdir=/tmp true; touch core/x"                            'outside --chdir= then touch core/ blocked'
run 2 "cp evil.sh .claude/hooks/x.sh; sudo -D /tmp true"                'protected write before an outside -D blocked'
# shellcheck disable=SC2016 # literal shell text for the guard
run 2 'echo $(sudo -D /tmp true); cp evil.sh .claude/hooks/x.sh'        'outside -D in $(...) then a protected write blocked'
run 2 "sudo -D /tmp cp evil x.sh > .claude/hooks/y.sh"                  'redirect after an outside -D is the caller'"'"'s write, blocked'
run 2 "sudo -D ../x true; cp evil.sh .claude/hooks/x.sh"                '.. -D then a protected write blocked'
run 2 "sudo -D a/../.. true; cp evil.sh .claude/hooks/x.sh"             'inner .. -D then a protected write blocked'
run 2 "sudo -D /tmp cp evil .claude/hooks/x.sh"                         'outside -D with a protected-looking target blocked (may over-block)'

# Review 3 of #1905: sudo -D/-R never changes the caller's directory, so a
# protected cwd from an earlier cd/pushd still covers the relative write after
# the sudo. Main blocks each of these.
mkdir -p "$TMP/.claude/hooks/sub"
run 2 "cd .claude/hooks; sudo -D sub true; cp evil x.sh"      'protected cd, relative -D, relative write blocked'
run 2 "cd .claude/hooks; sudo -D . true; cp evil x.sh"        'protected cd, -D ., relative write blocked'
run 2 "pushd .claude/hooks; sudo -D sub true; cp evil x.sh"   'protected pushd, relative -D, relative write blocked'
run 2 "cd .claude/hooks && sudo -u root -D sub ls && rm x.sh" 'protected cd, -u -D, relative rm blocked'
run 2 "cd .claude/hooks; sudo --chdir=sub true; touch x.sh"   'protected cd, --chdir=, relative touch blocked'
run 2 "cd .claude/hooks; sudo -R sub true; mv a x.sh"         'protected cd, relative -R, relative mv blocked'
run 2 "cd .claude/hooks; cp evil x.sh"                        'control: protected cd then relative write blocked'
run 2 "cd .claude/hooks; sudo -u root true; cp evil x.sh"     'control: protected cd, sudo -u, relative write blocked'

# Review 4 of #1905: a newline ends the sudo command. An option that still
# waits for its value at the end of a line (`sudo -u`, which sudo rejects)
# must not take the first word of the next line as that value: that word is
# the next command, and it runs as the caller. Main blocks each of these.
NL=$'\n'
run 2 "sudo -u${NL}cp evil.sh .claude/hooks/x.sh"            'value option at end of line does not hide the next line'
run 2 "sudo --user${NL}cp evil.sh .claude/hooks/x.sh"        'long value option at end of line does not hide the next line'
run 2 "sudo -g${NL}rm -rf core/"                             'sudo -g at end of line then rm core/ blocked'
run 2 "sudo -nu${NL}cp evil.sh .claude/hooks/x.sh"           'cluster ending in a value option at end of line blocked'
run 2 "sudo -D${NL}cp evil.sh .claude/hooks/x.sh"            'sudo -D at end of line then a protected write blocked'
run 2 "sudo -u${NL}	cp evil.sh .claude/hooks/x.sh"           'newline then a tab before the next command blocked'
run 2 "true; sudo -u${NL}cp evil.sh .claude/hooks/x.sh"      'sudo -u at end of line after ; blocked'
run 2 "x=1 sudo -u${NL}cp evil.sh .claude/hooks/x.sh"        'assignment, sudo -u at end of line blocked'
run 2 "ls | sudo -u${NL}cp evil.sh .claude/hooks/x.sh"       'pipe into sudo -u at end of line blocked'
run 2 "(sudo -u${NL}cp evil.sh .claude/hooks/x.sh)"          'subshell with sudo -u at end of line blocked'
run 2 "sudo -n${NL}cp evil.sh .claude/hooks/x.sh"            'flag at end of line then a protected write blocked'
run 2 "sudo -u root${NL}cp evil.sh .claude/hooks/x.sh"       'option value at end of line then a protected write blocked'
run 2 "sudo${NL}cp evil.sh .claude/hooks/x.sh"               'bare sudo at end of line then a protected write blocked'
run 2 "sudo -u \"a b\"${NL}cp evil.sh .claude/hooks/x.sh"    'quoted value at end of line then a protected write blocked'
run 2 "sudo -u root${NL}sudo -g wheel cp evil.sh .claude/hooks/x.sh" 'second sudo on the next line still read'

# Review 4 of #1905: the rewrite splits on whitespace and does not track
# quotes, so the word `sudo` may sit inside a string or a comment. An earlier
# version read a quote after such a `sudo` as the start of a quoted option
# value and replaced every word up to the next quote, which removed the real
# commands that follow the string. Main blocks each of these.
run 2 "echo \"x; sudo -p \"; cp evil.sh .claude/hooks/x.sh; echo a\" b\""   'sudo in a double-quoted string does not hide the write after it'
run 2 "echo 'x; sudo -p '; cp evil.sh .claude/hooks/x.sh; echo a' b'"       'sudo in a single-quoted string does not hide the write after it'
run 2 "echo \"x; sudo -u \"; rm -rf core/; echo a\" b\""                    'sudo -u in a string does not hide rm core/'
run 2 "echo \"x; sudo -p \" && cp evil.sh .claude/hooks/x.sh && echo a\" b\"" 'sudo in a string, && chain, write blocked'
run 2 "echo \"x | sudo -u root -p \"; cp evil.sh .claude/hooks/x.sh; echo a\" b\"" 'sudo after | in a string, write blocked'
run 2 "echo \"${NL}sudo -p \"; cp evil.sh .claude/hooks/x.sh; echo a\" b\"" 'sudo on a new line inside a string, write blocked'
run 2 "true # x; sudo -p \"${NL}cp evil.sh .claude/hooks/x.sh; echo a\" b\"" 'sudo in a comment does not hide the next line'
run 2 "sudo -u root sh -c \"x; sudo -p \"; cp evil.sh .claude/hooks/x.sh; echo a\" b\"" 'sudo in an sh -c string does not hide the write after it'
run 2 "echo \"x; sudo -p \";>.claude/hooks/x.sh;\" y\""                     'redirect glued between two strings is not taken as a quoted value'
# So a quoted option value is not rewritten and the command is judged as
# written, the same as on main. The write behind it is not checked.
run 0 "sudo -u \"build user\" cp evil.sh .claude/hooks/x.sh" 'double-quoted option value: left as written, same as main'
run 0 "sudo -p 'pw:' cp evil.sh .claude/hooks/x.sh"       'single-quoted option value: left as written, same as main'
run 0 "sudo -D 'a b' cp evil core/x"                      'quoted -D dir with a space: left as written, same as main'
# Quotes elsewhere in the command do not stop the rewrite.
run 2 "echo \"it's\"; sudo -u root cp evil.sh .claude/hooks/x.sh"           'a quoted word before sudo: write still blocked'
run 2 "sudo -u root cp \"evil file.sh\" .claude/hooks/x.sh"                 'a quoted argument after the command: write still blocked'

# A backslash-escaped ; & or | inside a word is not a command separator, so
# `x\;sudo` is one plain argument and the words after it are not sudo options.
run 2 'echo x | tee x\;sudo -a .claude/hooks/x.sh'   'escaped ; before sudo: tee target still checked'
run 2 'cp evil.sh x\;sudo -u .claude/hooks/'         'escaped ; before sudo: cp target still checked'
run 2 'cp evil.sh x\&sudo -u .claude/hooks/'         'escaped & before sudo: cp target still checked'
run 2 'cp evil.sh x\|sudo -t core/'                  'escaped | before sudo: cp -t still checked'
run 2 'rm x\;sudo -r core/x'                         'escaped ; before sudo: rm target still checked'
run 2 'mv x\;sudo -t .claude/hooks evil.sh'          'escaped ; before sudo: mv -t still checked'

# An escaped operator in an earlier word (`x\;`, `\(`) is a plain argument,
# so the next word sudo is not in command position.
run 2 'cp evil.sh x\; sudo -u .claude/hooks/'        'escaped ; in earlier word: cp target still checked'
run 2 'cp evil.sh \; sudo -t core/'                  'bare escaped ; earlier: cp -t still checked'
run 2 'cp evil.sh x\& sudo -u .claude/hooks/'        'escaped & in earlier word: cp target still checked'
run 2 'cp evil.sh x\| sudo -t core/'                 'escaped | in earlier word: cp -t still checked'
run 2 'cp evil.sh "x"\; sudo -t core/'               'quoted then escaped ; earlier: cp -t still checked'
run 2 'cp evil.sh \( sudo -t core/'                  'escaped ( earlier: cp -t still checked'
run 2 'cp evil.sh x\( sudo -t core/'                 'escaped ( in earlier word: cp -t still checked'

# Reserved words used as plain arguments do not start a command.
run 2 'cp evil.sh then sudo -u .claude/hooks/'       'then as argument: cp target still checked'
run 2 'cp evil.sh do sudo -t core/'                  'do as argument: cp -t still checked'
run 2 'cp evil.sh if sudo -t core/'                  'if as argument: cp -t still checked'
run 2 'cp evil.sh ! sudo -t core/'                   '! as argument: cp -t still checked'
run 2 'cp evil.sh { sudo -t core/'                   '{ as argument: cp -t still checked'
run 2 'rm -rf else sudo -D core/x'                   'else as argument: rm target still checked'
run 2 'echo x | tee while sudo -a .claude/hooks/x.sh' 'while as argument: tee target still checked'

# --- unrelated words named sudo are left alone --------------------------------
run 2 "cp sudo -t .claude/hooks x"        'a word sudo that is not the command keeps cp -t checked'
run 0 "grep -r sudo .claude/"             'grep for the word sudo stays allowed'
run 0 "sudo -u root cp a /tmp/b"          'sudo write outside protected paths stays allowed'

# --- shared resolver -----------------------------------------------------------
# shellcheck source=../hook-lib.sh
. "$ROOT/core/scripts/hook-lib.sh"
US=$'\037'
resolve() { # <expected executable> <space-separated argv>
  local want="$1" record="${2// /$US}"
  hq_shell_record_executable "$record" || :
  if [ "$HQ_SHELL_EXECUTABLE" = "$want" ]; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1))
    echo "FAIL [resolver $2]: expected [$want], got [$HQ_SHELL_EXECUTABLE]" >&2
  fi
}
resolve cp  "sudo cp a"
resolve cp  "sudo -u nobody cp a"
resolve git "sudo -nu root git status"
resolve git "sudo -uroot git status"
resolve rm  "sudo --user=root rm x"
resolve rm  "sudo --user root rm x"
resolve mv  "sudo -E -H mv a b"
resolve cp  "sudo -- cp a b"
resolve tee "FOO=1 sudo -g wheel env X=1 tee x"
resolve ''  "sudo -u"
resolve cp  "sudo -a type cp a"
resolve cp  "sudo -c cls cp a"
resolve cp  "sudo --login-class cls cp a"
resolve cp  "sudo -h cp a"
resolve cp  "sudo -nh cp a"
resolve cp  "sudo -hhost cp a"
resolve cp  "sudo -D /tmp cp a"
resolve cp  "HQ_SUDO_OPTION=1 cp a"

# The rewrite reads the command line by line. Every line without a sudo
# option, every blank line and a final newline (or its absence) come back
# byte for byte.
rewrite_is() { # <expected text> <command> <label>
  _hq_sudo_options_as_assignments "$2"
  if [ "$HQ_SUDO_REWRITE_RESULT" = "$1" ]; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1))
    echo "FAIL [rewrite $3]: got [$HQ_SUDO_REWRITE_RESULT]" >&2
  fi
}
rewrite_is "sudo HQ_SUDO_OPTION=1 HQ_SUDO_OPTION=1 cp a b" "sudo -u root cp a b" 'one line'
rewrite_is "a${NL}${NL}sudo HQ_SUDO_OPTION=1 cp a b${NL}" "a${NL}${NL}sudo -n cp a b${NL}" 'blank line and final newline kept'
rewrite_is "a  b${NL}	sudo HQ_SUDO_OPTION=1   cp a b${NL}${NL}" "a  b${NL}	sudo -n   cp a b${NL}${NL}" 'spacing and two final newlines kept'
rewrite_is "sudo HQ_SUDO_OPTION=1${NL}cp a b" "sudo -u${NL}cp a b" 'value option at end of line takes nothing from the next line'
rewrite_is "sudo -u \"a b\" cp x y${NL}sudo -n true" "sudo -u \"a b\" cp x y${NL}sudo -n true" 'a quoted value leaves the whole command as written'
rewrite_is "echo sudo -n${NL}x\\${NL}" "echo sudo -n${NL}x\\${NL}" 'no sudo in command position: unchanged, backslash kept'
# A long script with one sudo line is scanned in well under the hook budget
# (the scan used to walk every word of the command, which took tens of
# seconds on a 60 KB script).
# Built without `yes | head`: under pipefail that pipe exits 141 and set -e
# stops the file.
LONG_BODY="$(for _ in $(seq 2000); do echo 'line of text with several words in it'; done)"
LONG_START=$SECONDS
rewrite_is "sudo HQ_SUDO_OPTION=1 true${NL}${LONG_BODY}" "sudo -n true${NL}${LONG_BODY}" 'long script: only the sudo line changes'
if [ $((SECONDS - LONG_START)) -le 5 ]; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1))
  echo "FAIL [rewrite long script]: took $((SECONDS - LONG_START))s, expected at most 5" >&2
fi

# The resolver records the -D/--chdir directory for guards that anchor on it.
chdir_is() { # <expected dir> <space-separated argv>
  local want="$1" record="${2// /$US}"
  hq_shell_record_executable "$record" || :
  if [ "$HQ_SHELL_SUDO_CHDIR" = "$want" ]; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1))
    echo "FAIL [chdir $2]: expected [$want], got [$HQ_SHELL_SUDO_CHDIR]" >&2
  fi
}
chdir_is /tmp "sudo -D /tmp git commit"
chdir_is /tmp "sudo -D/tmp git commit"
chdir_is /tmp "sudo -nD /tmp git commit"
chdir_is /tmp "sudo --chdir /tmp git commit"
chdir_is /tmp "sudo --chdir=/tmp git commit"
chdir_is /b   "sudo -D /a -D /b git commit"
chdir_is ''   "sudo -R /tmp git commit"
chdir_is ''   "sudo -u root git commit"
chdir_is ''   "git commit"

# --- block-hq-root-git-mutation.sh: sudo -D DIR anchors git like git -C DIR ---
GIT_HOOK="$ROOT/.claude/hooks/block-hq-root-git-mutation.sh"
GTMP="$(cd "$TMP" && pwd -P)/git"
mkdir -p "$GTMP/hq/sub" "$GTMP/out"
git -C "$GTMP/hq" init -q
git -C "$GTMP/out" init -q
grun() { # <expected exit> <command> <label>
  local expect="$1" cmd="$2" label="$3" rc=0 payload
  payload=$(jq -n --arg cwd "$GTMP/hq" --arg cmd "$cmd" '{cwd: $cwd, tool_input: {command: $cmd}}')
  printf '%s' "$payload" | CLAUDE_PROJECT_DIR="$GTMP/hq" HQ_ALLOW_HQ_ROOT_GIT= bash "$GIT_HOOK" >/dev/null 2>&1 || rc=$?
  if [ "$rc" -eq "$expect" ]; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1))
    echo "FAIL [git guard: $label]: expected exit $expect, got $rc -- cmd: $cmd" >&2
  fi
}
grun 2 "sudo -u root git commit -m x"                 'sudo -u root git commit at the HQ root blocked'
grun 0 "sudo -D $GTMP/out git commit -m x"            'sudo -D <other repo> git commit allowed'
grun 0 "sudo --chdir=$GTMP/out git commit -m x"       'sudo --chdir=<other repo> git commit allowed'
grun 0 "sudo -nD $GTMP/out git commit -m x"           'sudo -nD <other repo> git commit allowed'
grun 2 "sudo -D $GTMP/hq git commit -m x"             'sudo -D <HQ root> git commit blocked'
grun 2 "sudo -D . git commit -m x"                    'sudo -D . git commit blocked'
grun 2 "sudo -D sub git commit -m x"                  'sudo -D <HQ subdir> git commit blocked'
grun 2 "sudo -D $GTMP/out git -C $GTMP/hq commit -m x" 'git -C <HQ root> after sudo -D <other> blocked'
grun 2 "sudo -R $GTMP/out git commit -m x"            'sudo -R is not a chdir: still blocked'
grun 2 "sudo -D $GTMP/out true; git commit -m x"      'sudo -D does not anchor the next command'

echo "block-core-writes-bash-sudo-options: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
