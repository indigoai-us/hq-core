#!/usr/bin/env bash
# hq-core: public
#
# Regression test for the US-003 disruption review
# (workspace/orchestrator/session-fingerprints/review/DISRUPTION-hq-core-staging.md).
# One section per report item (B1-B4, N1-N5, N7, N9) and per item of the
# re-review (DISRUPTION-hq-core-staging-rereview.md: N-A, N-B1, N-B2, N-C,
# N-E, N-G); each one repeats the report's experiment against
# core/scripts/hq-fingerprint-hooks.sh,
# core/scripts/commit-secret-scan.sh, the shared dispatcher
# (core/scripts/lib/git-hooks-dispatcher.sh) and the SessionStart hook.
#
# Every section runs in a fresh sandbox: its own HOME, GIT_CONFIG_GLOBAL,
# XDG_CONFIG_HOME, GIT_CONFIG_NOSYSTEM=1 and a fake HQ root, so the real
# machine's git config is never touched. Makes real `git commit`s. The hq CLI
# is a stub that logs every call.
#
# SRC=<tree> runs the same checks against another checkout's core/ (used to
# show the checks fail on the code before the fixes).
# US004LIB=<file> is the US-004 `git commit` helper (core/scripts/lib/
# fingerprint.sh), which shares the per-session cache with the stage. N-A
# and N-E need it and are skipped, with a message, when it is not there.
#
# Prints one "timing:" line per wired state (median ms per commit).
# shellcheck disable=SC2016 # hook bodies and init.sh lines are written unexpanded
set -u
# Git hooks export these; a test run from inside a hook must not inherit them.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY GIT_PREFIX
unset CLAUDE_PROJECT_DIR CI HQ_ROOT HQ_FINGERPRINT_TIMEOUT_TENTHS HQ_SECRET_SCAN_HOOKS_DIR
unset HQ_FINGERPRINT_CAPABILITY_CACHE HQ_FINGERPRINT_CAPABILITY_TTL_SECS GHD_STUB_SHELL
unset HQ_SESSION_ID CLAUDE_CODE_SESSION_ID CLAUDE_SESSION_ID CODEX_SESSION_ID CODEX_THREAD_ID GROK_SESSION_ID
unset HQ_AGENT_WORKDIR HQ_AGENT_COMPANY_DIR HQ_AGENT_IDENTITY_FILE OUTPOST_INSTANCE_TOKEN
REAL="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
SRC="${SRC:-$REAL}"
US004LIB="${US004LIB:-$REAL/core/scripts/lib/fingerprint.sh}"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
T="$(cd "$T" && pwd -P)"
# Not a fleet or Outpost box unless a section says so.
export HQ_AGENT_ROOT_PREFIX="$T/noagent"
export GIT_CONFIG_NOSYSTEM=1
BASE_PATH="$PATH"

# hq stub for HQ_FINGERPRINT_BIN / HQ_SECRET_SCAN_BIN: logs each call to
# $T/hq-calls; `fingerprint self` prints the value in $T/fp-value (junk or
# a null fingerprint when $T/fp-mode says so); `scan secrets` passes
# everything.
cat >"$T/stub-hq" <<'STUB'
#!/bin/sh
d="$(dirname "$0")"
echo "$*" >>"$d/hq-calls"
case "${1:-} ${2:-}" in
  "fingerprint self")
    case "$(cat "$d/fp-mode" 2>/dev/null)" in
      junk) echo "not json"; exit 0 ;;
      null) echo '{"fingerprint":null,"reason":"no HQ session"}'; exit 0 ;;
    esac
    printf '{"fingerprint":"%s","source":"session"}\n' "$(cat "$d/fp-value")" ;;
  "scan secrets")
    [ "${3:-}" = "--help" ] && { echo "usage: hq scan secrets [--staged] [files...]"; exit 0; }
    exit 0 ;;
  *) exit 2 ;;
esac
STUB
chmod +x "$T/stub-hq"

# An installed-style hq CLI: bin/hq inside a package folder whose
# package.json names @indigoai-us/hq-cli. $T/real-mode "old" acts like
# 5.345.129 and 5.345.130 (no `fingerprint` command, exit 1); "ok" prints a
# fingerprint.
mkfakecli() { # dir version
  mkdir -p "$1/bin"
  printf '{\n  "name": "@indigoai-us/hq-cli",\n  "version": "%s"\n}\n' "$2" >"$1/package.json"
  cat >"$1/bin/hq" <<EOS
#!/bin/sh
echo "\$*" >>'$T/real-calls'
case "\${1:-}" in
  fingerprint)
    if [ "\$(cat '$T/real-mode')" = old ]; then echo "error: unknown command 'fingerprint'" >&2; exit 1; fi
    printf '{"fingerprint":"%s"}\n' "\$(cat '$T/fp-value')" ;;
  *) exit 1 ;;
