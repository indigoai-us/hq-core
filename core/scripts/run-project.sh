#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HQ_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
TARGET="${HQ_ROOT}/.claude/scripts/run-project.sh"
DETECT_CODEX="${SCRIPT_DIR}/lib/detect-codex.sh"

if [[ ! -f "$TARGET" ]]; then
  echo "ERROR: missing orchestrator script: $TARGET" >&2
  exit 1
fi

if [[ -f "$DETECT_CODEX" ]]; then
  # shellcheck source=core/scripts/lib/detect-codex.sh
  source "$DETECT_CODEX"
else
  running_from_codex() { return 1; }
fi

args=()
engine_explicit=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --engine)
      if [[ $# -lt 2 ]]; then
        echo "ERROR: --engine requires a value: auto or codex" >&2
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
        echo "ERROR: --builder requires a value: auto or codex" >&2
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

if [[ "$engine_explicit" == true ]]; then
  builder=""
  for ((i = 0; i < ${#args[@]}; i++)); do
    if [[ "${args[$i]}" == "--builder" ]]; then
      builder="${args[$((i + 1))]:-}"
      break
    fi
  done

  case "$builder" in
    codex|auto|"") ;;
    claude)
      echo "ERROR: Claude builder is not supported for run-project." >&2
      exit 2
      ;;
    *)
      echo "ERROR: unknown builder: $builder" >&2
      echo "Expected one of: auto, codex" >&2
      exit 1
      ;;
  esac
fi

if [[ "$engine_explicit" == false ]]; then
  args+=(--builder codex)
fi

exec bash "$TARGET" "${args[@]}"
