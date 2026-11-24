#!/usr/bin/env bash
# hq-core: public
# credential-read-guard-windows-backslash.test.sh — on Windows (Git Bash,
# MSYS, Cygwin) block-credential-file-read.sh treats a backslash as a
# directory separator, so a credential path spelled with backslashes, mixed
# separators, a drive letter, a drive-relative C:name, a \\?\ or \\.\ prefix,
# a UNC path or a trailing dot is refused for the Read tool and for cat,
# like its forward-slash spelling.
#
# Sections:
#   [1] Read: every Windows spelling of each covered credential path blocks
#   [2] Bash cat: unquoted, single-quoted, double-quoted and doubled
#       backslash spellings block
#   [3] forward-slash spellings still block
#   [4] ordinary backslash paths and commands stay allowed
#   [5] the block message names one normalized path (no doubled cwd)
#   [5b] Cygwin spells drive C as /cygdrive/c
#   [5c] directory targets: drive-relative cd and recursive reads, and
#        administrative-share (\\host\c$) spellings of HOME, ".." above
#        the drive root (C:\..\x) and slash-first backslash paths (/x\y)
#   [6] off Windows a backslash stays a literal character
#
# Every case runs twice, with the fast path on and off; the two exit codes
# must match. On macOS and Linux the Windows runs set OSTYPE=msys and
# MSYSTEM=MINGW64. On Windows the process is already a Windows host.
# Only fake credential files under a temporary HOME are used.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
HOOK="$ROOT/.claude/hooks/block-credential-file-read.sh"
HOOK_BASH="${CRED_GUARD_HOOK_BASH:-bash}"

pass=0
fail=0
ok() { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; }

command -v jq >/dev/null 2>&1 || { echo "FAIL: jq is required" >&2; exit 1; }
[ -f "$HOOK" ] || { echo "FAIL: missing $HOOK" >&2; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/cred-guard-winbs.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
FH="$TMP/u"
PROJ="$FH/proj"
mkdir -p "$FH/.gem" "$FH/.docker" "$FH/.aws" "$FH/.ssh" "$FH/.config/gh" \
  "$FH/.hq/secrets-cache" "$PROJ/src" "$PROJ/docs"

FAKE="FAKE-NOT-A-TOKEN-$$"
CANARY="canary-${FAKE}"
# Credential paths relative to HOME, as the guard covers them in
# forward-slash form. Each gets a fake file holding the canary.
CRED_RELS=(.npmrc .netrc _netrc .pypirc .yarnrc .yarnrc.yml .git-credentials
  .gem/credentials .docker/config.json .config/gh/hosts.yml
  .aws/credentials .aws/config .ssh/id_rsa .ssh/id_ed25519 .ssh/id_ecdsa
  .hq/secrets-cache/token proj/.env proj/.env.local proj/.envrc proj/prod.env
  .npmrc.bak proj/.env~)
for rel in "${CRED_RELS[@]}"; do
  printf 'FAKE %s\n' "$CANARY" > "$FH/$rel"
done
printf 'hello\n' > "$PROJ/README.md"
printf 'x\n' > "$PROJ/src/main.ts"
printf 'x\n' > "$PROJ/notes.txt"
printf 'API_KEY=placeholder\n' > "$PROJ/.env.example"
printf 'ssh-ed25519 AAAAfake fake@example.invalid\n' > "$FH/.ssh/id_rsa.pub"
printf 'example.invalid ssh-ed25519 AAAAfake\n' > "$FH/.ssh/known_hosts"
printf 'Host example.invalid\n' > "$FH/.ssh/config"
# A neutral name that links to a fake credential file. On Git Bash, ln -s
# copies unless native symlinks are asked for.
MSYS=winsymlinks:nativestrict ln -s "$FH/.npmrc" "$PROJ/lnk" 2>/dev/null
if [ ! -L "$PROJ/lnk" ]; then
  echo "FAIL: cannot create the test symlink $PROJ/lnk" >&2
  exit 1
fi

credguard_win_host() {
  case "${OSTYPE:-}" in msys*|cygwin*|win32*) return 0 ;; esac
  case "${MSYSTEM:-}" in MINGW*|MSYS*|CYGWIN*|UCRT*|CLANG*) return 0 ;; esac
  return 1
}

# Git Bash rewrites an argument that starts with a slash before a native jq.
cg_jq() { MSYS2_ARG_CONV_EXCL='*' jq "$@"; }
payload_read() { # <file_path> <cwd>
  cg_jq -nc --arg p "$1" --arg cwd "$2" \
    '{session_id:"cred-guard-winbs",hook_event_name:"PreToolUse",tool_name:"Read",cwd:$cwd,tool_input:{file_path:$p}}'
}
payload_bash() { # <command> <cwd>
  cg_jq -nc --arg c "$1" --arg cwd "$2" \
    '{session_id:"cred-guard-winbs",hook_event_name:"PreToolUse",tool_name:"Bash",cwd:$cwd,tool_input:{command:$c}}'
}