esac
EOS
  chmod +x "$1/bin/hq"
}
mkfakecli "$T/pkg/hq-cli" 5.345.129
mkfakecli "$T/pkg2/hq-cli" 5.400.0
mkfakecli "$T/pkg3/hq-cli" 5.345.130

# Counts PATH lookups of bash made by git hooks.
mkdir -p "$T/shim"
cat >"$T/shim/bash" <<EOS
#!/bin/sh
echo "\$*" >>'$T/bash-calls'
exec /bin/bash "\$@"
EOS
chmod +x "$T/shim/bash"

pass=0; fail=0
ok() { if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "ok   $1"; else fail=$((fail+1)); echo "FAIL $1 (want $2, got $3)"; fi; }
rnd() { LC_ALL=C tr -dc "$1" </dev/urandom | head -c "$2"; }
newfp() { printf 'hqfp1:%s' "$(rnd 'a-z2-7' 26)" >"$T/fp-value"; cat "$T/fp-value"; }
lines() { if [ -f "$1" ]; then grep -c "${2:-}" "$1"; else echo 0; fi; }
repo() { mkdir -p "$1"; git -C "$1" init -q; echo "$1"; }
n=0
commit() { # repo [extra commit args...]
  local r="$1"; shift; n=$((n+1))
  echo "$n" >"$r/f.txt"; git -C "$r" add f.txt
  git -C "$r" commit -q -m "change $n" "$@" >/dev/null 2>&1
}
trailer() { git -C "$1" log -1 --format='%(trailers:key=HQ-Fingerprint,valueonly)' | sed '/^$/d'; }
stamp() { stat -c '%i %Y' "$1" 2>/dev/null || stat -f '%i %m' "$1"; }
now_ms() { perl -MTime::HiRes=time -e 'printf "%d\n", time() * 1000'; }
# Median wall time in ms of 5 commits to <repo>, run with the caller's env.
time5() { # repo
  local t0 t1 all=""
  for _ in 1 2 3 4 5; do
    t0=$(now_ms); commit "$1"; t1=$(now_ms)
    all="$all $((t1 - t0))"
  done
  # shellcheck disable=SC2086 # one number per word
  printf '%s\n' $all | sort -n | sed -n 3p
}
# "<unwired ms> <wired ms>": medians of 7 commits each to <repo>, taken in
# turns so a load change on the machine hits both sides. The unwired turn
# points core.hooksPath at the repo's own hooks folder, which is what git
# uses when nothing is wired.
time_pair() { # repo
  local t0 t1 a="" b=""
  for _ in 1 2 3 4 5 6 7; do
    t0=$(now_ms)
    GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0="$1/.git/hooks" commit "$1"
    t1=$(now_ms); a="$a $((t1 - t0))"
    t0=$(now_ms); commit "$1"; t1=$(now_ms); b="$b $((t1 - t0))"
  done
  # shellcheck disable=SC2086 # one number per word
  printf '%s %s\n' "$(printf '%s\n' $a | sort -n | sed -n 4p)" "$(printf '%s\n' $b | sort -n | sed -n 4p)"
}
# yes when <ms> is at most <base> + <slack>.
within() { [ "$1" -le $(($2 + $3)) ] && echo yes || echo "no ($1 ms vs $2 ms + $3)"; }
sid_cache() { echo "$R/workspace/sessions/$1/fingerprint-trailer.cache"; }
# The US-004 helper in a subshell, as the `git commit` wrapper calls it.
helper() { ( . "$US004LIB"; hq_fingerprint_trailer_args "$R" ) >/dev/null 2>&1; }

mkroot() { # dir
  mkdir -p "$1/core/scripts/lib" "$1/core/settings" "$1/core/hooks/SessionStart" "$1/repos"
  : >"$1/core/core.yaml"
  cp "$SRC/core/scripts/commit-secret-scan.sh" "$SRC/core/scripts/hq-fingerprint-hooks.sh" "$1/core/scripts/"
  cp "$SRC/core/scripts/lib/git-hooks-dispatcher.sh" "$SRC/core/scripts/lib/hq-cli-floor.sh" "$1/core/scripts/lib/"
  [ -f "$SRC/core/scripts/lib/hq-cli-capability.sh" ] && cp "$SRC/core/scripts/lib/hq-cli-capability.sh" "$1/core/scripts/lib/"
  cp "$SRC/core/settings/commit-secret-scan.yaml" "$SRC/core/settings/fingerprint.yaml" "$1/core/settings/"
  cp "$SRC/core/hooks/SessionStart/40-fingerprint-hooks-enable.sh" "$1/core/hooks/SessionStart/"
}

