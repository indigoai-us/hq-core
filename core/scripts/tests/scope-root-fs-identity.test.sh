#!/usr/bin/env bash
# hq-core: public
# Regression tests: the scope guard decides whether a path is inside HQ by
# filesystem identity, not only by the spelling of the HQ root. On a volume
# that folds letters, an HQ root spelled with a Latin ligature or a sharp s
# (an "st", "ss" or "fi" in the root path) opens the real HQ folder, so a
# file tool aimed at another company's folder through that spelling must be
# refused like the plain path. Paths outside HQ that only look similar, and
# the locked company's own folder, stay allowed.
# Tool calls are fed to the hook as JSON input and never executed.
#
# The synthetic HQ root is created under $TMPDIR (mktemp); its last segment
# holds "fi", "st" and "ss" so every fold has something to replace.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
BASE="$(mktemp -d)"
trap 'rm -rf "$BASE"' EXIT
BASE="$(cd "$BASE" && pwd -P)"
TMP="$BASE/hq-first-assist"
C="$TMP/companies"

mkdir -p "$TMP/.claude/hooks" "$TMP/core/scripts/lib" "$TMP/.codex/hooks" \
  "$C/alpha/knowledge" "$C/beta/knowledge" "$C/_template" \
  "$TMP/workspace/sessions/sess-bound" "$TMP/workspace/tmp" "$BASE/home/.hq" \
  "$BASE/hq-first-assist-twin/companies/beta/knowledge"
cp "$ROOT/.claude/hooks/mandatory-scope-authorizer.sh" "$TMP/.claude/hooks/"
cp "$ROOT/.claude/hooks/bash-arith-subst-guard-lib.sh" "$TMP/.claude/hooks/"
cp "$ROOT/.claude/hooks/path-fold-lib.sh" "$TMP/.claude/hooks/"
for f in session-authz.sh session-scope-capability.sh hook-caller-lineage.sh session-id.sh; do
  cp "$ROOT/core/scripts/lib/$f" "$TMP/core/scripts/lib/"
done
cp "$ROOT/core/scripts/hqd-hook-flag-cache-lib.sh" "$ROOT/core/scripts/hook-lib.sh" "$TMP/core/scripts/"
cp "$ROOT/.codex/hooks/codex-explicit-path-flag.cjs" "$TMP/.codex/hooks/"
printf 'companies:\n  alpha:\n    name: alpha\n  beta:\n    name: beta\n' > "$C/manifest.yaml"
printf 'SYNTHETIC-CANARY alpha\n' > "$C/alpha/knowledge/canary.md"
printf 'SYNTHETIC-CANARY beta\n' > "$C/beta/knowledge/canary.md"
printf '{"cells":[]}\n' > "$C/beta/knowledge/nb.ipynb"
printf '{"cells":[]}\n' > "$C/alpha/knowledge/nb.ipynb"
printf 'twin\n' > "$BASE/hq-first-assist-twin/companies/beta/knowledge/canary.md"
export HOME="$BASE/home"
printf 'company_slug: alpha\n' > "$TMP/workspace/sessions/sess-bound/meta.yaml"
# shellcheck source=../lib/session-scope-capability.sh
. "$ROOT/core/scripts/lib/session-scope-capability.sh"
session_scope_mint "$TMP" "sess-bound" "alpha" >/dev/null 2>&1

FOLDS=0
[ "$TMP/COMPANIES" -ef "$TMP/companies" ] && FOLDS=1
echo "case-insensitive volume: $FOLDS"