# run_mode <win|unix> <fastpath 0|1> <payload>: exit code of the hook.
run_mode() {
  local mode="$1" fp="$2" pl="$3" rc=0
  if [ "$mode" = win ]; then
    printf '%s' "$pl" | HOME="${T_HOME:-$FH}" OSTYPE=msys MSYSTEM=MINGW64 HQ_CRED_GUARD_FASTPATH="$fp" \
      "$HOOK_BASH" "$HOOK" >"$TMP/out" 2>"$TMP/err" || rc=$?
  elif [ "$mode" = cyg ]; then
    printf '%s' "$pl" | env -u MSYSTEM HOME="${T_HOME:-$FH}" OSTYPE=cygwin HQ_CRED_GUARD_FASTPATH="$fp" \
      "$HOOK_BASH" "$HOOK" >"$TMP/out" 2>"$TMP/err" || rc=$?
  else
    printf '%s' "$pl" | env -u MSYSTEM HOME="$FH" OSTYPE=linux-gnu HQ_CRED_GUARD_FASTPATH="$fp" \
      "$HOOK_BASH" "$HOOK" >"$TMP/out" 2>"$TMP/err" || rc=$?
  fi
  return "$rc"
}

# check <mode> <want-rc> <desc> <payload>
check() {
  local mode="$1" want="$2" desc="$3" pl="$4" rc=0 frc=0
  run_mode "$mode" 0 "$pl" || frc=$?
  head -1 "$TMP/err" > "$TMP/err.full"
  run_mode "$mode" 1 "$pl" || rc=$?
  if grep -qF "$CANARY" "$TMP/out" "$TMP/err"; then
    bad "$desc (hook output contains file contents)"
    return
  fi
  if [ "$rc" != "$frc" ]; then
    bad "$desc (fast path $rc, full check $frc; fast err=$(head -1 "$TMP/err"); full err=$(cat "$TMP/err.full"))"
  elif [ "$rc" = "$want" ]; then
    ok "$desc"
  else
    bad "$desc (want $want got $rc; err=$(head -c 300 "$TMP/err" | tr '\n' ' '))"
  fi
}
win_read() { check win "$1" "win Read: $2" "$(payload_read "$3" "${4:-$PROJ}")"; }
win_bash() { check win "$1" "win Bash: $2" "$(payload_bash "$3" "${4:-$PROJ}")"; }

bs() { printf '%s' "${1//\//\\}"; }

echo "[1] Read: Windows spellings of each credential path"
for rel in "${CRED_RELS[@]}"; do
  b="$(bs "$rel")"
  win_read 2 "drive backslash $rel" "C:\\Profiles\\me\\$b"
  win_read 2 "lower-case drive backslash $rel" "c:\\Profiles\\me\\$b"
  win_read 2 "mixed separators $rel" "C:/Profiles\\me/$b"
  win_read 2 "verbatim prefix $rel" "\\\\?\\C:\\Profiles\\me\\$b"
  win_read 2 "device prefix $rel" "\\\\.\\C:\\Profiles\\me\\$b"
  win_read 2 "UNC $rel" "\\\\server\\share\\$b"
  win_read 2 "verbatim UNC $rel" "\\\\?\\UNC\\server\\share\\$b"
  win_read 2 "home tilde backslash $rel" "~\\$b"
  win_read 2 "HOME variable backslash $rel" "\$HOME\\$b"
  win_read 2 "relative backslash $rel" "..\\$b"
  win_read 2 "drive-relative $rel" "C:..\\$b"
  win_read 2 "trailing dot $rel" "C:\\Profiles\\me\\$b."
  win_read 2 "trailing space $rel" "C:\\Profiles\\me\\$b "
  win_read 2 "default stream $rel" "C:\\Profiles\\me\\$b::\$DATA"
  win_read 2 "short default stream $rel" "C:\\Profiles\\me\\$b:\$DATA"
done
win_read 2 "directory index stream" 'C:\Profiles\me\.aws::$INDEX_ALLOCATION\credentials'
win_read 2 "neutral symlink default stream" "$(bs "$PROJ")\\lnk::\$DATA"
win_read 2 "neutral symlink trailing dot" "lnk."
win_read 2 "relative name in a backslash cwd" "credentials" 'C:\Profiles\me\.aws'
win_read 2 "relative key in a backslash cwd" "id_rsa" 'C:\Profiles\me\.ssh'
win_read 2 "dot-only segment inside .aws" 'C:\Profiles\me\.aws\...\credentials'
win_read 2 "dot-and-space segment inside .ssh" 'C:\Profiles\me\.ssh\. .\id_rsa'
win_read 2 "neutral symlink by backslash path" "$(bs "$PROJ")\\lnk"
win_read 2 "neutral symlink drive-relative" "C:lnk"
win_read 2 "neutral symlink in a backslash cwd" "lnk" "$(bs "$PROJ")"

