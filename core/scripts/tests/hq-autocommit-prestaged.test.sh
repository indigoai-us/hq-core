#!/usr/bin/env bash
# hq-core: public
# Regression: leftover foreign staged paths must not freeze every autosave
# (feedback_06a7f136). Save the edited file through a private index and leave
# the foreign staged set alone. Overlap with this path (or a directory add)
# still holds, logs each skip, and warns once the staged set outlives the
# staleness window (feedback_09c2b7a0).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(git -C "$SCRIPT_DIR/../../.." rev-parse --show-toplevel)"
TMP_PARENT="$(mktemp -d)"
TMP="$TMP_PARENT/hq"
trap 'rm -rf "$TMP_PARENT"' EXIT
export TMPDIR="$TMP_PARENT/tmp"
mkdir -p "$TMPDIR" "$TMP/.claude/hooks" "$TMP/core"
unset HQ_FLAGS_API_URL HQ_COMPANY_UID HQ_COMPANY_SLUG HQ_CLI_BIN HQ_AUTOCOMMIT_STRICT

cp "$ROOT/.claude/hooks/hq-autocommit.sh" "$TMP/.claude/hooks/hq-autocommit.sh"
chmod +x "$TMP/.claude/hooks/hq-autocommit.sh"
printf 'hqVersion: "test"\n' > "$TMP/core/core.yaml"
git -C "$TMP" init -q
git -C "$TMP" config user.email "hq-autocommit-test"
git -C "$TMP" config user.name "HQ Autocommit Test"
git -C "$TMP" add core/core.yaml .claude/hooks/hq-autocommit.sh
git -C "$TMP" commit -q -m "init"

FAIL=0
check() { local name="$1"; shift; if "$@"; then echo "  ok  $name"; else echo "  FAIL $name"; FAIL=1; fi; }

run_hook() { # <file> [env...] -> stdout+stderr in $OUT, rc in $RC
  local file="$1"; shift
  local payload
  payload="$(jq -cn --arg path "$file" '{tool_name:"Edit",tool_input:{file_path:$path},session_id:"prestaged-test"}')"
  RC=0
  OUT="$(cd "$TMP" && printf '%s' "$payload" | env "$@" bash .claude/hooks/hq-autocommit.sh 2>&1)" || RC=$?
}

LOG="$TMP/workspace/logs/hq-autocommit.log"
HEAD0="$(git -C "$TMP" rev-parse HEAD)"

printf 'foreign\n' > "$TMP/foreign.md"
git -C "$TMP" add foreign.md
printf 'mine\n' > "$TMP/mine.md"

# 1. Foreign staged file, edit another file: private-index save.
run_hook "$TMP/mine.md"
check "exit 0 while foreign pre-staged" test "$RC" -eq 0
check "commits the edited file" bash -c 'git -C "$1" show --name-only --format= HEAD | grep -qx mine.md' _ "$TMP"
check "does not commit the foreign staged path" bash -c '! git -C "$1" show --name-only --format= HEAD | grep -qx foreign.md' _ "$TMP"
check "foreign staged path left staged" test "$(git -C "$TMP" diff --cached --name-only)" = "foreign.md"
check "private-index save is logged" grep -q 'SAVE stage=private-index staged=1 path=mine.md' "$LOG"
check "no warning when the edit was saved" test -z "$OUT"

# 2. Self-staged overlap: skip, keep the index, log the skip, warn past the window.
printf 'self\n' > "$TMP/self.md"
git -C "$TMP" add -- self.md
printf 'self plus unstaged\n' > "$TMP/self.md"
HEAD_SELF="$(git -C "$TMP" rev-parse HEAD)"
run_hook "$TMP/self.md"
check "exit 0 while self pre-staged" test "$RC" -eq 0
check "no commit while self pre-staged" test "$(git -C "$TMP" rev-parse HEAD)" = "$HEAD_SELF"
check "skip is logged" grep -q 'SKIP stage=prestaged' "$LOG"
check "no warning inside the staleness window" test -z "$OUT"
run_hook "$TMP/self.md" HQ_AUTOCOMMIT_PRESTAGED_STALE_MINUTES=0
check "warning names the stuck index" bash -c '[[ "$1" == *"skipping edits because the HQ git index already has"* ]]' _ "$OUT"
run_hook "$TMP/self.md" HQ_AUTOCOMMIT_PRESTAGED_STALE_MINUTES=0
check "warning is not repeated in the same session" test -z "$OUT"