# Spellings of the HQ root. Each replaces one ASCII pair in the last segment
# only, so the rest of the path keeps the spelling the volume stores.
FI=$'\xef\xac\x81'   # U+FB01
LST=$'\xef\xac\x85'  # U+FB05
ST=$'\xef\xac\x86'   # U+FB06
SZ=$'\xc3\x9f'       # U+00DF
CSZ=$'\xe1\xba\x9e'  # U+1E9E
FFI=$'\xef\xac\x83'  # U+FB03 (no "ffi" in the root: never resolves)
parent="${TMP%/*}"
ROOTS=(
  "$parent/hq-${FI}rst-assist"
  "$parent/hq-fir${LST}-assist"
  "$parent/hq-fir${ST}-assist"
  "$parent/hq-first-a${SZ}ist"
  "$parent/hq-first-a${CSZ}ist"
  "$parent/hq-${FI}r${ST}-a${SZ}i${LST}"
)

# A spelling resolves to the real root only where the volume folds it.
B=0
if [ "$FOLDS" -eq 1 ] && [ "${ROOTS[0]}" -ef "$TMP" ]; then
  B=2
fi
echo "ligature root resolves: $([ "$B" = 2 ] && echo 1 || echo 0)"

FAILURES=0
PASSES=0
payload_for() {
  local tool="$1" p="$2"
  case "$tool" in
    Read) jq -cn --arg v "$p" '{file_path:$v}' ;;
    Write) jq -cn --arg v "$p" '{file_path:$v,content:"x"}' ;;
    Edit) jq -cn --arg v "$p" '{file_path:$v,old_string:"SYNTHETIC",new_string:"S"}' ;;
    MultiEdit) jq -cn --arg v "$p" '{file_path:$v,edits:[{old_string:"SYNTHETIC",new_string:"S"}]}' ;;
    NotebookEdit) jq -cn --arg v "${p%canary.md}nb.ipynb" '{notebook_path:$v,new_source:"x",cell_type:"code",edit_mode:"insert"}' ;;
    Grep) jq -cn --arg v "${p%/canary.md}" '{pattern:"SYNTHETIC",path:$v}' ;;
    Glob) jq -cn --arg v "${p%/canary.md}" '{pattern:"*.md",path:$v}' ;;
    Bash) jq -cn --arg v "cat '$p'" '{command:$v}' ;;
  esac
}

check() {
  local expected="$1" tool="$2" path="$3" label="$4" input payload rc=0 err
  input="$(payload_for "$tool" "$path")"
  payload="$(jq -cn --arg t "$tool" --arg cwd "$CWD" --argjson ti "$input" \
    '{tool_name:$t,hook_event_name:"PreToolUse",session_id:"sess-bound",cwd:$cwd,tool_input:$ti}')"
  err="$(printf '%s' "$payload" | "${BASH_BIN:-bash}" "$TMP/.claude/hooks/mandatory-scope-authorizer.sh" 2>&1 >/dev/null)" || rc=$?
  if [ "$rc" = "$expected" ]; then
    PASSES=$((PASSES + 1))
  else
    echo "FAIL [${LC_ALL:-} cwd=${CWD##*/}]: $tool $label (expected $expected, got $rc) ${err%%$'\n'*}" >&2
    FAILURES=$((FAILURES + 1))
  fi
}

TOOLS=(Read Write Edit MultiEdit NotebookEdit Grep Glob)
run_matrix() {
  local tool r i
  for tool in "${TOOLS[@]}"; do
    # The plain path to the other company, and the locked company's own path.
    check 2 "$tool" "$TMP/companies/beta/knowledge/canary.md" "ascii other company"
    check 0 "$tool" "$TMP/companies/alpha/knowledge/canary.md" "ascii own company"
    i=0
    for r in "${ROOTS[@]}"; do
      check "$B" "$tool" "$r/companies/beta/knowledge/canary.md" "folded root #$i other company"
      check 0 "$tool" "$r/companies/alpha/knowledge/canary.md" "folded root #$i own company"
      i=$((i + 1))
    done
    # A ligature that has no ASCII twin in the root never resolves.
    check 0 "$tool" "$parent/hq-first-a${FFI}st/companies/beta/knowledge/canary.md" "unresolvable ligature root"
    # Outside HQ: a sibling whose name only starts like the root.
    check 0 "$tool" "$BASE/hq-first-assist-twin/companies/beta/knowledge/canary.md" "lookalike sibling outside HQ"
    check 0 "$tool" "$parent/hq-fir${ST}-assist-twin/companies/beta/knowledge/canary.md" "folded lookalike sibling outside HQ"
  done
  # Bash already refused these; keep it pinned.
  check 2 Bash "$TMP/companies/beta/knowledge/canary.md" "ascii other company"
  # A Bash companies/ path is blocked even when the folded root is another
  # folder (case-sensitive volume): the check cannot trust the disk.
  check 2 Bash "${ROOTS[2]}/companies/beta/knowledge/canary.md" "folded root other company"
  check 0 Bash "${ROOTS[2]}/companies/alpha/knowledge/canary.md" "folded root own company"
}

