#!/usr/bin/env bash
# hq-core: public
# Regression: under the stock macOS /bin/bash (3.2) the mandatory scope
# authorizer must check long tool payloads well inside the host's 25 s hook
# cap (feedback f5437b14 and 346a71a9).
#
# Before the fix, three spots ran bash 3.2's global substitution
# ${text//pattern/}, whose cost grows close to length x length:
#   - the case fold ran ${text//"$HQ_ROOT"/} and ${text//companies/} over the
#     whole hook payload before any check, so a 40 KB heredoc or a long Edit
#     new_string full of company paths took about 25 s;
#   - the single-quote test ran ${prefix//[!\'\"]/} over the whole command
#     before each candidate path, so a 5.5 KB python heredoc took about 25 s;
#   - the tar option check stripped quotes from the whole command once per
#     simple command.
#
# Asserted here:
#   1. a 40 KB data heredoc, a 5.5 KB python heredoc and a 60 KB Edit, all
#      full of the bound company's paths, are allowed inside a budget well
#      under 25 s, with the hook run by /bin/bash (BASH_BIN overrides);
#   2. the same payloads aimed at another company are still denied with the
#      cross-company message, and a case-variant spelling of the other
#      company is still denied where the volume folds case;
#   3. the rewritten helpers give the same results as the code they replace
#      (decision equivalence), checked function by function.
# Commands are fed to the hook as JSON input and never executed.
# The hook helpers are eval'd below and read the SCOPE_* globals set here;
# the single-quoted $BASH_VERSION is for the child shell.
# shellcheck disable=SC2016,SC2034
set -euo pipefail

TEST_DIR=$(cd "$(dirname "$0")" && pwd)
DEFAULT_ROOT=$(git -C "$TEST_DIR/../../.." rev-parse --show-toplevel)
ROOT=${HOOK_ROOT_OVERRIDE:-$DEFAULT_ROOT}
HOOK_SRC=$ROOT/.claude/hooks/mandatory-scope-authorizer.sh
HOOK_BASH=${BASH_BIN:-/bin/bash}
[ -x "$HOOK_BASH" ] || HOOK_BASH=bash
# The Claude desktop app runs hooks in the C locale; pin it so timings do not
# depend on the runner's locale.
export LC_ALL=C

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
TMP=$(cd "$TMP" && pwd -P)
FIXTURE=$TMP/hq-root
mkdir -p "$FIXTURE/.claude/hooks" "$FIXTURE/core/scripts/lib" "$FIXTURE/companies/indigo/settings" \
  "$FIXTURE/companies/otherco/settings" "$FIXTURE/companies/_template" "$FIXTURE/personal" \
  "$FIXTURE/workspace/sessions/sess-bound"
for path in .claude/hooks/bash-arith-subst-guard-lib.sh .claude/hooks/mandatory-scope-authorizer.sh \
  core/scripts/lib/session-authz.sh core/scripts/lib/session-scope-capability.sh \
  core/scripts/lib/session-id.sh core/scripts/hook-lib.sh core/scripts/lib/hook-caller-lineage.sh \
  core/scripts/hqd-hook-flag-cache-lib.sh; do
  if [ -f "$ROOT/$path" ]; then
    mkdir -p "$FIXTURE/$(dirname "$path")"
    cp "$ROOT/$path" "$FIXTURE/$path"
  fi
done
printf 'companies:\n  indigo:\n  otherco:\n' > "$FIXTURE/companies/manifest.yaml"
touch "$FIXTURE/companies/indigo/settings/x" "$FIXTURE/companies/otherco/settings/x" \
  "$FIXTURE/companies/indigo/README.md" "$FIXTURE/companies/otherco/README.md"
printf '{"session_id":"sess-bound","company_slug":"indigo"}\n' \
  > "$FIXTURE/workspace/sessions/sess-bound/scope-capability.json"

FOLDS=0
[ "$FIXTURE/COMPANIES" -ef "$FIXTURE/companies" ] && FOLDS=1
echo "hook bash: $HOOK_BASH ($("$HOOK_BASH" -c 'echo "$BASH_VERSION"')); case-insensitive volume: $FOLDS"

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf 'PASS %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1" >&2; }

