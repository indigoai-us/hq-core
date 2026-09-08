#!/bin/bash
# context-warning-50.sh — RETIRED tombstone (2026-09-07).
#
# This was a Stop hook that printed a "context ~50%" checkpoint directive. It is
# retired for two reasons, both verified on this install:
#   1. Claude Code does not deliver Stop-hook stdout to the model, so the
#      directive was never seen; it fired into the void.
#   2. Its threshold was an uncalibrated transcript-size heuristic (1.75 MB with
#      the default window), so it either never fired or fired at the wrong time.
# Checkpointing now has exactly one mechanical trigger: PreCompact
# (auto-checkpoint-precompact.sh), whose output the model does receive.
#
# The file stays as an inert stub so stale settings, adapters, or caches that
# still name it get a silent no-op instead of a missing-file error. It is not
# registered in .claude/settings.json or hook-gate.sh. Do not re-register it.
cat >/dev/null 2>&1 || true
exit 0