# A fresh machine: new HOME and global git config, a new HQ root at $R.
k=0
reset() {
  k=$((k+1))
  export HOME="$T/home$k"
  export GIT_CONFIG_GLOBAL="$HOME/.gitconfig" XDG_CONFIG_HOME="$HOME/.config"
  export PATH="$BASE_PATH"
  export HQ_FINGERPRINT_BIN="$T/stub-hq" HQ_SECRET_SCAN_BIN="$T/stub-hq"
  mkdir -p "$HOME"
  git -C "$T" config --global user.email t@example.invalid
  git -C "$T" config --global user.name test
  git -C "$T" config --global init.defaultBranch main
  R="$T/hq$k/my hq root"
  mkroot "$R"
  F="$R/core/scripts/hq-fingerprint-hooks.sh"
  S="$R/core/scripts/commit-secret-scan.sh"
  SS="$R/core/hooks/SessionStart/40-fingerprint-hooks-enable.sh"
  LIB="$R/core/scripts/lib/git-hooks-dispatcher.sh"
  HOOKS="$HOME/.hq/git-hooks"
  : >"$T/hq-calls"; : >"$T/real-calls"; : >"$T/bash-calls"
  echo ok >"$T/fp-mode"
  newfp >/dev/null
}

# A husky v9 repo: core.hooksPath=.husky/_, each hook sources .husky/_/h,
# which sources ~/.config/husky/init.sh with $n set, then runs .husky/<n>.
husky_repo() { # dir
  repo "$1" >/dev/null
  mkdir -p "$1/.husky/_"
  cat >"$1/.husky/_/h" <<'EOS'
#!/bin/sh
n=$(basename "$0")
s=$(dirname "$(dirname "$0")")/$n
[ ! -f "$s" ] && exit 0
i="${XDG_CONFIG_HOME:-$HOME/.config}/husky/init.sh"
[ -f "$i" ] && . "$i"
[ "${HUSKY-}" = "0" ] && exit 0
sh -e "$s" "$@"
c=$?
[ $c != 0 ] && echo "husky - $n script failed (code $c)"
exit $c
EOS
  for h in pre-commit commit-msg; do
    printf '#!/bin/sh\n. "$(dirname "$0")/h"\n' >"$1/.husky/_/$h"
    chmod +x "$1/.husky/_/$h"
  done
  chmod +x "$1/.husky/_/h"
  printf 'echo ran >>"%s"\n' "$1.husky-log" >"$1/.husky/pre-commit"
  git -C "$1" config core.hooksPath .husky/_
}

# ---------------------------------------------------------------- B1
# An hq CLI without `hq fingerprint` must not be started on every commit
# (since N-B1 it is not started at all: it is below the version floor); a
# working one is started once per session.
reset
unset HQ_FINGERPRINT_BIN
echo old >"$T/real-mode"
in1=$(repo "$R/repos/private/app")
bash "$F" enable >/dev/null 2>&1
for _ in 1 2 3; do HQ_SESSION_ID=b1-old PATH="$T/pkg/hq-cli/bin:$BASE_PATH" commit "$in1"; done
ok "B1 old hq CLI: not started for three commits" 0 "$(lines "$T/real-calls" '^fingerprint')"
ok "B1 old hq CLI: commits still land" 3 "$(git -C "$in1" rev-list --count HEAD)"
grep -q "$(printf '\t')below-floor$(printf '\t')" "$HOME/.hq/fingerprint-capability.cache" 2>/dev/null && st=yes || st=no
ok "B1 old hq CLI: below-floor cached in ~/.hq/fingerprint-capability.cache" yes "$st"

reset
unset HQ_FINGERPRINT_BIN
echo ok >"$T/real-mode"
fp="$(cat "$T/fp-value")"
in1=$(repo "$R/repos/private/app")
bash "$F" enable >/dev/null 2>&1
for _ in 1 2 3; do HQ_SESSION_ID=b1-session PATH="$T/pkg2/hq-cli/bin:$BASE_PATH" commit "$in1"; done
ok "B1 working hq CLI: started once per session" 1 "$(lines "$T/real-calls" '^fingerprint')"
ok "B1 working hq CLI: every commit has the trailer" "$fp $fp $fp" \
  "$(git -C "$in1" log -3 --format='%(trailers:key=HQ-Fingerprint,valueonly)' | sed '/^$/d' | tr '\n' ' ' | sed 's/ $//')"

# ---------------------------------------------------------------- B2
# Outside HQ, a fingerprint-only box starts no bash for a commit, a
# checkout or a husky commit.
reset
mkdir -p "$XDG_CONFIG_HOME/husky"
out=$(repo "$T/b2/outside")
bash "$F" enable >/dev/null 2>&1
commit "$out"
: >"$T/bash-calls"
PATH="$T/shim:$BASE_PATH" commit "$out"
ok "B2 outside commit: no bash started" 0 "$(lines "$T/bash-calls")"
git -C "$out" branch -q other
: >"$T/bash-calls"
PATH="$T/shim:$BASE_PATH" git -C "$out" checkout -q other
PATH="$T/shim:$BASE_PATH" git -C "$out" checkout -q main
ok "B2 outside checkout there and back: no bash started" 0 "$(lines "$T/bash-calls")"
hus=$(husky_repo "$T/b2/husky"; echo "$T/b2/husky")
: >"$T/bash-calls"
PATH="$T/shim:$BASE_PATH" commit "$hus"; rc=$?
ok "B2 outside husky commit succeeds" 0 "$rc"
ok "B2 outside husky commit: no bash started" 0 "$(lines "$T/bash-calls")"
ok "B2 outside husky commit: the repo's husky hook ran" 1 "$(lines "$hus.husky-log")"