for loc in C en_US.UTF-8; do
  export LC_ALL="$loc"
  for CWD in "$TMP" "$BASE"; do
    run_matrix
  done
done
unset LC_ALL

# Other spellings that reach the same folder: a firmlink/bind-mount-like
# second path, a symlink to the root, // and .. forms, and a relative path
# from a cwd spelled with a ligature.
export LC_ALL=C
CWD="$TMP"
ln -s "$TMP" "$BASE/hq-link"
check 2 Read "$BASE/hq-link/companies/beta/knowledge/canary.md" "symlink to root"
check 2 Read "$TMP//companies//beta/knowledge/canary.md" "double slashes"
check 2 Read "$TMP/workspace/../companies/beta/knowledge/canary.md" "dot-dot"
check "$B" Read "${ROOTS[2]}/workspace/../companies/beta/knowledge/canary.md" "folded root and dot-dot"
check "$B" Read "${ROOTS[2]}//companies/beta/knowledge/canary.md" "folded root and double slash"
# macOS mounts the data volume a second time: /System/Volumes/Data/<path>
# opens the same folder as /<path> (a firmlink), with the same spelling.
if [ -d "/System/Volumes/Data$TMP" ] && [ "/System/Volumes/Data$TMP" -ef "$TMP" ]; then
  check 2 Read "/System/Volumes/Data$TMP/companies/beta/knowledge/canary.md" "second mount of the volume"
  check 2 Write "/System/Volumes/Data$TMP/companies/beta/knowledge/new.md" "second mount of the volume"
  check 2 Glob "/System/Volumes/Data$TMP/companies/beta/knowledge" "second mount of the volume"
  check 0 Read "/System/Volumes/Data$TMP/companies/alpha/knowledge/canary.md" "second mount, own company"
fi
# A new file in a new folder: only the ancestors that exist are compared.
check "$B" Write "${ROOTS[2]}/companies/beta/new/deeper/file.md" "folded root, new folders"
check 0 Write "${ROOTS[2]}/companies/alpha/new/deeper/file.md" "folded root, own new folders"
CWD="${ROOTS[2]}"
# A relative companies/ path is HQ-relative too, whatever the cwd.
check 2 Read "companies/beta/knowledge/canary.md" "relative path, folded cwd"
check 0 Read "companies/alpha/knowledge/canary.md" "relative own path, folded cwd"
CWD="${ROOTS[2]}/companies"
check "$B" Read "beta/knowledge/canary.md" "relative tenant path, folded companies cwd"
check "$B" Grep "beta/knowledge/canary.md" "relative tenant search root, folded companies cwd"
CWD="$TMP"