# run_hook <label> <tool> <tool_input JSON>; sets RC, ELAPSED, ERR_FILE.
run_hook() {
  local label=$1 tool=$2 tool_input=$3 start
  ERR_FILE=$TMP/$label.err
  jq -cn --arg t "$tool" --arg cwd "$FIXTURE" --argjson ti "$tool_input" \
    '{tool_name:$t,session_id:"sess-bound",cwd:$cwd,tool_input:$ti}' > "$TMP/$label.json"
  RC=0
  start=$SECONDS
  env LC_ALL="${HOOK_LC:-C}" HQ_HOOK_TOOL_NAME="$tool" HQ_HOOK_SESSION_ID=sess-bound \
    HQ_HOOK_CWD="$FIXTURE" HQ_HOOK_AGENT_ID="" HQ_HOOK_AGENT_TYPE="" \
    CLAUDE_PROJECT_DIR="$FIXTURE" \
    "$HOOK_BASH" "$FIXTURE/.claude/hooks/mandatory-scope-authorizer.sh" \
    < "$TMP/$label.json" > "$TMP/$label.out" 2> "$ERR_FILE" || RC=$?
  ELAPSED=$((SECONDS - start))
}
bash_input() { jq -cn --arg c "$1" '{command:$c,description:"long payload"}'; }

# expect_allowed <label> <budget seconds>; expect_denied <label> <budget>.
expect_allowed() {
  if [ "$RC" = 0 ] && [ "$ELAPSED" -le "$2" ]; then
    ok "$1 allowed in ${ELAPSED}s (budget $2s)"
  else
    bad "$1 rc=$RC elapsed=${ELAPSED}s (want 0 within $2s): $(head -c 300 "$ERR_FILE")"
  fi
}
expect_denied() {
  if [ "$RC" = 2 ] && grep -q 'Cross-company scope violation' "$ERR_FILE" && [ "$ELAPSED" -le "$2" ]; then
    ok "$1 denied as cross-company in ${ELAPSED}s"
  else
    bad "$1 rc=$RC elapsed=${ELAPSED}s (want a cross-company deny within $2s): $(head -c 300 "$ERR_FILE")"
  fi
}

BUDGET=15

# Path-dense data: every line names the bound company twice, once relative
# and once under the absolute HQ root.
dense_lines() {
  local min_bytes=$1 out="" i=0
  while [ "${#out}" -lt "$min_bytes" ]; do
    out+="- item $i: see $FIXTURE/companies/indigo/notes/item-$i.md and companies/indigo/notes/item-$i.md"$'\n'
    i=$((i + 1))
  done
  printf '%s' "$out"
}
DENSE_40K=$(dense_lines 40000)

# 1. 40 KB data heredoc into the bound company (f5437b14, large heredocs).
heredoc_cmd() { printf "cat > %s <<'EOF'\n%s\nEOF" "$1" "$DENSE_40K"; }
run_hook heredoc-40k Bash "$(bash_input "$(heredoc_cmd companies/indigo/notes/long.md)")"
expect_allowed "40 KB data heredoc of company paths" "$BUDGET"
run_hook heredoc-40k-deny Bash "$(bash_input "$(heredoc_cmd companies/otherco/notes/long.md)")"
expect_denied "40 KB data heredoc into another company" "$BUDGET"
# A case variant of the other company after the long heredoc.
run_hook heredoc-40k-case Bash "$(bash_input "$(heredoc_cmd companies/indigo/notes/long.md)"$'\n'"cat Companies/OtherCo/settings/x")"
if [ "$FOLDS" -eq 1 ]; then
  expect_denied "40 KB heredoc then a case-variant read of another company" "$BUDGET"
else
  expect_allowed "40 KB heredoc then a missing case-variant folder (case-sensitive volume)" "$BUDGET"
fi

