#!/usr/bin/env bash
# hq-core: public
# epochrealtime.sh — locale-proof parse of a bash $EPOCHREALTIME string.
#
# Sourced by work-mesh-enqueue.sh, hook-adapter-core.sh and hook-stop-async.sh.
# Bash prints EPOCHREALTIME with the locale decimal separator: "." under C,
# "," under de_DE or fr_FR, a multibyte character under ar_EG. The parse
# below never looks at the separator: the seconds are the leading digits and
# the fraction is every digit after them.
#
#   hq_epochrealtime_parse "12,345678" || fallback
#   # HQ_EPOCH_MS     = 12345  (seconds + first 3 fraction digits)
#   # HQ_EPOCH_DIGITS = 12345678  (seconds + whole fraction)
#
# Sets variables instead of printing so callers need no command substitution.
# Returns 1, with both variables empty, when the string has no leading digits.
# shellcheck disable=SC2034  # HQ_EPOCH_* are read by the sourcing callers
hq_epochrealtime_parse() {
  local s="${1-}" seconds fraction
  HQ_EPOCH_MS=""
  HQ_EPOCH_DIGITS=""
  seconds="${s%%[![:digit:]]*}"
  [ -n "$seconds" ] || return 1
  fraction="${s#"$seconds"}"
  fraction="${fraction//[![:digit:]]/}"
  HQ_EPOCH_DIGITS="${seconds}${fraction}"
  fraction="${fraction}000"
  HQ_EPOCH_MS="${seconds}${fraction:0:3}"
  return 0
}