echo "[2] Bash cat: Windows spellings of each credential path"
for rel in "${CRED_RELS[@]}"; do
  b="$(bs "$rel")"
  win_bash 2 "cat unquoted drive backslash $rel" "cat C:\\Profiles\\me\\$b"
  win_bash 2 "cat single-quoted drive backslash $rel" "cat 'C:\\Profiles\\me\\$b'"
  win_bash 2 "cat double-quoted drive backslash $rel" "cat \"C:\\Profiles\\me\\$b\""
  win_bash 2 "cat doubled backslash $rel" "cat C:\\\\Profiles\\\\me\\\\${b//\\/\\\\}"
  win_bash 2 "cat single-quoted mixed $rel" "cat 'C:/Profiles\\me/$b'"
  win_bash 2 "cat single-quoted verbatim prefix $rel" "cat '\\\\?\\C:\\Profiles\\me\\$b'"
  win_bash 2 "cat single-quoted UNC $rel" "cat '\\\\server\\share\\$b'"
  win_bash 2 "cat single-quoted relative backslash $rel" "cat '..\\$b'"
  win_bash 2 "cat drive-relative $rel" "cat 'C:..\\$b'"
  win_bash 2 "cat in a pipeline $rel" "true | cat 'C:\\Profiles\\me\\$b' | head -1"
  win_bash 2 "cat default stream $rel" "cat 'C:\\Profiles\\me\\$b::\$DATA'"
done
win_bash 2 "cat neutral symlink trailing dot" "cat lnk."
win_bash 2 "cat neutral symlink dot-slash trailing dot" "cat ./lnk."
win_bash 2 "cat neutral symlink trailing dots" "cat lnk..."
win_bash 2 "cat neutral symlink default stream" "cat 'lnk::\$DATA'"
win_bash 2 "cmd type neutral symlink trailing dot" "cmd //c type lnk."
win_bash 2 "cat relative name in a backslash cwd" "cat credentials" 'C:\Profiles\me\.aws'
win_bash 2 "cat neutral symlink by backslash path" "cat '$(bs "$PROJ")\\lnk'"
win_bash 2 "cat neutral symlink drive-relative" "cat C:lnk"
win_bash 2 "cat neutral symlink in a backslash cwd" "cat lnk" "$(bs "$PROJ")"
win_bash 2 "cat dot-only segment inside .aws" "cat 'C:\\Profiles\\me\\.aws\\...\\credentials'"

echo "[3] forward-slash spellings still block"
for rel in "${CRED_RELS[@]}"; do
  win_read 2 "forward-slash home $rel" "$FH/$rel"
  win_read 2 "forward-slash drive $rel" "C:/Profiles/me/$rel"
  win_bash 2 "cat forward-slash home $rel" "cat '$FH/$rel'"
  win_bash 2 "cat forward-slash drive $rel" "cat C:/Profiles/me/$rel"
  check unix 2 "unix Read: forward-slash home $rel" "$(payload_read "$FH/$rel" "$PROJ")"
  check unix 2 "unix Bash: cat forward-slash home $rel" "$(payload_bash "cat '$FH/$rel'" "$PROJ")"
done

echo "[4] ordinary backslash paths and commands stay allowed"
for p in 'C:\hq\README.md' 'src\main.ts' '.\notes.txt' 'C:notes.txt' \
  'C:\Profiles\me\.ssh\id_rsa.pub' 'C:\Profiles\me\.ssh\known_hosts' \
  'C:\Profiles\me\.ssh\config' 'C:\hq\.env.example' 'C:\hq\docs\npmrc-guide.md' \
  '\\server\share\docs\a.txt' 'C:\Program Files\Git\bin\bash.exe' \
  "$(bs "$PROJ")\\README.md"; do
  win_read 0 "ordinary $p" "$p"
done
win_bash 0 "cat single-quoted readme" "cat 'C:\\hq\\README.md'"
win_bash 0 "cat unquoted src file" 'cat src\main.ts'
win_bash 0 "cat single-quoted ssh public key" "cat 'C:\\Profiles\\me\\.ssh\\id_rsa.pub'"
win_bash 0 "cat env example" "cat 'C:\\hq\\.env.example'"
win_bash 0 "sed of a backslash path" "sed -n 1p 'src\\main.ts'"
win_bash 0 "ls of a backslash directory" "ls 'C:\\hq\\docs'"
win_bash 0 "grep regex with an escaped dot" "grep -c '\\.env' README.md"
win_bash 0 "printf with a newline escape" "printf '%s\\n' hi"
win_bash 0 "echo a Windows directory" 'echo C:\temp'
win_bash 0 "git revision" "git log -1 --oneline HEAD~1"
win_bash 0 "git show of a tracked readme at a revision" "git show HEAD:README.md"
win_read 0 "ordinary file default stream" 'C:\hq\README.md::$DATA'
win_bash 0 "ls in a backslash cwd" "ls" "$(bs "$PROJ")"
win_bash 0 "cat readme in a backslash cwd" "cat README.md" "$(bs "$PROJ")"
win_bash 0 "cat readme in a drive cwd" "cat README.md" 'C:\Profiles\me\proj'

