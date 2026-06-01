#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# run-project.sh — thin wrapper around the orchestrator script.
#
# The per-engine build path is RETIRED. `--ralph-mode` now runs the inline
# worker story loop unattended in the active session — see
# .claude/skills/run-project/SKILL.md. There is no detached subprocess, no
# `claude -p`, and no `--engine`/`--builder` engine selection.
#
# This wrapper's only job is to forward the still-live surface
# (--status / --dry-run / --help / <project> / --resume …) to the orchestrator
# script. Explicit --engine/--builder are rejected with a pointer to in-session
# ralph, because they selected the removed detached per-story builder.
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HQ_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
TARGET="${HQ_ROOT}/.claude/scripts/run-project.sh"

if [[ ! -f "$TARGET" ]]; then
  echo "ERROR: missing orchestrator script: $TARGET" >&2
  exit 1
fi

for arg in "$@"; do
  case "$arg" in
    --engine|--engine=*|--builder|--builder=*)
      echo "ERROR: run-project.sh no longer selects a build engine." >&2
      echo "Ralph runs in-session: /run-project <project> --ralph-mode" >&2
      echo "Live script surface: --status / --dry-run / --help (bare invocation runs the frozen codex fallback loop)." >&2
      exit 2
      ;;
  esac
done

exec bash "$TARGET" "$@"