# 1b. The same 54 KB data heredoc under a UTF-8 locale (a terminal session
# with LANG=en_US.UTF-8 and no Homebrew bash). bash 3.2 decodes the whole
# string again for every expansion in the case fold there, so this took 31 s
# and was blocked; the fold now runs in the C locale and skips the walk when
# grep proves it would change nothing. Under bash 3.2 in UTF-8, [a-z] also
# took in uppercase letters, so `Companies/Indigo` was not folded.
UTF8_LOCALE=$(locale -a 2>/dev/null | grep -i -m1 -E '^(en_US|C)\.utf-?8$' || true)
DENSE_54K=$(dense_lines 54000)
heredoc54_cmd() { printf "cat > %s <<'EOF'\n%s\nEOF%s" "$1" "$DENSE_54K" "${2:-}"; }
for loc in C ${UTF8_LOCALE:+"$UTF8_LOCALE"}; do
  HOOK_LC=$loc
  run_hook "heredoc-54k-$loc" Bash "$(bash_input "$(heredoc54_cmd companies/indigo/notes/long.md)")"
  expect_allowed "54 KB data heredoc of company paths ($loc)" 8
  run_hook "heredoc-54k-deny-$loc" Bash "$(bash_input "$(heredoc54_cmd companies/otherco/notes/long.md)")"
  expect_denied "54 KB data heredoc into another company ($loc)" 8
  if [ "$FOLDS" -eq 1 ]; then
    run_hook "heredoc-54k-case-$loc" Bash "$(bash_input "$(heredoc54_cmd companies/indigo/notes/long.md $'\n'"cat Companies/OtherCo/settings/x")")"
    expect_denied "54 KB heredoc then a case-variant read of another company ($loc)" "$BUDGET"
    run_hook "case-short-$loc" Bash "$(bash_input "cat Companies/OtherCo/settings/x")"
    expect_denied "case-variant read of another company ($loc)" 8
    # Under bash 3.2 in UTF-8 this was refused: the fold built [I] for I and
    # left the bound company's own case-variant path unfolded.
    run_hook "case-own-$loc" Bash "$(bash_input "cat Companies/Indigo/settings/x")"
    expect_allowed "case-variant read of the bound company ($loc)" 8
  fi
done
HOOK_LC=C
[ -n "$UTF8_LOCALE" ] || echo "no UTF-8 locale on this runner: UTF-8 hook runs skipped"

# 2. 5.5 KB python heredoc with many quoted strings and company paths
# (f5437b14, the common reported shape). Kept under the 6000-character
# interpreter-heredoc size gate.
python_body() {
  local out="import json, os"$'\n'"rows = []"$'\n' i=0
  while [ "${#out}" -lt 5400 ]; do
    out+="rows.append(json.load(open('companies/indigo/data/file-$i.json', 'r')))  # \"row $i\""$'\n'
    i=$((i + 1))
  done
  printf '%s' "$out"
}
PY_BODY=$(python_body)
python_cmd() { printf "python3 - <<'PY'\n%s%s\nprint(len(rows))\nPY" "$PY_BODY" "${1:-}"; }
PY_CMD=$(python_cmd)
echo "python heredoc: ${#PY_CMD} characters"
run_hook python-5k Bash "$(bash_input "$PY_CMD")"
expect_allowed "5.5 KB python heredoc of company paths" "$BUDGET"
run_hook python-5k-deny Bash "$(bash_input "$(python_cmd "x = open(\"companies/otherco/settings/x\").read()"$'\n')")"
expect_denied "5.5 KB python heredoc that opens another company" "$BUDGET"

# 3. Edit of a company README whose new_string is 60 KB of company paths
# (346a71a9: every Edit on a company README timed out).
DENSE_60K=$(dense_lines 60000)
edit_input() {
  jq -cn --arg f "$1" --arg n "$DENSE_60K" '{file_path:$f,old_string:"old",new_string:$n}'
}
run_hook edit-60k Edit "$(edit_input "$FIXTURE/companies/indigo/README.md")"
expect_allowed "Edit with a 60 KB new_string on the bound company README" 10
run_hook edit-60k-deny Edit "$(edit_input "$FIXTURE/companies/otherco/README.md")"
expect_denied "Edit with a 60 KB new_string on another company README" 10
if [ "$FOLDS" -eq 1 ]; then
  run_hook edit-60k-case Edit "$(edit_input "$FIXTURE/Companies/OTHERCO/README.md")"
  expect_denied "Edit of a case-variant path to another company" 10
fi

# 4. The cached quote-free text in the tar check still sees the whole command.
run_hook tar-env Bash "$(bash_input "tar cf /tmp/z.tar /tmp/a; echo TAR_OPT\"\"IONS=--to-command=sh")"
if [ "$RC" = 2 ] && grep -q 'TAR_OPTIONS' "$ERR_FILE"; then ok "quote-split tar options variable still refused"; else bad "tar-env rc=$RC: $(head -c 200 "$ERR_FILE")"; fi

