#!/usr/bin/env bash
# hq-core: public
# mandatory-scope-authorizer-windows-paths.test.sh — on a Windows host (Git
# Bash, MSYS, Cygwin) the scope authorizer reads a drive path (D:\x, D:/x), a
# long-path form (\\?\D:\x), an administrative share (\\host\d$\x) and a
# path that starts with one backslash as the same folder the shell spells
# /d/x, for the Read, Edit, Write, Grep, Glob and Bash tools.
#
# Sections:
#   [1] six tools x three spellings: own company allowed, other company refused
#   [2] other absolute spellings: mixed-case drive letter, long-path and
#       device prefixes, administrative shares, a path from the drive root,
#       a Windows working directory, Glob patterns, NotebookEdit
#   [3] Bash quoting: single quotes, double quotes, doubled backslashes
#   [4] forms with no shell spelling are refused
#   [5] a second tree answers as its shell spelling does
#   [6] ordinary commands with backslashes answer as they do off Windows
#   [7] OSTYPE cygwin is a Windows host too (Git Bash can report it)
#   [8] off Windows a colon and a backslash stay characters of a file name
#
# How Windows is simulated: on macOS and Linux the hook runs with OSTYPE=msys
# and MSYSTEM=MINGW64 in its environment, as the credential guard's Windows
# test does. A drive cannot be mounted at /d there, so the fixture tree sits
# at <tmp>/d/hq and HQ_SCOPE_DRIVE_PREFIX=<tmp> tells the hook that drives
# are mounted under <tmp>; D:\hq is then <tmp>/d/hq. On a real Windows host
# the same cases would need the tree on a drive root, so this file skips
# there.
set -uo pipefail

# shellcheck source=mandatory-scope-authorizer-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/mandatory-scope-authorizer-lib.sh"

case "${OSTYPE:-}" in
  msys*|cygwin*|win32*)
    echo "SKIP: simulated-drive cases run on macOS and Linux only"
    exit 0
    ;;
esac

BASE="$TMP"
trap 'rm -rf "$BASE"' EXIT
TMP="$BASE/d/hq"
mkdir -p "$TMP"
install_fixture
OWN=owncorp
OTHER=otherco
mkdir -p "$TMP/companies/$OWN/settings" "$TMP/workspace/notes"
printf 'companies:\n  %s:\n    name: Own\n  %s:\n    name: Other\n' "$OWN" "$OTHER" \
  > "$TMP/companies/manifest.yaml"
printf 'x\n' > "$TMP/companies/$OWN/settings/a.md"
printf 'x\n' > "$TMP/companies/$OTHER/settings/secret.md"
printf 'company_slug: %s\n' "$OWN" > "$TMP/workspace/sessions/sess-bound/meta.yaml"
# shellcheck source=../lib/session-scope-capability.sh
. "$ROOT/core/scripts/lib/session-scope-capability.sh"
session_scope_mint "$TMP" "sess-bound" "$OWN"

# A second tree on another drive, with the same company names.
TREE2="$BASE/e/hq2"
mkdir -p "$TREE2/companies/$OWN/settings" "$TREE2/companies/$OTHER/settings" "$TREE2/core/scripts/lib"
cp "$TMP/companies/manifest.yaml" "$TREE2/companies/manifest.yaml"
printf 'x\n' > "$TREE2/companies/$OTHER/settings/secret.md"
printf 'x\n' > "$TREE2/companies/$OWN/settings/a.md"

WIN_CWD='D:\hq'

# win <payload>: exit code of the hook on a simulated Windows host.
win() { run_hook_env "$1" OSTYPE=msys MSYSTEM=MINGW64 "HQ_SCOPE_DRIVE_PREFIX=$BASE"; }
cyg() { run_hook_env "$1" OSTYPE=cygwin "HQ_SCOPE_DRIVE_PREFIX=$BASE"; }

