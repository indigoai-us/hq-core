#!/usr/bin/env bash
# Regression: validate-policy-frontmatter.sh (PreToolUse Write/Edit/MultiEdit)
# blocks creating/editing a policy file whose RESULTING frontmatter lacks when:
# or on:, and leaves everything else alone. Also verifies the hook is live under
# all three hook-gate profiles (per hq-hook-gate-three-profile-lists).
set -euo pipefail
ROOT="$(git rev-parse --show-toplevel)"
HOOK="$ROOT/.claude/hooks/validate-policy-frontmatter.sh"
GATE="$ROOT/.claude/hooks/hook-gate.sh"
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not available"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 not available"; exit 0; }
fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "  ok: $*"; }
[ -f "$HOOK" ] || fail "hook not found: $HOOK"

PROJ="$(mktemp -d)"; trap 'rm -rf "$PROJ"' EXIT
mkdir -p "$PROJ/core/policies" "$PROJ/companies/acme/policies" "$PROJ/.claude/audit/policies" "$PROJ/repos/private/x/.claude/policies"
export CLAUDE_PROJECT_DIR="$PROJ"

GOOD=$'---\nid: hq-x\nwhen: git && push\non: [PreToolUse]\nenforcement: soft\n---\n## Rule\nx\n'
NOWHENON=$'---\nid: hq-x\ntitle: X\nenforcement: soft\n---\n## Rule\nx\n'
NOON=$'---\nid: hq-x\nwhen: always\nenforcement: soft\n---\nx\n'
NOWHEN=$'---\nid: hq-x\non: [SessionStart]\nenforcement: soft\n---\nx\n'

wrc() { printf '%s' "$1" | bash "$HOOK" >/dev/null 2>&1; echo $?; }
wp() { jq -nc --arg fp "$1" --arg c "$2" '{tool_input:{file_path:$fp,content:$c}}'; }
ep() { jq -nc --arg fp "$1" --arg o "$2" --arg n "$3" '{tool_input:{file_path:$fp,old_string:$o,new_string:$n}}'; }
exp() { local want="$1" got; got="$(wrc "$2")"; [ "$got" = "$want" ] || fail "want $want got $got :: $3"; pass "$3"; }

echo "[1] Write: policy with when+on ALLOWED; missing BLOCKED"
exp 0 "$(wp "$PROJ/core/policies/ok.md"   "$GOOD")"     "core policy with when/on -> allow"
exp 2 "$(wp "$PROJ/core/policies/bad.md"  "$NOWHENON")" "core policy missing when+on -> block"
exp 2 "$(wp "$PROJ/core/policies/bad2.md" "$NOON")"     "core policy missing on -> block"
exp 2 "$(wp "$PROJ/core/policies/bad3.md" "$NOWHEN")"   "core policy missing when -> block"
exp 2 "$(wp "$PROJ/core/policies/nofm.md" "no frontmatter here")" "policy with no frontmatter -> block"

echo "[2] scope coverage: company + repo policies enforced too"
exp 2 "$(wp "$PROJ/companies/acme/policies/x.md" "$NOWHENON")"     "company policy missing -> block"
exp 2 "$(wp "$PROJ/repos/private/x/.claude/policies/y.md" "$NOON")" "repo policy missing -> block"

echo "[3] exclusions: non-policy, audit store, README allowed; retired digest blocked"
exp 0 "$(wp "$PROJ/core/scripts/foo.sh" "echo hi")"                       "non-policy path -> allow"
exp 0 "$(wp "$PROJ/.claude/audit/policies/repo-internal-codes.md" "$NOWHENON")" "audit redaction rule -> allow"
exp 0 "$(wp "$PROJ/core/policies/README.md" "no frontmatter")"            "policies/README.md -> allow"
exp 2 "$(wp "$PROJ/core/policies/_digest.md" "no frontmatter")"           "retired policies/_digest.md path -> block"

echo "[4] Edit / MultiEdit reflect the RESULTING content"
POL="$PROJ/core/policies/live.md"; printf '%s' "$GOOD" > "$POL"
exp 0 "$(ep "$POL" "x" "y")"                             "edit body only -> allow"
exp 2 "$(ep "$POL" $'when: git && push\n' "")"           "edit removes when -> block"
ME="$(jq -nc --arg fp "$POL" '{tool_input:{file_path:$fp,edits:[{old_string:"on: [PreToolUse]\n",new_string:""}]}}')"
exp 2 "$ME" "multiedit removes on -> block"

echo "[5] operator override allows the write"
got="$(printf '%s' "$(wp "$PROJ/core/policies/bad.md" "$NOWHENON")" | HQ_ALLOW_POLICY_NO_TRIGGER=1 bash "$HOOK" >/dev/null 2>&1; echo $?)"
[ "$got" = "0" ] || fail "override should allow, got $got"; pass "HQ_ALLOW_POLICY_NO_TRIGGER=1 -> allow"

echo "[6] LIVE under all three hook-gate profiles (must block, rc=2)"
for p in minimal standard strict; do
  rc="$(printf '%s' "$(wp "$PROJ/core/policies/bad.md" "$NOWHENON")" | HQ_HOOK_PROFILE=$p bash "$GATE" validate-policy-frontmatter "$HOOK" >/dev/null 2>&1; echo $?)"
  [ "$rc" = "2" ] || fail "profile $p: want rc 2 got $rc (hook dead under this profile)"; pass "gate profile $p -> block"
done

echo "PASS: validate-policy-frontmatter"
