#!/bin/bash
# repair-stale-review-base.sh — SessionStart hook
#
# An HQ root that is itself a git repo with a remote attached accumulates
# autosave commits its remote-tracking ref never receives (HQ is never pushed),
# and a review tool that auto-selects a comparison base from refs/remotes/*
# eventually builds a whole-tree payload from the stranded ref — the 2026-07-28
# Codex desktop git-worker SIGTRAP crash. This hook runs the detector at
# session start and, when a stale review base is found in a top-level HQ
# install, repairs it automatically so the operator never has to know the
# mechanism to be protected by the fix.
#
# The repair is core/scripts/detect-stale-review-base.sh --fix: it deletes only
# refs/remotes/* entries past the staleness thresholds. It never touches local
# branches, never removes the configured remote, never fetches or pushes, and a
# later `git fetch` recreates the ref — fully recoverable. The detector refuses
# to operate on anything that is not a top-level HQ install (repos/ clones and
# worktree checkouts are refused by position), so this hook is inert everywhere
# except the case it exists for.
#
# Opt-out: HQ_NO_STALE_BASE_AUTOFIX=1 downgrades the repair to an advisory
# banner (report only, nothing deleted). The hook is also gated by hook-gate.sh
# under the id "repair-stale-review-base", so HQ_DISABLED_HOOKS covers it too.
#
# Always exits 0 — session start must never be blocked by git health.

# Fail silently on ANY error — advisory infrastructure, never a blocker.
# No `set -e`, no `set -u`; belt-and-suspenders EXIT trap forces a clean exit.
trap 'exit 0' EXIT

# Consume stdin (master-hook passes the event payload even if empty).
cat >/dev/null 2>&1 || true

{

# The detector ships in the same tree as this hook — resolve it script-relative
# so the tool version always matches the hook version, and aim it at the
# session's project root. In production both are the same HQ install.
SELF_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd -P)"
TOOL="$SELF_DIR/../../core/scripts/detect-stale-review-base.sh"
[ -f "$TOOL" ] || exit 0

TARGET_ROOT="${CLAUDE_PROJECT_DIR:-$(cd "$SELF_DIR/../.." 2>/dev/null && pwd -P)}"
[ -d "$TARGET_ROOT" ] || exit 0

# Fast triage. Exit 0 = clean, exit 2 = refused (not a top-level HQ install) —
# both mean silence. Exit 1 = a stale review base exists.
bash "$TOOL" --root "$TARGET_ROOT" --check >/dev/null 2>&1
rc=$?
[ "$rc" -eq 1 ] || exit 0

if [ "${HQ_NO_STALE_BASE_AUTOFIX:-0}" = "1" ]; then
  REPORT="$(bash "$TOOL" --root "$TARGET_ROOT" 2>/dev/null || true)"
  cat <<EOF
<stale-review-base-advisory>
This HQ root carries a remote-tracking ref far behind local HEAD. A review tool
that auto-selects a comparison base (for example the Codex desktop app's
automatic review) will pick it and build a whole-tree payload, which is known
to crash its git worker. Automatic repair is disabled here
(HQ_NO_STALE_BASE_AUTOFIX=1), so nothing was changed.

$REPORT
</stale-review-base-advisory>
EOF
  exit 0
fi

RESULT="$(bash "$TOOL" --root "$TARGET_ROOT" --fix 2>/dev/null)" || exit 0
[ -n "$RESULT" ] || exit 0
cat <<EOF
<stale-review-base-repaired>
This HQ root carried a remote-tracking ref far behind local HEAD — the
condition that makes review tools which auto-select a comparison base (for
example the Codex desktop app's automatic review) build a whole-tree payload
and crash. It has been repaired:

$RESULT

Only the stale remote-tracking ref was removed. Local branches, history, and
the configured remote are untouched, and a later \`git fetch\` would recreate
the ref (HQ roots are not meant to be fetched). Set HQ_NO_STALE_BASE_AUTOFIX=1
to downgrade this repair to an advisory banner.
</stale-review-base-repaired>
EOF

} 2>/dev/null || true

exit 0
