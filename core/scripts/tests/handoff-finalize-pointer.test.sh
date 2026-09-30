#!/usr/bin/env bash
# Regression tests for atomic, main-checkout-visible handoff pointers.
set -euo pipefail

SRC_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/var/tmp}/handoff-pointer-test.XXXXXX")"
TEST_BIN="$TMP_ROOT/bin"
mkdir -p "$TEST_BIN"
REAL_JQ="$(command -v jq)"
ACTIVE_PID=""
ATOMIC_RELEASE="$TMP_ROOT/atomic.release"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

pass() {
  echo "  ok: $*"
}

cleanup() {
  if [[ -n "$ACTIVE_PID" ]]; then
    : > "$ATOMIC_RELEASE"
    wait "$ACTIVE_PID" 2>/dev/null || true
  fi
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

scaffold_repo() {
  local repo="$1"
  mkdir -p "$repo/core/scripts/lib" "$repo/workspace/baseline" "$repo/workspace/threads" \
    "$repo/workspace/orchestrator" "$repo/home"
  cp "$SRC_ROOT/scripts/handoff-finalize.sh" "$repo/core/scripts/handoff-finalize.sh"
  cp "$SRC_ROOT/scripts/lib/session-id.sh" "$repo/core/scripts/lib/session-id.sh"
  cp "$SRC_ROOT/scripts/clean-worktree-reconcile-handoff.sh" "$repo/core/scripts/clean-worktree-reconcile-handoff.sh"
  cp "$SRC_ROOT/scripts/hq-status-summary.sh" "$repo/core/scripts/hq-status-summary.sh"
  cp "$SRC_ROOT/scripts/qmd-reindex-bg.sh" "$repo/core/scripts/qmd-reindex-bg.sh"
  chmod +x "$repo/core/scripts/"*.sh
  printf '%s\n' '{"categories":[{"name":"baseline","patterns":["companies/*","workspace/*","repos/*","core/settings/*",".hq/*"]}]}' \
    > "$repo/workspace/baseline/hq-local-baseline.json"
  printf '%s\n' '{"old":true}' > "$repo/workspace/threads/handoff.json"
  git -C "$repo" init -q
  git -C "$repo" config user.email test@example.test
  git -C "$repo" config user.name "US-083 Handoff Pointer Test"
  git -C "$repo" add core/scripts workspace
  git -C "$repo" commit -qm "test fixture"
}

run_finalize() {
  local repo="$1"
  (
    cd "$repo"
    HQ_ROOT="$repo" HOME="$repo/home" PATH="$TEST_BIN:/usr/bin:/bin" \
      bash core/scripts/handoff-finalize.sh \
        --title "Handoff: pointer test" \
        --summary "synthetic pointer verification" \
        --message "synthetic pointer verification" \
        --next-steps-json '[]' \
        --files-touched-json '[]' \
        --learnings-json '[]' \
        --tags-json '["handoff"]' \
        --slug "us083-pointer"
  )
}

test_linked_worktree_copies_thread_and_updates_main_pointer() {
  local main_repo="$TMP_ROOT/worktree-main" linked_repo="$TMP_ROOT/worktree-linked"
  scaffold_repo "$main_repo"
  git -C "$main_repo" worktree add -q -b us083-linked "$linked_repo" HEAD
  local out thread_id pointer_path resolved_thread
  out="$(run_finalize "$linked_repo")" || fail "handoff finalize failed in linked worktree"
  thread_id="$(jq -r '.thread_id' <<<"$out")"
  pointer_path="$main_repo/workspace/threads/handoff.json"
  [[ -f "$pointer_path" ]] || fail "main checkout handoff pointer was not written"
  [[ "$(jq -r '.last_thread' "$pointer_path")" == "$thread_id" ]] \
    || fail "main checkout pointer does not name the linked-worktree thread"
  resolved_thread="$(jq -r '.thread_path' "$pointer_path")"
  [[ "$resolved_thread" == "workspace/threads/$thread_id.json" ]] \
    || fail "main checkout pointer thread_path is not portable: $resolved_thread"
  [[ -f "$main_repo/$resolved_thread" ]] || fail "main checkout pointer cannot reach its copied thread file: $resolved_thread"
  cmp -s "$linked_repo/$resolved_thread" "$main_repo/$resolved_thread" \
    || fail "copied main-checkout thread differs from the linked-worktree thread"
  [[ "$(jq -r '.last_thread' "$linked_repo/workspace/threads/handoff.json")" == "$thread_id" ]] \
    || fail "linked-worktree pointer does not name its own thread"
  pass "linked-worktree handoff copies its thread and updates the main pointer with a portable path"
}

test_clean_worktree_reconciles_only_matching_handoff_mirrors() {
  local main_repo="$TMP_ROOT/reconcile-main" linked_repo="$TMP_ROOT/reconcile-linked"
  local base_head thread_id thread_path pointer_path mirrored_pointer held_thread
  local merge_output merge_status reconcile_output reconcile_status
  scaffold_repo "$main_repo"
  base_head="$(git -C "$main_repo" rev-parse HEAD)"
  git -C "$main_repo" worktree add -q -b us083-reconcile "$linked_repo" HEAD
  local out
  out="$(run_finalize "$linked_repo")" || fail "handoff finalize failed in reconcile worktree"
  thread_id="$(jq -r '.thread_id' <<<"$out")"
  thread_path="workspace/threads/$thread_id.json"
  pointer_path="$main_repo/workspace/threads/handoff.json"
  mirrored_pointer="$TMP_ROOT/reconcile-mirrored-pointer.json"
  held_thread="$TMP_ROOT/reconcile-held-thread.json"
  [[ -f "$main_repo/$thread_path" ]] || fail "main-checkout thread mirror is missing"
  cp "$pointer_path" "$mirrored_pointer"

  mv "$main_repo/$thread_path" "$held_thread"
  merge_status=0
  merge_output="$(git -C "$main_repo" merge --no-ff --no-edit us083-reconcile 2>&1)" || merge_status=$?
  [[ "$merge_status" -ne 0 ]] || fail "merge unexpectedly succeeded while the tracked pointer mirror was dirty"
  case "$merge_output" in
    *"local changes to the following files would be overwritten by merge"*) ;;
    *) fail "merge did not report the tracked pointer collision: $merge_output" ;;
  esac
  mv "$held_thread" "$main_repo/$thread_path"
  pass "without reconciliation, the tracked handoff pointer mirror blocks the merge"

  git -C "$main_repo" show "$base_head:workspace/threads/handoff.json" > "$TMP_ROOT/reconcile-base-pointer.json"
  cp "$TMP_ROOT/reconcile-base-pointer.json" "$pointer_path"
  merge_status=0
  merge_output="$(git -C "$main_repo" merge --no-ff --no-edit us083-reconcile 2>&1)" || merge_status=$?
  [[ "$merge_status" -ne 0 ]] || fail "merge unexpectedly succeeded while the untracked thread mirror was present"
  case "$merge_output" in
    *"untracked working tree files would be overwritten by merge"*) ;;
    *) fail "merge did not report the untracked thread collision: $merge_output" ;;
  esac
  pass "without reconciliation, the untracked copied thread blocks the merge"

  cp "$mirrored_pointer" "$pointer_path"
  reconcile_output="$(bash "$main_repo/core/scripts/clean-worktree-reconcile-handoff.sh" "$main_repo" us083-reconcile 2>&1)" \
    || fail "matching handoff mirrors were not reconciled: $reconcile_output"
  [[ "$reconcile_output" == *"Reconciled byte-identical handoff mirror: workspace/threads/handoff.json"* ]] \
    || fail "reconcile did not remove the identical handoff pointer: $reconcile_output"
  [[ "$reconcile_output" == *"Reconciled byte-identical handoff mirror: $thread_path"* ]] \
    || fail "reconcile did not remove the identical copied thread: $reconcile_output"
  [[ ! -e "$pointer_path" && ! -e "$main_repo/$thread_path" ]] \
    || fail "reconcile left byte-identical mirror files in the main checkout"
  git -C "$main_repo" merge --no-ff --no-edit us083-reconcile >/dev/null 2>&1 \
    || fail "merge failed after matching handoff mirrors were reconciled"
  git -C "$main_repo" show "us083-reconcile:workspace/threads/handoff.json" \
    | cmp -s - "$pointer_path" || fail "merge did not restore the incoming handoff pointer"
  git -C "$main_repo" show "us083-reconcile:$thread_path" \
    | cmp -s - "$main_repo/$thread_path" || fail "merge did not restore the incoming thread file"
  pass "reconciliation removes both byte-identical mirrors and merge restores them from the branch"

  printf '%s\n' '{"local":"keep this pointer"}' > "$pointer_path"
  cp "$pointer_path" "$TMP_ROOT/reconcile-different-pointer.json"
  reconcile_status=0
  reconcile_output="$(bash "$main_repo/core/scripts/clean-worktree-reconcile-handoff.sh" "$main_repo" us083-reconcile 2>&1)" \
    || reconcile_status=$?
  [[ "$reconcile_status" -eq 2 ]] || fail "different local pointer did not block reconciliation (exit $reconcile_status): $reconcile_output"
  [[ "$reconcile_output" == *"preserved main-checkout handoff path: workspace/threads/handoff.json"* ]] \
    || fail "different local pointer was not reported: $reconcile_output"
  cmp -s "$TMP_ROOT/reconcile-different-pointer.json" "$pointer_path" \
    || fail "reconciliation changed a pointer that differed from the branch"
  [[ -f "$main_repo/$thread_path" ]] \
    || fail "reconciliation removed the matching thread when the pointer differed"
  pass "a differing main-checkout pointer is reported and left untouched"
}

