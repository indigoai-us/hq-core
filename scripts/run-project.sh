#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HQ_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TARGET="${HQ_ROOT}/.claude/scripts/run-project.sh"

if [[ ! -f "$TARGET" ]]; then
  echo "ERROR: missing orchestrator script: $TARGET" >&2
  exit 1
fi

args=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --engine)
      if [[ $# -lt 2 ]]; then
        echo "ERROR: --engine requires a value: claude or codex" >&2
        exit 1
      fi
      args+=(--builder "$2")
      shift 2
      ;;
    *)
      args+=("$1")
      shift
      ;;
  esac
done

exec bash "$TARGET" "${args[@]}"
