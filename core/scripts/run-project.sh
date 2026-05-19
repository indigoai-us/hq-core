#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HQ_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
TARGET="${HQ_ROOT}/.claude/scripts/run-project.sh"

if [[ ! -f "$TARGET" ]]; then
  echo "ERROR: missing orchestrator script: $TARGET" >&2
  exit 1
fi

args=()
engine_explicit=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --engine)
      if [[ $# -lt 2 ]]; then
        echo "ERROR: --engine requires a value: auto, claude, or codex" >&2
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
        echo "ERROR: --builder requires a value: auto, claude, or codex" >&2
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
    claude|auto|"") ;;
    codex)
      if [[ "${HQ_ALLOW_CODEX_OPAQUE_BUILDER:-}" != "1" ]]; then
        echo "ERROR: Codex builder is not worker-authoritative yet." >&2
        echo "Use --builder claude, or set HQ_ALLOW_CODEX_OPAQUE_BUILDER=1 to opt into opaque codex exec." >&2
        exit 2
      fi
      ;;
    *)
      echo "ERROR: unknown builder: $builder" >&2
      echo "Expected one of: auto, claude, codex" >&2
      exit 1
      ;;
  esac
fi

exec bash "$TARGET" "${args[@]}"
