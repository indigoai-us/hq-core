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
  cp "$SRC_ROOT/scripts/lib/forwarder.sh" "$repo/core/scripts/lib/forwarder.sh"
  cp "$SRC_ROOT/scripts/lib/hq-cli-floor.sh" "$repo/core/scripts/lib/hq-cli-floor.sh"
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

# feedback_b75f1436: two handoffs with the same slug in the same second must
# get distinct thread ids, so /resumework can select each by its full id and
# neither overwrites the other.
test_same_second_same_slug_gets_unique_ids() {
  local repo="$TMP_ROOT/unique-ids" datebin="$TMP_ROOT/fixed-date-bin" real_date out1 out2 id1 id2 id3
  scaffold_repo "$repo"
  mkdir -p "$datebin"
  real_date="$(command -v date)"
  # Freeze the clock: every date call sees the same second.
  cat > "$datebin/date" <<SH
#!/usr/bin/env bash
if "$real_date" -r 0 >/dev/null 2>&1; then exec "$real_date" -r 999999999 "\$@"; fi
exec "$real_date" -d @999999999 "\$@"
SH
  chmod +x "$datebin/date"
  local saved_path="$TEST_BIN"
  TEST_BIN="$datebin:$saved_path"
  out1="$(run_finalize "$repo")" || fail "first same-second handoff failed"
  out2="$(run_finalize "$repo")" || fail "second same-second handoff failed"
  local out3; out3="$(run_finalize "$repo")" || fail "third same-second handoff failed"
  TEST_BIN="$saved_path"
  id1="$(jq -r '.thread_id' <<<"$out1")"; id2="$(jq -r '.thread_id' <<<"$out2")"; id3="$(jq -r '.thread_id' <<<"$out3")"
  [[ "$id1" == *-us083-pointer ]] || fail "first id lost its slug: $id1"
  [[ "$id2" == "$id1-2" ]] || fail "second same-second id not suffixed: $id1 / $id2"
  [[ "$id3" == "$id1-3" ]] || fail "third same-second id not suffixed: $id1 / $id3"
  [[ -f "$repo/workspace/threads/$id1.json" && -f "$repo/workspace/threads/$id2.json" && -f "$repo/workspace/threads/$id3.json" ]] \
    || fail "same-second handoffs did not each keep a thread file"
  [[ "$(jq -r '.thread_id' "$repo/workspace/threads/$id1.json")" == "$id1" ]] || fail "first thread file was overwritten"
  pass "same-second same-slug handoffs get unique thread ids ($id1, -2, -3)"
}

# Two desktop sessions handing off within minutes share one pointer. The
# second finalize may legitimately take the pointer, but a finalize whose
# thread is OLDER than the pointer on disk (clock skew, a replayed older copy
# racing a fresh handoff) must not win: the newest handoff stays resumable.
# Both the thread and the pointer also record the session that wrote them so
# the archive check can match on session id when the pointer moves on.
test_older_finalize_does_not_overwrite_newer_pointer() {
  local repo="$TMP_ROOT/newer-wins" datebin="$TMP_ROOT/old-date-bin" real_date out_new out_old id_new id_old
  scaffold_repo "$repo"
  out_new="$(HQ_SESSION_ID=sess-new run_finalize "$repo")" || fail "fresh handoff failed"
  id_new="$(jq -r '.thread_id' <<<"$out_new")"
  [[ "$(jq -r '.session_id' "$repo/workspace/threads/$id_new.json")" == "sess-new" ]] \
    || fail "thread file does not record the writing session id"
  [[ "$(jq -r '.session_id' "$repo/workspace/threads/handoff.json")" == "sess-new" ]] \
    || fail "pointer does not record the writing session id"
  # Freeze the clock in the past (epoch 999999999, 2001-09-09) so the second handoff is older.
  mkdir -p "$datebin"
  real_date="$(command -v date)"
  cat > "$datebin/date" <<SH
#!/usr/bin/env bash
if "$real_date" -r 0 >/dev/null 2>&1; then exec "$real_date" -r 999999999 "\$@"; fi
exec "$real_date" -d @999999999 "\$@"
SH
  chmod +x "$datebin/date"
  local saved_path="$TEST_BIN"
  TEST_BIN="$datebin:$saved_path"
  out_old="$(HQ_SESSION_ID=sess-old run_finalize "$repo")" || fail "older handoff failed"
  TEST_BIN="$saved_path"
  id_old="$(jq -r '.thread_id' <<<"$out_old")"
  [[ -f "$repo/workspace/threads/$id_old.json" ]] || fail "older handoff did not keep its own thread file"
  [[ "$(jq -r '.last_thread' "$repo/workspace/threads/handoff.json")" == "$id_new" ]] \
    || fail "older handoff overwrote the newer pointer: $(jq -c . "$repo/workspace/threads/handoff.json")"
  [[ "$(jq -r '.session_id' "$repo/workspace/threads/handoff.json")" == "sess-new" ]] \
    || fail "older handoff replaced the pointer's session id"
  [[ "$(jq -r '.pointer_kept_newer' <<<"$out_old")" == "true" ]] \
    || fail "finalize output does not report that the newer pointer was kept: $out_old"
  [[ "$(jq -r '.pointer_kept_newer' <<<"$out_new")" == "false" ]] \
    || fail "fresh finalize wrongly reports a kept pointer"
  # A later handoff (real clock) takes the pointer as usual.
  out_new="$(HQ_SESSION_ID=sess-later run_finalize "$repo")" || fail "later handoff failed"
  [[ "$(jq -r '.last_thread' "$repo/workspace/threads/handoff.json")" == "$(jq -r '.thread_id' <<<"$out_new")" ]] \
    || fail "a newer handoff did not take the pointer"
  pass "an older finalize keeps the newer pointer; thread and pointer carry the session id"
}

case "${1:-all}" in
  worktree) test_linked_worktree_copies_thread_and_updates_main_pointer ;;
  atomic) test_pointer_is_atomically_replaced_in_its_directory ;;
  reconcile) test_clean_worktree_reconciles_only_matching_handoff_mirrors ;;
  unique) test_same_second_same_slug_gets_unique_ids ;;
  newer) test_older_finalize_does_not_overwrite_newer_pointer ;;
  all) test_linked_worktree_copies_thread_and_updates_main_pointer; test_pointer_is_atomically_replaced_in_its_directory; test_clean_worktree_reconciles_only_matching_handoff_mirrors; test_same_second_same_slug_gets_unique_ids; test_older_finalize_does_not_overwrite_newer_pointer ;;
  *) fail "unknown test selector: $1" ;;
esac
echo "PASS: handoff-finalize-pointer"
