#!/usr/bin/env bash
# Regression test for feedback_732a6bfb: no numbered policy siblings.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
HOOK="$ROOT/core/hooks/PreToolUse/20-Edit,Write,MultiEdit--block-numbered-policy-sibling.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fails=0
ok() { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1"; fails=$((fails + 1)); }
run() { # <tool> <path> -> RC, ERR
  RC=0
  ERR="$(jq -cn --arg t "$1" --arg p "$2" '{hook_event_name:"PreToolUse",tool_name:$t,tool_input:{file_path:$p,content:"x"}}' \
    | bash "$HOOK" 2>&1 >/dev/null)" || RC=$?
}
P="$TMP/companies/acme/policies"
mkdir -p "$P/_archive" "$TMP/notes"
printf -- '---\nid: alpha\n---\n' > "$P/alpha.md"

run Write "$P/alpha 2.md"
[ "$RC" = 2 ] && ok "a numbered sibling of an existing policy is refused" || bad "sibling allowed (rc=$RC)"
case "$ERR" in *"replacing 'alpha.md' in place"*) ok "the message names the file to replace" ;; *) bad "message: $ERR" ;; esac
run Write "$P/alpha 13.md"
[ "$RC" = 2 ] && ok "any number is refused" || bad "alpha 13 allowed"
run Edit "$P/alpha.md"
[ "$RC" = 0 ] && ok "editing the policy in place is allowed" || bad "in-place edit refused"
run Write "$P/beta 2.md"
[ "$RC" = 0 ] && ok "a numbered name with no original is allowed" || bad "beta 2 refused"
run Write "$P/alpha2.md"
[ "$RC" = 0 ] && ok "a slug ending in a digit is allowed" || bad "alpha2 refused"
printf 'old\n' > "$P/alpha 3.md"
run Edit "$P/alpha 3.md"
[ "$RC" = 0 ] && ok "an existing sibling can still be edited for cleanup" || bad "cleanup edit refused"
printf 'x\n' > "$TMP/notes/alpha.md"
run Write "$TMP/notes/alpha 2.md"
[ "$RC" = 0 ] && ok "outside a policies folder nothing is refused" || bad "non-policy path refused"
printf 'x\n' > "$P/_archive/alpha.md"
run Write "$P/_archive/alpha 2.md"
[ "$RC" = 0 ] && ok "subfolders of policies are not checked" || bad "archive path refused"

[ "$fails" -eq 0 ] && echo "block-numbered-policy-sibling: ok" || { echo "block-numbered-policy-sibling: $fails failure(s)"; exit 1; }
