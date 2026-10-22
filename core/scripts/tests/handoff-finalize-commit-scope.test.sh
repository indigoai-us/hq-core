#!/usr/bin/env bash
# handoff-finalize-commit-scope.test.sh — the handoff commit holds only the
# handoff's own paths, and paths inside a nested knowledge repository are not
# restaged through the HQ root.
#
#   feedback_25b250a7-71f0-41b5-8a98-6311f094b7f2: a plain `git commit` swept a
#     stale pre-staged index (246,730 files) into one handoff commit.
#   feedback_d4fcd2e4-310e-459f-9095-601b6381c7ad,
#   feedback_121735c2-f75b-4473-a164-55f5ebfb0fc0: a changeset path inside
#     companies/<co>/knowledge (a gitlink) made finalize exit 4 stage-failed
#     even though the knowledge repo had already committed it.

set -euo pipefail

SRC_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP_ROOT=$(mktemp -d)
trap 'rm -rf "$TMP_ROOT"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_eq() { [[ "$1" == "$2" ]] || fail "$3: expected '$2', got '$1'"; }

scaffold_repo() {
  local repo="$1"
  mkdir -p "$repo/core/scripts/lib" "$repo/workspace/baseline" "$repo/workspace/threads" "$repo/workspace/orchestrator"
  cp "$SRC_ROOT/scripts/handoff-finalize.sh" "$repo/core/scripts/handoff-finalize.sh"
  cp "$SRC_ROOT/scripts/lib/session-id.sh" "$repo/core/scripts/lib/session-id.sh"
  cp "$SRC_ROOT/scripts/hq-status-summary.sh" "$repo/core/scripts/hq-status-summary.sh"
  cp "$SRC_ROOT/scripts/lib/forwarder.sh" "$repo/core/scripts/lib/forwarder.sh"
  cp "$SRC_ROOT/scripts/lib/hq-cli-floor.sh" "$repo/core/scripts/lib/hq-cli-floor.sh"
  printf '#!/usr/bin/env bash\nmkdir -p workspace/threads; echo "# Threads" > workspace/threads/INDEX.md; echo "- recent" > workspace/threads/recent.md\n' \
    > "$repo/core/scripts/rebuild-threads-index.sh"
  printf '#!/usr/bin/env bash\nmkdir -p workspace/orchestrator; echo "# Orchestrator" > workspace/orchestrator/INDEX.md\n' \
    > "$repo/core/scripts/rebuild-orchestrator-index.sh"
  chmod +x "$repo/core/scripts/"*.sh
  printf '{"categories":[{"name":"baseline","patterns":["workspace/*","repos/*","core/settings/*",".hq/*"]}]}\n' \
    > "$repo/workspace/baseline/hq-local-baseline.json"
  git -C "$repo" init -q
  git -C "$repo" config user.email test@example.com
  git -C "$repo" config user.name "Handoff Commit Scope Test"
  echo "base" > "$repo/tracked.txt"
  git -C "$repo" add tracked.txt core/scripts workspace/baseline/hq-local-baseline.json
  git -C "$repo" commit -qm "base"
}

finalize() { # <slug> <files-touched-json>
  bash core/scripts/handoff-finalize.sh --title "Handoff: $1" --summary "$1" --message "$1" \
    --files-touched-json "$2" --slug "$1"
}

# ── 1. A foreign pre-staged path stays out of the handoff commit ────────────
R1="$TMP_ROOT/prestaged"
scaffold_repo "$R1"
cd "$R1"
echo "stale" > foreign.txt
git add foreign.txt
echo "changed" > tracked.txt
rc=0; out=$(finalize prestaged '["tracked.txt"]') || rc=$?
assert_eq "$rc" "0" "pre-staged: exit code"
assert_eq "$(jq -r '.hq_commit_status' <<<"$out")" "committed" "pre-staged: status"
git show HEAD:tracked.txt | grep -q changed || fail "pre-staged: handoff path not committed"
git cat-file -e HEAD:foreign.txt 2>/dev/null && fail "pre-staged: foreign staged path was swept into the handoff commit"
jq -e '.committed_paths | index("foreign.txt")' <<<"$out" >/dev/null && fail "pre-staged: committed_paths lists the foreign path"
assert_eq "$(git diff --cached --name-only)" "foreign.txt" "pre-staged: foreign path must stay staged"