# The path a file tool opens is spelled the way the host computes it:
# trimmed, `~` expanded, `..` removed as text before links are followed.
# Each form below opens the other company's file and must be refused.
mkdir -p "$BASE/outside/deep/a/b" "$C/alpha/links"
ln -s "$C/beta" "$C/alpha/links/to-beta"
ln -s "$C" "$BASE/colink"
ln -s "$BASE/outside/deep/a/b" "$C/alpha/links/deepout"
FWD=$'\xef\xbc\x8e'  # U+FF0E fullwidth full stop: a plain name on disk
OPEN_ROWS=(
  "$C/alpha/links/to-beta/$FWD$FWD/$FWD$FWD/planted.md|fullwidth dots after a link into the other company"
  "$C/alpha/links/to-beta/.$FWD/planted.md|mixed dots after a link into the other company"
  "$BASE/hq-link/companies/beta/$FWD$FWD/$FWD$FWD/planted.md|fullwidth dots after a link to the root"
  "$BASE/colink/beta/$FWD$FWD/planted.md|fullwidth dots after a link to companies"
  "/tmp/..$TMP/companies/beta/knowledge/canary.md|dot-dot after a linked system folder"
  "$C/alpha/links/deepout/../../../beta/knowledge/canary.md|dot-dot after a link out of HQ"
  " $TMP/companies/beta/knowledge/canary.md|leading space"
  $'\t'"$TMP/companies/beta/knowledge/canary.md|leading tab"
  $'\xc2\xa0'"$TMP/companies/beta/knowledge/canary.md|leading no-break space"
  $'\xe3\x80\x80'"$TMP/companies/beta/knowledge/canary.md|leading ideographic space"
  $'\xef\xbb\xbf'"$TMP/companies/beta/knowledge/canary.md|leading byte order mark"
  "$TMP/companies/beta/knowledge/canary.md |trailing space"
  "$C/beta/x\\../../knowledge/canary.md|backslash and dot-dot"
)
for row in "${OPEN_ROWS[@]}"; do
  for tool in Read Write Edit MultiEdit NotebookEdit; do
    check 2 "$tool" "${row%%|*}" "${row#*|}"
  done
done
check 2 Grep "/tmp/..$TMP/companies/beta/knowledge/canary.md" "dot-dot after a linked system folder"
check 2 Glob " $TMP/companies/beta/knowledge/canary.md" "leading space"
check 0 Read "$C/alpha/knowledge/./canary.md" "own company with a dot segment"
check 0 Read " $C/alpha/knowledge/canary.md" "own company with a leading space"
check 0 Write "$C/alpha/knowledge/$FWD$FWD/new.md" "own company with a fullwidth-dot folder"
# Glob: an absolute pattern's base folder is checked as the tool opens it.
glob_pattern() {
  local expected="$1" pattern="$2" label="$3" payload rc=0
  payload="$(jq -cn --arg g "$pattern" --arg p "$BASE/outside" --arg cwd "$TMP" \
    '{tool_name:"Glob",hook_event_name:"PreToolUse",session_id:"sess-bound",cwd:$cwd,tool_input:{path:$p,pattern:$g}}')"
  printf '%s' "$payload" | "${BASH_BIN:-bash}" "$TMP/.claude/hooks/mandatory-scope-authorizer.sh" >/dev/null 2>&1 || rc=$?
  if [ "$rc" = "$expected" ]; then
    PASSES=$((PASSES + 1))
  else
    echo "FAIL: Glob pattern $label (expected $expected, got $rc)" >&2
    FAILURES=$((FAILURES + 1))
  fi
}
glob_pattern 2 "/tmp/..$C/beta/knowledge/*.md" "dot-dot after a linked system folder"
glob_pattern 2 "$C/alpha/links/deepout/../../../beta/knowledge/*.md" "dot-dot after a link out of HQ"
glob_pattern 0 "$C/alpha/knowledge/*.md" "own company"
# A partial last segment is not part of the base folder: the tool searches
# from the last `/` before the first glob character.
glob_pattern 2 "$C/be*/knowledge/*.md" "partial tenant segment with *"
glob_pattern 2 "$C/bet?/knowledge/*.md" "partial tenant segment with ?"
glob_pattern 2 "$C/b{eta}/knowledge/*.md" "partial tenant segment with a brace"
glob_pattern 2 "$TMP/compan*/beta/knowledge/*.md" "partial companies segment"
glob_pattern 2 "$TMP/compan{ies}/beta/knowledge/*.md" "braced companies segment"
glob_pattern 2 "/tmp/..$C/be*/knowledge/*.md" "partial segment after dot-dot"
glob_pattern 0 "$C/alpha/knowledge/can*.md" "own company, partial file name"
CWD="/tmp/..$TMP"
check 2 Read "companies/beta/knowledge/canary.md" "relative path, cwd with dot-dot"
check 2 Grep "companies/beta/knowledge/canary.md" "relative search root, cwd with dot-dot"
CWD="$TMP"
# `~` and `~/` are the home folder: here the HQ root's parent.
HOME_SAVED="$HOME"
export HOME="$BASE"
for tool in "${TOOLS[@]}"; do
  check 2 "$tool" "~/hq-first-assist/companies/beta/knowledge/canary.md" "home-relative other company"
  check 0 "$tool" "~/hq-first-assist/companies/alpha/knowledge/canary.md" "home-relative own company"
