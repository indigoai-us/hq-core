#!/usr/bin/env bash
# handoff-finalize-index-lock-retry.test.sh — a .git/index.lock held by another
# session is waited out, not reported as stage-failed on the first try
# (feedback_29213da4-dde6-4951-a9e4-ad5b0136a112).
#
# Reported shape: finalize exited 4 with stage_failures on two paths at 16:23
# while other sessions committed their own handoff checkpoints at 16:23:27,
# 16:24:26 and 16:24:51; a dry-run add minutes later succeeded. The lock here
# is a real .git/index.lock that a background process removes after a moment.
#
# Also covers the commit scope for a changeset that lists a DIRECTORY while a
# foreign path is staged: the handoff commit holds the files under the
# directory and nothing else, and the foreign path stays staged.

set -euo pipefail

SRC_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP_ROOT=$(mktemp -d)
trap 'rm -rf "$TMP_ROOT"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_eq() {
  [[ "$1" == "$2" ]] || fail "$3: expected '$2', got '$1'"
}

# A git shim that fails the first FAKE_LOCK_FAILS `add` calls the way a held
# index.lock does, then passes through. The count lives in a file so every
# invocation of the shim sees it.
REAL_GIT="$(command -v git)"
export REAL_GIT
mkdir -p "$TMP_ROOT/shim"
cat > "$TMP_ROOT/shim/git" <<'SH'
#!/usr/bin/env bash
if [[ -n "${FAKE_LOCK_COUNTER:-}" ]]; then
  for a in "$@"; do
    if [[ "$a" == "add" ]]; then
      left="$(cat "$FAKE_LOCK_COUNTER" 2>/dev/null || echo 0)"
      if [[ "$left" -gt 0 ]]; then
        echo $((left-1)) > "$FAKE_LOCK_COUNTER"
        printf "fatal: Unable to create '%s/.git/index.lock': File exists.\n" "$PWD" >&2
        exit 128
      fi
      break
    fi
    case "$a" in -*) continue ;; *) break ;; esac
  done
fi
exec "$REAL_GIT" "$@"
SH
chmod +x "$TMP_ROOT/shim/git"

scaffold_repo() {
  local repo="$1"
  mkdir -p "$repo/core/scripts/lib" "$repo/workspace/baseline" "$repo/workspace/threads" "$repo/workspace/orchestrator"
  cp "$SRC_ROOT/scripts/handoff-finalize.sh" "$repo/core/scripts/handoff-finalize.sh"
  cp "$SRC_ROOT/scripts/lib/session-id.sh" "$repo/core/scripts/lib/session-id.sh"
  cp "$SRC_ROOT/scripts/hq-status-summary.sh" "$repo/core/scripts/hq-status-summary.sh"
  cp "$SRC_ROOT/scripts/lib/forwarder.sh" "$repo/core/scripts/lib/forwarder.sh"
  cp "$SRC_ROOT/scripts/lib/hq-cli-floor.sh" "$repo/core/scripts/lib/hq-cli-floor.sh"
  cat > "$repo/core/scripts/rebuild-threads-index.sh" <<'SH'
#!/usr/bin/env bash
mkdir -p workspace/threads
echo "# Threads" > workspace/threads/INDEX.md
echo "- recent" > workspace/threads/recent.md
SH
  cat > "$repo/core/scripts/rebuild-orchestrator-index.sh" <<'SH'
#!/usr/bin/env bash
mkdir -p workspace/orchestrator
echo "# Orchestrator" > workspace/orchestrator/INDEX.md
SH
  chmod +x "$repo/core/scripts/"*.sh
  cat > "$repo/workspace/baseline/hq-local-baseline.json" <<'JSON'
{"categories":[{"name":"baseline","patterns":["companies/*","workspace/*","repos/*","core/settings/*",".hq/*"]}]}
JSON
  git -C "$repo" init -q
  git -C "$repo" config user.email test@example.com
  git -C "$repo" config user.name "Handoff Index Lock Test"
  echo "base" > "$repo/tracked.txt"
  git -C "$repo" add tracked.txt core/scripts workspace/baseline/hq-local-baseline.json
  git -C "$repo" commit -qm "base"
}

