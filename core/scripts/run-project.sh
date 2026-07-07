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
WORK_MESH="${HQ_ROOT}/core/scripts/work-mesh.sh"

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

mesh_project_arg() {
  local arg want_value=0
  for arg in "$@"; do
    if [[ "$want_value" == "1" ]]; then
      want_value=0
      continue
    fi
    case "$arg" in
      --help|-h|--status|--dry-run)
        return 1
        ;;
      --timeout|--max-workers|--branch|--repo|--company)
        want_value=1
        ;;
      --*)
        ;;
      *)
        printf '%s\n' "$arg"
        return 0
        ;;
    esac
  done
  return 1
}

mesh_project_prd() {
  local project="$1" prd
  shopt -s nullglob
  for prd in "$HQ_ROOT"/companies/*/projects/"$project"/prd.json; do
    printf '%s\n' "$prd"
    return 0
  done
  return 1
}

mesh_company_from_prd() {
  local prd="$1" company_dir
  company_dir="$(dirname "$(dirname "$(dirname "$prd")")")"
  basename "$company_dir"
}

mesh_project_complete() {
  local prd="$1"
  command -v jq >/dev/null 2>&1 || return 1
  jq -e '([.userStories[]? | select(.passes != true)] | length) == 0' "$prd" >/dev/null 2>&1
}

mesh_report_start() {
  local project="$1" company="$2"
  [[ -x "$WORK_MESH" ]] || return 0
  "$WORK_MESH" start --company "$company" --project "$project" \
    --summary "run-project started for $project" --silent >/dev/null 2>&1 || true
}

mesh_report_finish() {
  local project="$1" company="$2" rc="$3" prd="$4"
  [[ -x "$WORK_MESH" ]] || return 0
  if [[ "$rc" == "0" ]] && [[ -n "$prd" ]] && mesh_project_complete "$prd"; then
    "$WORK_MESH" done --company "$company" --project "$project" \
      --summary "run-project completed for $project" --silent >/dev/null 2>&1 || true
  elif [[ "$rc" == "0" ]]; then
    "$WORK_MESH" progress --company "$company" --project "$project" \
      --summary "run-project made progress on $project" --silent >/dev/null 2>&1 || true
  else
    "$WORK_MESH" blocked --company "$company" --project "$project" \
      --reason "run-project exited with code $rc" --silent >/dev/null 2>&1 || true
  fi
}

PROJECT_FOR_MESH="$(mesh_project_arg "$@" || true)"
COMPANY_FOR_MESH=""
PRD_FOR_MESH=""
if [[ -n "$PROJECT_FOR_MESH" ]]; then
  PRD_FOR_MESH="$(mesh_project_prd "$PROJECT_FOR_MESH" || true)"
fi
if [[ -n "$PRD_FOR_MESH" ]]; then
  COMPANY_FOR_MESH="$(mesh_company_from_prd "$PRD_FOR_MESH" || true)"
fi

if [[ -n "$PROJECT_FOR_MESH" && -n "$COMPANY_FOR_MESH" ]]; then
  mesh_report_start "$PROJECT_FOR_MESH" "$COMPANY_FOR_MESH"
fi

set +e
bash "$TARGET" "$@"
rc=$?
set -e

if [[ -n "$PROJECT_FOR_MESH" && -n "$COMPANY_FOR_MESH" ]]; then
  mesh_report_finish "$PROJECT_FOR_MESH" "$COMPANY_FOR_MESH" "$rc" "$PRD_FOR_MESH"
fi

exit "$rc"
