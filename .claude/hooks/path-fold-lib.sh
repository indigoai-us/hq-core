#!/usr/bin/env bash
# hq-core: public
# path-fold-lib.sh: the Unicode fold shared by HQ path guards (fold v1).
#
# A case-insensitive volume (APFS and HFS+ on macOS, NTFS on Windows) folds
# some non-ASCII letters onto ASCII ones, so a path spelled with them opens
# the ASCII-named file. Bash's nocasematch does not see that. A guard that
# compares path strings folds the text with this table first.
#
# Fold v1. Each code point below is replaced; every other code point is kept:
#   U+00DF (sharp s) -> "ss"     U+1E9E (capital sharp s) -> "ss"
#   U+017F (long s)  -> "s"      U+212A (Kelvin sign)     -> "k"
#   U+0130 (I with dot above) -> "i"   U+0131 (dotless i) -> "i"
#   U+FB00 -> "ff"  U+FB01 -> "fi"  U+FB02 -> "fl"  U+FB03 -> "ffi"
#   U+FB04 -> "ffl" U+FB05 -> "st"  U+FB06 -> "st"
#   fullwidth letters and digits, and fullwidth . _ -
#     U+FF10..U+FF19, U+FF21..U+FF3A, U+FF41..U+FF5A,
#     U+FF0E, U+FF3F, U+FF0D -> code point - 0xFEE0 (0-9 A-Z a-z . _ -)
# Every fold produces only letters, digits, ".", "_" or "-", so a fold never
# adds a shell metacharacter, a quote, a space or a separator. Other
# fullwidth punctuation is kept as it is. The native guard port must apply
# the same table.
#
# The volume subset. Eleven entries are the only non-ASCII code points that
# a case-insensitive APFS volume resolves to an ASCII name: U+00DF, U+1E9E,
# U+017F, U+212A and U+FB00..U+FB06. They fold to letters only. The other
# entries (U+0130, U+0131 and fullwidth forms) fold to ASCII under Turkish
# casing, NFKC or Windows best-fit conversion, but the volume keeps them as
# distinct names, and the fullwidth full stop folds to ".", which is path
# syntax. A guard that resolves paths therefore classifies with the volume
# subset, and checks a v1-folded copy as well, blocking when either blocks:
# folding fullwidth "．．" to ".." before resolving would move a path out of
# the folder it really opens.
#
# Usage (any locale; no process is spawned):
#   hq_path_fold <text>                 fold v1; result in HQ_PATH_FOLD_OUT
#   hq_path_fold_needed <text>          succeeds when fold v1 would change <text>
#   hq_path_fold_volume <text>          volume subset; result in HQ_PATH_FOLD_OUT
#   hq_path_fold_volume_needed <text>   succeeds when the subset would change it
# The same tables as jq programs, for a JSON payload (string values only,
# after JSON unescaping; object keys are kept). Each prints the folded
# document, or nothing when the fold changes nothing:
#   jq -nc "$HQ_PATH_FOLD_V1_JQ" <<<"$json"
#   jq -nc "$HQ_PATH_FOLD_VOLUME_JQ" <<<"$json"
# The bash functions copy the text once per folded character, so use them on
# path strings; fold a whole payload with the jq programs.
#
# The bash functions work on UTF-8 bytes in the C locale. UTF-8 never puts an
# ASCII byte or a lead byte inside another character, so a byte match finds
# exactly the encoded code point.

HQ_PATH_FOLD_OUT=""

_HQ_PATH_FOLD_JQ_DEFS='def hq_fold_volume_cp:
  if . == 223 or . == 7838 then [115, 115]
  elif . == 383 then [115]
  elif . == 8490 then [107]
  elif . == 64256 then [102, 102]
  elif . == 64257 then [102, 105]
  elif . == 64258 then [102, 108]
  elif . == 64259 then [102, 102, 105]
  elif . == 64260 then [102, 102, 108]
  elif . == 64261 or . == 64262 then [115, 116]
  else [.] end;
def hq_fold_v1_cp:
  if . == 304 or . == 305 then [105]
  elif (. >= 65296 and . <= 65305) or (. >= 65313 and . <= 65338)
    or (. >= 65345 and . <= 65370) or . == 65294 or . == 65343 or . == 65293
    then [. - 65248]
  else hq_fold_volume_cp end;