# ---------------------------------------------------------------- B3
# The lib is gone (revert, moved or removed HQ folder). exp2 E: husky
# repos still commit. exp2 F: a repo's own hooks still run.
reset
mkdir -p "$XDG_CONFIG_HOME/husky"
hus=$(husky_repo "$T/b3/husky"; echo "$T/b3/husky")
own=$(repo "$T/b3/own")
printf '#!/bin/sh\necho ran >>"%s"\n' "$T/b3/own-log" >"$own/.git/hooks/pre-commit"
chmod +x "$own/.git/hooks/pre-commit"
bash "$F" enable >/dev/null 2>&1
mv "$LIB" "$LIB.away"
commit "$hus"; rc=$?
ok "B3 exp2 E: husky repo commit with the lib missing succeeds" 0 "$rc"
ok "B3 exp2 E: the husky hook ran" 1 "$(lines "$hus.husky-log")"
commit "$own"; rc=$?
ok "B3 exp2 F: commit with the lib missing succeeds" 0 "$rc"
ok "B3 exp2 F: the repo's own pre-commit still runs" 1 "$(lines "$T/b3/own-log")"
mv "$LIB.away" "$LIB"

# Secret scan on: still fails closed, and says how to repair.
reset
out=$(repo "$T/b3/scan")
bash "$S" enable >/dev/null 2>&1
mv "$LIB" "$LIB.away"
n=$((n+1)); echo "$n" >"$out/f.txt"; git -C "$out" add f.txt
err="$(git -C "$out" commit -q -m blocked 2>&1 >/dev/null)"; rc=$?
[ "$rc" -ne 0 ] && st=blocked || st=committed
ok "B3 secret scan on, lib missing: commit blocked" blocked "$st"
case "$err" in *"git-hooks-dispatcher.sh repair"*) st=yes ;; *) st=no ;; esac
ok "B3 secret scan on, lib missing: message names the repair command" yes "$st"
mv "$LIB.away" "$LIB"

# The HQ folder moved: `repair` from the new place rewrites the stubs.
R2="$T/b3/moved hq"
mv "$(dirname "$R")" "$T/b3/moved-parent"; R="$T/b3/moved-parent/my hq root"
mv "$R" "$R2"
rep="$(bash "$R2/core/scripts/lib/git-hooks-dispatcher.sh" repair 2>&1)"
case "$rep" in Rewrote:*) st=yes ;; *) st=no ;; esac
ok "B3 repair after a move rewrites the stubs" yes "$st"
grep -qF "$R2/core/scripts/lib/git-hooks-dispatcher.sh" "$HOOKS/pre-commit" 2>/dev/null && st=yes || st=no
ok "B3 repair: stubs point at the new lib" yes "$st"
commit "$out"; rc=$?
ok "B3 repair: scanned commits work again" 0 "$rc"
R3="$T/b3/moved again"
mv "$R2" "$R3"
first="$(bash "$R3/core/scripts/commit-secret-scan.sh" enable 2>&1 | head -n 1)"
ok "B3 enable while wired after a move" "Already on." "$first"
grep -qF "$R3/core/scripts/lib/git-hooks-dispatcher.sh" "$HOOKS/pre-commit" 2>/dev/null && st=yes || st=no
ok "B3 enable while wired rewrites stale stubs" yes "$st"

# ---------------------------------------------------------------- B4
# A global core.hooksPath written as ~/.githooks keeps running.
reset
mkdir -p "$HOME/.githooks"
printf '#!/bin/sh\necho ran >>"%s"\n' "$T/b4-log" >"$HOME/.githooks/pre-commit"
chmod +x "$HOME/.githooks/pre-commit"
# shellcheck disable=SC2088 # the literal ~ is the point
git -C "$T" config --global core.hooksPath '~/.githooks'
out=$(repo "$T/b4/outside")
commit "$out"
ok "B4 own global hook runs before HQ" 1 "$(lines "$T/b4-log")"
bash "$F" enable >/dev/null 2>&1
commit "$out"
ok "B4 own global hook (~ form) runs while HQ is wired" 2 "$(lines "$T/b4-log")"
bash "$F" disable >/dev/null 2>&1
commit "$out"
ok "B4 own global hook runs after disable" 3 "$(lines "$T/b4-log")"
# shellcheck disable=SC2088
ok "B4 disable restores the literal ~ value" '~/.githooks' "$(git -C "$T" config --global --get core.hooksPath)"