# 5. Decision equivalence of the rewritten helpers, in this shell (run the
# whole test under /bin/bash on macOS to cover bash 3.2).
missing_helper=0
for fn in scope_case_folds scope_case_pattern scope_case_replace_all scope_case_company_entry \
  scope_literal_replace_all scope_c_locale_enter scope_c_locale_leave scope_case_fold_is_noop \
  scope_case_fold_text_bytes scope_case_fold_text scope_candidate_is_single_quoted; do
  # Assign first: bash 3.2 brace-expands {/,/^} in "$(sed ... "/^$fn() {/,/^}/p")"
  # inside eval's argument, so sed got two broken scripts and nothing was
  # defined. An assignment is not brace-expanded.
  fn_src=$(sed -n "/^$fn() {/,/^}/p" "$HOOK_SRC")
  eval "$fn_src"
  # Every helper must exist before section 5 runs, or the equivalence checks
  # below would never execute (they exited 127 under bash 3.2).
  if declare -F "$fn" >/dev/null; then
    ok "helper $fn extracted from the hook"
  else
    bad "helper $fn not defined after extraction (bash $BASH_VERSION)"
    missing_helper=1
  fi
done
if [ "$missing_helper" -ne 0 ]; then
  printf 'mandatory-scope-authorizer-bash32-payload: hook helpers missing, %s passed, %s failed\n' "$PASS" "$FAIL" >&2
  exit 1
fi
eval "$(grep -m1 '^SCOPE_CASE_COMPANIES_PAT=' "$HOOK_SRC")"

# 5a. scope_literal_replace_all matches ${text//"$lit"/"$rep"}.
check_lit() {
  local text=$1 lit=$2 rep=$3
  scope_literal_replace_all "$text" "$lit" "$rep"
  if [ "$SCOPE_LIT_OUT" = "${text//"$lit"/$rep}" ]; then ok "literal replace: [$text] [$lit] -> [$rep]"; else bad "literal replace: [$text] [$lit] gave [$SCOPE_LIT_OUT]"; fi
}
check_lit "" companies ""
check_lit "companies" companies ""
check_lit "a companies b companies" companies ""
check_lit "aaaa" aa ""
check_lit "aaaaa" aa b
check_lit "x[*?]y[*?]" "[*?]" "-"
check_lit "/r/hq/r/hq/r" "/r/hq" ""
check_lit "abc" abc abcabc
LS=$'\xc5\xbf'
KS=$'\xe2\x84\xaa'
DENSE_4K=$(dense_lines 4000)
check_lit "companie$LS/x companie$LS" "$LS" s
check_lit "$DENSE_4K" "$FIXTURE" ""
check_lit "$DENSE_4K" companies ""