done
check 2 Read "~/../${BASE##*/}/hq-first-assist/companies/beta/knowledge/canary.md" "home-relative with dot-dot"
check "$B" Read "~/hq-fir${ST}-assist/companies/beta/knowledge/canary.md" "home-relative folded root"
export HOME="$HOME_SAVED"

# Long text with many folded characters stays well inside the hook cap: the
# payload is folded once by jq, not character by character in bash.
for word in "Stra${SZ}e" "${FI}ne" $'\xef\xbc\xa1\xef\xbc\xa2'; do
  big="$(awk -v w="$word " 'BEGIN { for (i = 0; i < 8000; i++) printf "%s", w }')"
  payload="$(jq -cn --arg p "$C/alpha/knowledge/long.md" --arg c "$big" --arg cwd "$TMP" \
    '{tool_name:"Write",hook_event_name:"PreToolUse",session_id:"sess-bound",cwd:$cwd,tool_input:{file_path:$p,content:$c}}')"
  start=$SECONDS
  rc=0
  printf '%s' "$payload" | "${BASH_BIN:-bash}" "$TMP/.claude/hooks/mandatory-scope-authorizer.sh" >/dev/null 2>&1 || rc=$?
  took=$((SECONDS - start))
  if [ "$rc" = 0 ] && [ "$took" -le 8 ]; then
    PASSES=$((PASSES + 1))
  else
    echo "FAIL: long Write content with folded characters: rc=$rc in ${took}s (want 0 within 8s)" >&2
    FAILURES=$((FAILURES + 1))
  fi
done

# A helper file that is present but does not load refuses every call, in
# every bash: a syntax error, a truncated copy, an unreadable or empty file.
LIBF="$TMP/.claude/hooks/path-fold-lib.sh"
cp "$LIBF" "$BASE/path-fold-lib.good"
printf 'hq_path_fold() {\n' > "$LIBF"
check 2 Read "$TMP/companies/alpha/knowledge/canary.md" "helper with a syntax error"
check 2 Read "$TMP/companies/beta/knowledge/canary.md" "helper with a syntax error, other company"
head -c 4000 "$BASE/path-fold-lib.good" > "$LIBF"
check 2 Read "$TMP/companies/beta/knowledge/canary.md" "truncated helper"
: > "$LIBF"
check 2 Read "$TMP/companies/beta/knowledge/canary.md" "empty helper"
# A syntax error in the middle (a leftover merge conflict) with the last line
# kept: bash 3.2 aborts inside the source, and the exit must still refuse.
{ head -n 40 "$BASE/path-fold-lib.good"; printf '<<<<<<< ours\nif then\n=======\n>>>>>>> theirs\n'; tail -n +41 "$BASE/path-fold-lib.good"; } > "$LIBF"
check 2 Read "$TMP/companies/beta/knowledge/canary.md" "helper with a mid-file syntax error"
check 2 Read "$TMP/companies/alpha/knowledge/canary.md" "helper with a mid-file syntax error, own company"
cp "$BASE/path-fold-lib.good" "$LIBF"
if [ "$(id -u)" != 0 ]; then
  chmod 000 "$LIBF"
  check 2 Read "$TMP/companies/beta/knowledge/canary.md" "unreadable helper"
  check 2 Read "$TMP/companies/alpha/knowledge/canary.md" "unreadable helper, own company"
  chmod 644 "$LIBF"
