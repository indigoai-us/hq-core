#!/usr/bin/env bash
# hq-core: public
# Regression: protect-core.sh's locked-path deny message must NOT hand an agent a
# bare "set HQ_BYPASS_CORE_PROTECT to bypass" instruction. It must state that the
# bypass requires the human operator's EXPLICIT permission and that an agent must
# never set it autonomously.
#
# Why: a real grok -p --yolo run read the old bare message and self-bypassed core
# protection by writing HQ_BYPASS_CORE_PROTECT into the (writable)
# settings.local.json the message advertised. The wording is the guardrail.
set -euo pipefail
ROOT="$(git rev-parse --show-toplevel)"
HOOK="$ROOT/.claude/hooks/protect-core.sh"
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not available"; exit 0; }
command -v yq >/dev/null 2>&1 || { echo "SKIP: yq not available"; exit 0; }
fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "  ok: $*"; }
[ -f "$HOOK" ] || fail "hook not found: $HOOK"

PROJ="$(mktemp -d)"; trap 'rm -rf "$PROJ"' EXIT
mkdir -p "$PROJ/.claude/hooks" "$PROJ/core/scripts"
cat > "$PROJ/core/core.yaml" <<'YAML'
rules:
  locked:
    - core/
  exclude:
    - .claude/settings.local.json
  reviewable: []
YAML
export CLAUDE_PROJECT_DIR="$PROJ"

# Drive the hook on a locked core/ path; capture the deny stderr + exit code.
# (set +e: the hook exits 2, which would otherwise trip `set -e` on capture.)
PAYLOAD="$(printf '{"tool_input":{"file_path":"%s"}}' "$PROJ/core/scripts/evil.sh")"
set +e
ERR="$(printf '%s' "$PAYLOAD" | bash "$HOOK" 2>&1 >/dev/null)"
printf '%s' "$PAYLOAD" | bash "$HOOK" >/dev/null 2>&1
RC=$?
set -e

[ "$RC" -eq 2 ] || fail "expected exit 2 for locked core/ write, got $RC"
pass "locked core/ write is blocked (exit 2)"

# Flatten line wraps so phrase checks are not defeated by where the message wraps.
ERR_FLAT="$(printf '%s' "$ERR" | tr '\n' ' ' | tr -s ' ')"

# The hardened wording must be present.
grep -qiF "human operator's EXPLICIT permission" <<<"$ERR_FLAT" \
  || fail "deny message omits 'human operator's EXPLICIT permission': $ERR"
pass "message requires explicit human permission"

grep -qiF "never set this flag autonomously" <<<"$ERR_FLAT" \
  || fail "deny message omits 'never set this flag autonomously': $ERR"
pass "message forbids autonomous self-bypass"

grep -qiF "DO NOT enable it on your own" <<<"$ERR_FLAT" \
  || fail "deny message omits 'DO NOT enable it on your own': $ERR"
pass "message says do not enable on your own"

# The old bare, instructional phrasing must be gone.
if grep -qiE '^To bypass: set' <<<"$ERR"; then
  fail "deny message still leads with the bare 'To bypass: set …' instruction: $ERR"
fi
pass "no bare 'To bypass: set …' instruction remains"

echo "protect-core-bypass-wording: all passed"
