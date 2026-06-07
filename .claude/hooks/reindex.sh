#!/bin/bash
# reindex.sh — thin hook shim.
#
# The implementation now lives in the @indigoai-us/hq-cloud package and is
# invoked via `hq reindex`. This shim preserves the historical hook path
# referenced by .claude/settings.json (Stop + PostToolUse Write/Edit/MultiEdit)
# so settings need no change: it reads and discards stdin (hook contract), then
# runs `hq reindex` against the HQ root.
#
# What `hq reindex` does (see the hq-cloud package for the script):
#   - surfaces namespaced skills as .claude/skills/<ns>:<skill>/ wrappers
#   - mirrors personal/{knowledge,policies,workers,settings} into core/
#   - prunes orphan wrappers + legacy command symlinks
#   - regenerates the workers registry
#
# `hq reindex` was formerly `hq master-sync` (renamed to avoid colliding with
# cloud `sync`); the CLI keeps a `master-sync` alias for one release, so this
# shim works whether the installed CLI is mid- or post-rename.
#
# Robustness: if the hq CLI isn't on PATH (e.g. a partial install), the shim
# exits cleanly so a missing binary never breaks a session. HQ_NO_UPDATE_CHECK
# is set so this hot hook never blocks on the CLI's network version gate or
# triggers an auto-update mid-session.

set -uo pipefail

# Read and discard stdin (hook contract).
cat > /dev/null

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

if command -v hq >/dev/null 2>&1; then
  HQ_NO_UPDATE_CHECK=1 hq reindex --repo-root "$REPO_ROOT" 1>&2 || true
fi

exit 0