# 3. Index cleared: autosave resumes and the pre-staged marker is dropped.
git -C "$TMP" reset -q -- foreign.md self.md
printf 'mine again\n' > "$TMP/mine.md"
run_hook "$TMP/mine.md"
check "autosave resumes after the index clears" bash -c 'git -C "$1" log -1 --name-only --format= | grep -qx mine.md' _ "$TMP"
check "pre-staged marker removed" test ! -e "$TMP/workspace/.autocommit-warnings/prestaged-since"


# Regression coverage for the shared-index corruption cases from review.
# Every snapshot includes staged object ids/modes and the full binary diff:
# preserving path names alone would miss overwritten partial stages.
new_case() {
  TMP="$TMP_PARENT/$1"
  mkdir -p "$TMP/.claude/hooks" "$TMP/core" "$TMP/notes"
  cp "$ROOT/.claude/hooks/hq-autocommit.sh" "$TMP/.claude/hooks/hq-autocommit.sh"
  printf 'hqVersion: "test"\n' > "$TMP/core/core.yaml"
  git -C "$TMP" init -q
  git -C "$TMP" config user.email test@example.com
  git -C "$TMP" config user.name "Autosave Index Preservation"
  local file
  for file in notes/part.md notes/café.md notes/old.md outside.md; do
    printf 'one\ntwo\nthree\nfour\nfive\nsix\n' > "$TMP/$file"
  done
  git -C "$TMP" add .
  git -C "$TMP" commit -qm baseline
}
index_signature() {
  git -C "$TMP" ls-files --stage -z | git -C "$TMP" hash-object --stdin
  git -C "$TMP" diff --cached --binary --full-index --no-renames | git -C "$TMP" hash-object --stdin
}
stage_partial() {
  printf 'one\ntwo\nthree\nfour\nSTAGED\nsix\n' > "$TMP/$1"
  git -C "$TMP" add -- "$1"
  printf 'one\ntwo\nthree\nfour\nSTAGED plus UNSTAGED\nsix\n' > "$TMP/$1"
}
check_held_index() {
  local label="$1" before="$2" head="$3"
  check "$label: staged blobs/modes and binary diff preserved" test "$(index_signature)" = "$before"
  check "$label: HEAD unchanged" test "$(git -C "$TMP" rev-parse HEAD)" = "$head"
  check "$label: hook remains non-blocking" test "$RC" -eq 0
}

new_case partial-directory
stage_partial notes/part.md
printf 'own edit\n' > "$TMP/notes/mine.md"
BEFORE="$(index_signature)"; HEAD_BEFORE="$(git -C "$TMP" rev-parse HEAD)"
run_hook "$TMP/notes"
check_held_index "directory partial stage" "$BEFORE" "$HEAD_BEFORE"

new_case nonascii-overlap
stage_partial notes/café.md
BEFORE="$(index_signature)"; HEAD_BEFORE="$(git -C "$TMP" rev-parse HEAD)"
run_hook "$TMP/notes/café.md"
check_held_index "non-ASCII partial stage" "$BEFORE" "$HEAD_BEFORE"

new_case foreign-oversize
printf '%0100d' 0 > "$TMP/notes/foreign.bin"
git -C "$TMP" add notes/foreign.bin
printf 'own\n' > "$TMP/notes/mine.md"
BEFORE="$(index_signature)"; HEAD_BEFORE="$(git -C "$TMP" rev-parse HEAD)"
run_hook "$TMP/notes" HQ_OFFLOAD_MIN_BYTES=32
check_held_index "foreign oversize file" "$BEFORE" "$HEAD_BEFORE"

new_case foreign-rename
git -C "$TMP" mv notes/old.md moved.md
printf 'own\n' > "$TMP/notes/mine.md"
BEFORE="$(index_signature)"; HEAD_BEFORE="$(git -C "$TMP" rev-parse HEAD)"
run_hook "$TMP/notes"
check_held_index "foreign rename" "$BEFORE" "$HEAD_BEFORE"

# Deterministic retry interleaving: if the hook attempts add, a simulated
# third writer stages a real path after the early snapshot, then add reports
# one index.lock failure. A safe hold returns before this interleaving starts.
new_case retry-third-writer
printf 'foreign\n' > "$TMP/outside.md"
git -C "$TMP" add outside.md
printf 'third writer\n' > "$TMP/notes/late.md"
printf 'own\n' > "$TMP/notes/mine.md"
SHIM="$TMP_PARENT/shim"
mkdir -p "$SHIM"
REAL_GIT="$(command -v git)"
cat > "$SHIM/git" <<'SH'
#!/bin/bash
for arg in "$@"; do
  if [[ "$arg" == add && ! -e "$INTERLEAVE_MARK" ]]; then
    : > "$INTERLEAVE_MARK"
    "$REAL_GIT" -C "$INTERLEAVE_ROOT" add -- notes/late.md
    echo 'fatal: Unable to create index.lock: File exists' >&2
    exit 128
  fi