def hq_fold_all(f): if type == "string" then [explode[] | f[]] | implode
  elif type == "object" then map_values(hq_fold_all(f))
  elif type == "array" then map(hq_fold_all(f))
  else . end;
def hq_fold_doc(f): [inputs] as $docs
  | if ($docs | length) != 1 then empty
    else $docs[0] as $o | ($o | hq_fold_all(f)) as $g
    | if $g == $o then empty else $g end
    end;'
HQ_PATH_FOLD_V1_JQ="$_HQ_PATH_FOLD_JQ_DEFS hq_fold_doc(hq_fold_v1_cp)"
HQ_PATH_FOLD_VOLUME_JQ="$_HQ_PATH_FOLD_JQ_DEFS hq_fold_doc(hq_fold_volume_cp)"

# Switch to the C locale and back without a subshell. Assigning or unsetting
# LC_ALL makes bash call setlocale at once.
_hq_path_fold_lc_enter() {
  _HQ_PF_LC_SET="${LC_ALL+1}"
  _HQ_PF_LC_SAVED="${LC_ALL-}"
  LC_ALL=C
}
_hq_path_fold_lc_leave() {
  if [ -n "$_HQ_PF_LC_SET" ]; then
    LC_ALL="$_HQ_PF_LC_SAVED"
  else
    unset LC_ALL
  fi
}

# Byte tests for the encoded code points of each table. Call in the C locale.
_hq_path_fold_volume_needed_bytes() {
  case "${1:-}" in
    *$'\xc3\x9f'*|*$'\xc5\xbf'*|*$'\xe1\xba\x9e'*|*$'\xe2\x84\xaa'*) return 0 ;;
    *$'\xef\xac'[$'\x80'-$'\x86']*) return 0 ;;
  esac
  return 1
}
_hq_path_fold_needed_bytes() {
  _hq_path_fold_volume_needed_bytes "${1:-}" && return 0
  case "${1:-}" in
    *$'\xc4\xb0'*|*$'\xc4\xb1'*) return 0 ;;
    *$'\xef\xbc'[$'\x8d'$'\x8e'$'\x90'-$'\x99'$'\xa1'-$'\xba'$'\xbf']*) return 0 ;;
    *$'\xef\xbd'[$'\x81'-$'\x9a']*) return 0 ;;
  esac
  return 1
}

hq_path_fold_needed() {
  local rc=1
  _hq_path_fold_lc_enter
  _hq_path_fold_needed_bytes "${1:-}" && rc=0
  _hq_path_fold_lc_leave
  return "$rc"
}

hq_path_fold_volume_needed() {
  local rc=1
  _hq_path_fold_lc_enter
  _hq_path_fold_volume_needed_bytes "${1:-}" && rc=0
  _hq_path_fold_lc_leave
  return "$rc"
}

# Replace every occurrence of the literal <lit> in <text> with <rep>. A walk
# from one occurrence to the next: ${text//lit/rep} costs about length x
# length in bash 3.2 on a long payload. Result in _HQ_PF_REPL.
_hq_path_fold_replace() {
  local text="${1:-}" lit="$2" rep="$3" out="" pre
  while [[ "$text" == *"$lit"* ]]; do
    pre="${text%%"$lit"*}"
    out="$out$pre$rep"
    text="${text:$((${#pre} + ${#lit}))}"
  done
  _HQ_PF_REPL="$out$text"
}

