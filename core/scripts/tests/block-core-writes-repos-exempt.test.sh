#!/usr/bin/env bash
# Regression: block-core-writes-bash.sh must NOT block edits to a checked-out
# repo's own scaffold (repos/<...>/.claude, repos/<...>/core, ...) -- those are
# legitimate dev edits, not writes to the LIVE HQ root. It must still block
# relative scaffold writes outside a repos/ context, and still block ABSOLUTE
# live-root writes even when the command also cd's into a repos/ checkout.
set -euo pipefail
ROOT="$(git rev-parse --show-toplevel)"
HOOK="$ROOT/.claude/hooks/block-core-writes-bash.sh"
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not available"; exit 0; }
fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "  ok: $*"; }
[ -f "$HOOK" ] || fail "hook not found: $HOOK"

# Isolated fake HQ root with NO settings.local.json so the HQ_BYPASS_CORE_PROTECT
# escape hatch is never active during the test (a real session may set it).
PROJ="$(mktemp -d)"; trap 'rm -rf "$PROJ"' EXIT
mkdir -p "$PROJ/.claude" "$PROJ/core" "$PROJ/repos"
export CLAUDE_PROJECT_DIR="$PROJ"

gate() { printf '%s' "$1" | jq -Rs '{tool_input:{command:.}}' | bash "$HOOK" >/dev/null 2>&1; echo $?; }
expect() { local want="$1" got; got="$(gate "$2")"; [ "$got" = "$want" ] || fail "want exit $want got $got for: $2"; pass "exit $want :: $3"; }

echo "[1] live-root relative writes (no repo context) are BLOCKED"
expect 2 'echo x > .claude/hooks/evil.sh'   'redirect into .claude'
expect 2 'chmod +x core/scripts/foo.sh'     'chmod core/'
expect 2 'rm -rf .claude/hooks'             'rm .claude'
expect 2 'cd /tmp/myrepos && rm .claude/x'  'myrepos/ is NOT a repos/ context'

echo "[2] edits inside a repos/ checkout are ALLOWED"
expect 0 'cd repos/private/x && chmod u+x .claude/hooks/hook-gate.sh' 'chmod repo .claude (relative cd)'
expect 0 'cd repos/private/x && echo hi > core/scripts/test.sh'       'redirect repo core (relative cd)'
expect 0 "cd $PROJ/repos/private/hq-pro && rm -rf .claude/old"        'rm repo .claude (absolute cd)'

echo "[3] ABSOLUTE live-root writes stay BLOCKED even with a repos/ cd"
expect 2 "cd $PROJ/repos/x && rm -rf $PROJ/.claude/hooks" 'absolute live-root rm despite repos cd'

echo "ALL PASS: block-core-writes-repos-exempt"