done
exec "$REAL_GIT" "$@"
SH
chmod +x "$SHIM/git"
BEFORE="$(index_signature)"; HEAD_BEFORE="$(git -C "$TMP" rev-parse HEAD)"
run_hook "$TMP/notes" PATH="$SHIM:$PATH" REAL_GIT="$REAL_GIT" \
  INTERLEAVE_MARK="$TMP_PARENT/interleave-fired" INTERLEAVE_ROOT="$TMP"
check_held_index "retry third writer" "$BEFORE" "$HEAD_BEFORE"
check "foreign-stage hold returns before any add" test ! -e "$TMP_PARENT/interleave-fired"

# Positive controls: an exact ASCII overlap of this path is held. An unrelated
# partial stage is left on the shared index while this file still saves.
new_case unrelated-partial
stage_partial outside.md
OUTSIDE_BLOB="$(git -C "$TMP" rev-parse :outside.md)"
printf 'own changed\n' > "$TMP/notes/part.md"
HEAD_BEFORE="$(git -C "$TMP" rev-parse HEAD)"
run_hook "$TMP/notes/part.md"
check "unrelated partial stage: foreign blob preserved" test "$(git -C "$TMP" rev-parse :outside.md)" = "$OUTSIDE_BLOB"
check "unrelated partial stage: foreign path still staged" bash -c 'git -C "$1" diff --cached --name-only -- outside.md | grep -qx outside.md' _ "$TMP"
check "unrelated partial stage: edited file still saved" bash -c '[[ "$(git -C "$1" rev-parse HEAD)" != "$2" ]] && git -C "$1" show --name-only --format= HEAD | grep -qx notes/part.md' _ "$TMP" "$HEAD_BEFORE"
check "unrelated partial stage: hook remains non-blocking" test "$RC" -eq 0

new_case ascii-overlap
stage_partial notes/part.md
BEFORE="$(index_signature)"; HEAD_BEFORE="$(git -C "$TMP" rev-parse HEAD)"
run_hook "$TMP/notes/part.md"
check_held_index "exact ASCII overlap" "$BEFORE" "$HEAD_BEFORE"


# A stopped merge or cherry-pick leaves staged and unmerged paths that look
# foreign. Committing then would end the operation and record a tree without
# the other side, so the hook holds and the operation state stays intact.
start_side_conflict() {
  BASE_BRANCH="$(git -C "$TMP" symbolic-ref --short HEAD)"
  git -C "$TMP" checkout -q -b side
  printf 'side\n' > "$TMP/outside.md"
  printf 'side only\n' > "$TMP/side-only.md"
  git -C "$TMP" add -A
  git -C "$TMP" commit -qm side
  git -C "$TMP" checkout -q "$BASE_BRANCH"
  printf 'base side\n' > "$TMP/outside.md"
  git -C "$TMP" commit -qam base-side
}

new_case merge-in-progress
start_side_conflict
git -C "$TMP" merge side >/dev/null 2>&1 || true
MERGE_HEAD_BEFORE="$(git -C "$TMP" rev-parse -q --verify MERGE_HEAD || true)"
check "merge in progress: fixture stopped mid-merge" test -n "$MERGE_HEAD_BEFORE"
printf 'own edit during merge\n' > "$TMP/notes/part.md"
BEFORE="$(index_signature)"; HEAD_BEFORE="$(git -C "$TMP" rev-parse HEAD)"
run_hook "$TMP/notes/part.md"
check_held_index "merge in progress" "$BEFORE" "$HEAD_BEFORE"
check "merge in progress: MERGE_HEAD kept" test "$(git -C "$TMP" rev-parse -q --verify MERGE_HEAD || true)" = "$MERGE_HEAD_BEFORE"