# run_finalize <repo> <slug> <files-touched json> — prints the payload; the
# exit code lands in $TMP_ROOT/rc.
run_finalize() {
  local repo="$1" slug="$2" files="$3" rc=0 out
  out="$(cd "$repo" && bash core/scripts/handoff-finalize.sh \
      --title "Handoff: $slug" --summary "$slug" --message "$slug" \
      --files-touched-json "$files" --slug "$slug" 2>"$TMP_ROOT/$slug.err")" || rc=$?
  printf '%s' "$rc" > "$TMP_ROOT/rc"
  printf '%s' "$out"
}

# 1. A lock another session releases after two failed attempts: the handoff
#    commits, and the payload counts the waits.
REPO="$TMP_ROOT/released"
scaffold_repo "$REPO"
echo "changed" > "$REPO/tracked.txt"
echo 2 > "$TMP_ROOT/released.counter"
out="$(cd "$REPO" && FAKE_LOCK_COUNTER="$TMP_ROOT/released.counter" PATH="$TMP_ROOT/shim:$PATH" \
  bash core/scripts/handoff-finalize.sh \
    --title "Handoff: released" --summary released --message released \
    --files-touched-json '["tracked.txt"]' --slug released 2>"$TMP_ROOT/released.err")" && rc=0 || rc=$?
assert_eq "$rc" "0" "released lock: exit code"
assert_eq "$(jq -r '.hq_commit_status' <<<"$out")" "committed" "released lock: hq_commit_status"
assert_eq "$(jq -r '.stage_failures | length' <<<"$out")" "0" "released lock: no stage failures"
assert_eq "$(jq -r '.index_lock_waits' <<<"$out")" "2" "released lock: index_lock_waits"
assert_eq "$(cat "$TMP_ROOT/released.counter")" "0" "released lock: both failing attempts were consumed"
git -C "$REPO" show --stat --format= HEAD | grep -q "tracked.txt" || fail "released lock: tracked.txt must be in the handoff commit"

# 2. A lock that is never released still ends as a classified stage failure,
#    within the retry budget.
REPO="$TMP_ROOT/held"
scaffold_repo "$REPO"
echo "changed" > "$REPO/tracked.txt"
: > "$REPO/.git/index.lock"
out="$(cd "$REPO" && HQ_HANDOFF_INDEX_LOCK_RETRIES=2 bash core/scripts/handoff-finalize.sh \
    --title "Handoff: held" --summary held --message held \
    --files-touched-json '["tracked.txt"]' --slug held 2>"$TMP_ROOT/held.err")" && rc=0 || rc=$?
assert_eq "$rc" "4" "held lock: exit code"
assert_eq "$(jq -r '.hq_commit_status' <<<"$out")" "stage-failed" "held lock: hq_commit_status"
assert_eq "$(jq -r '.stage_failure_class' <<<"$out")" "index-lock" "held lock: stage_failure_class"
[[ "$(jq -r '.index_lock_waits' <<<"$out")" -ge 2 ]] || fail "held lock: index_lock_waits must show the retries"
rm -f "$REPO/.git/index.lock"

# 3. Directory changeset next to a foreign staged path: only the directory's
#    files commit; the foreign path stays staged (feedback 25b250a7 shape).
REPO="$TMP_ROOT/dir"
scaffold_repo "$REPO"
mkdir -p "$REPO/personal/projects/demo"
echo "notes" > "$REPO/personal/projects/demo/notes.md"
echo "plan" > "$REPO/personal/projects/demo/plan.md"
echo "foreign" > "$REPO/foreign.txt"
git -C "$REPO" add foreign.txt
out="$(run_finalize "$REPO" dir '["personal/projects/demo/"]')"
assert_eq "$(cat "$TMP_ROOT/rc")" "0" "directory: exit code"
assert_eq "$(jq -r '.hq_commit_status' <<<"$out")" "committed" "directory: hq_commit_status"
committed="$(git -C "$REPO" show --name-only --format= HEAD | sort | tr '\n' ' ')"
[[ "$committed" == *"personal/projects/demo/notes.md"* && "$committed" == *"personal/projects/demo/plan.md"* ]] \
  || fail "directory: both files under the listed directory must commit; got: $committed"
[[ "$committed" != *"foreign.txt"* ]] || fail "directory: foreign staged path must not be in the handoff commit"
git -C "$REPO" diff --cached --name-only | grep -qx "foreign.txt" || fail "directory: foreign path must stay staged"
jq -e '.committed_paths | index("personal/projects/demo/notes.md") != null and index("foreign.txt") == null' <<<"$out" >/dev/null \
  || fail "directory: committed_paths must list the directory's files and not the foreign path"

echo "PASS: handoff-finalize waits out a held index.lock and scopes directory changesets"