echo "[5] block message names one normalized path"
pl="$(payload_read 'C:\work\hq\workspace\x\.npmrc' 'C:\work\hq')"
rc=0
run_mode win 0 "$pl" || rc=$?
msg="$(head -1 "$TMP/err")"
if [ "$rc" = 2 ] && [ "$msg" = "BLOCKED: reading a credential file (/c/work/hq/workspace/x/.npmrc)" ]; then
  ok "Read block message for a Windows path in a Windows cwd"
else
  bad "Read block message for a Windows path in a Windows cwd (rc $rc): $msg"
fi
pl="$(payload_read 'workspace\x\.npmrc' 'C:\work\hq')"
rc=0
run_mode win 0 "$pl" || rc=$?
msg="$(head -1 "$TMP/err")"
if [ "$rc" = 2 ] && [ "$msg" = "BLOCKED: reading a credential file (/c/work/hq/workspace/x/.npmrc)" ]; then
  ok "Read block message for a relative path in a Windows cwd"
else
  bad "Read block message for a relative path in a Windows cwd (rc $rc): $msg"
fi

echo "[5b] Cygwin names drive C as /cygdrive/c"
check cyg 2 "cygwin Read: drive backslash npmrc" "$(payload_read 'C:\work\.npmrc' "$PROJ")"
check cyg 2 "cygwin Bash: cat drive backslash ssh key" "$(payload_bash "cat 'C:\\work\\.ssh\\id_rsa'" "$PROJ")"
check cyg 0 "cygwin Read: drive backslash readme" "$(payload_read 'C:\work\README.md' "$PROJ")"
pl="$(payload_read 'C:\work\x\.npmrc' "$PROJ")"
rc=0
run_mode cyg 0 "$pl" || rc=$?
msg="$(head -1 "$TMP/err")"
if [ "$rc" = 2 ] && [ "$msg" = "BLOCKED: reading a credential file (/cygdrive/c/work/x/.npmrc)" ]; then
  ok "cygwin Read block message uses /cygdrive/c"
else
  bad "cygwin Read block message uses /cygdrive/c (rc $rc): $msg"
fi

echo "[5c] directory targets with drive-relative and share spellings"
# A drive-relative C:x directory has two readings: C:\x (the MSYS and Cygwin
# runtime, so cd, pushd and the MSYS tools) and x under drive C's current
# directory (a native Windows program). Recursive readers and archivers are
# checked against both; cd and pushd follow C:\x.
BPROJ="$(bs "$PROJ")"
# A neutral name in the cwd that links to the fake ~/.aws directory. A native
# program reads C:lnkaws as lnkaws under the cwd.
MSYS=winsymlinks:nativestrict ln -s "$FH/.aws" "$PROJ/lnkaws" 2>/dev/null
if [ ! -L "$PROJ/lnkaws" ]; then
  echo "FAIL: cannot create the test symlink $PROJ/lnkaws" >&2
  exit 1
fi
win_bash 2 "script given a drive-relative link to ~/.aws (cwd reading)" "python3 x.py C:lnkaws" "$BPROJ"
win_bash 2 "script given a drive-relative link to ~/.aws, trailing dot" "python3 x.py C:lnkaws." "$BPROJ"
win_bash 2 "forward-slash control: script given a link to ~/.aws" "python3 x.py lnkaws" "$BPROJ"
# Quotes inside the drive word are removed by the shell (C"":x is C:x).
for qcwd in "$BPROJ" "$PROJ"; do
  win_bash 2 "empty double quotes after the drive letter ($qcwd)" 'python3 x.py C"":lnkaws' "$qcwd"
  win_bash 2 "double-quoted drive letter ($qcwd)" 'python3 x.py "C":lnkaws' "$qcwd"
  win_bash 2 "single-quoted drive letter ($qcwd)" "python3 x.py 'C':lnkaws" "$qcwd"
  win_bash 2 "double-quoted colon ($qcwd)" 'python3 x.py C":"lnkaws' "$qcwd"
  win_bash 2 "empty ANSI-C quotes after the drive letter ($qcwd)" "python3 x.py C\$'':lnkaws" "$qcwd"
