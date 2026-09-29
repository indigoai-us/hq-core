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

mesh_project_repo_source() {
  local repo_path="$1" candidate base parent common_dir
  if common_dir="$(git -C "$repo_path" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"; then
    dirname "$common_dir"
    return 0
  fi

  # The orchestrator may create the configured worktree during the child run
  # and remove it before this wrapper reports completion. Mirror its suffix
  # walk now so the source repository remains available for the later check.
  candidate="$repo_path"
  while [[ -n "$candidate" && "$candidate" != "$(dirname "$candidate")" ]]; do
    base="$(basename "$candidate")"
    parent="$(dirname "$candidate")"
    [[ "$base" == *-* ]] || break
    candidate="$parent/${base%-*}"
    if common_dir="$(git -C "$candidate" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"; then
      dirname "$common_dir"
      return 0
    fi
  done
  return 1
}

MESH_SOURCE_REPO=""
MESH_START_BRANCH_OID=""
mesh_capture_completion_snapshot() {
  local prd="$1" repo_path branch_name
  MESH_SOURCE_REPO=""
  MESH_START_BRANCH_OID=""
  if ! repo_path="$(jq -r '.metadata.repoPath // empty' "$prd" 2>/dev/null)"; then
    printf '%s\n' 'run-project: unable to read repository metadata for completion evidence; completion will not be claimed' >&2
    return 0
  fi
  [[ -n "$repo_path" ]] || return 0
  [[ "$repo_path" = /* ]] || repo_path="$HQ_ROOT/$repo_path"
  if MESH_SOURCE_REPO="$(mesh_project_repo_source "$repo_path")"; then
    if ! branch_name="$(jq -r '.branchName // empty' "$prd" 2>/dev/null)"; then
      printf '%s\n' 'run-project: unable to read project branch for completion evidence; completion will not be claimed' >&2
      MESH_SOURCE_REPO=""
      return 0
    fi
    if [[ -n "$branch_name" ]] && git -C "$MESH_SOURCE_REPO" \
      check-ref-format "refs/heads/$branch_name" >/dev/null 2>&1; then
      MESH_START_BRANCH_OID="$(git -C "$MESH_SOURCE_REPO" rev-parse --verify \
        "${branch_name}^{commit}" 2>/dev/null)" || MESH_START_BRANCH_OID=""
    fi
  else
    MESH_SOURCE_REPO=""
  fi
  return 0
}

mesh_project_complete() {
  local prd="$1" repo_path="${2:-}" start_branch_oid="${3:-}"
  local configured_repo branch_name base_branch commit_count current_branch_oid
  command -v jq >/dev/null 2>&1 || return 1
  jq -e '([.userStories[]? | select(.passes != true)] | length) == 0' "$prd" >/dev/null 2>&1 || return 1

  configured_repo="$(jq -r '.metadata.repoPath // empty' "$prd" 2>/dev/null)" || return 1
  # Keep projects without a configured repository on the story-pass contract;
  # there is no branch whose delivery evidence this wrapper can inspect.
  [[ -n "$configured_repo" ]] || return 0
  [[ -n "$repo_path" ]] || return 1

  branch_name="$(jq -r '.branchName // empty' "$prd" 2>/dev/null)" || return 1
  base_branch="$(jq -r '.metadata.baseBranch // "main"' "$prd" 2>/dev/null)" || return 1
  [[ -n "$branch_name" && -n "$base_branch" ]] || return 1
  git -C "$repo_path" check-ref-format "refs/heads/$branch_name" >/dev/null 2>&1 || return 1
  git -C "$repo_path" check-ref-format "refs/heads/$base_branch" >/dev/null 2>&1 || return 1
  # Direct-base projects need a commit created during this run as evidence.
  if [[ "$branch_name" == "$base_branch" ]]; then
    [[ -n "$start_branch_oid" ]] || return 1
    current_branch_oid="$(git -C "$repo_path" rev-parse --verify \
      "${branch_name}^{commit}" 2>/dev/null)" || return 1
    [[ "$current_branch_oid" != "$start_branch_oid" ]]
    return
  fi
  commit_count="$(git -C "$repo_path" rev-list --count "${base_branch}..${branch_name}" 2>/dev/null)" || return 1
  [[ "$commit_count" =~ ^[1-9][0-9]*$ ]]
}

mesh_report_start() {
  local project="$1" company="$2"
  command -v hq >/dev/null 2>&1 || return 0
  hq mesh session note --enqueue --session-id "${HQ_SESSION_ID:-run-project}" --seq 1 \
    --harness claude-code --adapter-version 1.0.0 \
    --company-slug "$company" --project "$project" \
    --summary "run-project started for $project" >/dev/null 2>&1 || true
}

mesh_report_finish() {
  local project="$1" company="$2" rc="$3" prd="$4"
  command -v hq >/dev/null 2>&1 || return 0
  local summary
  if [[ "$rc" == "0" ]] && [[ -n "$prd" ]] \
    && mesh_project_complete "$prd" "$MESH_SOURCE_REPO" "$MESH_START_BRANCH_OID"; then
    summary="run-project completed for $project"
  elif [[ "$rc" == "0" ]]; then
    summary="run-project made progress on $project"
  else
    summary="run-project exited with code $rc"
  fi
  hq mesh session note --enqueue --session-id "${HQ_SESSION_ID:-run-project}" --seq 1 \
    --harness claude-code --adapter-version 1.0.0 \
    --company-slug "$company" --project "$project" \
    --summary "$summary" >/dev/null 2>&1 || true
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
  mesh_capture_completion_snapshot "$PRD_FOR_MESH"
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
