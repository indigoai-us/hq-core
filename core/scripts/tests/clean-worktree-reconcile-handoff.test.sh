#!/usr/bin/env bash
# Regression tests for core/scripts/clean-worktree-reconcile-handoff.sh.
# Keeps coverage for byte-identical mirror reconciliation, differing-pointer
# refusal, and unsafe thread_path rejection after handoff-finalize.sh removal.
set -euo pipefail

SRC_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$SRC_ROOT/scripts/clean-worktree-reconcile-handoff.sh"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/var/tmp}/clean-worktree-reconcile.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

pass() {
  echo "  ok: $*"
}

[ -f "$SCRIPT" ] || fail "missing script: $SCRIPT"

scaffold_repo() {
  local repo="$1"
  mkdir -p "$repo/core/scripts" "$repo/workspace/threads"
  cp "$SCRIPT" "$repo/core/scripts/clean-worktree-reconcile-handoff.sh"
  chmod +x "$repo/core/scripts/clean-worktree-reconcile-handoff.sh"
  printf '%s\n' '{"old":true,"last_thread":"T-base","thread_path":"workspace/threads/T-base.json"}' \
    > "$repo/workspace/threads/handoff.json"
  git -C "$repo" init -q
  git -C "$repo" config user.email test@example.test
  git -C "$repo" config user.name "Clean Worktree Reconcile Test"
  git -C "$repo" config core.hooksPath /dev/null
  git -C "$repo" add core/scripts workspace
  git -C "$repo" commit -qm "test fixture"
}