done
win_bash 0 "cd drive-relative into src, then cat a source file" "cd C:src && cat main.ts" "$BPROJ"
win_bash 0 "grep -r of a drive-relative source dir" "grep -r foo 'C:src'" "$BPROJ"
# HOME and cwd as Windows paths; these checks are by name only.
T_HOME='C:\Profiles\me'
WCWD='C:\Profiles\me\proj'
win_bash 2 "grep -r of HOME by drive-relative .. (cwd reading)" "grep -r token 'C:..'" "$WCWD"
win_bash 2 "grep -r of HOME by drive-relative ..\\..\\me (cwd reading)" "grep -r token 'C:..\\..\\me'" "$WCWD"
win_bash 2 "tar of HOME by drive-relative path (cwd reading)" "tar cf - 'C:..\\..\\me' | tar xOf -" "$WCWD"
win_bash 2 "grep -r of HOME by drive-relative Profiles\\me (root reading)" "grep -r token 'C:Profiles\\me'" "$WCWD"
win_bash 2 "zip -r of HOME by drive-relative Profiles\\me (root reading)" "zip -r out.zip 'C:Profiles\\me'" "$WCWD"
win_bash 2 "cd drive-relative to HOME (root reading), then grep -r" "cd 'C:Profiles\\me' && grep -r token ." "$WCWD"
win_bash 2 "pushd drive-relative to HOME (root reading), then grep -r" "pushd 'C:Profiles\\me' >/dev/null; grep -r token ." "$WCWD"
win_bash 2 "cd drive-relative to Profiles, then cd me and grep -r" "cd C:Profiles; cd me; grep -r token ." "$WCWD"
win_bash 2 "cd drive-relative to Profiles, then tar me" "cd C:Profiles && tar cf - me | tar xOf -" "$WCWD"
win_bash 2 "grep -r of HOME by drive-relative path from a drive D cwd" "grep -r token 'C:Profiles\\me'" 'D:\work'
win_bash 2 "forward-slash control: grep -r of ../../me" "grep -r token ../../me" "$WCWD"
# One leading backslash starts at the root of the cwd's drive: \Profiles\me
# is C:\Profiles\me here.
win_bash 2 "grep -r of HOME by root-relative path" "grep -r token '\\Profiles\\me'" "$WCWD"
win_bash 2 "grep -r of HOME's parent by root-relative path" "grep -r token '\\Profiles'" "$WCWD"
win_bash 2 "rg of HOME by root-relative path" "rg token '\\Profiles\\me'" "$WCWD"
win_bash 2 "zip -r of HOME by root-relative path" "zip -r out.zip '\\Profiles\\me'" "$WCWD"
win_bash 2 "cd to HOME by root-relative path, then grep -r" "cd '\\Profiles\\me' && grep -r token ." "$WCWD"
win_bash 0 "grep -r of a project dir by root-relative path" "grep -r token '\\Profiles\\me\\proj\\src'" "$WCWD"
win_bash 0 "cat of a readme by root-relative path" "cat '\\hq\\README.md'" "$WCWD"
win_bash 0 "grep -r of a root-relative dir on drive D" "grep -r token '\\Profiles\\me'" 'D:\work'
win_bash 2 "grep -r of HOME by admin share" "grep -r token '\\\\localhost\\c\$\\Profiles\\me'" "$WCWD"
win_bash 2 "grep -r of HOME by upper-case admin share" "grep -r token '\\\\HOST1\\C\$\\Profiles\\me'" "$WCWD"
win_bash 2 "grep -r of HOME by verbatim UNC admin share" "grep -r token '\\\\?\\UNC\\localhost\\C\$\\Profiles\\me'" "$WCWD"
win_bash 2 "grep -r of HOME by forward-slash admin share" "grep -r token '//localhost/c\$/Profiles/me'" "$WCWD"
win_bash 2 "cd to HOME by admin share, then grep -r" "cd '\\\\localhost\\c\$\\Profiles\\me' && grep -r token ." "$WCWD"
win_read 2 "Read of an ssh key by admin share" '\\localhost\c$\Profiles\me\.ssh\id_rsa' "$WCWD"
win_bash 0 "grep -r of a project dir on a drive-D share" "grep -r token '\\\\server\\d\$\\data'" "$WCWD"
# C:. is C:\ under the drive-root reading, which holds HOME.
win_bash 2 "grep -r of the drive root by drive-relative . (root reading)" "grep -r token 'C:.'" "$WCWD"
win_bash 0 "grep -r of a project dir by drive-relative path" "grep -r token 'C:Profiles\\me\\proj\\src'" "$WCWD"
win_bash 0 "grep -r of a drive-relative source dir in a drive cwd" "grep -r token 'C:src'" "$WCWD"
win_bash 0 "cat of a readme by admin share" "cat '\\\\localhost\\c\$\\Profiles\\me\\proj\\README.md'" "$WCWD"
# Windows stops ".." at the drive root: C:\..\Profiles\me is C:\Profiles\me,
# and so is \..\Profiles\me or a backslash relative path with too many ..
# segments. The MSYS reading of a POSIX /c/.. is checked as well.
win_bash 2 "grep -r of HOME by .. above the drive root" "grep -r token 'C:\\..\\Profiles\\me'" "$WCWD"
win_bash 2 "grep -r of HOME by .. above the drive root, forward slashes" "grep -r token 'C:/../Profiles/me'" "$WCWD"
win_bash 2 "grep -r of HOME by .. above the drive root, twice" "grep -r token 'C:\\..\\..\\Profiles\\me'" "$WCWD"
win_bash 2 "grep -r of HOME by root-relative .. above the root" "grep -r token '\\..\\Profiles\\me'" "$WCWD"
win_bash 2 "grep -r of HOME by relative .. past the drive root" "grep -r token '..\\..\\..\\..\\..\\Profiles\\me'" "$WCWD"
win_bash 2 "grep -r of HOME by drive-relative .. past the drive root" "grep -r token 'C:..\\..\\..\\..\\Profiles\\me'" "$WCWD"
win_bash 2 "rg of HOME by .. above the drive root" "rg token 'C:\\..\\Profiles\\me'" "$WCWD"
win_bash 2 "tar of HOME by .. above the drive root" "tar cf - 'C:\\..\\Profiles\\me' | tar xOf -" "$WCWD"
win_bash 2 "zip -r of HOME by root-relative .. above the root" "zip -r out.zip '\\..\\Profiles\\me'" "$WCWD"
win_bash 2 "cd to HOME by .. above the drive root, then grep -r" "cd 'C:\\..\\Profiles\\me' && grep -r token ." "$WCWD"
win_bash 2 "cd to HOME by root-relative .. above the root, then grep -r" "cd '\\..\\Profiles\\me' && grep -r token ." "$WCWD"
win_bash 2 "cd to HOME by relative .. past the drive root, then grep -r" "cd '..\\..\\..\\..\\Profiles\\me' && grep -r token ." "$WCWD"
win_bash 2 "cd above the drive root, then grep -r Profiles" "cd 'C:\\..' && grep -r token Profiles" "$WCWD"
win_bash 2 "MSYS control: grep -r of HOME by /c/../c" "grep -r token /c/../c/Profiles/me" "$WCWD"
win_read 2 "Read of an ssh key by .. above the drive root" 'C:\..\Profiles\me\.ssh\id_rsa' "$WCWD"
win_bash 2 "cat of an npmrc by .. above the drive root" "cat 'C:\\..\\Profiles\\me\\.npmrc'" "$WCWD"
win_bash 0 "grep -r of another dir by .. above the drive root" "grep -r token 'C:\\..\\other'" "$WCWD"
win_bash 0 "grep -r of another profile by root-relative .." "grep -r token '\\..\\Profiles\\other'" "$WCWD"
win_bash 0 "cd to the project by .. above the drive root, then cat a readme" "cd 'C:\\..\\Profiles\\me\\proj' && cat README.md" "$WCWD"
win_bash 0 "grep -r of a project dir by .. above the drive root" "grep -r token 'C:\\..\\Profiles\\me\\proj\\src'" "$WCWD"
# A path with one leading slash and a backslash later (/Profiles\me) is a
# Windows path on the cwd's drive.
win_bash 2 "grep -r of HOME by slash-first backslash path" "grep -r token '/Profiles\\me'" "$WCWD"
win_bash 2 "grep -r of HOME by trailing-backslash path" "grep -r token '/Profiles/me\\'" "$WCWD"
win_bash 2 "grep -r of HOME's parent by slash-first backslash path" "grep -r token '/Profiles\\'" "$WCWD"
win_bash 2 "rg of HOME by slash-first backslash path" "rg token '/Profiles\\me'" "$WCWD"
win_bash 2 "zip -r of HOME by slash-first backslash path" "zip -r out.zip '/Profiles\\me'" "$WCWD"
win_bash 2 "cd to HOME by slash-first backslash path, then grep -r" "cd '/Profiles\\me' && grep -r token ." "$WCWD"
win_bash 0 "grep -r of a project dir by slash-first backslash path" "grep -r token '/Profiles\\me\\proj\\src'" "$WCWD"
win_bash 0 "grep -r of a slash-first backslash path on drive D" "grep -r token '/Profiles\\me'" 'D:\work'
check cyg 2 "cygwin Bash: grep -r of HOME by .. above the drive root" "$(payload_bash "grep -r token 'C:\\..\\Profiles\\me'" "$WCWD")"
check cyg 2 "cygwin Bash: grep -r of HOME by root-relative .. above the root" "$(payload_bash "grep -r token '\\..\\Profiles\\me'" "$WCWD")"
check cyg 2 "cygwin Bash: grep -r of HOME by slash-first backslash path" "$(payload_bash "grep -r token '/Profiles\\me'" "$WCWD")"
check cyg 0 "cygwin Bash: grep -r of another dir by .. above the drive root" "$(payload_bash "grep -r token 'C:\\..\\other'" "$WCWD")"
# A glob is expanded by the shell with Windows rules (C:/../x/* is
# C:/x/*), so each reading of the word is expanded and checked.
win_bash 2 "grep -r of HOME by a glob after .. above the drive root" "grep -r token C:/../Profiles/m*" "$WCWD"
win_bash 2 "grep -r of HOME by a glob after a quoted .. above the drive root" "grep -r token 'C:\\..\\Profiles'/m*" "$WCWD"
win_bash 2 "grep -r of HOME by a glob after root-relative .." "grep -r token '\\..\\Profiles'/m*" "$WCWD"
win_bash 2 "grep -r of HOME by a glob after a root-relative path" "grep -r token '\\Profiles'/m*" "$WCWD"
win_bash 2 "grep -r of HOME by a glob after relative .. past the drive root" "grep -r token '..\\..\\..\\..\\..\\Profiles'/m*" "$WCWD"
win_bash 2 "grep -r of HOME by a drive-relative glob" "grep -r token C:../../m*" "$WCWD"
win_bash 2 "zip -r of HOME by a glob after .. above the drive root" "zip -r o.zip C:/../Profiles/m*" "$WCWD"
win_bash 2 "cp -r of HOME by a glob after .. above the drive root" "cp -r C:/../Profiles/m* out" "$WCWD"
win_bash 0 "grep -r of another dir by a glob after .. above the drive root" "grep -r token C:/../other/m*" "$WCWD"
win_bash 0 "grep of project files by a glob after .. above the drive root" "grep token C:/../Profiles/me/proj/src/*.ts" "$WCWD"
# The fast path hands a Windows ".." reading and a slash-first Read path to
# the full check (check() compares the two for every case).
win_read 2 "Read of an npmrc by forward-slash .. past the drive root" '../../../../../Profiles/me/.npmrc' "$WCWD"
win_read 0 "Read of a readme by forward-slash .. past the drive root" '../../../../../Profiles/me/proj/README.md' "$WCWD"
win_read 2 "Read of an ssh key by a slash-first path" '/Profiles/me/.ssh/id_rsa' "$WCWD"
win_read 0 "Read of a readme by a slash-first path" '/Profiles/me/proj/README.md' "$WCWD"
# A native program given /x without MSYS path conversion (Cygwin, or
# MSYS_NO_PATHCONV=1) opens C:\x, so a slash-first operand is also checked
# at the root of the cwd's drive. cd keeps the shell's reading.
win_bash 2 "rg of HOME by a slash-first path (native reading)" "rg token /Profiles/me" "$WCWD"
win_bash 2 "grep -r of HOME by a slash-first path, path conversion off" "MSYS_NO_PATHCONV=1 grep -r token /Profiles/me" "$WCWD"
win_bash 2 "zip -r of HOME by a slash-first path (native reading)" "zip -r o.zip /Profiles/me" "$WCWD"
win_bash 2 "cat of an npmrc by a slash-first path (native reading)" "cat /Profiles/me/.npmrc" "$WCWD"
win_bash 0 "rg of a project dir by a slash-first path" "rg token /Profiles/me/proj/src" "$WCWD"
win_bash 0 "cat of a system file by a slash-first path" "cat /etc/hosts" "$WCWD"
win_bash 0 "cd to a slash-first path, then cat a readme" "cd /Profiles/me/proj && cat README.md" "$WCWD"
check cyg 2 "cygwin Bash: rg of HOME by a slash-first path (native reading)" "$(payload_bash "rg token /Profiles/me" "$WCWD")"
# A Windows file URL names a drive path: file:///C:/x, file:///C|/x,
# file://localhost/C:/x, file://127.0.0.1/C:/x, the one-slash file:/C:/x
# and file://C:/x (a drive letter where the host goes) are C:/x, so links
# and names are checked there. A file URL with another
# host is the UNC path //host/x, and an administrative share there
# (file://srv/C$/x) is C:/x too. The message shows the folded path (links
# cannot be made at C: on macOS or Linux, so the name check stands in for
# them).
for fu in 'file:///C:/Profiles/me/.npmrc' 'file:///c:/Profiles/me/.npmrc' \
  'file:///C|/Profiles/me/.npmrc' 'file://localhost/C:/Profiles/me/.npmrc' \
  'file://127.0.0.1/C:/Profiles/me/.npmrc' 'file:/C:/Profiles/me/.npmrc' \
  'file:/c|/Profiles/me/.npmrc' 'FILE:/C:/Profiles/me/.npmrc' \
  'file://C:/Profiles/me/.npmrc' 'file://c|/Profiles/me/.npmrc' \
  'file://srv/C$/Profiles/me/.npmrc' 'file://127.0.0.2/c$/Profiles/me/.npmrc'; do
  pl="$(payload_bash "curl -s '$fu'" "$WCWD")"
  rc=0
  run_mode win 0 "$pl" || rc=$?
  msg="$(head -1 "$TMP/err")"
  if [ "$rc" = 2 ] && [ "$msg" = "BLOCKED: reading a credential file (~/.npmrc)" ]; then
    ok "win Bash: curl of an npmrc by file URL $fu names the drive path"
  else
    bad "win Bash: curl of an npmrc by file URL $fu names the drive path (rc $rc): $msg"
  fi