# payload <tool> <path> [cwd]: the tool call that opens <path>.
payload() {
  local tool="$1" p="$2" cwd="${3:-$WIN_CWD}"
  case "$tool" in
    Read) jq -cn --arg cwd "$cwd" --arg p "$p" '{tool_name:"Read",session_id:"sess-bound",cwd:$cwd,tool_input:{file_path:$p}}' ;;
    Edit) jq -cn --arg cwd "$cwd" --arg p "$p" '{tool_name:"Edit",session_id:"sess-bound",cwd:$cwd,tool_input:{file_path:$p,old_string:"x",new_string:"y"}}' ;;
    Write) jq -cn --arg cwd "$cwd" --arg p "$p" '{tool_name:"Write",session_id:"sess-bound",cwd:$cwd,tool_input:{file_path:$p,content:"y"}}' ;;
    NotebookEdit) jq -cn --arg cwd "$cwd" --arg p "$p" '{tool_name:"NotebookEdit",session_id:"sess-bound",cwd:$cwd,tool_input:{notebook_path:$p,new_source:"y"}}' ;;
    Grep) jq -cn --arg cwd "$cwd" --arg p "$p" '{tool_name:"Grep",session_id:"sess-bound",cwd:$cwd,tool_input:{pattern:"x",path:$p}}' ;;
    Glob) jq -cn --arg cwd "$cwd" --arg p "$p" '{tool_name:"Glob",session_id:"sess-bound",cwd:$cwd,tool_input:{pattern:"*.md",path:$p}}' ;;
    GlobPattern) jq -cn --arg cwd "$cwd" --arg p "$p" '{tool_name:"Glob",session_id:"sess-bound",cwd:$cwd,tool_input:{pattern:$p}}' ;;
    Bash) jq -cn --arg cwd "$cwd" --arg c "cat '$p'" '{tool_name:"Bash",session_id:"sess-bound",cwd:$cwd,tool_input:{command:$c}}' ;;
    Command) jq -cn --arg cwd "$cwd" --arg c "$p" '{tool_name:"Bash",session_id:"sess-bound",cwd:$cwd,tool_input:{command:$c}}' ;;
  esac
}

# target <tool> <file> <folder>: file tools and Bash open the file, the
# search tools open its folder.
target() {
  case "$1" in Grep|Glob) printf '%s' "$3" ;; *) printf '%s' "$2" ;; esac
}
bs() { printf '%s' "${1//\//\\}"; }

TOOLS=(Read Edit Write Grep Glob Bash)
OWN_FILE="hq/companies/$OWN/settings/a.md"
OWN_DIR="hq/companies/$OWN/settings"
OTHER_FILE="hq/companies/$OTHER/settings/secret.md"
OTHER_DIR="hq/companies/$OTHER/settings"

echo "[1] six tools, three spellings"
for tool in "${TOOLS[@]}"; do
  own="$(target "$tool" "$OWN_FILE" "$OWN_DIR")"
  oth="$(target "$tool" "$OTHER_FILE" "$OTHER_DIR")"
  expect_exit 0 "$(win "$(payload "$tool" "D:\\$(bs "$own")")")" "$tool own company, backslash drive path"
  expect_exit 0 "$(win "$(payload "$tool" "D:/$own")")" "$tool own company, forward-slash drive path"
  expect_exit 0 "$(win "$(payload "$tool" "$BASE/d/$own")")" "$tool own company, shell spelling"
  expect_exit 2 "$(win "$(payload "$tool" "D:\\$(bs "$oth")")")" "$tool other company, backslash drive path"
  expect_exit 2 "$(win "$(payload "$tool" "D:/$oth")")" "$tool other company, forward-slash drive path"
  expect_exit 2 "$(win "$(payload "$tool" "$BASE/d/$oth")")" "$tool other company, shell spelling"
done

