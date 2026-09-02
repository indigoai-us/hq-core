#!/bin/bash
# eval-trigger.sh — evaluate a policy `when:` boolean expression against a fact set.
#
# Usage:
#   eval-trigger.sh "<expr>" "<space-separated facts>"
#   eval-trigger.sh --check < "<id>\t<expr>" lines   → "<id>\tok|malformed"
#
# Expression grammar (tiny boolean algebra over open identifiers):
#   expr   := or
#   or     := and ( '||' and )*
#   and    := not ( '&&' not )*
#   not    := '!' not | atom
#   atom   := '(' or ')' | identifier
#   identifier := [A-Za-z0-9_./][A-Za-z0-9_./-]*
#                 Letters, digits, _ . / - . May start with `.` or `/`, so a
#                 filename (`.mcp.json`, `settings.json`) or a slash-command
#                 (`/brainstorm`) is a single literal token. Operators
#                 (`&& || ! ( )`) and whitespace are the only delimiters.
#
# Tokens are OPEN — no vocabulary. An identifier is TRUE iff it appears in the
# fact set; absent or misspelled identifiers are FALSE.
#
# Exit codes:
#   0 — expression is TRUE  given the facts
#   1 — expression is FALSE given the facts
#   2 — expression is empty / malformed / unsafe  → caller should FAIL OPEN
#
# Safety: each identifier is substituted with 1/0 by fact membership, then the
# result must contain ONLY `0 1 & | ! ( )` and spaces. Anything else (quotes,
# backticks, `$`, letters left over, etc.) yields exit 2 — the expression is
# never eval'd by a shell, only by awk's own boolean operators. Dots, slashes,
# and dashes are part of the identifier charset, so they are consumed by the
# substitution and never survive to the gate; quotes/backticks/$ still do, and
# still fail open.

set -euo pipefail

# --check: batch SYNTAX mode. Reads `<id><TAB><expr>` lines on stdin and prints
# `<id><TAB>ok` or `<id><TAB>malformed`, one line per input. Validity does not
# depend on the fact set — every identifier substitutes to 0 — so this is the
# same parse the single-expression mode runs, just without a process per
# expression. Callers linting a whole tree use this; there is deliberately no
# second implementation of the grammar to drift from.
if [ "${1-}" = "--check" ]; then
  awk -F'\t' '
    function skip() { while (substr(E, pos, 1) == " ") pos++ }
    function parseOr(  v) {
      v = parseAnd(); skip()
      while (substr(E, pos, 2) == "||") { pos += 2; if (parseAnd() || v) v = 1; else v = 0; skip() }
      return v
    }
    function parseAnd(  v) {
      v = parseNot(); skip()
      while (substr(E, pos, 2) == "&&") { pos += 2; if (parseNot() && v) v = 1; else v = 0; skip() }
      return v
    }
    function parseNot(  c) {
      skip(); c = substr(E, pos, 1)
      if (c == "!") { pos++; return (parseNot() ? 0 : 1) }
      return parseAtom()
    }
    function parseAtom(  v, c) {
      skip(); c = substr(E, pos, 1)
      if (c == "(") { pos++; v = parseOr(); skip(); if (substr(E, pos, 1) == ")") pos++; return v }
      pos++; return (c == "1") ? 1 : 0
    }
    function check(expr,   e, s, out, tok) {
      e = expr; gsub(/[ \t]/, "", e)
      if (e == "") return 0
      s = expr; out = ""
      while (match(s, "[A-Za-z0-9_./][A-Za-z0-9_./-]*")) {
        tok = substr(s, RSTART, RLENGTH)
        out = out substr(s, 1, RSTART - 1) "0"
        s = substr(s, RSTART + RLENGTH)
      }
      out = out s
      if (out ~ /[^01&|!() ]/) return 0
      E = out; pos = 1
      parseOr()
      skip()
      if (pos <= length(E)) return 0          # trailing garbage
      return 1
    }
    { print $1 "\t" (check($2) ? "ok" : "malformed") }
  '
  exit 0
fi

EXPR="${1-}"
FACTS="${2-}"

# Empty expression → nothing to evaluate; caller fails open.
case "$EXPR" in
  ''|*[!\ ]*) : ;;  # has at least one non-space char → continue
esac
# (the case above is a readability no-op; the real empty check is in awk)

awk -v expr="$EXPR" -v facts="$FACTS" '
function skip() { while (substr(E, pos, 1) == " ") pos++ }
function parseOr(  v) {
  v = parseAnd(); skip()
  while (substr(E, pos, 2) == "||") { pos += 2; if (parseAnd() || v) v = 1; else v = 0; skip() }
  return v
}
function parseAnd(  v) {
  v = parseNot(); skip()
  while (substr(E, pos, 2) == "&&") { pos += 2; if (parseNot() && v) v = 1; else v = 0; skip() }
  return v
}
function parseNot(  c) {
  skip(); c = substr(E, pos, 1)
  if (c == "!") { pos++; return (parseNot() ? 0 : 1) }
  return parseAtom()
}
function parseAtom(  v, c) {
  skip(); c = substr(E, pos, 1)
  if (c == "(") { pos++; v = parseOr(); skip(); if (substr(E, pos, 1) == ")") pos++; return v }
  pos++; return (c == "1") ? 1 : 0
}
BEGIN {
  # empty / whitespace-only expression → fail open
  e = expr; gsub(/[ \t]/, "", e)
  if (e == "") exit 2

  # build fact membership set
  n = split(facts, fa, /[ ,]+/)
  for (i = 1; i <= n; i++) if (fa[i] != "") have[fa[i]] = 1

  # substitute identifiers -> 1/0 by membership
  s = expr; out = ""
  while (match(s, "[A-Za-z0-9_./][A-Za-z0-9_./-]*")) {
    tok = substr(s, RSTART, RLENGTH)
    out = out substr(s, 1, RSTART - 1) ((tok in have) ? "1" : "0")
    s = substr(s, RSTART + RLENGTH)
  }
  out = out s

  # safety gate: only 0 1 & | ! ( ) and spaces may remain
  if (out ~ /[^01&|!() ]/) exit 2

  # evaluate
  E = out; pos = 1
  v = parseOr()

  # The parse must consume the WHOLE expression. Recursive descent stops at the
  # first token it cannot continue from, so `merge || pull request` would parse
  # as `merge || pull` and silently discard everything after the bare space —
  # the policy then fires (or fails to) on a prefix nobody authored. Leftover
  # input means the expression is malformed, not shorter.
  skip()
  if (pos <= length(E)) exit 2

  exit (v ? 0 : 1)
}
'
