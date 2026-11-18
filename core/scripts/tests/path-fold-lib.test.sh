#!/usr/bin/env bash
# hq-core: public
# path-fold-lib.sh (fold v1) matches the reference table, written here as a
# jq program, for every code point U+0080..U+2FFFF, in the C and UTF-8
# locales. hq_path_fold_needed must succeed exactly when the fold changes
# the text, and text without a folded code point must come back unchanged.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
LIB="$ROOT/.claude/hooks/path-fold-lib.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

REF_JQ='def fold_cp:
  if . == 223 or . == 7838 then [115, 115]
  elif . == 383 then [115]
  elif . == 8490 then [107]
  elif . == 304 or . == 305 then [105]
  elif . == 64256 then [102, 102]
  elif . == 64257 then [102, 105]
  elif . == 64258 then [102, 108]
  elif . == 64259 then [102, 102, 105]
  elif . == 64260 then [102, 102, 108]
  elif . == 64261 or . == 64262 then [115, 116]
  elif (. >= 65296 and . <= 65305) or (. >= 65313 and . <= 65338)
    or (. >= 65345 and . <= 65370) or . == 65294 or . == 65343 or . == 65293
    then [. - 65248]
  else [.] end;
def fold: [explode[] | fold_cp[]] | implode;'

# Every code point once, each followed by "|" so a fold cannot join two.
# Both files are built from code point numbers: jq's own UTF-8 reader turns
# some valid sequences into U+FFFD, so the reference never re-reads text.
CPS='[range(128; 196608) | select(. < 55296 or . > 57343)]'
jq -rn "$CPS"' | map(., 124) | implode' > "$TMP/all.txt"
jq -rn "$REF_JQ"' '"$CPS"' | map((fold_cp[]), 124) | implode' > "$TMP/ref.txt"

# The volume subset: the eleven code points a folding APFS volume resolves.
VOL_JQ='def vol_cp:
  if . == 223 or . == 7838 then [115, 115]
  elif . == 383 then [115]
  elif . == 8490 then [107]
  elif . == 64256 then [102, 102]
  elif . == 64257 then [102, 105]
  elif . == 64258 then [102, 108]
  elif . == 64259 then [102, 102, 105]
  elif . == 64260 then [102, 102, 108]
  elif . == 64261 or . == 64262 then [115, 116]
  else [.] end;'
jq -rn "$VOL_JQ"' '"$CPS"' | map((vol_cp[]), 124) | implode' > "$TMP/vol.txt"

FAILURES=0
# The helper's jq programs give the same folds on a JSON payload, values only.
# shellcheck source=../../../.claude/hooks/path-fold-lib.sh
. "$LIB"
jq -cn --rawfile s "$TMP/all.txt" '{tool_input:{file_path:$s, list:[$s]}, ($s[0:4]):1}' > "$TMP/doc.json"
want="$(jq -cn --rawfile s "$TMP/ref.txt" --rawfile k "$TMP/all.txt" '{tool_input:{file_path:$s, list:[$s]}, ($k[0:4]):1}')"
[ "$(jq -nc "$HQ_PATH_FOLD_V1_JQ" < "$TMP/doc.json")" = "$want" ] \
  && echo "PASS: HQ_PATH_FOLD_V1_JQ matches the reference" \
  || { echo "FAIL: HQ_PATH_FOLD_V1_JQ differs from the reference" >&2; FAILURES=$((FAILURES + 1)); }
want="$(jq -cn --rawfile s "$TMP/vol.txt" --rawfile k "$TMP/all.txt" '{tool_input:{file_path:$s, list:[$s]}, ($k[0:4]):1}')"
[ "$(jq -nc "$HQ_PATH_FOLD_VOLUME_JQ" < "$TMP/doc.json")" = "$want" ] \
  && echo "PASS: HQ_PATH_FOLD_VOLUME_JQ matches the volume subset" \
  || { echo "FAIL: HQ_PATH_FOLD_VOLUME_JQ differs from the volume subset" >&2; FAILURES=$((FAILURES + 1)); }
[ -z "$(printf '{"a":"companies/x","b":["café"]}' | jq -nc "$HQ_PATH_FOLD_V1_JQ")" ] \
  && echo "PASS: unchanged payload prints nothing" \
  || { echo "FAIL: unchanged payload printed a document" >&2; FAILURES=$((FAILURES + 1)); }