# ---------------------------------------------------------------- N1
# init.sh without a final newline.
reset
mkdir -p "$XDG_CONFIG_HOME/husky"
INIT="$XDG_CONFIG_HOME/husky/init.sh"
printf 'export MYVAR=1' >"$INIT"
bash "$S" enable >/dev/null 2>&1
dash -n "$INIT" 2>/dev/null && st=yes || st=no
ok "N1 init.sh parses under dash" yes "$st"
sh -n "$INIT" 2>/dev/null && st=yes || st=no
ok "N1 init.sh parses under sh" yes "$st"
ok "N1 dash keeps the user's variable" 1 "$(dash -c 'n=post-checkout; . "$1"; echo "${MYVAR:-}"' x "$INIT" 2>/dev/null)"
ok "N1 sh keeps the user's variable" 1 "$(sh -c 'n=post-checkout; . "$1"; echo "${MYVAR:-}"' x "$INIT" 2>/dev/null)"
# A file already joined by the old code is repaired.
reset
mkdir -p "$XDG_CONFIG_HOME/husky"
INIT="$XDG_CONFIG_HOME/husky/init.sh"
printf '%s\n' 'export MYVAR=1# >>> HQ commit secret scan (core/scripts/commit-secret-scan.sh) >>>' \
  'case "${n:-}" in' '  pre-commit|commit-msg) bash /gone/git-hooks-dispatcher.sh husky "$n" "$@" || exit 1 ;;' \
  'esac' '# <<< HQ commit secret scan <<<' >"$INIT"
bash "$S" enable >/dev/null 2>&1
ok "N1 joined line split back to the user's line" 1 "$(grep -c '^export MYVAR=1$' "$INIT")"
ok "N1 exactly one HQ block" 1 "$(grep -c '>>> HQ' "$INIT")"
dash -n "$INIT" 2>/dev/null && st=yes || st=no
ok "N1 repaired init.sh parses under dash" yes "$st"

# ---------------------------------------------------------------- N2
# A "---" line in the body does not move the trailer.
reset
in1=$(repo "$R/repos/private/app")
bash "$F" enable >/dev/null 2>&1
fp="$(cat "$T/fp-value")"
printf 'Subject\n\nSome text\n---\nMore text\n' >"$T/n2-msg"
echo n2 >"$in1/f.txt"; git -C "$in1" add f.txt
HQ_SESSION_ID=n2 git -C "$in1" commit -q -F "$T/n2-msg" >/dev/null 2>&1
ok "N2 trailer readable with %(trailers)" "$fp" "$(trailer "$in1")"
ok "N2 trailer is the last line" "HQ-Fingerprint: $fp" "$(git -C "$in1" log -1 --format=%B | sed '/^$/d' | tail -n 1)"

# ---------------------------------------------------------------- N3
# Hooks the old stub list did not cover still run: post-update in a local
# bare repo, post-index-change in a work tree.
reset
bare="$T/n3/bare.git"
git init -q --bare "$bare"
printf '#!/bin/sh\necho ran >>"%s"\n' "$T/n3-post-update" >"$bare/hooks/post-update"
chmod +x "$bare/hooks/post-update"
git -C "$T" clone -q "$bare" "$T/n3/work" 2>/dev/null
work="$T/n3/work"
printf '#!/bin/sh\necho ran >>"%s"\n' "$T/n3-pic" >"$work/.git/hooks/post-index-change"
chmod +x "$work/.git/hooks/post-index-change"
commit "$work"; git -C "$work" push -q origin HEAD:main 2>/dev/null
pu_before="$(lines "$T/n3-post-update")"; pic_before="$(lines "$T/n3-pic")"
bash "$F" enable >/dev/null 2>&1
commit "$work"; git -C "$work" push -q origin HEAD:main 2>/dev/null
ok "N3 post-update runs once per push, before and after wiring" "1 2" "$pu_before $(lines "$T/n3-post-update")"
[ "$pic_before" -ge 1 ] && [ "$(lines "$T/n3-pic")" -ge $((pic_before * 2)) ] && st=yes || st=no
ok "N3 post-index-change runs after wiring as before ($pic_before, then $(lines "$T/n3-pic"))" yes "$st"

# ---------------------------------------------------------------- N4
# enabled: false stops the stage even while still wired.
reset
in1=$(repo "$R/repos/private/app")
bash "$F" enable >/dev/null 2>&1
mkdir -p "$R/personal/settings"
printf 'enabled: false\n' >"$R/personal/settings/fingerprint.yaml"
: >"$T/hq-calls"
commit "$in1"
ok "N4 kill switch: no trailer" "" "$(trailer "$in1")"
ok "N4 kill switch: hq not started" 0 "$(lines "$T/hq-calls")"