# The replacement for the third byte of a three-byte form that starts with
# EF AC (ligatures), EF BC or EF BD (fullwidth). Empty for a byte outside the
# table, or for a fullwidth form when <mode> is "volume".
_hq_path_fold_tail() {
  _HQ_PF_TAIL=""
  case "$1:$3" in
    volume:bc|volume:bd) return 0 ;;
  esac
  case "$3:$2" in
    ac:$'\x80') _HQ_PF_TAIL=ff ;;
    ac:$'\x81') _HQ_PF_TAIL=fi ;;
    ac:$'\x82') _HQ_PF_TAIL=fl ;;
    ac:$'\x83') _HQ_PF_TAIL=ffi ;;
    ac:$'\x84') _HQ_PF_TAIL=ffl ;;
    ac:$'\x85'|ac:$'\x86') _HQ_PF_TAIL=st ;;
    bc:$'\x8d') _HQ_PF_TAIL=- ;;
    bc:$'\x8e') _HQ_PF_TAIL=. ;;
    bc:$'\xbf') _HQ_PF_TAIL=_ ;;
    bc:$'\x90') _HQ_PF_TAIL=0 ;; bc:$'\x91') _HQ_PF_TAIL=1 ;;
    bc:$'\x92') _HQ_PF_TAIL=2 ;; bc:$'\x93') _HQ_PF_TAIL=3 ;;
    bc:$'\x94') _HQ_PF_TAIL=4 ;; bc:$'\x95') _HQ_PF_TAIL=5 ;;
    bc:$'\x96') _HQ_PF_TAIL=6 ;; bc:$'\x97') _HQ_PF_TAIL=7 ;;
    bc:$'\x98') _HQ_PF_TAIL=8 ;; bc:$'\x99') _HQ_PF_TAIL=9 ;;
    bc:$'\xa1') _HQ_PF_TAIL=A ;; bc:$'\xa2') _HQ_PF_TAIL=B ;;
    bc:$'\xa3') _HQ_PF_TAIL=C ;; bc:$'\xa4') _HQ_PF_TAIL=D ;;
    bc:$'\xa5') _HQ_PF_TAIL=E ;; bc:$'\xa6') _HQ_PF_TAIL=F ;;
    bc:$'\xa7') _HQ_PF_TAIL=G ;; bc:$'\xa8') _HQ_PF_TAIL=H ;;
    bc:$'\xa9') _HQ_PF_TAIL=I ;; bc:$'\xaa') _HQ_PF_TAIL=J ;;
    bc:$'\xab') _HQ_PF_TAIL=K ;; bc:$'\xac') _HQ_PF_TAIL=L ;;
    bc:$'\xad') _HQ_PF_TAIL=M ;; bc:$'\xae') _HQ_PF_TAIL=N ;;
    bc:$'\xaf') _HQ_PF_TAIL=O ;; bc:$'\xb0') _HQ_PF_TAIL=P ;;
    bc:$'\xb1') _HQ_PF_TAIL=Q ;; bc:$'\xb2') _HQ_PF_TAIL=R ;;
    bc:$'\xb3') _HQ_PF_TAIL=S ;; bc:$'\xb4') _HQ_PF_TAIL=T ;;
    bc:$'\xb5') _HQ_PF_TAIL=U ;; bc:$'\xb6') _HQ_PF_TAIL=V ;;
    bc:$'\xb7') _HQ_PF_TAIL=W ;; bc:$'\xb8') _HQ_PF_TAIL=X ;;
    bc:$'\xb9') _HQ_PF_TAIL=Y ;; bc:$'\xba') _HQ_PF_TAIL=Z ;;
    bd:$'\x81') _HQ_PF_TAIL=a ;; bd:$'\x82') _HQ_PF_TAIL=b ;;
    bd:$'\x83') _HQ_PF_TAIL=c ;; bd:$'\x84') _HQ_PF_TAIL=d ;;
    bd:$'\x85') _HQ_PF_TAIL=e ;; bd:$'\x86') _HQ_PF_TAIL=f ;;
    bd:$'\x87') _HQ_PF_TAIL=g ;; bd:$'\x88') _HQ_PF_TAIL=h ;;
    bd:$'\x89') _HQ_PF_TAIL=i ;; bd:$'\x8a') _HQ_PF_TAIL=j ;;
    bd:$'\x8b') _HQ_PF_TAIL=k ;; bd:$'\x8c') _HQ_PF_TAIL=l ;;
    bd:$'\x8d') _HQ_PF_TAIL=m ;; bd:$'\x8e') _HQ_PF_TAIL=n ;;
    bd:$'\x8f') _HQ_PF_TAIL=o ;; bd:$'\x90') _HQ_PF_TAIL=p ;;
    bd:$'\x91') _HQ_PF_TAIL=q ;; bd:$'\x92') _HQ_PF_TAIL=r ;;
    bd:$'\x93') _HQ_PF_TAIL=s ;; bd:$'\x94') _HQ_PF_TAIL=t ;;
    bd:$'\x95') _HQ_PF_TAIL=u ;; bd:$'\x96') _HQ_PF_TAIL=v ;;
    bd:$'\x97') _HQ_PF_TAIL=w ;; bd:$'\x98') _HQ_PF_TAIL=x ;;
    bd:$'\x99') _HQ_PF_TAIL=y ;; bd:$'\x9a') _HQ_PF_TAIL=z ;;
  esac
}