new_case cherry-pick-in-progress
start_side_conflict
git -C "$TMP" cherry-pick side >/dev/null 2>&1 || true
PICK_HEAD_BEFORE="$(git -C "$TMP" rev-parse -q --verify CHERRY_PICK_HEAD || true)"
check "cherry-pick in progress: fixture stopped mid-pick" test -n "$PICK_HEAD_BEFORE"
printf 'own edit during pick\n' > "$TMP/notes/part.md"
BEFORE="$(index_signature)"; HEAD_BEFORE="$(git -C "$TMP" rev-parse HEAD)"
run_hook "$TMP/notes/part.md"
check_held_index "cherry-pick in progress" "$BEFORE" "$HEAD_BEFORE"
check "cherry-pick in progress: CHERRY_PICK_HEAD kept" test "$(git -C "$TMP" rev-parse -q --verify CHERRY_PICK_HEAD || true)" = "$PICK_HEAD_BEFORE"

# A private-index save must not re-hash the whole tree. `git commit` refreshes
# every entry of a HEAD-seeded index, which takes minutes on a large HQ.
new_case private-index-no-full-refresh
printf 'foreign staged\n' > "$TMP/outside.md"
git -C "$TMP" add -- outside.md
printf 'own edit\n' > "$TMP/notes/part.md"
TRACKED_COUNT="$(git -C "$TMP" ls-files | grep -c .)"
HEAD_BEFORE="$(git -C "$TMP" rev-parse HEAD)"
run_hook "$TMP/notes/part.md" GIT_TRACE2_PERF="$TMP_PARENT/private-index.perf"
MAX_LSTAT="$(sed -n 's/.*refresh\/sum_lstat:\([0-9][0-9]*\).*/\1/p' "$TMP_PARENT/private-index.perf" 2>/dev/null | sort -n | tail -1)"
check "private index: edited file saved" bash -c '[[ "$(git -C "$1" rev-parse HEAD)" != "$2" ]] && git -C "$1" show --name-only --format= HEAD | grep -qx notes/part.md' _ "$TMP" "$HEAD_BEFORE"
check "private index: commit has one parent, the previous HEAD" test "$(git -C "$TMP" rev-parse HEAD^)" = "$HEAD_BEFORE"
check "private index: trace captured" test -n "$MAX_LSTAT"
check "private index: no refresh over the whole tree" test "${MAX_LSTAT:-0}" -lt "$TRACKED_COUNT"
check "private index: shared index shows no staged revert of the saved file" test "$(git -C "$TMP" diff --cached --name-only)" = "outside.md"
check "private index: reflog names the autosave" bash -c 'git -C "$1" reflog -1 --format=%gs | grep -q "autosave(hq): notes/part.md"' _ "$TMP"


# Git quotes names holding `"` or `\` even with core.quotepath=false. Such a
# name must still count as this path's own partial stage and be held.
new_case quoted-name-overlap
printf 'one\ntwo\nthree\nfour\nfive\nsix\n' > "$TMP/notes/say \"hi\".md"
git -C "$TMP" add -- "notes/say \"hi\".md"
git -C "$TMP" commit -qm quoted
stage_partial 'notes/say "hi".md'
BEFORE="$(index_signature)"; HEAD_BEFORE="$(git -C "$TMP" rev-parse HEAD)"
run_hook "$TMP/notes/say \"hi\".md"
check_held_index "quoted name overlap" "$BEFORE" "$HEAD_BEFORE"

# A git writer holding the shared index lock makes the private-index save step
# aside. HEAD, the index and the other writer's lock are all left alone.
new_case index-busy
printf 'foreign staged\n' > "$TMP/outside.md"
git -C "$TMP" add -- outside.md
printf 'own edit\n' > "$TMP/notes/part.md"
: > "$TMP/.git/index.lock"
BEFORE="$(index_signature)"; HEAD_BEFORE="$(git -C "$TMP" rev-parse HEAD)"
run_hook "$TMP/notes/part.md"
check_held_index "index busy" "$BEFORE" "$HEAD_BEFORE"
check "index busy: other writer's lock left in place" test -e "$TMP/.git/index.lock"
check "index busy: skip is logged" grep -q 'SKIP stage=index-busy path=notes/part.md' "$TMP/workspace/logs/hq-autocommit.log"
rm -f "$TMP/.git/index.lock"
run_hook "$TMP/notes/part.md"
check "index busy: saves once the lock is released" bash -c '[[ "$(git -C "$1" rev-parse HEAD)" != "$2" ]]' _ "$TMP" "$HEAD_BEFORE"
check "index busy: hook releases its own lock" test ! -e "$TMP/.git/index.lock"

