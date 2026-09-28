#!/usr/bin/env bash
# Remove only handoff mirrors that are byte-identical to the incoming branch,
# so clean-worktree's merge can recreate them from that branch.
set -euo pipefail

usage() {
  echo "Usage: clean-worktree-reconcile-handoff.sh <absolute-hq-root> <local-branch>" >&2
}

if [[ $# -ne 2 ]]; then
  usage
  exit 64
fi

HQ_ROOT="$1"
BRANCH="$2"
if [[ "$HQ_ROOT" != /* ]]; then
  echo "ERROR: HQ root must be an absolute path" >&2
  usage
  exit 64
fi
if [[ ! -d "$HQ_ROOT" ]]; then
  echo "ERROR: HQ root is not a directory: $HQ_ROOT" >&2
  exit 1
fi
HQ_ROOT="$(cd -P "$HQ_ROOT" && pwd -P)"
TOPLEVEL="$(git -C "$HQ_ROOT" rev-parse --show-toplevel 2>/dev/null)" || {
  echo "ERROR: HQ root is not a Git worktree: $HQ_ROOT" >&2
  exit 1
}
TOPLEVEL="$(cd -P "$TOPLEVEL" && pwd -P)"
if [[ "$TOPLEVEL" != "$HQ_ROOT" ]]; then
  echo "ERROR: supplied path is not the Git worktree root: $HQ_ROOT" >&2
  exit 1
fi

BRANCH_REF="refs/heads/$BRANCH"
if ! git -C "$HQ_ROOT" show-ref --verify --quiet "$BRANCH_REF"; then
  echo "ERROR: incoming branch does not exist locally: $BRANCH" >&2
  exit 1
fi

POINTER_PATH="workspace/threads/handoff.json"
if ! git -C "$HQ_ROOT" cat-file -e "$BRANCH_REF:$POINTER_PATH" 2>/dev/null; then
  echo "No incoming handoff pointer on $BRANCH; no mirror paths to reconcile."
  exit 0
fi

THREAD_PATH="$(git -C "$HQ_ROOT" show "$BRANCH_REF:$POINTER_PATH" | jq -er '.thread_path | select(type == "string")')" || {
  echo "ERROR: incoming branch handoff pointer has no string thread_path" >&2
  exit 1
}
case "$THREAD_PATH" in
  workspace/threads/*) ;;
  *) echo "ERROR: unsafe incoming handoff thread_path: $THREAD_PATH" >&2; exit 1 ;;
esac
case "/$THREAD_PATH/" in
  *"//"*|*"/./"*|*"/../"*)
    echo "ERROR: unsafe incoming handoff thread_path: $THREAD_PATH" >&2
    exit 1
    ;;
esac
if [[ "$THREAD_PATH" == "$POINTER_PATH" || "$THREAD_PATH" == *$'\n'* || "$THREAD_PATH" == *$'\r'* ]]; then
  echo "ERROR: unsafe incoming handoff thread_path: $THREAD_PATH" >&2
  exit 1
fi
if ! git -C "$HQ_ROOT" cat-file -e "$BRANCH_REF:$THREAD_PATH" 2>/dev/null; then
  echo "ERROR: incoming handoff thread is missing from $BRANCH: $THREAD_PATH" >&2
  exit 1
fi

branch_file_matches() {
  local relative_path="$1" local_file="$2" comparison_status=0
  if git -C "$HQ_ROOT" show "$BRANCH_REF:$relative_path" | cmp -s - "$local_file"; then
    return 0
  else
    comparison_status=$?
  fi
  if [[ "$comparison_status" -eq 1 ]]; then
    return 1
  fi
  return 2
}

declare -a mirror_paths=("$POINTER_PATH" "$THREAD_PATH")
declare -a identical_paths=()
declare -a differing_paths=()
for relative_path in "${mirror_paths[@]}"; do
  absolute_path="$HQ_ROOT/$relative_path"
  if [[ ! -e "$absolute_path" && ! -L "$absolute_path" ]]; then
    continue
  fi
  if [[ -L "$absolute_path" || ! -f "$absolute_path" ]]; then
    differing_paths+=("$relative_path (not a regular file)")
    continue
  fi
  comparison_status=0
  if branch_file_matches "$relative_path" "$absolute_path"; then
    identical_paths+=("$relative_path")
  else
    comparison_status=$?
    if [[ "$comparison_status" -eq 1 ]]; then
      differing_paths+=("$relative_path (content differs from $BRANCH)")
    else
      echo "ERROR: could not compare incoming $relative_path with $absolute_path" >&2
      exit 1
    fi
  fi
done

if [[ ${#differing_paths[@]} -gt 0 ]]; then
  for relative_path in "${differing_paths[@]}"; do
    echo "BLOCK: preserved main-checkout handoff path: $relative_path" >&2
  done
  echo "No mirror paths were removed; surface these local files before merging." >&2
  exit 2
fi

reconciliation_blocked=0
for relative_path in "${identical_paths[@]}"; do
  absolute_path="$HQ_ROOT/$relative_path"
  if [[ ! -e "$absolute_path" && ! -L "$absolute_path" ]]; then
    continue
  fi
  if [[ -L "$absolute_path" || ! -f "$absolute_path" ]]; then
    echo "BLOCK: preserved changed main-checkout path: $relative_path" >&2
    reconciliation_blocked=1
    continue
  fi

  destination_dir="$(dirname "$absolute_path")"
  moved_file="$(mktemp "$destination_dir/.clean-worktree-handoff.XXXXXX")"
  if ! mv "$absolute_path" "$moved_file"; then
    rm -f "$moved_file"
    echo "ERROR: could not safely move mirrored handoff path: $relative_path" >&2
    exit 1
  fi

  comparison_status=0
  if [[ ! -L "$moved_file" && -f "$moved_file" ]] && branch_file_matches "$relative_path" "$moved_file"; then
    if [[ -e "$absolute_path" || -L "$absolute_path" ]]; then
      rm -f "$moved_file"
      echo "BLOCK: a new main-checkout file appeared during reconciliation; preserved it: $relative_path" >&2
      reconciliation_blocked=1
    else
      rm "$moved_file"
      echo "Reconciled byte-identical handoff mirror: $relative_path"
    fi
  else
    comparison_status=$?
    if [[ ! -e "$absolute_path" && ! -L "$absolute_path" ]]; then
      if mv "$moved_file" "$absolute_path"; then
        echo "BLOCK: handoff path changed during reconciliation; restored it untouched: $relative_path" >&2
      else
        echo "BLOCK: handoff path changed during reconciliation; preserved it at $moved_file" >&2
      fi
    else
      echo "BLOCK: handoff path changed during reconciliation; preserved captured file at $moved_file and current path $absolute_path" >&2
    fi
    if [[ "$comparison_status" -gt 1 ]]; then
      echo "ERROR: could not compare incoming $relative_path with its moved file" >&2
      exit 1
    fi
    reconciliation_blocked=1
  fi
done

if [[ "$reconciliation_blocked" -ne 0 ]]; then
  echo "No merge should be attempted until the changed handoff paths are surfaced." >&2
  exit 2
fi