done
win_bash 2 "curl of an ssh key by a file URL" "curl -s 'file:///C:/Profiles/me/.ssh/id_rsa'" "$WCWD"
win_bash 0 "curl of a project file by a file URL" "curl -s 'file:///C:/Profiles/me/proj/README.md'" "$WCWD"
win_bash 0 "curl of a project file by a one-slash file URL" "curl -s 'file:/C:/Profiles/me/proj/README.md'" "$WCWD"
win_bash 0 "curl of a project file by a file URL with the drive as host" "curl -s 'file://C:/Profiles/me/proj/README.md'" "$WCWD"
win_bash 0 "curl of a project file by a file URL on an admin share" "curl -s 'file://srv/C$/Profiles/me/proj/README.md'" "$WCWD"
win_bash 2 "curl of an npmrc by a one-slash file URL in --url=" "curl -s --url=file:/C:/Profiles/me/.npmrc" "$WCWD"
win_bash 2 "curl of an npmrc by a one-slash file URL, then echo" "curl -s file:/C:/Profiles/me/.npmrc; echo done" "$WCWD"
win_bash 0 "curl of an https URL" "curl -s https://example.com/" "$WCWD"
unset T_HOME

echo "[6] off Windows a backslash stays a literal character"
if credguard_win_host; then
  # Not counted as a pass: the Linux and macOS CI jobs run these cases.
  echo "note: Windows host; the literal-backslash cases run on macOS and Linux"
