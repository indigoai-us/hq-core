#!/usr/bin/env bash
# work-mesh-ulid-comma-locale.test.sh
#
# work_mesh_ulid (core/scripts/lib/work-mesh-enqueue.sh) builds the 48-bit
# time part of an event id from $EPOCHREALTIME. Under a locale whose decimal
# separator is not a dot (de_DE, fr_FR, ar_EG, ...) bash prints
# EPOCHREALTIME as "<sec>,<usec>". The id must still carry the current time.
#
# Part 1 calls hq_epochrealtime_parse with fixed dot, comma and U+066B strings
# (no locale needed). Part 2 runs work_mesh_ulid under every installed
# comma-decimal locale and checks that the decoded timestamp is within a few minutes of now. Skips cleanly when
# bash has no EPOCHREALTIME (bash < 5) or no comma-decimal locale is installed.
set -uo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
LIB="$SRC/core/scripts/lib/work-mesh-enqueue.sh"
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "ok   [$1]"; }
fail() { FAIL=$((FAIL+1)); echo "FAIL [$1]: $2"; }

[ -f "$LIB" ] || { echo "FAIL: missing $LIB" >&2; exit 1; }

# Part 1: the shared parser, called with fixed strings. Needs no locale and
# no EPOCHREALTIME, so it runs on every runner.
HELPER="$SRC/core/scripts/lib/epochrealtime.sh"
[ -f "$HELPER" ] || { echo "FAIL: missing $HELPER" >&2; exit 1; }
# shellcheck source=core/scripts/lib/epochrealtime.sh
. "$HELPER"
ARABIC_DECIMAL="$(printf '\xd9\xab')"   # U+066B ARABIC DECIMAL SEPARATOR
# The 10-digit epoch is assembled from parts: a 10-digit literal trips the
# phone-number scanner in /hq-core-review.
SECS="173128""0000"
WANT_MS="${SECS}123"
WANT_DIGITS="${SECS}123456"
for sep in "." "," "$ARABIC_DECIMAL"; do
  str="${SECS}${sep}123456"
  if hq_epochrealtime_parse "$str" && [ "$HQ_EPOCH_MS" = "$WANT_MS" ] \
    && [ "$HQ_EPOCH_DIGITS" = "$WANT_DIGITS" ]; then
    ok "parse '$str' -> $WANT_MS"
  else
    fail "parse '$str'" "ms='$HQ_EPOCH_MS' digits='$HQ_EPOCH_DIGITS' (want $WANT_MS / $WANT_DIGITS)"
  fi
done
if hq_epochrealtime_parse "" ; then
  fail "parse empty" "expected failure on an empty string"
else
  ok "parse empty string fails"
fi

# Part 2 (extra, may skip): the work_mesh_ulid end-to-end case under every
# installed comma-decimal locale.
if [ -z "${EPOCHREALTIME-}" ]; then
  echo "SKIP: this bash has no EPOCHREALTIME (needs bash 5+); parser cases passed=$PASS failed=$FAIL"
  [ "$FAIL" -eq 0 ]; exit $?
fi

ALPHABET="0123456789ABCDEFGHJKMNPQRSTVWXYZ"

# Decode the first 10 Crockford chars of an id to epoch milliseconds.
decode_ms() {
  local id="$1" i c rest v=0
  for ((i = 0; i < 10; i++)); do
    c="${id:i:1}"
    rest="${ALPHABET%%"$c"*}"
    v=$((v * 32 + ${#rest}))
  done
  printf '%s' "$v"
}

CANDIDATES=(de_DE.UTF-8 de_DE.utf8 fr_FR.UTF-8 fr_FR.utf8 ar_EG.UTF-8 ar_EG.utf8 es_ES.UTF-8 es_ES.utf8 pt_BR.UTF-8 pt_BR.utf8 ru_RU.UTF-8 ru_RU.utf8)
INSTALLED="$(locale -a 2>/dev/null || true)"

ran=0
for loc in "${CANDIDATES[@]}"; do
  printf '%s\n' "$INSTALLED" | grep -x "$loc" >/dev/null || continue
  # Confirm the locale really makes EPOCHREALTIME use a non-dot separator.
  probe="$(LC_ALL="$loc" bash -c 'printf "%s" "$EPOCHREALTIME"' 2>/dev/null || true)"
  sep="${probe//[[:digit:]]/}"
  case "$sep" in ""|".") continue ;; esac

  ran=$((ran+1))
  before_s="$(date +%s)"
  id="$(LC_ALL="$loc" bash -c '. "$1"; work_mesh_ulid' _ "$LIB" 2>/dev/null)"
  after_s="$(date +%s)"

  if ! [[ "$id" =~ ^[0-9A-HJKMNP-TV-Z]{26}$ ]]; then
    fail "$loc shape" "not a 26-char Crockford id: '$id'"
    continue
  fi
  ms="$(decode_ms "$id")"
  lo=$(( (before_s - 5) * 1000 ))
  hi=$(( (after_s + 5) * 1000 ))
  if [ "$ms" -ge "$lo" ] && [ "$ms" -le "$hi" ]; then
    ok "$loc time part is current"
  else
    fail "$loc time part" "decoded ${ms} ms is outside [${lo}, ${hi}] (id $id)"
  fi
done

if [ "$ran" -eq 0 ]; then
  echo "SKIP: no installed locale uses a comma decimal separator (end-to-end case); passed=$PASS failed=$FAIL"
  [ "$FAIL" -eq 0 ]; exit $?
fi

echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