echo "[2] other absolute spellings"
for tool in "${TOOLS[@]}"; do
  own="$(bs "$(target "$tool" "$OWN_FILE" "$OWN_DIR")")"
  oth="$(bs "$(target "$tool" "$OTHER_FILE" "$OTHER_DIR")")"
  expect_exit 2 "$(win "$(payload "$tool" "d:\\$oth")")" "$tool other company, lower-case drive letter"
  expect_exit 0 "$(win "$(payload "$tool" "d:\\$own")")" "$tool own company, lower-case drive letter"
  expect_exit 2 "$(win "$(payload "$tool" "D:/hq\\companies/$OTHER\\settings")")" "$tool other company, mixed separators"
  expect_exit 2 "$(win "$(payload "$tool" "\\\\?\\D:\\$oth")")" "$tool other company, long-path prefix"
  expect_exit 0 "$(win "$(payload "$tool" "\\\\?\\D:\\$own")")" "$tool own company, long-path prefix"
  expect_exit 2 "$(win "$(payload "$tool" "\\\\.\\D:\\$oth")")" "$tool other company, device prefix on a drive"
  expect_exit 2 "$(win "$(payload "$tool" "\\\\localhost\\d\$\\$oth")")" "$tool other company, administrative share"
  expect_exit 2 "$(win "$(payload "$tool" "\\\\?\\UNC\\localhost\\d\$\\$oth")")" "$tool other company, long-path administrative share"
  expect_exit 2 "$(win "$(payload "$tool" "\\$oth")")" "$tool other company, path from the drive root"
  expect_exit 0 "$(win "$(payload "$tool" "\\$own")")" "$tool own company, path from the drive root"
  expect_exit 2 "$(win "$(payload "$tool" "D:\\$oth" "$TMP")")" "$tool other company, backslash drive path, shell-spelled cwd"
  expect_exit 2 "$(win "$(payload "$tool" "D:\\hq\\companies\\$OWN\\..\\$OTHER\\settings")")" "$tool other company, .. after own company"
done
for tool in Read Edit Write Bash; do
  expect_exit 2 "$(win "$(payload "$tool" "companies\\$OTHER\\settings\\secret.md")")" "$tool other company, relative backslash path, Windows cwd"
  expect_exit 0 "$(win "$(payload "$tool" "companies\\$OWN\\settings\\a.md")")" "$tool own company, relative backslash path, Windows cwd"
  expect_exit 2 "$(win "$(payload "$tool" "..\\..\\$OTHER\\settings\\secret.md" "D:\\hq\\companies\\$OWN\\settings")")" "$tool other company, ..\\ from an own-company cwd"
done
expect_exit 2 "$(win "$(payload NotebookEdit "D:\\hq\\companies\\$OTHER\\settings\\n.ipynb")")" "NotebookEdit other company, backslash drive path"
expect_exit 0 "$(win "$(payload NotebookEdit "D:\\hq\\companies\\$OWN\\settings\\n.ipynb")")" "NotebookEdit own company, backslash drive path"
expect_exit 2 "$(win "$(payload GlobPattern "D:\\hq\\companies\\$OTHER\\**\\*.md")")" "Glob pattern other company, backslash drive path"
expect_exit 2 "$(win "$(payload GlobPattern "D:/hq/companies/$OTHER/**/*.md")")" "Glob pattern other company, forward-slash drive path"
expect_exit 2 "$(win "$(payload GlobPattern "companies\\$OTHER\\**\\*.md")")" "Glob pattern other company, relative backslash"
expect_exit 0 "$(win "$(payload GlobPattern "D:\\hq\\companies\\$OWN\\**\\*.md")")" "Glob pattern own company, backslash drive path"
expect_exit 0 "$(win "$(payload GlobPattern "companies\\$OWN\\**\\*.md")")" "Glob pattern own company, relative backslash"

echo "[3] Bash quoting"
O_BS="D:\\hq\\companies\\$OTHER\\settings\\secret.md"
A_BS="D:\\hq\\companies\\$OWN\\settings\\a.md"
expect_exit 2 "$(win "$(payload Command "cat \"$O_BS\"")")" "Bash other company, double-quoted backslash drive path"
expect_exit 2 "$(win "$(payload Command "cat ${O_BS//\\/\\\\}")")" "Bash other company, unquoted doubled backslashes"
expect_exit 2 "$(win "$(payload Command "cat \"${O_BS//\\/\\\\}\"")")" "Bash other company, double-quoted doubled backslashes"
expect_exit 2 "$(win "$(payload Command "cat D:/hq/companies/$OTHER/settings/secret.md")")" "Bash other company, unquoted forward-slash drive path"
expect_exit 2 "$(win "$(payload Command "true && head -1 '$O_BS' | wc -l")")" "Bash other company, backslash drive path inside a pipeline"
expect_exit 2 "$(win "$(payload Command "ls 'D:\\hq\\companies\\$OTHER'")")" "Bash other company, ls of a backslash folder"
expect_exit 2 "$(win "$(payload Command "cat '\\hq\\companies\\$OTHER\\settings\\secret.md'")")" "Bash other company, path from the drive root"
expect_exit 2 "$(win "$(payload Command "cat '\\\\localhost\\d\$\\hq\\companies\\$OTHER\\settings\\secret.md'")")" "Bash other company, administrative share"
expect_exit 2 "$(win "$(payload Command "cat '\\\\?\\D:\\hq\\companies\\$OTHER\\settings\\secret.md'")")" "Bash other company, long-path prefix"
expect_exit 0 "$(win "$(payload Command "cat \"$A_BS\"")")" "Bash own company, double-quoted backslash drive path"
expect_exit 0 "$(win "$(payload Command "cat ${A_BS//\\/\\\\}")")" "Bash own company, unquoted doubled backslashes"
expect_exit 0 "$(win "$(payload Command "cat D:/hq/companies/$OWN/settings/a.md")")" "Bash own company, unquoted forward-slash drive path"
expect_exit 0 "$(win "$(payload Command "cat '\\\\?\\D:\\hq\\companies\\$OWN\\settings\\a.md'")")" "Bash own company, long-path prefix"