fi

# Without the shared fold table, a payload that holds a non-ASCII or \u
# escaped character cannot be classified and is refused; plain ASCII still
# works.
mv "$TMP/.claude/hooks/path-fold-lib.sh" "$BASE/path-fold-lib.saved"
check 2 Read "${ROOTS[2]}/companies/alpha/knowledge/canary.md" "fold helper missing, non-ASCII payload"
check 0 Read "$TMP/companies/alpha/knowledge/canary.md" "fold helper missing, ASCII own company"
check 2 Read "$TMP/companies/beta/knowledge/canary.md" "fold helper missing, ASCII other company"
mv "$BASE/path-fold-lib.saved" "$TMP/.claude/hooks/path-fold-lib.sh"
unset LC_ALL

# An absolute path outside HQ that holds companies/ is checked as this HQ's
# companies/. The hook runs before the command, so a command that creates,
# moves or links the prefix first must not get through.
bash_cmd() {
  local expected="$1" command="$2" label="$3" payload rc=0
  payload="$(jq -cn --arg c "$command" --arg cwd "$TMP" \
    '{tool_name:"Bash",hook_event_name:"PreToolUse",session_id:"sess-bound",cwd:$cwd,tool_input:{command:$c}}')"
  printf '%s' "$payload" | "${BASH_BIN:-bash}" "$TMP/.claude/hooks/mandatory-scope-authorizer.sh" >/dev/null 2>&1 || rc=$?
  if [ "$rc" = "$expected" ]; then
    PASSES=$((PASSES + 1))
  else
    echo "FAIL: Bash $label (expected $expected, got $rc)" >&2
    FAILURES=$((FAILURES + 1))
  fi
}
L="$BASE/lnk"
OUT="$BASE/hq-first-assist-twin"
mkdir -p "$BASE/movable"
bash_cmd 2 "ln -s $TMP $L && cat $L/companies/beta/knowledge/canary.md" "absolute link to HQ made first"
bash_cmd 2 "ln -s $C $L && cat $L/beta/knowledge/canary.md" "absolute link to companies made first"
bash_cmd 2 "cat /nonexistent/zz/companies/beta/knowledge/canary.md" "missing prefix"
bash_cmd 2 "cat $BASE/nope/companies/beta/knowledge/canary.md" "missing prefix under a real dir"
bash_cmd 2 "cd $BASE && ln -s hq-first-assist lnk && cat $L/companies/beta/knowledge/canary.md" "relative link made first"
bash_cmd 2 "mv $BASE/movable $BASE/m2 && ln -s $TMP $BASE/movable; cat $BASE/movable/companies/beta/knowledge/canary.md" "existing dir moved then linked"
bash_cmd 2 "mv $TMP $OUT/x; cat $OUT/x/companies/beta/knowledge/canary.md" "HQ moved under an outside dir"
bash_cmd 2 "cd $L && cat $L/companies/beta/knowledge/canary.md" "cd into a link"
bash_cmd 2 "d=$BASE; cat \$d/lnk/companies/beta/knowledge/canary.md" "variable-built prefix"
bash_cmd 2 "cat \${HOME%/*}/hq-first-assist/companies/beta/knowledge/canary.md" "expansion-built prefix"
bash_cmd 2 "python3 -c 'import os; os.symlink(\"$TMP\", \"$L\")'; cat $L/companies/beta/knowledge/canary.md" "interpreter makes the link"
bash_cmd 2 "cat $OUT/companies/beta/knowledge/canary.md; ln -s $TMP/companies/beta $OUT/companies/beta2" "outside path with a link in the same command"
# Command words spelled with quotes, escapes, globs or a wrapper still run the
# reshaping command, so they keep the normal check too.
R="$BASE/movable"
for pre in "m''v|l''n" 'm""v|l""n' 'l"n"|l"n"' '\mv|\ln' 'm\v|l\n' '"mv"|"ln"' '/bin/m[v]|/bin/l[n]' '/bin/mv|/bin/ln' \
  'command mv|command ln' 'builtin command mv|builtin command ln' 'env mv|env ln' 'exec mv|exec ln' \
  'busybox mv|busybox ln' 'X=1 mv|X=1 ln' '{ mv|{ ln'; do
  m="${pre%%|*}"; l="${pre#*|}"
  bash_cmd 2 "$m $R $BASE/m2 && $l -s $TMP $R && cat $R/companies/beta/knowledge/canary.md" "reshape spelled as $pre"
