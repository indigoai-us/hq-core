#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HQ_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
TARGET="${HQ_ROOT}/.claude/scripts/run-project.sh"

if [[ ! -f "$TARGET" ]]; then
  echo "ERROR: missing orchestrator script: $TARGET" >&2
  exit 1
fi

# shellcheck source=lib/detect-codex.sh
source "${SCRIPT_DIR}/lib/detect-codex.sh"

args=()
engine_explicit=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --engine)
      if [[ $# -lt 2 ]]; then
        echo "ERROR: --engine requires a value: claude or codex" >&2
        exit 1
      fi
      args+=(--builder "$2")
      engine_explicit=true
      shift 2
      ;;
    --engine=*)
      args+=(--builder "${1#--engine=}")
      engine_explicit=true
      shift
      ;;
    --builder)
      if [[ $# -lt 2 ]]; then
        echo "ERROR: --builder requires a value: claude or codex" >&2
        exit 1
      fi
      args+=(--builder "$2")
      engine_explicit=true
      shift 2
      ;;
    --builder=*)
      args+=(--builder "${1#--builder=}")
      engine_explicit=true
      shift
      ;;
    *)
      args+=("$1")
      shift
      ;;
  esac
done

if [[ "$engine_explicit" == false ]] && running_from_codex; then
  args+=(--builder codex)
fi

exec bash "$TARGET" "${args[@]}"