# If the shared-index fixup fails after HEAD moved, HEAD goes back so the
# shared index never shows a staged revert of the saved file.
new_case shared-index-fixup-fails
printf 'foreign staged\n' > "$TMP/outside.md"
git -C "$TMP" add -- outside.md
printf 'own edit\n' > "$TMP/notes/part.md"
FIXUP_SHIM="$TMP_PARENT/fixup-shim"
mkdir -p "$FIXUP_SHIM"
FIXUP_REAL_GIT="$(command -v git)"
cat > "$FIXUP_SHIM/git" <<'SH'
#!/usr/bin/env bash
for arg in "$@"; do
  if [[ "$arg" == "--cacheinfo" ]]; then
    echo "simulated update-index failure" >&2
    exit 1
  fi
done
exec "$REAL_GIT" "$@"
SH
chmod +x "$FIXUP_SHIM/git"
BEFORE="$(index_signature)"; HEAD_BEFORE="$(git -C "$TMP" rev-parse HEAD)"
run_hook "$TMP/notes/part.md" PATH="$FIXUP_SHIM:$PATH" REAL_GIT="$FIXUP_REAL_GIT"
check_held_index "shared-index fixup failure" "$BEFORE" "$HEAD_BEFORE"
check "shared-index fixup failure: failure is logged" grep -q 'FAIL stage=shared-index' "$TMP/workspace/logs/hq-autocommit.log"
check "shared-index fixup failure: lock released" test ! -e "$TMP/.git/index.lock"

# A staged rename lists only its new name by default. The old name must count
# as staged so recreating it is held instead of undoing the rename's delete.
new_case staged-rename
git -C "$TMP" mv notes/part.md notes/renamed.md
printf 'recreated\n' > "$TMP/notes/part.md"
BEFORE="$(index_signature)"; HEAD_BEFORE="$(git -C "$TMP" rev-parse HEAD)"
run_hook "$TMP/notes/part.md"
check_held_index "staged rename" "$BEFORE" "$HEAD_BEFORE"


# A name with glob characters must save only itself. As a glob it also matched
# a modified sibling, committed it, and left that sibling as a staged revert.
new_case glob-name
printf 'one\n' > "$TMP/notes/a[1].md"
printf 'one\n' > "$TMP/notes/a1.md"
git -C "$TMP" add -- 'notes/a[1].md' notes/a1.md
git -C "$TMP" commit -qm glob
printf 'foreign staged\n' > "$TMP/outside.md"
git -C "$TMP" add -- outside.md
printf 'changed\n' > "$TMP/notes/a[1].md"
printf 'sibling changed\n' > "$TMP/notes/a1.md"
HEAD_BEFORE="$(git -C "$TMP" rev-parse HEAD)"
run_hook "$TMP/notes/a[1].md"
check "glob name: saved" bash -c '[[ "$(git -C "$1" rev-parse HEAD)" != "$2" ]] && git -C "$1" show --name-only --format= HEAD | grep -Fqx "notes/a[1].md"' _ "$TMP" "$HEAD_BEFORE"
check "glob name: sibling not committed" bash -c '! git -C "$1" show --name-only --format= HEAD | grep -Fqx notes/a1.md' _ "$TMP"
check "glob name: only the foreign path is staged" test "$(git -C "$TMP" diff --cached --name-only)" = "outside.md"

# A signal during the shared-index fixup must not leave HEAD moved with the old
# entry in the shared index.
new_case fixup-interrupted
printf 'foreign staged\n' > "$TMP/outside.md"
git -C "$TMP" add -- outside.md
printf 'own edit\n' > "$TMP/notes/part.md"
KILL_SHIM="$TMP_PARENT/kill-shim"
mkdir -p "$KILL_SHIM"
cat > "$KILL_SHIM/git" <<'SH'
#!/usr/bin/env bash
for arg in "$@"; do
  if [[ "$arg" == "--cacheinfo" ]]; then
    # The parent is the hook's command-substitution subshell; signal the hook.
    kill -TERM "$(ps -o ppid= -p "$PPID" | tr -d ' ')"
    sleep 1
    exit 1
  fi
done
exec "$REAL_GIT" "$@"
SH
chmod +x "$KILL_SHIM/git"
BEFORE="$(index_signature)"; HEAD_BEFORE="$(git -C "$TMP" rev-parse HEAD)"
run_hook "$TMP/notes/part.md" PATH="$KILL_SHIM:$PATH" REAL_GIT="$(command -v git)"
check "interrupted fixup: HEAD rolled back" test "$(git -C "$TMP" rev-parse HEAD)" = "$HEAD_BEFORE"
check "interrupted fixup: staged blobs/modes and binary diff preserved" test "$(index_signature)" = "$BEFORE"
check "interrupted fixup: lock released" test ! -e "$TMP/.git/index.lock"

exit "$FAIL"