done
bash_cmd 2 "echo $R | xargs -I{} ln -s $TMP {}; cat $R/companies/beta/knowledge/canary.md" "xargs makes the link"
bash_cmd 2 "find $BASE/m2 -maxdepth 0 -exec ln -s $TMP $R ';'; cat $R/companies/beta/knowledge/canary.md" "find -exec makes the link"
# No outside-HQ exemption for a path that holds companies/: the hook decides
# before the open, so another call can swap the outside folder for a link to
# HQ in between. Every such path keeps the normal companies/ check.
bash_cmd 2 "cat $OUT/companies/beta/knowledge/canary.md" "existing outside tree"
bash_cmd 2 "cat '$OUT/companies/beta/knowledge/canary.md' | head -n 1" "existing outside tree, quoted, piped"
bash_cmd 2 "grep -n twin $OUT/companies/beta/knowledge/canary.md" "grep in existing outside tree"
bash_cmd 2 "ls $OUT/companies/beta/knowledge" "ls in existing outside tree"
# Cross-call race: a background job from an earlier call swaps a real outside
# folder and a link to HQ. Each state, and reads during the swap, must block.
RACE="$BASE/race"
mkdir -p "$RACE/real/companies/beta/knowledge"
printf 'outside\n' > "$RACE/real/companies/beta/knowledge/canary.md"
bash_cmd 2 "cat $RACE/real/companies/beta/knowledge/canary.md" "race target while a real dir"
mv "$RACE/real" "$RACE/r2"; ln -s "$TMP" "$RACE/real"
bash_cmd 2 "cat $RACE/real/companies/beta/knowledge/canary.md" "race target while a link to HQ"
rm "$RACE/real"; mv "$RACE/r2" "$RACE/real"
( k=0; while [ "$k" -lt 400 ]; do
    mv "$RACE/real" "$RACE/r2" 2>/dev/null; ln -s "$TMP" "$RACE/real" 2>/dev/null; sleep 0.005
    rm -f "$RACE/real"; mv "$RACE/r2" "$RACE/real" 2>/dev/null; sleep 0.005; k=$((k + 1))
  done ) &
SWAP_PID=$!
n=0
while [ "$n" -lt 12 ]; do
  bash_cmd 2 "cat $RACE/real/companies/beta/knowledge/canary.md" "race read during the swap ($n)"
  n=$((n + 1))
done
kill "$SWAP_PID" 2>/dev/null; wait "$SWAP_PID" 2>/dev/null || true
# Editors and expect can rename and link from inside an argument.
V="$BASE/vreal"
mkdir -p "$V/companies/beta/knowledge"
bash_cmd 2 "vim -es \"+!mv $V $BASE/v2\" \"+!ln -s $TMP $V\" +q ; cat $V/companies/beta/knowledge/canary.md" "vim moves and links first"
bash_cmd 2 "ex -s \"+!mv $V $BASE/v2\" \"+!ln -s $TMP $V\" +q ; cat $V/companies/beta/knowledge/canary.md" "ex moves and links first"
bash_cmd 2 "expect -c \"file rename $V $BASE/v2\" ; cat $V/companies/beta/knowledge/canary.md" "expect renames first"
bash_cmd 0 "cat $TMP/companies/alpha/knowledge/canary.md" "own company"