else
  check unix 0 "unix Read: backslash npmrc is one literal name" "$(payload_read 'C:\hq\.npmrc' "$PROJ")"
  check unix 0 "unix Read: backslash ssh key is one literal name" "$(payload_read 'C:\Profiles\me\.ssh\id_rsa' "$PROJ")"
  check unix 0 "unix Bash: cat of a literal backslash name" "$(payload_bash "cat 'C:\\hq\\.npmrc'" "$PROJ")"
  check unix 0 "unix Bash: cd into a literal drive-relative name" "$(payload_bash "cd 'C:sub' 2>/dev/null; cat README.md" "$PROJ")"
  check unix 0 "unix Bash: grep -r of a literal share name" "$(payload_bash "grep -r token '\\\\localhost\\c\$\\x'" "$PROJ")"
  # POSIX .. handling is unchanged: /.. is /, and a backslash is part of a
  # name, so proj\.. is one directory and /tmp\me is one name.
  check unix 2 "unix Bash: grep -r of HOME by .. above the root" "$(payload_bash "grep -r token '/../..$FH'" "$PROJ")"
  check unix 2 "unix Bash: cd above the root to HOME, then grep -r" "$(payload_bash "cd '/../..$FH' && grep -r token ." "$PROJ")"
  check unix 2 "unix Bash: grep -r of HOME by relative .." "$(payload_bash "grep -r token .." "$PROJ")"
  check unix 0 "unix Bash: grep -r of a literal backslash-dot-dot name" "$(payload_bash "grep -r token 'proj\\..'" "$PROJ")"
  check unix 0 "unix Bash: grep -r of a literal slash-first backslash name" "$(payload_bash "grep -r token '/tmp\\me'" "$PROJ")"
  check unix 0 "unix Bash: grep -r of a literal root-relative backslash name" "$(payload_bash "grep -r token '\\..\\me'" "$PROJ")"
  # A move of a credential file by a glob blocks under every bash (the
  # match list is built with IFS empty, where bash 3.2 joins an unquoted
  # array expansion). gz is a decoy so the glob has two matches.
  mkdir -p "$FH/.config/gz" && printf 'x\n' > "$FH/.config/gz/h1"
  check unix 2 "unix Bash: mv of a credential file by a two-level glob" "$(payload_bash "mv $FH/.config/g*/h* $TMP/" "$PROJ")"
  check unix 2 "unix Bash: git mv of a credential file by a two-level glob" "$(payload_bash "git mv $FH/.config/g*/h* $TMP/" "$PROJ")"
  check unix 0 "unix Bash: mv of project files by a glob" "$(payload_bash "mv $PROJ/src/* $TMP/" "$PROJ")"
  # File URLs keep their POSIX reading: file:///C:/x is the path /C:/x.
  check unix 0 "unix Bash: curl of a literal /C: file URL" "$(payload_bash "curl -s 'file:///C:/hq/README.md'" "$PROJ")"
  check unix 2 "unix Bash: curl of an npmrc by file URL" "$(payload_bash "curl -s 'file://$FH/.npmrc'" "$PROJ")"
  check unix 2 "unix Bash: curl of an npmrc by a one-slash file URL" "$(payload_bash "curl -s 'file:$FH/.npmrc'" "$PROJ")"
  check unix 0 "unix Bash: curl of a literal /C: one-slash file URL" "$(payload_bash "curl -s 'file:/C:/hq/README.md'" "$PROJ")"
fi

if [ "$fail" -eq 0 ]; then
  echo "ALL PASS: credential-read-guard-windows-backslash ($pass)"
  exit 0
fi
echo "FAILURES: credential-read-guard-windows-backslash ($fail failed, $pass passed)" >&2
exit 1