echo "[4] forms with no shell spelling are refused"
for tool in Read Edit Write Grep Glob; do
  expect_exit 2 "$(win "$(payload "$tool" "D:companies\\$OTHER\\settings")")" "$tool drive-relative path"
  expect_exit 2 "$(win "$(payload "$tool" '\\?\Volume{0}\hq\companies')")" "$tool volume path"
  expect_exit 2 "$(win "$(payload "$tool" '\\.\pipe\x')")" "$tool device path"
done
expect_exit 2 "$(win "$(payload Command "cat '\\\\?\\Volume{0}\\hq\\companies\\$OTHER\\settings\\secret.md'")")" "Bash volume path"
expect_exit 2 "$(win "$(payload Command "cat '\\\\.\\pipe\\x'")")" "Bash device path"

echo "[5] a second tree answers as its shell spelling does"
for tool in "${TOOLS[@]}"; do
  for who in "$OWN" "$OTHER"; do
    f="hq2/companies/$who/settings/secret.md"
    [ "$who" = "$OTHER" ] || f="hq2/companies/$who/settings/a.md"
    t="$(target "$tool" "$f" "hq2/companies/$who/settings")"
    want="$(win "$(payload "$tool" "$BASE/e/$t")")"
    expect_exit "$want" "$(win "$(payload "$tool" "E:\\$(bs "$t")")")" "$tool second tree $who, backslash drive path (shell spelling answers $want)"
    expect_exit "$want" "$(win "$(payload "$tool" "E:/$t")")" "$tool second tree $who, forward-slash drive path (shell spelling answers $want)"
    expect_exit "$want" "$(win "$(payload "$tool" "e:\\$(bs "$t")")")" "$tool second tree $who, lower-case drive letter (shell spelling answers $want)"
  done
done

echo "[6] ordinary commands with backslashes answer as they do off Windows"
while IFS= read -r c; do
  [ -n "$c" ] || continue
  want="$(run_hook "$(payload Command "$c" "$TMP")")"
  expect_exit "$want" "$(win "$(payload Command "$c")")" "ordinary command, Windows cwd: $c (off Windows answers $want)"
  expect_exit "$want" "$(win "$(payload Command "$c" "$TMP")")" "ordinary command, shell cwd: $c (off Windows answers $want)"
done <<'CMDS'
printf '%s\n' hi
echo "a\"b" 'c'
grep -c '\.md' workspace/notes/x.txt
grep -E '\\.\\w+' workspace/notes/x.txt
sed 's/\(a\)/\1/' workspace/notes/x.txt
echo one\ two
echo C:\\temp
ls 'C:\Program Files'
git log -1 --format='%h %s' HEAD~1
echo "x: y" | tr ':' '\n'
find workspace/notes -name \*.md -exec ls {} \;
CMDS

echo "[7] OSTYPE cygwin is a Windows host too (Git Bash can report it)"
expect_exit 2 "$(cyg "$(payload Read "D:\\$(bs "$OTHER_FILE")")")" "Cygwin Read other company, backslash drive path"
expect_exit 0 "$(cyg "$(payload Read "D:\\$(bs "$OWN_FILE")")")" "Cygwin Read own company, backslash drive path"
expect_exit 2 "$(cyg "$(payload Bash "D:\\$(bs "$OTHER_FILE")")")" "Cygwin Bash other company, backslash drive path"