install_slow_jq() {
  cat > "$TEST_BIN/jq" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
is_pointer=0
for arg in "$@"; do
  case "$arg" in
    *'last_thread: $thread_id'*) is_pointer=1 ;;
  esac
done
if [[ "$is_pointer" -eq 1 && "${US083_ATOMIC_TEST:-}" == "1" ]]; then
  rendered="$("$US083_REAL_JQ" "$@")"
  printf '%s' "${rendered:0:5}"
  : > "$US083_ATOMIC_STARTED"
  while [[ ! -f "$US083_ATOMIC_RELEASE" ]]; do sleep 0.01; done
  printf '%s' "${rendered:5}"
  printf '\n'
  exit 0
fi
exec "$US083_REAL_JQ" "$@"
SH
  chmod +x "$TEST_BIN/jq"
}

test_pointer_is_atomically_replaced_in_its_directory() {
  local repo="$TMP_ROOT/atomic-repo" marker="$TMP_ROOT/atomic.started"
  scaffold_repo "$repo"
  cp "$repo/workspace/threads/handoff.json" "$TMP_ROOT/old-pointer.json"
  install_slow_jq
  (
    cd "$repo"
    HQ_ROOT="$repo" HOME="$repo/home" PATH="$TEST_BIN:/usr/bin:/bin" \
      US083_ATOMIC_TEST=1 US083_REAL_JQ="$REAL_JQ" \
      US083_ATOMIC_STARTED="$marker" US083_ATOMIC_RELEASE="$ATOMIC_RELEASE" \
      bash core/scripts/handoff-finalize.sh \
        --title "Handoff: atomic pointer test" \
        --summary "synthetic pointer verification" \
        --message "synthetic pointer verification" \
        --files-touched-json '[]' \
        --learnings-json '[]' \
        --tags-json '["handoff"]' \
        --slug "us083-atomic"
  ) >"$TMP_ROOT/atomic.stdout" 2>"$TMP_ROOT/atomic.stderr" &
  ACTIVE_PID=$!

  local attempt temp_file=""
  for ((attempt = 0; attempt < 500; attempt++)); do
    [[ -f "$marker" ]] && break
    if ! kill -0 "$ACTIVE_PID" 2>/dev/null; then
      fail "handoff finalizer exited before reaching the pointer write: $(cat "$TMP_ROOT/atomic.stderr")"
    fi
    sleep 0.01
  done
  [[ -f "$marker" ]] || fail "timed out waiting for the pointer writer"
  cmp -s "$TMP_ROOT/old-pointer.json" "$repo/workspace/threads/handoff.json" \
    || fail "handoff pointer became partial or changed before atomic rename"
  for candidate in "$repo"/workspace/threads/.handoff-pointer.*; do
    [[ -f "$candidate" ]] && temp_file="$candidate" && break
  done
  [[ -n "$temp_file" ]] || fail "pointer temp file was not created beside handoff.json"
  [[ "$(cd "$(dirname "$temp_file")" && pwd -P)" == "$(cd "$repo/workspace/threads" && pwd -P)" ]] \
    || fail "pointer temp file is not in the handoff.json directory"

  : > "$ATOMIC_RELEASE"
  wait "$ACTIVE_PID" || fail "handoff finalizer failed after atomic rename"
  ACTIVE_PID=""
  jq -e '.last_thread and (.thread_path | startswith("workspace/threads/"))' \
    "$repo/workspace/threads/handoff.json" >/dev/null \
    || fail "atomically published pointer is invalid or does not use a checkout-relative thread_path"
  [[ ! -e "$temp_file" ]] || fail "pointer temp file was not removed by rename"
  pass "handoff pointer stays intact while a same-directory temp is written, then publishes valid JSON"
  rm -f "$TEST_BIN/jq"
}

case "${1:-all}" in
  worktree) test_linked_worktree_copies_thread_and_updates_main_pointer ;;
  atomic) test_pointer_is_atomically_replaced_in_its_directory ;;
  reconcile) test_clean_worktree_reconciles_only_matching_handoff_mirrors ;;
  all) test_linked_worktree_copies_thread_and_updates_main_pointer; test_pointer_is_atomically_replaced_in_its_directory; test_clean_worktree_reconciles_only_matching_handoff_mirrors ;;
  *) fail "unknown test selector: $1" ;;
esac
echo "PASS: handoff-finalize-pointer"
