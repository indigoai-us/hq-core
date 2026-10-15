#!/usr/bin/env bash
# hq-core: public
#
# Regression test for core/scripts/hq-fingerprint-hooks.sh, the shared git
# hook dispatcher (core/scripts/lib/git-hooks-dispatcher.sh) and the
# SessionStart hook that turns the trailer on.
#
# Runs in a sandbox: a temporary HOME, GIT_CONFIG_GLOBAL, XDG_CONFIG_HOME,
# GIT_CONFIG_NOSYSTEM=1 and a fake HQ root, so the real machine's git config
# is never touched. Makes real `git commit`s. The `hq fingerprint` and
# `hq scan secrets` commands are stubs.
#
# The fake HQ root has a space and a quote in its path, to prove the generated
# hook scripts quote it.
set -u
# Git hooks export these; a test run from inside a hook must not inherit them.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY GIT_PREFIX
unset CLAUDE_PROJECT_DIR CI HQ_FINGERPRINT_TIMEOUT_TENTHS HQ_SECRET_SCAN_HOOKS_DIR
REAL="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
ROOT="$T/my hq's root"
export HOME="$T/home" GIT_CONFIG_GLOBAL="$T/home/.gitconfig" XDG_CONFIG_HOME="$T/home/.config" GIT_CONFIG_NOSYSTEM=1
mkdir -p "$HOME" "$ROOT/core/scripts/lib" "$ROOT/core/settings" "$ROOT/core/hooks/SessionStart" "$ROOT/repos"
: >"$ROOT/core/core.yaml"
cp "$REAL/core/scripts/commit-secret-scan.sh" "$REAL/core/scripts/hq-fingerprint-hooks.sh" "$ROOT/core/scripts/"
cp "$REAL/core/scripts/lib/git-hooks-dispatcher.sh" "$REAL/core/scripts/lib/hq-cli-floor.sh" \
  "$REAL/core/scripts/lib/hq-cli-capability.sh" "$ROOT/core/scripts/lib/"
cp "$REAL/core/settings/commit-secret-scan.yaml" "$REAL/core/settings/fingerprint.yaml" "$ROOT/core/settings/"
cp "$REAL/core/hooks/SessionStart/40-fingerprint-hooks-enable.sh" "$ROOT/core/hooks/SessionStart/"
export HQ_ROOT="$ROOT"
# Not a fleet or Outpost box unless a test says so, and no agent session id.
unset HQ_AGENT_WORKDIR HQ_AGENT_COMPANY_DIR HQ_AGENT_IDENTITY_FILE OUTPOST_INSTANCE_TOKEN
unset HQ_SESSION_ID CLAUDE_CODE_SESSION_ID CLAUDE_SESSION_ID CODEX_SESSION_ID CODEX_THREAD_ID GROK_SESSION_ID
export HQ_AGENT_ROOT_PREFIX="$T/noagent"
F="$ROOT/core/scripts/hq-fingerprint-hooks.sh"
S="$ROOT/core/scripts/commit-secret-scan.sh"
SS="$ROOT/core/hooks/SessionStart/40-fingerprint-hooks-enable.sh"
LOG="$HOME/.hq/fingerprint-hook.log"

# hq stub: `fingerprint self` answers per $T/fp-mode with the value in
# $T/fp-value; `scan secrets` flags GitHub-token shapes.
cat >"$T/stub-hq" <<'STUB'
#!/usr/bin/env bash
d="$(dirname "$0")"
case "${1:-} ${2:-}" in
  "fingerprint self")
    echo x >>"$d/spawns"
    case "$(cat "$d/fp-mode")" in
      ok)    printf '{"fingerprint":"%s","source":"session","companies":["acme"]}\n' "$(cat "$d/fp-value")" ;;
      null)  printf '{"fingerprint":null,"reason":"no HQ session"}\n' ;;
      sleep) sleep 10; printf '{"fingerprint":"%s"}\n' "$(cat "$d/fp-value")" ;;
      child) sleep 30 & echo $! >"$d/child-pid"; wait ;;
      junk)  echo "not json" ;;
    esac ;;
  "scan secrets")
    shift 2
    [ "${1:-}" = "--help" ] && { echo "usage: hq scan secrets [--staged] [files...]"; exit 0; }
    pat='gh''p_[A-Za-z0-9]{36}'
    if [ "${1:-}" = "--staged" ]; then
      git diff --cached -U0 | grep -qE "^\+.*$pat" && { echo "stub: possible secret" >&2; exit 1; }
      exit 0
    fi
    grep -qE "$pat" "$@" 2>/dev/null && { echo "stub: possible secret" >&2; exit 1; }
    exit 0 ;;
  *) exit 2 ;;