# Fold the three-byte forms that start with EF <id byte>. A form outside the
# table keeps its bytes. Result in _HQ_PF_REPL.
_hq_path_fold_three() {
  local text="${1:-}" mode="$2" id="$3" prefix out="" pre third
  case "$id" in
    ac) prefix=$'\xef\xac' ;;
    bc) prefix=$'\xef\xbc' ;;
    bd) prefix=$'\xef\xbd' ;;
  esac
  while [[ "$text" == *"$prefix"* ]]; do
    pre="${text%%"$prefix"*}"
    third="${text:$((${#pre} + 2)):1}"
    _hq_path_fold_tail "$mode" "$third" "$id"
    if [ -n "$_HQ_PF_TAIL" ]; then
      out="$out$pre$_HQ_PF_TAIL"
      text="${text:$((${#pre} + 3))}"
    else
      out="$out$pre$prefix"
      text="${text:$((${#pre} + 2))}"
    fi
  done
  _HQ_PF_REPL="$out$text"
}

# _hq_path_fold_run <mode> <text>: mode is "v1" or "volume". Call in the C
# locale. Result in HQ_PATH_FOLD_OUT.
_hq_path_fold_run() {
  local mode="$1" text="${2:-}"
  case "$text" in *$'\xc3\x9f'*) _hq_path_fold_replace "$text" $'\xc3\x9f' ss; text="$_HQ_PF_REPL" ;; esac
  case "$text" in *$'\xe1\xba\x9e'*) _hq_path_fold_replace "$text" $'\xe1\xba\x9e' ss; text="$_HQ_PF_REPL" ;; esac
  case "$text" in *$'\xc5\xbf'*) _hq_path_fold_replace "$text" $'\xc5\xbf' s; text="$_HQ_PF_REPL" ;; esac
  case "$text" in *$'\xe2\x84\xaa'*) _hq_path_fold_replace "$text" $'\xe2\x84\xaa' k; text="$_HQ_PF_REPL" ;; esac
  case "$text" in *$'\xef\xac'*) _hq_path_fold_three "$text" "$mode" ac; text="$_HQ_PF_REPL" ;; esac
  if [ "$mode" = v1 ]; then
    case "$text" in *$'\xc4\xb0'*) _hq_path_fold_replace "$text" $'\xc4\xb0' i; text="$_HQ_PF_REPL" ;; esac
    case "$text" in *$'\xc4\xb1'*) _hq_path_fold_replace "$text" $'\xc4\xb1' i; text="$_HQ_PF_REPL" ;; esac
    case "$text" in *$'\xef\xbc'*) _hq_path_fold_three "$text" "$mode" bc; text="$_HQ_PF_REPL" ;; esac
    case "$text" in *$'\xef\xbd'*) _hq_path_fold_three "$text" "$mode" bd; text="$_HQ_PF_REPL" ;; esac
  fi
  HQ_PATH_FOLD_OUT="$text"
}

hq_path_fold() {
  local text="${1:-}"
  _hq_path_fold_lc_enter
  if _hq_path_fold_needed_bytes "$text"; then
    _hq_path_fold_run v1 "$text"
  else
    HQ_PATH_FOLD_OUT="$text"
  fi
  _hq_path_fold_lc_leave
}

hq_path_fold_volume() {
  local text="${1:-}"
  _hq_path_fold_lc_enter
  if _hq_path_fold_volume_needed_bytes "$text"; then
    _hq_path_fold_run volume "$text"
  else
    HQ_PATH_FOLD_OUT="$text"
  fi
  _hq_path_fold_lc_leave
}

# Last line: a caller can tell a complete load from a truncated file.
HQ_PATH_FOLD_LIB_LOADED=1