# File tools: a relative companies/ path is checked as HQ-relative even when
# the session cwd is a real folder outside HQ, since that folder can be
# swapped for a link into HQ before the tool opens the path.
FCWD="$BASE/fcwd"
mkdir -p "$FCWD/companies/beta/knowledge" "$FCWD/companies/alpha/knowledge"
printf 'outside\n' > "$FCWD/companies/beta/knowledge/canary.md"
SAVED_CWD="$CWD"
CWD="$FCWD"
for tool in Read Edit Write Grep Glob; do
  check 2 "$tool" "companies/beta/knowledge/canary.md" "relative other company from an outside cwd"
done
CWD="$TMP"
# Glob with no path and a relative companies/ pattern, from the outside cwd.
glob_rel() {
  local expected="$1" cwd="$2" pattern="$3" label="$4" payload rc=0 err
  payload="$(jq -cn --arg g "$pattern" --arg cwd "$cwd" \
    '{tool_name:"Glob",hook_event_name:"PreToolUse",session_id:"sess-bound",cwd:$cwd,tool_input:{pattern:$g}}')"
  err="$(printf '%s' "$payload" | "${BASH_BIN:-bash}" "$TMP/.claude/hooks/mandatory-scope-authorizer.sh" 2>&1 >/dev/null)" || rc=$?
  if [ "$rc" = "$expected" ]; then
    PASSES=$((PASSES + 1))
  else
    echo "FAIL: Glob relative pattern $label (expected $expected, got $rc) $(printf '%s' "$err" | grep -m1 '^Path:')" >&2
    FAILURES=$((FAILURES + 1))
  fi
}
glob_rel 2 "$FCWD" "companies/beta/knowledge/*.md" "other company from an outside cwd"
glob_rel 2 "$TMP" "companies/beta/knowledge/*.md" "other company from the HQ root"
CWD="$TMP"
check 0 Glob "companies/alpha/knowledge/canary.md" "relative own company path from the HQ root"
check 0 Grep "companies/alpha/knowledge/canary.md" "relative own company path from the HQ root"
check 0 Read "companies/alpha/knowledge/canary.md" "relative own company from the HQ root"
check 2 Read "companies/beta/knowledge/canary.md" "relative other company from the HQ root"
# The same reads while a background job swaps the outside cwd and a link to
# HQ: none of 60 tries may be allowed.
( k=0; while [ "$k" -lt 3000 ]; do
    mv "$FCWD" "$BASE/fcwd2" 2>/dev/null; ln -s "$TMP" "$FCWD" 2>/dev/null; sleep 0.005
    rm -f "$FCWD"; mv "$BASE/fcwd2" "$FCWD" 2>/dev/null; sleep 0.005; k=$((k + 1))
  done ) &
SWAP_PID=$!
CWD="$FCWD"
RACE_BEFORE="$FAILURES"
n=0
while [ "$n" -lt 60 ]; do
  case $((n % 5)) in
    0) tool=Read ;; 1) tool=Edit ;; 2) tool=Write ;; 3) tool=Grep ;; *) tool=Glob ;;
  esac
  check 2 "$tool" "companies/beta/knowledge/canary.md" "relative read during the cwd swap ($n)"
  n=$((n + 1))
done
kill "$SWAP_PID" 2>/dev/null; wait "$SWAP_PID" 2>/dev/null || true
[ -L "$FCWD" ] && rm -f "$FCWD"
[ -d "$BASE/fcwd2" ] && [ ! -e "$FCWD" ] && mv "$BASE/fcwd2" "$FCWD"
echo "cwd swap race: $((FAILURES - RACE_BEFORE)) of 60 allowed"
CWD="$SAVED_CWD"

echo "passed: $PASSES"
if [ "$FAILURES" -gt 0 ]; then
  echo "$FAILURES root fs-identity scope check(s) failed" >&2
  exit 1
fi
echo "all root fs-identity scope checks passed"
