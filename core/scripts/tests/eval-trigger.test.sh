#!/usr/bin/env bash
# hq-core: public
# Tests for core/scripts/eval-trigger.sh
#
# Contract:
#   bash eval-trigger.sh "<expr>" "<space-separated facts>"
#     exit 0 = expression TRUE  given the fact set
#     exit 1 = expression FALSE given the fact set
#     exit 2 = malformed / unsafe expression (caller FAILS OPEN = inject)
#
# Tokens are open (no vocabulary): an identifier is TRUE iff present in the
# fact set; absent or misspelled identifiers are FALSE. Grammar: identifiers
# joined by && || ! and ( ). After substituting identifiers -> 1/0, only
# `0 1 & | ! ( )` + spaces may remain; anything else -> exit 2 (fail open).

set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/eval-trigger.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }

# run <expected-exit> <expr> <facts> <label>
run() {
  local want="$1" expr="$2" facts="$3" label="$4" got=0
  bash "$SRC" "$expr" "$facts" >/dev/null 2>&1 || got=$?
  [ "$got" = "$want" ] || fail "$label: expected exit $want, got $got  (expr='$expr' facts='$facts')"
}

[ -f "$SRC" ] || fail "eval-trigger.sh not found at $SRC (implement it)"

# --- basic AND ---
run 0 "git && push"            "git push vercel"  "AND both present"
run 1 "git && push"            "git deploy"       "AND one missing"
run 1 "git && push"            ""                 "AND empty facts"

# --- OR ---
run 0 "git || push"            "deploy push"      "OR one present"
run 1 "git || push"            "deploy commit"    "OR none present"

# --- NOT ---
run 0 "! main"                 "git push"         "NOT of absent = true"
run 1 "! main"                 "main git"         "NOT of present = false"
run 0 "git && ! main"          "git feature"      "AND NOT (clean)"
run 1 "git && ! main"          "git main"         "AND NOT (blocked)"

# --- parens / precedence ---
run 0 "git && ( push || commit )" "git commit"    "paren OR right branch"
run 0 "git && ( push || commit )" "git push"      "paren OR left branch"
run 1 "git && ( push || commit )" "git deploy"    "paren OR neither"
run 0 "( a || b ) && ( c || d )"  "b d"           "two paren groups true"
run 1 "( a || b ) && ( c || d )"  "b x"           "two paren groups one false"

# --- open tokens: misspelled/unknown identifier is simply FALSE ---
run 1 "git && frobnicate"      "git"              "unknown token -> false"
run 0 "git || frobnicate"      "git"              "unknown token OR present"

# --- dot/slash identifiers: filenames and slash-commands are literal tokens ---
run 0 ".mcp.json"                       "always .mcp.json .json"     "dotfile token present"
run 1 ".mcp.json"                       "always settings.json"       "dotfile token absent"
run 0 "settings.json || settings.local.json" "always settings.local.json" "dotted basename OR"
run 0 ".png || .jpg"                    "always shot.png .png"       "extension token present"
run 0 "/brainstorm"                     "always /brainstorm"         "slash-command token"
run 1 "/brainstorm"                     "always /deep-plan"          "slash-command absent"
run 0 "/deep-plan && ! main"            "always /deep-plan feature"  "slash-command AND NOT"

# --- malformed / unsafe -> exit 2 (caller fails open) ---
run 2 ""                        "git"             "empty expr -> fail open"
run 2 'git && system("rm")'     "git"             "quotes/charset -> fail open"
run 2 'git && `id`'             "git"             "backticks -> fail open"

echo "PASS: eval-trigger.sh"
