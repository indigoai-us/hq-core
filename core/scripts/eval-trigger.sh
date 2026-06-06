#!/bin/bash
# eval-trigger.sh — evaluate a policy `when:` boolean expression against a fact set.
#
# Usage:
#   eval-trigger.sh "<expr>" "<space-separated facts>"
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
  while (substr(E, pos, 2) == "||") { pos += 2; if (parseAnd() || v) v = 1; else v = 0 }
  return v
}
function parseAnd(  v) {
  v = parseNot(); skip()
  while (substr(E, pos, 2) == "&&") { pos += 2; if (parseNot() && v) v = 1; else v = 0 }
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
  exit (v ? 0 : 1)
}
'