# ---------------------------------------------------------------- N5
# Fleet and Outpost boxes are left alone by SessionStart.
reset
HQ_AGENT_WORKDIR=/srv/agent bash "$SS"
ok "N5 HQ_AGENT_WORKDIR: not wired" "" "$(git -C "$T" config --global --get core.hooksPath)"
OUTPOST_INSTANCE_TOKEN=x bash "$SS"
ok "N5 OUTPOST_INSTANCE_TOKEN: not wired" "" "$(git -C "$T" config --global --get core.hooksPath)"
mkdir -p "$T/n5box/etc/outpost"; : >"$T/n5box/etc/outpost/codex-identity.env"
HQ_AGENT_ROOT_PREFIX="$T/n5box" bash "$SS"
ok "N5 Outpost identity file: not wired" "" "$(git -C "$T" config --global --get core.hooksPath)"
mkdir -p "$T/n5fleet/var/lib/hq-agent"; : >"$T/n5fleet/var/lib/hq-agent/machine-creds.json"
HQ_AGENT_ROOT_PREFIX="$T/n5fleet" bash "$SS"
ok "N5 fleet machine-creds file: not wired" "" "$(git -C "$T" config --global --get core.hooksPath)"
bash "$SS"
ok "N5 ordinary box: wired" "$HOOKS" "$(git -C "$T" config --global --get core.hooksPath)"

# ---------------------------------------------------------------- N7
# Windows: core.hooksPath in another spelling of the same folder.
reset
bash "$F" enable >/dev/null 2>&1
mkdir -p "$T/n7bin"
cat >"$T/n7bin/cygpath" <<'EOS'
#!/bin/sh
p="$2"
case "$p" in */.hq/git-hooks|C:/fake/hooks) echo C:/fake/hooks ;; *) echo "$p" ;; esac
EOS
chmod +x "$T/n7bin/cygpath"
git -C "$T" config --global core.hooksPath C:/fake/hooks
ok "N7 status reads on for an equivalent path" "fingerprint trailer: on" "$(PATH="$T/n7bin:$BASE_PATH" bash "$F" status | head -n 1)"
ln -s "$HOOKS" "$HOME/hooks-alias"
git -C "$T" config --global core.hooksPath "$HOME/hooks-alias"
ok "N7 status reads on through a symlink" "fingerprint trailer: on" "$(bash "$F" status | head -n 1)"

# ---------------------------------------------------------------- N9
reset
in1=$(repo "$R/repos/private/app")
bash "$F" enable >/dev/null 2>&1
[ -d "$XDG_CONFIG_HOME/husky" ] && st=created || st=absent
ok "N9 no husky on the box: ~/.config/husky not created" absent "$st"
LOG="$HOME/.hq/fingerprint-hook.log"
mkdir -p "$HOME/.hq"
head -c 1100000 /dev/zero | tr '\0' x >"$LOG"
echo junk >"$T/fp-mode"
HQ_SESSION_ID=n9 commit "$in1"
[ -f "$LOG.1" ] && st=yes || st=no
ok "N9 log over 1 MB rotated to .1" yes "$st"
[ "$(wc -c <"$LOG" | tr -d ' ')" -lt 1048576 ] && st=yes || st=no
ok "N9 log restarted small" yes "$st"
before="$(stamp "$HOOKS/commit-msg")"
sleep 1
bash "$F" enable >/dev/null 2>&1
rep="$(bash "$LIB" repair 2>&1)"
ok "N9 repair with nothing stale" "HQ git hooks are up to date." "$rep"
ok "N9 unchanged stubs are not rewritten" "$before" "$(stamp "$HOOKS/commit-msg")"

reset
mkdir -p "$XDG_CONFIG_HOME/husky"
INIT="$XDG_CONFIG_HOME/husky/init.sh"
printf '%s\n' 'export KEEP=1' '# >>> HQ commit secret scan (core/scripts/commit-secret-scan.sh) >>>' \
  'case "${n:-}" in' '  pre-commit|commit-msg) bash /old/git-hooks-dispatcher.sh husky "$n" "$@" || exit 1 ;;' \
  'esac' '# <<< HQ commit secret scan <<<' >"$INIT"
bash "$F" enable >/dev/null 2>&1
ok "N9 husky block labelled HQ git hooks" 1 "$(grep -c '^# >>> HQ git hooks' "$INIT")"
ok "N9 legacy block stripped" 0 "$(grep -c 'HQ commit secret scan' "$INIT")"
ok "N9 user's lines kept" 1 "$(grep -c '^export KEEP=1$' "$INIT")"