test_reconciles_only_matching_handoff_mirrors() {
  local main_repo="$TMP_ROOT/reconcile-main" linked_repo="$TMP_ROOT/reconcile-linked"
  local base_head thread_id thread_path pointer_path mirrored_pointer held_thread
  local merge_output merge_status reconcile_output reconcile_status

  scaffold_repo "$main_repo"
  base_head="$(git -C "$main_repo" rev-parse HEAD)"
  git -C "$main_repo" worktree add -q -b wt-reconcile "$linked_repo" HEAD

  thread_id="T-reconcile-01"
  thread_path="workspace/threads/${thread_id}.json"
  pointer_path="$main_repo/workspace/threads/handoff.json"
  mirrored_pointer="$TMP_ROOT/reconcile-mirrored-pointer.json"
  held_thread="$TMP_ROOT/reconcile-held-thread.json"

  # Commit a new thread and pointer on the linked worktree branch, then mirror
  # both files byte-identically into the main checkout (matching handoff finalize).
  printf '{"thread_id":"%s","summary":"linked handoff"}\n' "$thread_id" > "$linked_repo/$thread_path"
  printf '{"last_thread":"%s","thread_path":"%s"}\n' "$thread_id" "$thread_path" \
    > "$linked_repo/workspace/threads/handoff.json"
  git -C "$linked_repo" add "$thread_path" workspace/threads/handoff.json
  git -C "$linked_repo" commit -qm "linked worktree handoff"

  cp "$linked_repo/$thread_path" "$main_repo/$thread_path"
  cp "$linked_repo/workspace/threads/handoff.json" "$pointer_path"
  cp "$pointer_path" "$mirrored_pointer"

  # 1. Without reconciliation, dirty tracked pointer mirror blocks merge.
  mv "$main_repo/$thread_path" "$held_thread"
  merge_status=0
  merge_output="$(git -C "$main_repo" merge --no-ff --no-edit wt-reconcile 2>&1)" || merge_status=$?
  [[ "$merge_status" -ne 0 ]] || fail "merge unexpectedly succeeded while tracked pointer mirror was dirty"
  case "$merge_output" in
    *"local changes to the following files would be overwritten by merge"*) ;;
    *) fail "merge did not report tracked pointer collision: $merge_output" ;;
  esac
  mv "$held_thread" "$main_repo/$thread_path"
  pass "without reconciliation, tracked handoff pointer mirror blocks merge"

  # 2. Without reconciliation, untracked thread mirror blocks merge.
  git -C "$main_repo" show "$base_head:workspace/threads/handoff.json" > "$TMP_ROOT/reconcile-base-pointer.json"
  cp "$TMP_ROOT/reconcile-base-pointer.json" "$pointer_path"
  merge_status=0
  merge_output="$(git -C "$main_repo" merge --no-ff --no-edit wt-reconcile 2>&1)" || merge_status=$?
  [[ "$merge_status" -ne 0 ]] || fail "merge unexpectedly succeeded while untracked thread mirror was present"
  case "$merge_output" in
    *"untracked working tree files would be overwritten by merge"*) ;;
    *) fail "merge did not report untracked thread collision: $merge_output" ;;
  esac
  pass "without reconciliation, untracked copied thread blocks merge"

  # 3. Reconciliation removes both byte-identical mirrors so merge succeeds and restores them.
  cp "$mirrored_pointer" "$pointer_path"
  reconcile_output="$(bash "$main_repo/core/scripts/clean-worktree-reconcile-handoff.sh" "$main_repo" wt-reconcile 2>&1)" \
    || fail "matching handoff mirrors were not reconciled: $reconcile_output"
  [[ "$reconcile_output" == *"Reconciled byte-identical handoff mirror: workspace/threads/handoff.json"* ]] \
    || fail "reconcile did not remove identical handoff pointer: $reconcile_output"
  [[ "$reconcile_output" == *"Reconciled byte-identical handoff mirror: $thread_path"* ]] \
    || fail "reconcile did not remove identical copied thread: $reconcile_output"
  [[ ! -e "$pointer_path" && ! -e "$main_repo/$thread_path" ]] \
    || fail "reconcile left byte-identical mirror files in main checkout"
  git -C "$main_repo" merge --no-ff --no-edit wt-reconcile >/dev/null 2>&1 \
    || fail "merge failed after matching handoff mirrors were reconciled"
  git -C "$main_repo" show "wt-reconcile:workspace/threads/handoff.json" \
    | cmp -s - "$pointer_path" || fail "merge did not restore incoming handoff pointer"
  git -C "$main_repo" show "wt-reconcile:$thread_path" \
    | cmp -s - "$main_repo/$thread_path" || fail "merge did not restore incoming thread file"
  pass "reconciliation removes byte-identical mirrors and merge restores them from the branch"

  # 4. A differing local pointer blocks with exit 2 and leaves both files untouched.
  printf '%s\n' '{"local":"keep this pointer"}' > "$pointer_path"
  cp "$pointer_path" "$TMP_ROOT/reconcile-different-pointer.json"
  reconcile_status=0
  reconcile_output="$(bash "$main_repo/core/scripts/clean-worktree-reconcile-handoff.sh" "$main_repo" wt-reconcile 2>&1)" \
    || reconcile_status=$?
  [[ "$reconcile_status" -eq 2 ]] || fail "different local pointer did not block reconciliation (exit $reconcile_status): $reconcile_output"
  [[ "$reconcile_output" == *"preserved main-checkout handoff path: workspace/threads/handoff.json"* ]] \
    || fail "different local pointer was not reported: $reconcile_output"
  cmp -s "$TMP_ROOT/reconcile-different-pointer.json" "$pointer_path" \
    || fail "reconciliation changed a pointer that differed from the branch"
  [[ -f "$main_repo/$thread_path" ]] \
    || fail "reconciliation removed the matching thread when the pointer differed"
  pass "differing main-checkout pointer is reported and left untouched"
}

test_rejects_unsafe_thread_path() {
  local repo="$TMP_ROOT/unsafe-path"
  local status=0 out=""
  scaffold_repo "$repo"
  git -C "$repo" checkout -q -b wt-unsafe
  printf '%s\n' '{"last_thread":"T-bad","thread_path":"workspace/threads/../evil.json"}' \
    > "$repo/workspace/threads/handoff.json"
  git -C "$repo" add workspace/threads/handoff.json
  git -C "$repo" commit -qm "unsafe pointer"
  git -C "$repo" checkout -q -

  out="$(bash "$repo/core/scripts/clean-worktree-reconcile-handoff.sh" "$repo" wt-unsafe 2>&1)" || status=$?
  [[ "$status" -eq 1 ]] || fail "unsafe thread_path exited $status (want 1): $out"
  [[ "$out" == *"unsafe incoming handoff thread_path"* ]] \
    || fail "unsafe thread_path did not report rejection: $out"
  pass "unsafe incoming thread_path is rejected"
}

test_reconciles_only_matching_handoff_mirrors
test_rejects_unsafe_thread_path
echo "PASS: clean-worktree-reconcile-handoff"