esac
STUB
chmod +x "$T/stub-hq"
export HQ_FINGERPRINT_BIN="$T/stub-hq" HQ_SECRET_SCAN_BIN="$T/stub-hq"
echo ok >"$T/fp-mode"

git -C "$T" config --global user.email t@example.invalid
git -C "$T" config --global user.name test
git -C "$T" config --global init.defaultBranch main

pass=0; fail=0
ok() { if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "ok   $1"; else fail=$((fail+1)); echo "FAIL $1 (want $2, got $3)"; fi; }
rnd() { LC_ALL=C tr -dc "$1" </dev/urandom | head -c "$2"; }
# The trailer is cached per agent session; a new stub answer starts clean.
SC="$ROOT/workspace/sessions/test-session/fingerprint-trailer.cache"
fresh() { rm -f "$ROOT"/workspace/sessions/*/fingerprint-trailer.cache; }
newfp() { fresh; printf 'hqfp1:%s' "$(rnd 'a-z2-7' 26)" >"$T/fp-value"; cat "$T/fp-value"; }
mode() { fresh; echo "$1" >"$T/fp-mode"; }
spawns() { if [ -f "$T/spawns" ]; then wc -l <"$T/spawns" | tr -d ' '; else echo 0; fi; }
repo() { local d="$1"; mkdir -p "$d"; git -C "$d" init -q; echo "$d"; }
n=0
commit() { # repo [extra commit args...]
  local r="$1"; shift; n=$((n+1))
  echo "$n" >"$r/f.txt"; git -C "$r" add f.txt
  git -C "$r" commit -q -m "change $n" "$@" >/dev/null 2>&1
}
trailer() { git -C "$1" log -1 --format='%(trailers:key=HQ-Fingerprint,valueonly)' | sed '/^$/d'; }
ntrailers() { git -C "$1" log -1 --format=%B | grep -c '^HQ-Fingerprint:'; }
commits() { git -C "$1" rev-list --count HEAD 2>/dev/null || echo 0; }
snapshot() { # the global git state a round trip must leave alone
  printf '%s\n' "--- file"; cat "$GIT_CONFIG_GLOBAL" 2>/dev/null
  printf '%s\n' "--- list"; git -C "$T" config --global --list 2>/dev/null
  printf '%s\n' "--- hooks"; ls -la "$HOME/.hq/git-hooks" 2>/dev/null
  printf '%s\n' "--- husky"; cat "$XDG_CONFIG_HOME/husky/init.sh" 2>/dev/null
  ls -d "$XDG_CONFIG_HOME/husky" 2>/dev/null
}

in1=$(repo "$ROOT/repos/private/app")
out=$(repo "$T/outside")

# --- off until enabled
ok "starts off" "fingerprint trailer: off" "$(bash "$F" status | head -1)"
commit "$in1"
ok "off: no trailer" "" "$(trailer "$in1")"

# --- enable then disable leaves the global git config and hook files as they were
before="$(snapshot)"
bash "$F" enable >/dev/null 2>&1
ok "enable wires the dispatcher" "$HOME/.hq/git-hooks" "$(git -C "$T" config --global --get core.hooksPath)"
[ -x "$HOME/.hq/git-hooks/commit-msg" ] && st=yes || st=no
ok "enable writes the commit-msg stub" yes "$st"
grep -qF "dispatch commit-msg" "$HOME/.hq/git-hooks/commit-msg" && grep -qF "'$T/my hq'\\''s root'" "$HOME/.hq/git-hooks/commit-msg" && st=yes || st=no
ok "stub quotes the HQ path" yes "$st"
ok "status reads on" "fingerprint trailer: on" "$(bash "$F" status | head -1)"
bash "$F" disable >/dev/null 2>&1
ok "round trip leaves git config and hook files identical" "$before" "$(snapshot)"
ok "disable records enabled: false" "enabled: false" "$(grep '^enabled:' "$ROOT/personal/settings/fingerprint.yaml")"
out2="$(bash "$F" disable 2>&1)"
ok "second disable says already off" "Already off." "$(printf '%s\n' "$out2" | head -1)"
bash "$F" enable >/dev/null 2>&1
ok "enable records enabled: true" "enabled: true" "$(grep '^enabled:' "$ROOT/personal/settings/fingerprint.yaml")"
bash "$F" disable >/dev/null 2>&1

# --- SessionStart respects the setting
bash "$SS"
ok "session start: enabled: false keeps it off" "" "$(git -C "$T" config --global --get core.hooksPath)"
rm -f "$ROOT/personal/settings/fingerprint.yaml" "$HOME"/.hq/fingerprint-hooks-enable.*
bash "$SS"
ok "session start: core default enabled: true wires it" "$HOME/.hq/git-hooks" "$(git -C "$T" config --global --get core.hooksPath)"
ok "session start sets the fingerprint switch" true "$(git -C "$T" config --global --get hq.hooks.fingerprint)"
ls "$HOME"/.hq/fingerprint-hooks-enable.* >/dev/null 2>&1 && st=yes || st=no
ok "session start stamps today" yes "$st"
ok "secret scan stays off" "commit secret scan: off" "$(bash "$S" status | head -1)"
printf 'enabled: false\n' >"$ROOT/personal/settings/fingerprint.yaml"
ok "enable while already wired" "Already on." "$(bash "$F" enable 2>&1)"
ok "enable while already wired records enabled: true" "setting: enabled=true" "$(bash "$F" status | sed -n 2p)"

# --- no agent session: no trailer and the hq command is never started
newfp >/dev/null
s0="$(spawns)"
commit "$in1"
ok "no session id: no trailer" "" "$(trailer "$in1")"
ok "no session id: hq not started" "$s0" "$(spawns)"

# --- the trailer
export HQ_SESSION_ID=test-session
fp1="$(newfp)"
s0="$(spawns)"
commit "$in1"
ok "inside repo: trailer added" "$fp1" "$(trailer "$in1")"
ok "session cache: v2 format shared with the fingerprint helper" \
  "hq-fingerprint-trailer.v2|bin:$T/stub-hq|value:$fp1" "$(paste -sd'|' "$SC" 2>/dev/null)"
commit "$in1"
ok "session cache: second commit reuses the value" "$fp1" "$(trailer "$in1")"
ok "session cache: hq started once for two commits" $((s0 + 1)) "$(spawns)"
fp2="$(newfp)"
echo amended >>"$in1/f.txt"; git -C "$in1" add f.txt
git -C "$in1" commit -q --amend --no-edit >/dev/null 2>&1
ok "amend: trailer replaced" "$fp2" "$(trailer "$in1")"
ok "amend: one trailer" 1 "$(ntrailers "$in1")"
git -C "$in1" commit -q --amend --no-edit >/dev/null 2>&1
ok "amend with the same value: still one trailer" 1 "$(ntrailers "$in1")"

c0="$(commits "$in1")"
HQ_FINGERPRINT_BIN=false commit "$in1"
ok "failing command: commit still made" $((c0 + 1)) "$(commits "$in1")"
ok "failing command: no trailer" "" "$(trailer "$in1")"
grep -q "fingerprint command failed" "$LOG" 2>/dev/null && st=yes || st=no
ok "failing command: logged" yes "$st"

HQ_FINGERPRINT_BIN="$T/no-such-hq" commit "$in1"
ok "missing command: no trailer" "" "$(trailer "$in1")"

mode null
commit "$in1"
ok "null fingerprint: no trailer" "" "$(trailer "$in1")"
grep -q "fingerprint unavailable (no HQ session)" "$LOG" 2>/dev/null && st=yes || st=no
ok "null fingerprint: reason logged" yes "$st"

mode junk
commit "$in1"
ok "unreadable output: no trailer" "" "$(trailer "$in1")"

mode sleep; newfp >/dev/null
c0="$(commits "$in1")"
t0="$(date +%s)"; commit "$in1"; t1="$(date +%s)"
ok "slow command: commit still made" $((c0 + 1)) "$(commits "$in1")"
[ $((t1 - t0)) -lt 4 ] && st=yes || st="no ($((t1 - t0))s)"
ok "slow command: cut off under 4s" yes "$st"
ok "slow command: no trailer" "" "$(trailer "$in1")"
grep -q "timed out" "$LOG" 2>/dev/null && st=yes || st=no
ok "slow command: logged" yes "$st"

# a wrapper `hq` that started a child: the timeout stops the child too
mode child; rm -f "$T/child-pid"
c0="$(commits "$in1")"
commit "$in1"
ok "wrapper timeout: commit still made" $((c0 + 1)) "$(commits "$in1")"
cpid="$(cat "$T/child-pid" 2>/dev/null)"
sleep 0.2
[ -n "$cpid" ] && ! kill -0 "$cpid" 2>/dev/null && st=yes || st=no
ok "wrapper timeout: the wrapper's child is stopped" yes "$st"
[ -n "$cpid" ] && kill "$cpid" 2>/dev/null
mode ok

# --- empty messages: git aborts the commit as usual, never a trailer-only commit
newfp >/dev/null
empty_commit() { # label [git -c options...] -- [commit args...]
  local label="$1" c0 rc; shift
  local pre=() ; while [ $# -gt 0 ] && [ "$1" != "--" ]; do pre+=("$1"); shift; done; shift
  n=$((n+1)); echo "$n" >"$in1/f.txt"; git -C "$in1" add f.txt
  c0="$(commits "$in1")"
  git -C "$in1" ${pre[@]+"${pre[@]}"} commit -q "$@" >/dev/null 2>&1; rc=$?
  ok "$label: commit aborted" "aborted $c0" "$([ "$rc" -ne 0 ] && echo aborted || echo made) $(commits "$in1")"
}
GIT_EDITOR=true empty_commit "editor left the message empty" --
GIT_EDITOR=true empty_commit "editor left it empty, core.commentChar=;" -c "core.commentChar=;" --
: >"$T/empty-msg"
empty_commit "-F empty file" -- -F "$T/empty-msg"
printf '\n  \n\n' >"$T/blank-msg"
empty_commit "-F blank lines only" -- -F "$T/blank-msg"
GIT_EDITOR=: empty_commit "user editor is the no-op ':' and the template is untouched" --
printf '# only a comment line\n' >"$T/hash-msg"
empty_commit "--cleanup=strip -F with a comment-only file" -- --cleanup=strip -F "$T/hash-msg"
# A comment-only -F message commits under git's default cleanup for -F
# (whitespace), but the hook cannot tell that apart from an untouched editor
# template, so it adds no trailer there: a missed trailer, never a wrong one.
fp7="$(newfp)"
c0="$(commits "$in1")"
n=$((n+1)); echo "$n" >"$in1/f.txt"; git -C "$in1" add f.txt
git -C "$in1" commit -q -F "$T/hash-msg" >/dev/null 2>&1
ok "-F with a # line: commit made" $((c0 + 1)) "$(commits "$in1")"
ok "-F with a # line: no trailer (comment-only messages are left alone)" "" "$(trailer "$in1")"
ok "-F with a # line: the builder did return a fingerprint for the control" yes "$([ -n "$fp7" ] && echo yes || echo no)"

# --- husky repos: husky's own core.hooksPath; the init.sh block adds the trailer
hk=$(repo "$ROOT/repos/private/husky-app")
git -C "$hk" config core.hooksPath .husky/_
mkdir -p "$hk/.husky/_"
# A trimmed copy of husky 9's .husky/_/h.
cat >"$hk/.husky/_/h" <<'H'
#!/usr/bin/env sh
n=$(basename "$0")
s=$(dirname "$(dirname "$0")")/$n
[ ! -f "$s" ] && exit 0
i="${XDG_CONFIG_HOME:-$HOME/.config}/husky/init.sh"
[ -f "$i" ] && . "$i"
sh -e "$s" "$@"
H
# shellcheck disable=SC2016 # expanded by the generated hooks
printf '#!/usr/bin/env sh\n. "$(dirname "$0")/h"\n' >"$hk/.husky/_/commit-msg"
# shellcheck disable=SC2016
printf 'cp "$1" "%s/husky-saw"\n' "$T" >"$hk/.husky/commit-msg"
chmod +x "$hk/.husky/_/h" "$hk/.husky/_/commit-msg"
# The husky block is only written once a husky repo is seen; the next enable
# (the daily SessionStart run) picks this one up.
bash "$F" enable >/dev/null 2>&1
fp8="$(newfp)"
commit "$hk"
ok "husky repo: trailer added" "$fp8" "$(trailer "$hk")"
grep -qxF "HQ-Fingerprint: $fp8" "$T/husky-saw" 2>/dev/null && st=yes || st=no
ok "husky repo: its commit-msg hook gets the message file with the trailer" yes "$st"

# merge commits keep git's message
fp3="$(newfp)"
git -C "$in1" checkout -q -b side
echo side >"$in1/side.txt"; git -C "$in1" add side.txt; git -C "$in1" commit -q -m side >/dev/null 2>&1
git -C "$in1" checkout -q main
commit "$in1"
git -C "$in1" merge -q --no-ff -m "merge side" side >/dev/null 2>&1
ok "merge made" 2 "$(git -C "$in1" log -1 --format=%P | wc -w | tr -d ' ')"
ok "merge commit: no trailer" "" "$(trailer "$in1")"
ok "merge parent still has its trailer" "$fp3" "$(git -C "$in1" log -1 --format='%(trailers:key=HQ-Fingerprint,valueonly)' HEAD^1 | sed '/^$/d')"

# the repo's own commit-msg hook still runs, after the trailer is added
# shellcheck disable=SC2016 # $1 belongs to the generated hook
printf '#!/bin/sh\ncp "$1" "%s/own-hook-saw"\n' "$T" >"$in1/.git/hooks/commit-msg"; chmod +x "$in1/.git/hooks/commit-msg"
fp4="$(newfp)"
commit "$in1"
[ -f "$T/own-hook-saw" ] && st=yes || st=no
ok "repo's own commit-msg hook runs" yes "$st"
grep -qxF "HQ-Fingerprint: $fp4" "$T/own-hook-saw" 2>/dev/null && st=yes || st=no
ok "repo's own hook sees the trailer" yes "$st"
ok "trailer added with an own hook present" "$fp4" "$(trailer "$in1")"
rm -f "$in1/.git/hooks/commit-msg"

# a worktree under workspace/worktrees is inside the HQ folder too
mkdir -p "$ROOT/workspace/worktrees"
git -C "$in1" worktree add -q -b wt "$ROOT/workspace/worktrees/app-wt" >/dev/null 2>&1
fp5="$(newfp)"
commit "$ROOT/workspace/worktrees/app-wt"
ok "worktree inside HQ: trailer added" "$fp5" "$(trailer "$ROOT/workspace/worktrees/app-wt")"

# --- repos outside the HQ folder are never touched
lines_before="$(wc -l <"$LOG" | tr -d ' ')"
newfp >/dev/null
commit "$out"
ok "outside repo: commit made" 1 "$(commits "$out")"
ok "outside repo: no trailer" "" "$(trailer "$out")"
ok "outside repo: message untouched" "change $n" "$(git -C "$out" log -1 --format=%B | sed '/^$/d')"
ok "outside repo: fingerprint not even asked for" "$lines_before" "$(wc -l <"$LOG" | tr -d ' ')"
# an HQ-looking path next to the root (prefix match) is outside too
sib=$(repo "$T/my hq's root-other/repos/x")
commit "$sib"
ok "sibling folder with the same prefix: no trailer" "" "$(trailer "$sib")"

# --- HQ folder moved: commits still go through
mv "$ROOT/core/scripts/lib/git-hooks-dispatcher.sh" "$T/lib.bak"
c0="$(commits "$in1")"
commit "$in1"
ok "lib missing, trailer only: commit still made" $((c0 + 1)) "$(commits "$in1")"
mv "$T/lib.bak" "$ROOT/core/scripts/lib/git-hooks-dispatcher.sh"

# --- the secret scan and the trailer share one dispatcher
bash "$F" disable >/dev/null 2>&1
bash "$S" enable >/dev/null 2>&1
backups_scan="$(ls "$HOME/.hq/git-hooks-backups"/backup-*.tsv 2>/dev/null | wc -l | tr -d ' ')"
bash "$F" enable >/dev/null 2>&1
ok "fingerprint enable after scan: no second backup" "$backups_scan" "$(ls "$HOME/.hq/git-hooks-backups"/backup-*.tsv 2>/dev/null | wc -l | tr -d ' ')"
c0="$(commits "$in1")"
printf 'token = "%s"\n' "gh""p_$(rnd 'A-Za-z0-9' 36)" >"$in1/s.py"; git -C "$in1" add s.py
git -C "$in1" commit -q -m secret >/dev/null 2>&1
ok "both on: secret still blocked" "$c0" "$(commits "$in1")"
git -C "$in1" rm -q --cached s.py; rm -f "$in1/s.py"
bash "$S" disable >/dev/null 2>&1
ok "scan off: dispatcher stays wired" "$HOME/.hq/git-hooks" "$(git -C "$T" config --global --get core.hooksPath)"
fp6="$(newfp)"
commit "$in1"
ok "scan off: trailer still added" "$fp6" "$(trailer "$in1")"
bash "$F" disable >/dev/null 2>&1
ok "both off: dispatcher unwired" "" "$(git -C "$T" config --global --get core.hooksPath)"
ok "both off: switches removed" "" "$(git -C "$T" config --global --get-regexp '^hq\.hooks\.')"

# --- a machine wired by the older secret-scan-only script: no hq.hooks keys
bash "$S" enable >/dev/null 2>&1
git -C "$T" config --global --remove-section hq.hooks
dry="$(bash "$F" disable --dry-run 2>&1)"
printf '%s\n' "$dry" | grep -qF "stays for the commit secret scan" && st=yes || st=no
ok "legacy scan: disable --dry-run says the hook stays" yes "$st"
ok "legacy scan: dry run writes no switch" "" "$(git -C "$T" config --global --get-regexp '^hq\.hooks\.')"
bash "$F" disable >/dev/null 2>&1
ok "legacy scan: fingerprint disable keeps the hook wired" "$HOME/.hq/git-hooks" "$(git -C "$T" config --global --get core.hooksPath)"
ok "legacy scan: scan still on" "commit secret scan: on" "$(bash "$S" status | head -1)"
ok "legacy scan: recorded as a switch" true "$(git -C "$T" config --global --get hq.hooks.secretScan)"
bash "$S" disable >/dev/null 2>&1
ok "legacy scan: scan disable unwires" "" "$(git -C "$T" config --global --get core.hooksPath)"

# --- husky init.sh: what was there before install is what stays after
H="$XDG_CONFIG_HOME/husky"
mkdir -p "$H"; : >"$H/init.sh"
bash "$F" enable >/dev/null 2>&1; bash "$F" disable >/dev/null 2>&1
[ -f "$H/init.sh" ] && [ ! -s "$H/init.sh" ] && st=yes || st=no
ok "husky: a pre-existing empty init.sh is kept" yes "$st"
rm -f "$H/init.sh"
bash "$F" enable >/dev/null 2>&1; bash "$F" disable >/dev/null 2>&1
[ -d "$H" ] && [ ! -e "$H/init.sh" ] && st=yes || st=no
ok "husky: a pre-existing folder is kept, the created init.sh removed" yes "$st"
rmdir "$H"
bash "$F" enable >/dev/null 2>&1; bash "$F" disable >/dev/null 2>&1
[ -e "$H" ] && st=no || st=yes
ok "husky: a folder enable created is removed" yes "$st"

# --- session start never wires a fleet agent box
: >"$T/identity.json"
rm -f "$ROOT/personal/settings/fingerprint.yaml" "$HOME"/.hq/fingerprint-hooks-enable.*
HQ_AGENT_IDENTITY_FILE="$T/identity.json" bash "$SS"
ok "session start on a fleet agent box: not wired" "" "$(git -C "$T" config --global --get core.hooksPath)"
bash "$SS"
ok "session start off a fleet box: wired" "$HOME/.hq/git-hooks" "$(git -C "$T" config --global --get core.hooksPath)"
bash "$F" disable >/dev/null 2>&1

# --- the log never holds a fingerprint value
st=clean
for v in "$fp1" "$fp2" "$fp3" "$fp4" "$fp5" "$fp6" "$(cat "$T/fp-value")"; do
  grep -qF "$v" "$LOG" 2>/dev/null && st=leaked
done
grep -q 'hqfp1:' "$LOG" 2>/dev/null && st=leaked
ok "log never contains the value" clean "$st"

echo "passed $pass, failed $fail"
[ "$fail" -eq 0 ]