echo "[8] off Windows a colon and a backslash stay characters of a file name"
# Expected codes are the answers of the hook before it read Windows spellings.
expect_exit 0 "$(run_hook "$(payload Read "D:\\$(bs "$OTHER_FILE")" "$TMP")")" "off Windows Read of a file named with a drive-like prefix"
expect_exit 0 "$(run_hook "$(payload Read "D:/$OTHER_FILE" "$TMP")")" "off Windows Read under a folder named D:"
expect_exit 2 "$(run_hook "$(payload Read "companies\\$OTHER\\settings\\secret.md" "$TMP")")" "off Windows Read of a relative backslash name"
expect_exit 0 "$(run_hook "$(payload Bash "D:\\$(bs "$OTHER_FILE")" "$TMP")")" "off Windows Bash cat of a file named with a drive-like prefix"
expect_exit 0 "$(run_hook "$(payload Bash "companies\\$OTHER\\settings\\secret.md" "$TMP")")" "off Windows Bash cat of a relative backslash name"
expect_exit 0 "$(run_hook "$(payload Grep "D:\\hq\\companies\\$OTHER" "$TMP")")" "off Windows Grep under a folder named with a drive-like prefix"
expect_exit 0 "$(run_hook "$(payload Read 'D:notes.txt' "$TMP")")" "off Windows Read of a file named D:notes.txt"
expect_exit 0 "$(run_hook "$(payload Read '\\.\pipe\x' "$TMP")")" "off Windows Read of a name that starts with backslashes"
expect_exit 2 "$(run_hook "$(payload Read "$TMP/companies/$OTHER/settings/secret.md" "$TMP")")" "off Windows Read other company"
expect_exit 0 "$(run_hook "$(payload Read "$TMP/companies/$OWN/settings/a.md" "$TMP")")" "off Windows Read own company"

echo "[9] names Windows rewrites: trailing periods and spaces, short 8.3 names"
for tool in Read Edit Write Grep Glob; do
  oth="$(target "$tool" "$OTHER_FILE" "$OTHER_DIR")"
  own="$(target "$tool" "$OWN_FILE" "$OWN_DIR")"
  expect_exit 2 "$(win "$(payload "$tool" "D:\\$(bs "${oth/$OTHER/$OTHER.}")")")" "$tool other company, trailing period on the company folder"
  expect_exit 2 "$(win "$(payload "$tool" "D:\\$(bs "${oth/$OTHER/$OTHER. }")")")" "$tool other company, trailing period and space on the company folder"
  expect_exit 2 "$(win "$(payload "$tool" "D:/${oth/companies/companies.}")")" "$tool other company, trailing period on companies"
  rel="${oth#hq/}"
  expect_exit 2 "$(win "$(payload "$tool" "${rel/$OTHER/$OTHER.}")")" "$tool other company, relative path with a trailing period"
  expect_exit 0 "$(win "$(payload "$tool" "D:\\$(bs "${own/$OWN/$OWN.}")")")" "$tool own company, trailing period on the company folder"
  expect_exit 2 "$(win "$(payload "$tool" "D:\\$(bs "${oth/companies/COMPAN~1}")")")" "$tool other company, 8.3 name of companies"
  expect_exit 2 "$(win "$(payload "$tool" "D:\\$(bs "${oth/$OTHER/OTHERC~1}")")")" "$tool other company, 8.3 name of the company folder"
  expect_exit 2 "$(win "$(payload "$tool" "D:/hq/companies/otherc~1/settings")")" "$tool other company, lower-case 8.3 name"
  expect_exit 0 "$(win "$(payload "$tool" "D:\\hq\\workspace\\notes")")" "$tool own tree, ordinary folder"
  expect_exit 0 "$(win "$(payload "$tool" "D:\\hq\\workspace\\NOTES~1")")" "$tool 8.3 name outside companies"
