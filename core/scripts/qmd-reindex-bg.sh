#!/usr/bin/env bash
# FORWARDER — the implementation of this script now lives in the hq CLI.
#
# It runs as `hq index background`. This file stays behind so every existing
# caller — skills, other scripts, CI, and muscle memory — keeps working against
# the path it already knows.
#
# Why the implementation moved: the single-flight background reindex is a
# durable state machine (lock ownership, stale reclaim, completion stamps,
# signal cleanup) that belongs in tested code rather than 700 lines of shell.
#
# Equivalence is not assumed. hq-cli's e2e/qmd-background-differential.test.ts
# runs a byte-frozen copy of this script's pre-migration source against the CLI
# over identical injected worlds and compares exit status, stdout, the qmd argv
# sequence, and the resulting lock/stamp state: agent short-circuit before any
# qmd lookup or lock, empty-HOME silence, cleanup->update->embed ordering with a
# completion stamp, no stamp after a failed update, and no competing writer
# behind a held lock.
#
# ONE INTENDED DIVERGENCE: this script printed "skipped" when no qmd was on
# PATH. The CLI bundles qmd (@tobilu/qmd is a dependency, resolved via
# node_modules/.bin since hq-cli 5.94.1), so it proceeds instead of skipping.
# That is the point of bundling; see hq-cli#333.
#
# The ABI is otherwise preserved: arguments are forwarded unchanged, stdin is
# never read by this file, stdout and stderr are inherited untouched, and the
# child replaces this process so its exit code and signal disposition become the
# caller's.

set -euo pipefail

HQ_ROOT="${HQ_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

if ! command -v hq >/dev/null 2>&1; then
  echo "qmd-reindex-bg.sh: requires the hq CLI — this script's implementation now ships with it." >&2
  echo "Install it with: npm install -g @indigoai-us/hq-cli" >&2
  exit 127
fi

exec hq index background --hq-root "$HQ_ROOT" "$@"