# ── 2. A path committed inside a nested knowledge repo is not a failure ─────
R2="$TMP_ROOT/nested"
scaffold_repo "$R2"
cd "$R2"
K=companies/acme/knowledge
mkdir -p "$K"
git -C "$K" init -q
git -C "$K" config user.email test@example.com
git -C "$K" config user.name "Knowledge"
echo "v1" > "$K/brief.md"
git -C "$K" add brief.md && git -C "$K" commit -qm "v1"
git -c advice.addEmbeddedRepo=false add "$K" && git commit -qm "add knowledge gitlink"
assert_eq "$(git ls-files -s -- "$K" | awk '{print $1}')" "160000" "nested: fixture is a gitlink"
echo "v2" > "$K/brief.md"
git -C "$K" commit -qam "v2"            # what handoff-knowledge-commit.sh does
rc=0; out=$(finalize nested "[\"$K/brief.md\"]") || rc=$?
assert_eq "$rc" "0" "nested committed: exit code"
assert_eq "$(jq -r '.hq_commit_status' <<<"$out")" "committed" "nested committed: status"
assert_eq "$(jq -r '.stage_failures | length' <<<"$out")" "0" "nested committed: stage_failures"
jq -e --arg p "$K/brief.md" '.nested_repo_paths | index($p)' <<<"$out" >/dev/null \
  || fail "nested committed: nested_repo_paths must keep the changeset path"
assert_eq "$(git ls-tree HEAD -- "$K" | awk '{print $3}')" "$(git -C "$K" rev-parse HEAD)" \
  "nested committed: HQ root must record the new knowledge pointer"

# ── 3. A path still uncommitted inside the nested repo is named as such ─────
echo "v3" > "$K/brief.md"
rc=0; out=$(finalize nested-dirty "[\"$K/brief.md\"]") || rc=$?
assert_eq "$rc" "4" "nested dirty: exit code"
assert_eq "$(jq -r '.hq_commit_status' <<<"$out")" "stage-failed" "nested dirty: status"
jq -e --arg p "$K/brief.md" '.stage_failures | index($p)' <<<"$out" >/dev/null \
  || fail "nested dirty: stage_failures must list the path"
jq -r '.hq_commit_error' <<<"$out" | grep -q "inside nested repository $K" \
  || fail "nested dirty: error must name the nested repository; got: $(jq -r '.hq_commit_error' <<<"$out")"

# ── 4. An excluded nested repo (not a gitlink) keeps the old quiet skip ─────
# HQ keeps knowledge and project src repos out of the root index through
# .git/info/exclude; a dirty file there is normal mid-session and must not
# fail the handoff (review on #1516).
R4="$TMP_ROOT/excluded"
scaffold_repo "$R4"
cd "$R4"
X=companies/other/knowledge
mkdir -p "$X"
git -C "$X" init -q
git -C "$X" config user.email test@example.com
git -C "$X" config user.name "Knowledge"
echo "v1" > "$X/note.md"
git -C "$X" add note.md && git -C "$X" commit -qm "v1"
printf '/%s/\n' "$X" >> .git/info/exclude
echo "dirty" > "$X/note.md"
echo "changed" > tracked.txt
rc=0; out=$(finalize excluded "[\"tracked.txt\",\"$X/note.md\"]") || rc=$?
assert_eq "$rc" "0" "excluded nested: exit code"
assert_eq "$(jq -r '.hq_commit_status' <<<"$out")" "committed" "excluded nested: status"
jq -e --arg p "$X/note.md" '.stage_failures | index($p)' <<<"$out" >/dev/null \
  && fail "excluded nested: path must not be a stage failure"
git ls-files -s -- "$X" | grep -q 160000 && fail "excluded nested: must not embed the repo as a gitlink"

echo "handoff-finalize-commit-scope: all checks passed"
