#!/usr/bin/env bash
# hq-core: public
# Regression: autosave must not skip silently forever when the HQ index already
# holds staged paths (feedback_09c2b7a0-fb5f-4da3-90fc-076a089aa497). It still
# leaves the foreign staged set alone, but it logs each skip and warns once the
# staged set outlives the staleness window.

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

# 1. Fresh pre-staged index: skip, keep the index, log the skip, no warning yet.
run_hook "$TMP/mine.md"
check "exit 0 while pre-staged" test "$RC" -eq 0
check "no commit while pre-staged" test "$(git -C "$TMP" rev-parse HEAD)" = "$HEAD0"
check "foreign staged path left staged" test "$(git -C "$TMP" diff --cached --name-only)" = "foreign.md"
check "skip is logged" grep -q 'SKIP stage=prestaged staged=1 path=mine.md' "$LOG"
check "no warning inside the staleness window" test -z "$OUT"

# 2. Past the window: warn once, not on every edit.
run_hook "$TMP/mine.md" HQ_AUTOCOMMIT_PRESTAGED_STALE_MINUTES=0
check "warning names the stuck index" bash -c '[[ "$1" == *"skipping edits because the HQ git index already has 1 staged path"* ]]' _ "$OUT"
run_hook "$TMP/mine.md" HQ_AUTOCOMMIT_PRESTAGED_STALE_MINUTES=0
check "warning is not repeated in the same session" test -z "$OUT"

# 3. Index cleared: autosave resumes and the pre-staged marker is dropped.
git -C "$TMP" reset -q -- foreign.md
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

# Positive controls: neither a partial stage outside the edited path nor an
# exact ASCII overlap is touched. The earlier clear-index check separately
# proves the ordinary no-contention autosave still commits.
new_case unrelated-partial
stage_partial outside.md
printf 'own changed\n' > "$TMP/notes/part.md"
BEFORE="$(index_signature)"; HEAD_BEFORE="$(git -C "$TMP" rev-parse HEAD)"
run_hook "$TMP/notes/part.md"
check_held_index "unrelated partial stage" "$BEFORE" "$HEAD_BEFORE"

new_case ascii-overlap
stage_partial notes/part.md
BEFORE="$(index_signature)"; HEAD_BEFORE="$(git -C "$TMP" rev-parse HEAD)"
run_hook "$TMP/notes/part.md"
check_held_index "exact ASCII overlap" "$BEFORE" "$HEAD_BEFORE"

exit "$FAIL"