# ---------------------------------------------------------------- N-A
# The stage and the US-004 `git commit` helper share one per-session cache
# (workspace/sessions/<id>/fingerprint-trailer.cache, format v2), so a
# session builds its fingerprint once whichever of the two goes first.
if [ -f "$US004LIB" ]; then
  reset
  in1=$(repo "$R/repos/private/app")
  bash "$F" enable >/dev/null 2>&1
  fp="$(cat "$T/fp-value")"
  export HQ_SESSION_ID=na-stub
  helper; commit "$in1"; helper; commit "$in1"
  ok "N-A stub: helper, commit, helper, commit build once" 1 "$(lines "$T/hq-calls" '^fingerprint')"
  ok "N-A stub: the commit has the trailer" "$fp" "$(trailer "$in1")"
  ok "N-A stub: cache in the US-004 v2 format" "hq-fingerprint-trailer.v2|bin:$T/stub-hq|value:$fp|" \
    "$(tr '\n' '|' <"$(sid_cache na-stub)" 2>/dev/null)"
  export HQ_SESSION_ID=na-stub2
  : >"$T/hq-calls"
  commit "$in1"; helper; commit "$in1"; helper
  ok "N-A stub: commit, helper, commit, helper build once" 1 "$(lines "$T/hq-calls" '^fingerprint')"
  unset HQ_SESSION_ID

  reset
  unset HQ_FINGERPRINT_BIN
  echo ok >"$T/real-mode"
  in1=$(repo "$R/repos/private/app")
  bash "$F" enable >/dev/null 2>&1
  fp="$(cat "$T/fp-value")"
  export HQ_SESSION_ID=na-real PATH="$T/pkg2/hq-cli/bin:$BASE_PATH"
  helper; commit "$in1"; helper; commit "$in1"
  ok "N-A hq-cli 5.400.0: helper, commit, helper, commit start hq once" 1 "$(lines "$T/real-calls" '^fingerprint')"
  ok "N-A hq-cli 5.400.0: the commit has the trailer" "$fp" "$(trailer "$in1")"
  ok "N-A hq-cli 5.400.0: cache key" "hq-cli:5.400.0" "$(sed -n 2p "$(sid_cache na-real)" 2>/dev/null)"
  unset HQ_SESSION_ID; export PATH="$BASE_PATH"
else
  echo "SKIP N-A: US-004 helper not found at $US004LIB (set US004LIB to core/scripts/lib/fingerprint.sh of the US-004 tree)"
fi

# ---------------------------------------------------------------- N-E
# A session with no fingerprint (hq answers null) is cached as `none`: the
# builder is not started again for that session.
reset
in1=$(repo "$R/repos/private/app")
bash "$F" enable >/dev/null 2>&1
echo null >"$T/fp-mode"
for _ in 1 2 3; do HQ_SESSION_ID=ne-commits commit "$in1"; done
ok "N-E null fingerprint: three commits start hq once" 1 "$(lines "$T/hq-calls" '^fingerprint')"
ok "N-E null fingerprint: no trailer" "" "$(trailer "$in1")"
ok "N-E null fingerprint: cached as none" none "$(sed -n 3p "$(sid_cache ne-commits)" 2>/dev/null)"
if [ -f "$US004LIB" ]; then
  : >"$T/hq-calls"
  export HQ_SESSION_ID=ne-helper
  helper
  for _ in 1 2 3; do commit "$in1"; done
  ok "N-E null fingerprint: helper then three commits start hq once" 1 "$(lines "$T/hq-calls" '^fingerprint')"
  unset HQ_SESSION_ID
else
  echo "SKIP N-E helper step: US-004 helper not found at $US004LIB"
fi

# ---------------------------------------------------------------- N-B1
# An hq CLI below the version floor (today's 5.345.129 and 5.345.130) is
# never started, and a commit costs what it costs unwired.
for v in 5.345.129:pkg 5.345.130:pkg3; do
  reset
  unset HQ_FINGERPRINT_BIN
  echo old >"$T/real-mode"
  in1=$(repo "$R/repos/private/app")
  export HQ_SESSION_ID="nb1-${v%%:*}" PATH="$T/${v#*:}/hq-cli/bin:$BASE_PATH"
  commit "$in1"
  base=$(time5 "$in1")
  bash "$F" enable >/dev/null 2>&1
  : >"$T/real-calls"
  wired=$(time5 "$in1")
  ok "N-B1 hq-cli ${v%%:*}: five commits start hq zero times" 0 "$(lines "$T/real-calls" '^fingerprint')"
  [ -e "$R/workspace/sessions/$HQ_SESSION_ID" ] && st=present || st=absent
  ok "N-B1 hq-cli ${v%%:*}: no session cache" absent "$st"
  ok "N-B1 hq-cli ${v%%:*}: commit within 100 ms of unwired" yes "$(within "$wired" "$base" 100)"
  echo "timing: unwired ${base} ms; wired, hq-cli ${v%%:*} below floor ${wired} ms"
  unset HQ_SESSION_ID; export PATH="$BASE_PATH"
done

