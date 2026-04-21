#!/bin/bash
# check-repo-active-runs.sh — SessionStart hook (non-blocking)
#
# Emits a banner when the current working directory is inside a repo that
# is currently owned by another Claude session running /run-project,
# /execute-task, or similar. The banner tells the new session to:
#   1. Avoid edits (they will be hard-blocked by block-on-active-run.sh)
#   2. Branch into a git worktree for parallel work
#   3. Or wait for the owning session to finish
#
# Runs the registry 'check' subcommand from a "foreign" perspective by
# passing pid=0 session=__new__ so the registry returns all covering
# entries (there is no match-self exception yet — this is a fresh session).
#
# Exit codes: always 0 (SessionStart hooks cannot block session startup)

set -euo pipefail

# Read and discard stdin
cat >/dev/null 2>&1 || true

HQ_ROOT="${HQ_ROOT:-${HOME}/Documents/HQ}"
REGISTRY="$HQ_ROOT/scripts/repo-run-registry.sh"

[[ ! -x "$REGISTRY" ]] && exit 0

CWD="$(pwd)"

# Quick bail-out: if cwd is literally HQ_ROOT, don't banner (we'd only be
# warning about HQ itself, and HQ is rarely the target of a /run-project).
# Any subdir walk-up will still catch the check.
TARGET="$CWD"

# Pid 0 / synthetic session-id guarantees "no self-match" so check() treats
# the current shell as a foreign caller and returns all covering entries.
OUTPUT=""
STATUS=0
if OUTPUT=$("$REGISTRY" check --target "$TARGET" --pid 0 --session-id "__sessionstart__" 2>&1); then
  STATUS=0
else
  STATUS=$?
fi

# Exit 2 from the registry means: foreign owner(s) cover this path.
# Registry prints owner rows on stderr (captured here via 2>&1).
if [[ $STATUS -eq 2 && -n "$OUTPUT" ]]; then
  cat <<BANNER
<active-runs-warning>
WARNING: This directory is inside a repo currently owned by another Claude session.
Concurrent edits, deletes, and dangerous bash will be HARD-BLOCKED by block-on-active-run.sh.

Active run(s):
$OUTPUT

Recommended options:
  1. Read-only exploration is allowed — Read/Grep/Glob/qmd will not be blocked.
  2. For parallel work: create a git worktree in a sibling directory and cd into it.
       git -C <repo> worktree add ../<repo>-wt-<branch> <branch>
     Worktrees that are not registered as owned can be edited freely.
  3. Wait for the owning session to finish. Stale entries auto-clear after the
     heartbeat timeout (default 15 min) or when the owning PID dies.
  4. Emergency bypass (use with caution, logged to workspace/learnings/):
       export HQ_IGNORE_ACTIVE_RUNS=1
     or pass --ignore-active-runs to /run-project.

Registry: workspace/orchestrator/active-runs.json
Policy:   .claude/policies/repo-run-coordination.md
</active-runs-warning>
BANNER
fi

exit 0