# 5b. scope_case_fold_text gives the same text as the code it replaces.
old_case_fold_text() {
  local text="${1:-}" stripped out="" pre seg
  OLD_FOLD_OUT="$text"
  scope_case_folds || return 0
  text="${text//$'\xc5\xbf'/s}"
  text="${text//$'\xe2\x84\xaa'/k}"
  if [ -z "${SCOPE_CASE_ROOT_PAT:-}" ]; then
    scope_case_pattern "$HQ_ROOT"
    SCOPE_CASE_ROOT_PAT="$SCOPE_CASE_PAT"
  fi
  stripped="${text//"$HQ_ROOT"/}"
  if [[ "$stripped" == *$SCOPE_CASE_ROOT_PAT* ]]; then
    scope_case_replace_all "$text" "$HQ_ROOT" "$SCOPE_CASE_ROOT_PAT"
    text="$SCOPE_CASE_OUT"
  fi
  stripped="${text//companies/}"
  if [[ "$stripped" == *$SCOPE_CASE_COMPANIES_PAT* ]]; then
    scope_case_replace_all "$text" companies "$SCOPE_CASE_COMPANIES_PAT"
    text="$SCOPE_CASE_OUT"
  fi
  while [[ "$text" == *companies/* ]]; do
    pre="${text%%companies/*}"
    out="${out}${pre}companies/"
    text="${text:$((${#pre} + 10))}"
    seg="${text%%[!A-Za-z0-9._-]*}"
    [ -n "$seg" ] || continue
    scope_case_company_entry "$seg"
    out="$out$SCOPE_CASE_ENTRY"
    text="${text:${#seg}}"
  done
  OLD_FOLD_OUT="$out$text"
}
HQ_ROOT=$FIXTURE
SCOPE_CASE_FOLDS=1
unset SCOPE_CASE_ROOT_PAT
ROOT_UP=$(printf '%s' "$FIXTURE" | tr '[:lower:]' '[:upper:]')
check_fold() {
  local label=$1 text=$2
  old_case_fold_text "$text"
  scope_case_fold_text "$text"
  if [ "$SCOPE_CASE_TEXT" = "$OLD_FOLD_OUT" ]; then ok "fold equivalence: $label"; else bad "fold equivalence: $label"; fi
}
check_fold "empty" ""
check_fold "no company text" "echo hello world"
check_fold "canonical paths" "$DENSE_4K"
check_fold "case variants" "cat Companies/OtherCo/settings/x COMPANIES/indigo/y $ROOT_UP/companies/otherco/z"
check_fold "variants after canonical" "$DENSE_4K cat Companies/OtherCo/settings/x"
check_fold "root in another case among canonical" "$DENSE_4K $ROOT_UP/companies/otherco/z"
check_fold "long s and kelvin" "cat companie$LS/otherco/x companies/${KS}iwi/x COMPANIE$LS/indigo"
check_fold "json payload" "$(head -c 6000 "$TMP/heredoc-40k-case.json")"
# Text of 4 KB or more first goes through scope_case_fold_is_noop. Each case
# puts one spelling the fold must rewrite after 8 KB of canonical paths, so a
# wrong "no-op" answer shows up as a mismatch.
DENSE_8K=$(dense_lines 8000)
check_fold "long: canonical only" "$DENSE_8K"
check_fold "long: slug in another case" "$DENSE_8K cat companies/OTHERCO/x"
check_fold "long: Companies in another case" "$DENSE_8K cat COMPANIES/indigo/x"
check_fold "long: both in another case" "$DENSE_8K cat Companies/OtherCo/settings/x"
check_fold "long: root in another case" "$DENSE_8K $ROOT_UP/companies/otherco/z"
check_fold "long: long s" "$DENSE_8K cat companie$LS/otherco/x"
check_fold "long: kelvin sign" "$DENSE_8K cat companies/${KS}x"
check_fold "long: missing slug" "$DENSE_8K cat companies/nosuchco/x companies/"
check_fold "long: multibyte text" "$DENSE_8K café ü 日本 companies/indigoé/x Companies/OtherCoé/x"

# 5b2. Under a UTF-8 locale the fold gives the C-locale result and puts the
# caller's locale back. bash 3.2 reads [a-z] by collation there (it takes
# in A-Y), so before the fold switched to the C locale it built `[O]` for
# `O` and left `Companies/OtherCo` unfolded.
if [ -n "$UTF8_LOCALE" ]; then
  for case_text in "cat Companies/OtherCo/settings/x" "$ROOT_UP/companies/otherco/z" \
    "$DENSE_8K cat Companies/OtherCo/settings/x" "$DENSE_8K" "café companies/indigoé/x Companies/OtherCoé/x"; do
    old_case_fold_text "$case_text"
    LC_ALL=$UTF8_LOCALE
    scope_case_fold_text "$case_text"
    utf8_after=${LC_ALL-unset}
    LC_ALL=C
    if [ "$SCOPE_CASE_TEXT" = "$OLD_FOLD_OUT" ] && [ "$utf8_after" = "$UTF8_LOCALE" ]; then
      ok "fold under $UTF8_LOCALE matches the C locale: ${case_text: -40}"
    else
      bad "fold under $UTF8_LOCALE (locale after: $utf8_after): ${case_text: -40}"
    fi
  done
fi
# The fold restores an unset LC_ALL as unset.
if (
  unset LC_ALL
  scope_case_fold_text "cat Companies/OtherCo/x"
  [ "${LC_ALL+set}" != set ]
); then
  ok "fold leaves an unset LC_ALL unset"
else
  bad "fold set LC_ALL for its caller"
fi

# 5c. scope_case_fold_text on the 40 KB payload stays fast with folding forced
# on (covers case-sensitive CI volumes, where the hook skips the fold).
start=$SECONDS
scope_case_fold_text "$(cat "$TMP/heredoc-40k.json")"
fold_elapsed=$((SECONDS - start))
if [ "$fold_elapsed" -le 8 ]; then ok "fold of the 40 KB payload in ${fold_elapsed}s"; else bad "fold of the 40 KB payload took ${fold_elapsed}s"; fi
# The 54 KB heredoc, in each locale: the no-op proof makes this a few greps.
for loc in C ${UTF8_LOCALE:+"$UTF8_LOCALE"}; do
  fold_text=$(heredoc54_cmd companies/indigo/notes/long.md)
  LC_ALL=$loc
  start=$SECONDS
  scope_case_fold_text "$fold_text"
  fold_elapsed=$((SECONDS - start))
  LC_ALL=C
  if [ "$fold_elapsed" -le 2 ] && [ "$SCOPE_CASE_TEXT" = "$fold_text" ]; then
    ok "fold of the 54 KB heredoc ($loc) in ${fold_elapsed}s, unchanged"
  else
    bad "fold of the 54 KB heredoc ($loc) took ${fold_elapsed}s (unchanged: $([ "$SCOPE_CASE_TEXT" = "$fold_text" ] && echo yes || echo no))"
  fi
done

# 5d. scope_candidate_is_single_quoted (with its prefix cache) answers as the
# uncached walk does, for prefixes in order, out of order, and long ones.
ref_single_quoted() {
  local candidate="${1:-}" prefix="${2:-}" state=0 quotes ch i
  [ -n "$candidate" ] || return 1
  quotes="${prefix//[!\'\"]/}"
  for ((i = 0; i < ${#quotes}; i++)); do
    ch="${quotes:i:1}"
    if [ "$state" -eq 1 ]; then
      [ "$ch" = "'" ] && state=0
    elif [ "$state" -eq 2 ]; then
      [ "$ch" = '"' ] && state=0
    elif [ "$ch" = "'" ]; then
      state=1
    else
      state=2
    fi
  done
  [ "$state" -eq 1 ]
}
SQ_TEXT="python3 -c 'import os'; echo \"it's\" 'a\"b' ${PY_BODY:0:1800}"
SQ_OFFSETS=()
rest=$SQ_TEXT
off=0
while [[ "$rest" == *companies/* ]]; do
  pre=${rest%%companies/*}
  off=$((off + ${#pre}))
  SQ_OFFSETS+=("$off")
  rest=${rest:$((${#pre} + 10))}
  off=$((off + 10))
done
SQ_MISMATCH=0
check_sq_at() {
  local offset=$1 want=0 got=0
  ref_single_quoted companies/x "${SQ_TEXT:0:$offset}" || want=$?
  scope_candidate_is_single_quoted companies/x "${SQ_TEXT:0:$offset}" || got=$?
  [ "$want" = "$got" ] || SQ_MISMATCH=$((SQ_MISMATCH + 1))
}
SCOPE_SQ_BASE=""
SCOPE_SQ_BASE_STATE=0
for offset in "${SQ_OFFSETS[@]}"; do check_sq_at "$offset"; done
for ((k = ${#SQ_OFFSETS[@]} - 1; k >= 0; k--)); do check_sq_at "${SQ_OFFSETS[$k]}"; done
for offset in 0 1 2 12 "${#SQ_TEXT}" 5 1500 7; do check_sq_at "$offset"; done
# A prefix that is not an extension of the cached one must not reuse its state.
SCOPE_SQ_BASE="echo '"
SCOPE_SQ_BASE_STATE=1
want=0; got=0
ref_single_quoted x "echo \"" || want=$?
scope_candidate_is_single_quoted x "echo \"" || got=$?
[ "$want" = "$got" ] || SQ_MISMATCH=$((SQ_MISMATCH + 1))
if [ "${#SQ_OFFSETS[@]}" -gt 12 ] && [ "$SQ_MISMATCH" -eq 0 ]; then
  ok "single-quoted state matches the uncached walk at ${#SQ_OFFSETS[@]} candidate offsets"
else
  bad "single-quoted state: $SQ_MISMATCH mismatches over ${#SQ_OFFSETS[@]} offsets"
fi

if (( FAIL > 0 )); then
  printf 'mandatory-scope-authorizer-bash32-payload: %s passed, %s failed\n' "$PASS" "$FAIL" >&2
  exit 1
fi
printf 'mandatory-scope-authorizer-bash32-payload: %s passed, %s failed\n' "$PASS" "$FAIL"