# ---------------------------------------------------------------- N-B2
# No agent session id: no trailer and nothing started, even with a capable
# hq. Timed next to a capable commit with a session id.
reset
in1=$(repo "$R/repos/private/app")
bash "$F" enable >/dev/null 2>&1
commit "$in1"
: >"$T/hq-calls"
nosid=$(time5 "$in1")
ok "N-B2 no session id: five commits start hq zero times" 0 "$(lines "$T/hq-calls" '^fingerprint')"
ok "N-B2 no session id: no trailer" "" "$(trailer "$in1")"
withsid=$(HQ_SESSION_ID=nb2 time5 "$in1")
ok "N-B2 with a session id: built once" 1 "$(lines "$T/hq-calls" '^fingerprint')"
echo "timing: wired, capable, session id ${withsid} ms; wired, capable, no session id ${nosid} ms"

# ---------------------------------------------------------------- N-C
# HOME unset (cron, launchd, some CI): commits still land, inside HQ with the
# trailer wired and outside HQ with the secret scan on.
reset
in1=$(repo "$R/repos/private/app")
out=$(repo "$T/nc/outside")
bash "$F" enable >/dev/null 2>&1
bash "$S" enable >/dev/null 2>&1
fp="$(cat "$T/fp-value")"
( unset HOME; HQ_SESSION_ID=nc commit "$in1" ); rc=$?
ok "N-C HOME unset: commit inside HQ succeeds" 0 "$rc"
ok "N-C HOME unset: the commit inside HQ has the trailer" "$fp" "$(trailer "$in1")"
( unset HOME; commit "$out" ); rc=$?
ok "N-C HOME unset: secret-scanned commit outside HQ succeeds" 0 "$rc"
ok "N-C HOME unset: the secret scan ran" yes "$(grep -q '^scan secrets' "$T/hq-calls" && echo yes || echo no)"

# ---------------------------------------------------------------- N-G
# enabled: false is applied at the next session start: the fingerprint
# switch is cleared (no bash for a commit inside HQ), the dispatcher is put
# back when nothing else uses it and kept while the secret scan is on, the
# secret scan keeps running, and enabled: true turns it back on even when
# the day's stamp is already there.
reset
in1=$(repo "$R/repos/private/app")
commit "$in1"
bash "$F" enable >/dev/null 2>&1
mkdir -p "$R/personal/settings"
printf 'enabled: false\n' >"$R/personal/settings/fingerprint.yaml"
CLAUDE_PROJECT_DIR="$R" bash "$SS"
ok "N-G kill switch: fingerprint switch dropped with the dispatcher" "" "$(git -C "$T" config --global --get hq.hooks.fingerprint)"
ok "N-G kill switch: dispatcher put back (nothing else uses it)" "" "$(git -C "$T" config --global --get core.hooksPath)"
ok "N-G kill switch: hook stubs removed" no "$([ -e "$HOOKS/commit-msg" ] && echo yes || echo no)"
: >"$T/bash-calls"; : >"$T/hq-calls"
PATH="$T/shim:$BASE_PATH" HQ_SESSION_ID=ng commit "$in1"
ok "N-G kill switch: commit inside HQ starts no bash" 0 "$(lines "$T/bash-calls")"
ok "N-G kill switch: hq not started" 0 "$(lines "$T/hq-calls")"
pair=$(HQ_SESSION_ID=ng time_pair "$in1")
base=${pair% *}; killed=${pair#* }
ok "N-G kill switch: commit within 15 ms of unwired" yes "$(within "$killed" "$base" 15)"
echo "timing: unwired ${base} ms; kill switch on ${killed} ms"
printf 'enabled: true\n' >"$R/personal/settings/fingerprint.yaml"
mkdir -p "$HOME/.hq"; : >"$HOME/.hq/fingerprint-hooks-enable.$(date +%Y%m%d)"
CLAUDE_PROJECT_DIR="$R" bash "$SS"
ok "N-G enabled again: switch back on at the next start (same-day stamp)" true "$(git -C "$T" config --global --get hq.hooks.fingerprint)"
fp="$(newfp)"
HQ_SESSION_ID=ng-again commit "$in1"
ok "N-G enabled again: trailer back" "$fp" "$(trailer "$in1")"

reset
in1=$(repo "$R/repos/private/app")
bash "$F" enable >/dev/null 2>&1
bash "$S" enable >/dev/null 2>&1
mkdir -p "$R/personal/settings"
printf 'enabled: false\n' >"$R/personal/settings/fingerprint.yaml"
CLAUDE_PROJECT_DIR="$R" bash "$SS"
ok "N-G kill switch: secret scan switch kept" true "$(git -C "$T" config --global --get hq.hooks.secretScan)"
ok "N-G kill switch: fingerprint switch off with the secret scan on" false "$(git -C "$T" config --global --get hq.hooks.fingerprint)"
ok "N-G kill switch: dispatcher kept for the secret scan" "$HOOKS" "$(git -C "$T" config --global --get core.hooksPath)"
: >"$T/hq-calls"
commit "$in1"
ok "N-G kill switch: secret scan still runs" yes "$(grep -q '^scan secrets' "$T/hq-calls" && echo yes || echo no)"

echo
echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]
