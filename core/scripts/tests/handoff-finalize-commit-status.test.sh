#!/usr/bin/env bash
# handoff-finalize-commit-status.test.sh — B4: a failed handoff commit must
# never be reported inside a success payload.
#
# The finalizer used to run `git commit >/dev/null 2>&1` and only flip
# hq_committed on success, so a refused commit produced
# {"hq_committed": false, "committed_paths": [...]} on stdout with exit 0 —
# indistinguishable from "there was nothing to commit", and read by the caller
# as a completed handoff. These cases pin the three outcomes apart.

set -euo pipefail

SRC_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP_ROOT=$(mktemp -d)
trap 'rm -rf "$TMP_ROOT"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_eq() {
  local actual="$1" expected="$2" label="$3"
  [[ "$actual" == "$expected" ]] || fail "$label: expected '$expected', got '$actual'"
}

# scaffold_repo <dir> — a minimal HQ-shaped git repo with the finalizer and the
# index-rebuild scripts it shells out to.
scaffold_repo() {
  local repo="$1"
  mkdir -p "$repo/core/scripts" "$repo/workspace/baseline" "$repo/workspace/threads" "$repo/workspace/orchestrator"
  cp "$SRC_ROOT/scripts/handoff-finalize.sh" "$repo/core/scripts/handoff-finalize.sh"
  cp "$SRC_ROOT/scripts/hq-status-summary.sh" "$repo/core/scripts/hq-status-summary.sh"
  chmod +x "$repo/core/scripts/"*.sh

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
  chmod +x "$repo/core/scripts/rebuild-threads-index.sh" "$repo/core/scripts/rebuild-orchestrator-index.sh"

  cat > "$repo/workspace/baseline/hq-local-baseline.json" <<'JSON'
{"categories":[{"name":"baseline","patterns":["companies/*","workspace/*","repos/*","core/settings/*",".hq/*"]}]}
JSON

  git -C "$repo" init -q
  git -C "$repo" config user.email test@example.com
  git -C "$repo" config user.name "Handoff Commit Status Test"
  echo "base" > "$repo/tracked.txt"
  git -C "$repo" add tracked.txt core/scripts workspace/baseline/hq-local-baseline.json
  git -C "$repo" commit -qm "base"
}

# ── 1. Healthy commit: status "committed", paths listed, exit 0 ─────────────
OK_REPO="$TMP_ROOT/ok"
scaffold_repo "$OK_REPO"
cd "$OK_REPO"
echo "changed" > tracked.txt

rc=0
out=$(bash core/scripts/handoff-finalize.sh \
  --title "Handoff: healthy" \
  --summary "Healthy commit" \
  --message "Healthy commit" \
  --files-touched-json '["tracked.txt"]' \
  --slug "healthy") || rc=$?

assert_eq "$rc" "0" "healthy finalize exit code"
assert_eq "$(jq -r '.hq_committed' <<<"$out")" "true" "healthy hq_committed"
assert_eq "$(jq -r '.hq_commit_status' <<<"$out")" "committed" "healthy hq_commit_status"
assert_eq "$(jq -r '.hq_commit_error' <<<"$out")" "" "healthy hq_commit_error"
assert_eq "$(jq -r '.stage_failures | length' <<<"$out")" "0" "healthy stage_failures"
jq -e '.committed_paths | index("tracked.txt")' <<<"$out" >/dev/null \
  || fail "healthy run must list the committed path"
git show HEAD:tracked.txt | grep -q changed || fail "healthy run did not commit the file"

# ── 2. Refused commit: status "failed", no committed paths, exit 4 ──────────
# A failing pre-commit hook is the cheapest faithful stand-in for the real
# cause (an orphaned .git/index.lock): git refuses, and the finalizer has to
# decide what to report.
BAD_REPO="$TMP_ROOT/refused"
scaffold_repo "$BAD_REPO"
cd "$BAD_REPO"
mkdir -p .git/hooks
cat > .git/hooks/pre-commit <<'SH'
#!/usr/bin/env bash
echo "pre-commit refused this commit" >&2
exit 1
SH
chmod +x .git/hooks/pre-commit
echo "changed" > tracked.txt
head_before="$(git rev-parse HEAD)"