done
expect_exit 2 "$(win "$(payload Command "cat 'D:\\hq\\companies\\$OTHER.\\settings\\secret.md'")")" "Bash other company, trailing period on the company folder"
expect_exit 2 "$(win "$(payload Command "cat companies/$OTHER./settings/secret.md")")" "Bash other company, relative path with a trailing period"
expect_exit 2 "$(win "$(payload Command "ls D:/hq/companies/$OTHER.")")" "Bash other company, trailing period at the end of a word"
expect_exit 2 "$(win "$(payload Command "cat 'D:\\hq\\COMPAN~1\\$OTHER\\settings\\secret.md'")")" "Bash other company, 8.3 name of companies"
expect_exit 2 "$(win "$(payload Command "cat companies/OTHERC~1/settings/secret.md")")" "Bash other company, 8.3 name of the company folder"
expect_exit 0 "$(win "$(payload Command "cat 'D:\\hq\\companies\\$OWN.\\settings\\a.md'")")" "Bash own company, trailing period on the company folder"
expect_exit 0 "$(win "$(payload Command "echo done.")")" "Bash sentence that ends in a period"
expect_exit 0 "$(win "$(payload Command "ls workspace/NOTES~1")")" "Bash 8.3 name outside companies"
LONGTAIL=""
for _ in $(seq 1 70); do LONGTAIL+=" x."; done
expect_exit 2 "$(win "$(payload Command "cat companies/$OTHER./settings/secret.md; echo$LONGTAIL")")" "Bash other company, trailing period before 70 more trailing periods"
expect_exit 2 "$(win "$(payload Command "cat 'D:\\hq\\companies\\$OTHER.\\settings\\secret.md'; echo$LONGTAIL")")" "Bash other company, backslash path with a trailing period before 70 more"
expect_exit 0 "$(win "$(payload Command "echo$LONGTAIL")")" "Bash 70 sentences that end in a period"

echo "[10] ANSI-C quoting spells a backslash"
for esc in '\x5c' '\134' '\u005c'; do
  if [ "$esc" = '\u005c' ] && { [ "${BASH_VERSINFO[0]:-3}" -lt 4 ] || { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]:-0}" -lt 2 ]; }; }; then
    continue # \u is ANSI-C quoting from bash 4.2 on; Git Bash ships bash 5; stock macOS bash 3.2 decodes neither in the shell nor the hook.
  fi
  w="D:${esc}hq${esc}companies${esc}$OTHER${esc}settings${esc}secret.md"
  expect_exit 2 "$(win "$(payload Command "cat \$'$w'")")" "Bash other company, drive path with $esc for each backslash"
  w="companies${esc}$OTHER${esc}settings${esc}secret.md"
  expect_exit 2 "$(win "$(payload Command "cat \$'$w'")")" "Bash other company, relative path with $esc for each backslash"
done
expect_exit 2 "$(win "$(payload Command "cat \$'\\x5chq\\x5ccompanies\\x5c$OTHER\\x5csettings\\x5csecret.md'")")" "Bash other company, drive-root path with \\x5c"
expect_exit 2 "$(win "$(payload Command "cat \$'\\x5c\\x5c?\\x5cD:\\x5chq\\x5ccompanies\\x5c$OTHER\\x5csettings\\x5csecret.md'")")" "Bash other company, long-path prefix with \\x5c"
expect_exit 0 "$(win "$(payload Command "cat \$'D:\\x5chq\\x5ccompanies\\x5c$OWN\\x5csettings\\x5ca.md'")")" "Bash own company, drive path with \\x5c"
expect_exit 2 "$(win "$(payload Command "cat '\\\\.\\D:\\hq\\companies\\$OTHER\\settings\\secret.md'")")" "Bash other company, device prefix on a drive"
ADM=""
for _ in $(seq 1 70); do ADM+=" //h/c\$/x"; done
expect_exit 2 "$(win "$(payload Command "ls$ADM")")" "Bash more than 64 administrative shares is refused"

echo "[10b] trailing periods the shell spells with quotes, braces, escapes and variables"
# $OTHER is otherco; each command reads otherco/settings/secret.md on Windows.
while IFS= read -r c; do
  [ -n "$c" ] || continue
  expect_exit 2 "$(win "$(payload Command "$c")")" "Bash other company: $c"
  o="${c//otherco/$OWN}"
  o="${o//other\\co/$OWN}"
  o="${o//secret.md/a.md}"
  expect_exit 0 "$(win "$(payload Command "$o")")" "Bash own company: $o"
