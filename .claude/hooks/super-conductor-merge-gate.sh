#!/usr/bin/env bash
# A merge from a /super-conductor session (the conductor or a lane on its
# link) needs an answered decision row for that repo, PR and head. The logic
# is core/scripts/super-conductor-merge-gate.mjs; sessions on no link, or on a
# link with no decision queue, are not gated. With no node the hook allows,
# like the other PreToolUse shims.
set -uo pipefail
command -v node >/dev/null 2>&1 || exit 0
root="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd)}"
script="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd)/core/scripts/super-conductor-merge-gate.mjs"
[ -f "$script" ] || exit 0
node "$script" hook "$root" 2>/dev/null || true
exit 0