rc=0
err_file="$TMP_ROOT/refused.err"
out=$(bash core/scripts/handoff-finalize.sh \
  --title "Handoff: refused" \
  --summary "Refused commit" \
  --message "Refused commit" \
  --files-touched-json '["tracked.txt"]' \
  --slug "refused" 2>"$err_file") || rc=$?

assert_eq "$rc" "4" "refused finalize exit code"
jq -e . <<<"$out" >/dev/null || fail "refused run must still emit a parseable payload"
assert_eq "$(jq -r '.hq_committed' <<<"$out")" "false" "refused hq_committed"
assert_eq "$(jq -r '.hq_commit_status' <<<"$out")" "failed" "refused hq_commit_status"
assert_eq "$(jq -r '.committed_paths | length' <<<"$out")" "0" \
  "refused run must not report any path as committed"
[[ -n "$(jq -r '.hq_commit_error' <<<"$out")" ]] \
  || fail "refused run must carry git's error message"
grep -q "commit FAILED" "$err_file" || fail "refused run must warn loudly on stderr"
assert_eq "$(git rev-parse HEAD)" "$head_before" "refused run must not move HEAD"
[[ -f "$(jq -r '.thread_path' <<<"$out")" ]] \
  || fail "thread file must still be written so the session is recoverable"

# ── 3. Nothing to commit: distinct status, still exit 0 ─────────────────────
# hq_committed:false is legitimate when there is genuinely nothing staged; that
# must stay a success. Ignoring everything the finalizer would stage reproduces
# it without contriving a git failure.
EMPTY_REPO="$TMP_ROOT/empty"
scaffold_repo "$EMPTY_REPO"
cd "$EMPTY_REPO"
printf 'workspace/\nINDEX.md\n' > .gitignore
git add .gitignore
git commit -qm "ignore generated handoff output"

rc=0
out=$(bash core/scripts/handoff-finalize.sh \
  --title "Handoff: empty" \
  --summary "Nothing to commit" \
  --message "Nothing to commit" \
  --files-touched-json '[]' \
  --slug "empty") || rc=$?

assert_eq "$rc" "0" "nothing-to-commit finalize exit code"
assert_eq "$(jq -r '.hq_committed' <<<"$out")" "false" "nothing-to-commit hq_committed"
assert_eq "$(jq -r '.hq_commit_status' <<<"$out")" "nothing-to-commit" "nothing-to-commit status"
assert_eq "$(jq -r '.stage_failures | length' <<<"$out")" "0" \
  "gitignored paths are a deliberate exclusion, not a staging failure"

# ── 4. Unstageable paths: status "stage-failed", exit 4 ────────────────────
# The reported cause (a held .git/index.lock) fails every `git add`, so nothing
# is staged and no commit is attempted. That must not read as the benign
# "nothing to commit" case — the whole handoff is sitting uncommitted on disk.
LOCKED_REPO="$TMP_ROOT/locked"
scaffold_repo "$LOCKED_REPO"
cd "$LOCKED_REPO"
echo "changed" > tracked.txt
: > .git/index.lock
head_before="$(git rev-parse HEAD)"

rc=0
err_file="$TMP_ROOT/locked.err"
out=$(bash core/scripts/handoff-finalize.sh \
  --title "Handoff: locked" \
  --summary "Locked index" \
  --message "Locked index" \
  --files-touched-json '["tracked.txt"]' \
  --slug "locked" 2>"$err_file") || rc=$?

assert_eq "$rc" "4" "locked-index finalize exit code"
assert_eq "$(jq -r '.hq_commit_status' <<<"$out")" "stage-failed" "locked-index hq_commit_status"
assert_eq "$(jq -r '.hq_committed' <<<"$out")" "false" "locked-index hq_committed"
assert_eq "$(jq -r '.committed_paths | length' <<<"$out")" "0" \
  "locked-index run must not report any path as committed"
[[ "$(jq -r '.stage_failures | length' <<<"$out")" -gt 0 ]] \
  || fail "locked-index run must list the paths git add rejected"
grep -q "git add failed" "$err_file" || fail "locked-index run must warn loudly on stderr"
assert_eq "$(git rev-parse HEAD)" "$head_before" "locked-index run must not move HEAD"
rm -f .git/index.lock

echo "handoff-finalize commit status: ok"