done <<'CMDS'
cat companies/otherco...../settings/secret.md
cat companies/otherco.''/settings/secret.md
cat companies/otherco.""/settings/secret.md
cat companies/{otherco.,zz}/settings/secret.md
cat companies/otherco.\ /settings/secret.md
cat companies/otherco$'\x2e'/settings/secret.md
F=companies/otherco.; cat $F/settings/secret.md
cat companies/other\co./settings/secret.md
cat companies/otherco{.,..}/settings/secret.md
cat companies/otherco.{,}/settings/secret.md
cat companies/otherco{..,...}/settings/secret.md
cat companies/otherco{.,.}{,}/settings/secret.md
cat companies/otherco{,}./settings/secret.md
CMDS
# A bare //host word (cmd's //c switch) is not a path; a share after it is.
expect_exit 0 "$(win "$(payload Command "cmd //c ver")")" "Bash cmd //c ver"
expect_exit 0 "$(win "$(payload Command "cmd //c/ ver")")" "Bash cmd //c/ ver"
expect_exit 2 "$(win "$(payload Command "cat //localhost/d\$/hq/companies/$OTHER/settings/secret.md")")" "Bash other company, //host/d\$ share"
expect_exit 2 "$(win "$(payload Command "cmd //c type //localhost/d\$/hq/companies/$OTHER/settings/secret.md")")" "Bash other company, cmd //c type of a //host/d\$ share"
expect_exit 2 "$(win "$(payload Command "cat //d\$/hq/companies/$OTHER/settings/secret.md")")" "Bash other company, //d\$ share with no host"
# cmd //c type, the way a Windows command reads a file from Git Bash.
for p in "D:/hq/companies/otherco/settings/secret.md" 'D:\hq\companies\otherco\settings\secret.md' 'D:/hq\companies/otherco\settings/secret.md' "D:/hq/companies/otherco./settings/secret.md"; do
  expect_exit 2 "$(win "$(payload Command "cmd //c type \"$p\"")")" "Bash other company, cmd //c type $p"
  o="${p//otherco/$OWN}"
  o="${o//secret.md/a.md}"
  s=$SECONDS
  expect_exit 0 "$(win "$(payload Command "cmd //c type \"$o\"")")" "Bash own company, cmd //c type $o"
  if [ $((SECONDS - s)) -gt 10 ]; then
    echo "FAIL: Bash own company, cmd //c type $o took $((SECONDS - s)) s (limit 10 s)" >&2
    REGRESSION_FAILURES=$((REGRESSION_FAILURES + 1))
  fi
done

echo "[11] raw spellings refused before Windows paths were read are still refused"
# The hook already read a backslash as a separator on Windows and refused
# these with the shell-spelled cwd; the rewrite must not turn them into allows.
for tool in Read Edit Write; do
  expect_exit 2 "$(win "$(payload "$tool" "companies\\$OTHER\\settings\\secret.md" "$TMP")")" "$tool other company, relative backslash path, shell cwd"
  expect_exit 2 "$(win "$(payload "$tool" "companies/$OWN\\..\\$OTHER\\settings\\secret.md" "$TMP")")" "$tool other company, backslash .. after own company, shell cwd"
  expect_exit 2 "$(win "$(payload "$tool" "$TMP\\companies\\$OTHER\\settings\\secret.md" "$TMP")")" "$tool other company, shell-spelled root with backslashes"
done
for tool in Grep Glob; do
  expect_exit 2 "$(win "$(payload "$tool" "companies\\$OTHER\\settings" "$TMP")")" "$tool other company, relative backslash folder, shell cwd"
done
expect_exit 2 "$(win "$(payload Command "cat companies\\\\$OTHER\\\\settings\\\\secret.md" "$TMP")")" "Bash other company, unquoted doubled backslashes, shell cwd"

# Off Windows the same names are ordinary names.
expect_exit 0 "$(run_hook "$(payload Read "$TMP/companies/$OTHER./settings/secret.md" "$TMP")")" "off Windows Read of a folder named with a trailing period"

if [ "$REGRESSION_FAILURES" -gt 0 ]; then
  echo "FAILED: $REGRESSION_FAILURES case(s)" >&2
  exit 1
fi
echo "PASS: mandatory-scope-authorizer-windows-paths"