for loc in C en_US.UTF-8; do
  out="$(LC_ALL="$loc" "${BASH_BIN:-bash}" -c '
    . "$1"
    text="$(cat "$2")"
    hq_path_fold_volume "$text"
    printf "%s" "$HQ_PATH_FOLD_OUT"
  ' _ "$LIB" "$TMP/all.txt")"
  if [ "$out" = "$(cat "$TMP/vol.txt")" ]; then
    echo "PASS: volume subset [$loc]"
  else
    echo "FAIL: volume subset differs from the reference [$loc]" >&2
    FAILURES=$((FAILURES + 1))
  fi
  out="$(LC_ALL="$loc" "${BASH_BIN:-bash}" -c '
    . "$1"
    text="$(cat "$2")"
    hq_path_fold "$text"
    printf "%s" "$HQ_PATH_FOLD_OUT"
  ' _ "$LIB" "$TMP/all.txt")"
  if [ "$out" = "$(cat "$TMP/ref.txt")" ]; then
    echo "PASS: full table [$loc]"
  else
    echo "FAIL: full table differs from the reference [$loc]" >&2
    FAILURES=$((FAILURES + 1))
  fi
  # Per code point: hq_path_fold_needed agrees with "the fold changes it".
  # Checked over the code points near the table (every 3-byte lead used).
  bad="$(LC_ALL="$loc" "${BASH_BIN:-bash}" -c '
    . "$1"
    while IFS= read -r ch; do
      hq_path_fold "x${ch}y"
      if [ "$HQ_PATH_FOLD_OUT" != "x${ch}y" ]; then changed=1; else changed=0; fi
      if hq_path_fold_needed "x${ch}y"; then needed=1; else needed=0; fi
      [ "$changed" = "$needed" ] || printf "%s " "$ch"
      hq_path_fold_volume "x${ch}y"
      if [ "$HQ_PATH_FOLD_OUT" != "x${ch}y" ]; then changed=1; else changed=0; fi
      if hq_path_fold_volume_needed "x${ch}y"; then needed=1; else needed=0; fi
      [ "$changed" = "$needed" ] || printf "vol:%s " "$ch"
    done
  ' _ "$LIB" < <(jq -rn '[range(128; 1024), range(7680; 7936), range(8448; 8576), range(64224; 64336), range(65280; 65520)][] | [.] | implode'))"
  if [ -z "$bad" ]; then
    echo "PASS: hq_path_fold_needed agrees with the fold [$loc]"
  else
    echo "FAIL: hq_path_fold_needed disagrees [$loc]: $bad" >&2
    FAILURES=$((FAILURES + 1))
  fi
done

# Plain text, other scripts and other fullwidth punctuation are unchanged.
for s in 'companies/acme/x' 'café Straße' 'naïve résumé' '日本語/テスト' $'\xef\xbc\x83 \xef\xbc\x82' $'\xef\xac\x87' ''; do
  out="$(LC_ALL=en_US.UTF-8 "${BASH_BIN:-bash}" -c '. "$1"; hq_path_fold "$2"; printf "%s" "$HQ_PATH_FOLD_OUT"' _ "$LIB" "$s")"
  want="$(printf '%s' "$s" | jq -rRs "$REF_JQ"' fold')"
  if [ "$out" = "$want" ]; then
    echo "PASS: [$s]"
  else
    echo "FAIL: [$s] -> [$out], want [$want]" >&2
    FAILURES=$((FAILURES + 1))
  fi
done

# The caller's locale is restored.
got="$(LC_ALL=en_US.UTF-8 "${BASH_BIN:-bash}" -c '. "$1"; hq_path_fold "a"; hq_path_fold_needed "b" || true; printf "%s" "$LC_ALL"' _ "$LIB")"
[ "$got" = en_US.UTF-8 ] && echo "PASS: LC_ALL kept" || { echo "FAIL: LC_ALL became [$got]" >&2; FAILURES=$((FAILURES + 1)); }
got="$(env -u LC_ALL "${BASH_BIN:-bash}" -c '. "$1"; hq_path_fold "a"; printf "%s" "${LC_ALL-unset}"' _ "$LIB")"
[ "$got" = unset ] && echo "PASS: unset LC_ALL kept" || { echo "FAIL: LC_ALL became [$got]" >&2; FAILURES=$((FAILURES + 1)); }

if [ "$FAILURES" -gt 0 ]; then
  echo "$FAILURES path-fold check(s) failed" >&2
  exit 1
fi
echo "all path-fold checks passed"
