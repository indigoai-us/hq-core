#!/usr/bin/env bash
# On Windows (Git Bash, MSYS, Cygwin) mapfile and read take a here-string one
# byte per read() call, so collapsing a large CRLF command through them is
# slow there. hq_crlf_to_lf (core/scripts/hook-lib.sh) and
# master_command_crlf_to_lf (.claude/hooks/master-hook.sh) must not read the
# command through mapfile, readarray or read when OSTYPE is msys or cygwin,
# and must still give exactly ${s//$'\r\n'/$'\n'}.
#
# OSTYPE is set by hand so the Windows branch also runs on macOS and Linux.
# Each reading builtin is shadowed by a function that counts its calls.
#
# Explicitly wired into .github/workflows/pr-checks.yml.
set -uo pipefail
TEST_DIR="$(cd "${BASH_SOURCE[0]%/*}" && pwd)"
ROOT="$(cd "$TEST_DIR/../../.." && pwd)"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); printf 'PASS %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1" >&2; }

# master_command_crlf_to_lf lives inside master-hook.sh, which runs its hook
# chain when sourced. Copy just the function definition out.
awk '/^master_command_crlf_to_lf\(\) \{/ { on = 1 } on { print } on && /^}/ { exit }' \
  "$ROOT/.claude/hooks/master-hook.sh" > "$TMP/master-crlf.sh"
if grep -q '^master_command_crlf_to_lf() {' "$TMP/master-crlf.sh"; then
  pass "found master_command_crlf_to_lf in master-hook.sh"
else
  fail "master_command_crlf_to_lf not found in master-hook.sh"
fi

cat > "$TMP/no-byte-reads.sh" <<'CASE'
set -u
. "$1"
. "$2"
OSTYPE="$3"
byte_reads=0
mapfile() { byte_reads=$((byte_reads + 1)); builtin mapfile "$@"; }
readarray() { byte_reads=$((byte_reads + 1)); builtin readarray "$@"; }
read() { byte_reads=$((byte_reads + 1)); builtin read "$@"; }
fails=0
# check <value> [<expected>]: both helpers must match the reference and read
# no bytes. Large inputs pass the expected value: the reference substitution
# is quadratic on bash 3.2.
check() {
  local v="$1" want="${2-${1//$'\r\n'/$'\n'}}" before="$byte_reads"
  hq_crlf_to_lf v
  TOOL_COMMAND="$1"
  master_command_crlf_to_lf
  if [[ "$v" != "$want" || "$TOOL_COMMAND" != "$want" ]]; then
    fails=$((fails + 1))
    if ((${#1} < 200)); then
      printf 'mismatch in=%q helper=%q master=%q want=%q\n' "$1" "$v" "$TOOL_COMMAND" "$want" >&2
    else
      printf 'mismatch on a %d-byte input\n' "${#1}" >&2
    fi
  fi
  if ((byte_reads != before)); then
    fails=$((fails + 1))
    printf 'mapfile/readarray/read called %d time(s) for a %d-byte input\n' \
      "$((byte_reads - before))" "${#1}" >&2
  fi
}
for s in '' a $'\r' $'\n' $'\r\n' $'\r\r\n' $'\r\n\r\n' $'a\r' $'a\r\n' $'\ra' \
  $'\r\nb' $'a\rb\r\nc' $'a\r\r\r\nb\r' $'x\n\r\n\r\r' $'\\\r\n\\' $'a\r\n\n' \
  $'a\r\nx\r' $'x\r\nx' $'\n\n\r\n' $'  lead\r\n  trail  ' $'a\tb\r\nc\td' $'*\r\n?\r\n[a]'; do
  check "$s"
done
alpha=($'\r' $'\n' a x ' ' '\' $'\t' '*')
RANDOM=1422
for ((i = 0; i < 1000; i++)); do
  s=""
  for ((j = RANDOM % 12; j > 0; j--)); do s+="${alpha[RANDOM % 8]}"; done
  check "$s"
done
# Git Bash is bash 5, where the substitution over 64 KB takes about 0.06 s.
# Bash 3.2 never runs on Windows and is quadratic there, so keep its inline
# case small.
inline_lines=4000
((BASH_VERSINFO[0] < 4)) && inline_lines=400
printf -v inline 'echo %07d\r\n' $(seq 1 "$inline_lines")
printf -v large 'echo %07d\r\n' $(seq 1 60000)
printf -v large_lf 'echo %07d\n' $(seq 1 60000)
TIMEFORMAT=%R
for tail in '' $'\r' $'\r\n' 'z'; do
  tail_lf="$tail"
  [[ "$tail" == $'\r\n' ]] && tail_lf=$'\n'
  check "$inline$tail"
  { time check "$large$tail" "$large_lf$tail_lf"; } 2>> "$4"
done
{ time check "$inline"; } 2> "$5"
printf '%s %s %s %s %s\n' "$fails" "${BASH_VERSINFO[0]}" "${#inline}" "${#large}" "$(<"$5")"
CASE

BASHES=(bash)
if [[ -x /bin/bash && "$(/bin/bash -c 'echo "${BASH_VERSINFO[0]}"')" != "$(bash -c 'echo "${BASH_VERSINFO[0]}"')" ]]; then
  BASHES+=(/bin/bash)
fi
for b in "${BASHES[@]}"; do
  for os in msys cygwin; do
    : > "$TMP/large.time"
    read -r fails major inline_bytes large_bytes inline_secs < <(
      "$b" "$TMP/no-byte-reads.sh" "$ROOT/core/scripts/hook-lib.sh" "$TMP/master-crlf.sh" \
        "$os" "$TMP/large.time" "$TMP/inline.time"
    )
    large_secs="$(sort -n "$TMP/large.time" | tail -1)"
    if [[ "${fails:-x}" == 0 ]] && awk -v t="${large_secs:-99}" 'BEGIN { exit !(t + 0 < 2) }'; then
      pass "OSTYPE=$os bash $major: no mapfile/read calls, matches \${s//CRLF/LF}; ${inline_bytes} B in ${inline_secs}s, ${large_bytes} B in ${large_secs}s"
    else
      fail "OSTYPE=$os bash ${major:-?}: ${fails:-?} failures, ${large_bytes:-?} B took ${large_secs:-?}s (limit 2s)"
    fi
  done
done

# Off Windows the builtin split stays: it is linear on bash 3.2, where the
# substitution is not.
cat > "$TMP/posix.sh" <<'CASE'
. "$1"
OSTYPE=darwin
calls=0
mapfile() { calls=$((calls + 1)); builtin mapfile "$@"; }
read() { calls=$((calls + 1)); builtin read "$@"; }
v=$'a\r\nb'
hq_crlf_to_lf v
[[ "$v" == $'a\nb' ]] && ((calls > 0)) && echo ok
CASE
if [[ "$(bash "$TMP/posix.sh" "$ROOT/core/scripts/hook-lib.sh")" == ok ]]; then
  pass "OSTYPE=darwin keeps the builtin line split"
else
  fail "OSTYPE=darwin no longer uses the builtin line split"
fi

if ((FAIL)); then
  printf 'hook-crlf-windows-no-byte-reads: %s passed, %s failed\n' "$PASS" "$FAIL" >&2
  exit 1
fi
printf 'hook-crlf-windows-no-byte-reads: %s passed, 0 failed\n' "$PASS"
