#!/usr/bin/env bash
# hq-core: public
# Tests for git-icon-file-check.sh.
#
# Every case runs on a real repository and the central assertions run git
# itself: `git fsck` must be clean and `git commit` must succeed after --fix,
# and must fail before it, so a test that only looked at filenames would not
# prove the repair.

set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
SCRIPT="$ROOT/core/scripts/git-icon-file-check.sh"
TMP_PARENT="$(mktemp -d)"
trap 'rm -rf "$TMP_PARENT"' EXIT

ICON="Icon"$'\r'
# GIT_ICON_TEST_BASH=/bin/bash runs the script under macOS bash 3.2.
RUN_BASH="${GIT_ICON_TEST_BASH:-bash}"
PASS=0

fail() { echo "FAIL: $1" >&2; exit 1; }
pass() { PASS=$((PASS + 1)); }

# Isolate HOME so the iCloud check never reads the real one.
export HOME="$TMP_PARENT/home"
mkdir -p "$HOME"
export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL="$HOME/.gitconfig"
git config --global user.email "icon-test@example.com"
git config --global user.name "Icon Test"
git config --global init.defaultBranch main

# A repo with one commit, a real `Icons` file in the work tree, and
# look-alike names inside .git that must survive.
make_repo() {
  local dir="$1"
  mkdir -p "$dir/companies/example-co/data"
  git -C "$dir" init -q
  printf 'one\n' > "$dir/a.md"
  printf 'real icons file\n' > "$dir/Icons"
  printf 'col\n1\n' > "$dir/companies/example-co/data/report.csv"
  git -C "$dir" add -A
  git -C "$dir" commit -qm "seed"
  printf 'keep\n' > "$dir/.git/info/Icons"
  printf 'keep\n' > "$dir/.git/info/Icon"
}

seed_icons() {
  local dir="$1"
  mkdir -p "$dir/.git/objects/ab"
  : > "$dir/.git/objects/ab/$ICON"
  : > "$dir/.git/refs/$ICON"
}

# Stage a new file, then delete its loose object: the index now points at a
# missing blob, which is what turns stray icons into "Error building trees".
stage_then_lose_object() {
  local dir="$1" rel="$2" content="$3" sha
  printf '%s' "$content" > "$dir/$rel"
  git -C "$dir" add -- "$rel"
  sha="$(git -C "$dir" rev-parse ":$rel")"
  rm -f "$dir/.git/objects/${sha:0:2}/${sha:2}"
  printf '%s\n' "$sha"
}

count_icons() { find "$1/.git" -type f -name "$ICON" | wc -l | tr -d ' '; }

# --- 1. Clean repo: ok, exit 0, nothing changes -----------------------------
REPO="$TMP_PARENT/clean"
make_repo "$REPO"
rc=0; out="$("$RUN_BASH" "$SCRIPT" --root "$REPO" 2>&1)" || rc=$?
[ "$rc" -eq 0 ] || fail "clean repo should exit 0, got $rc: $out"
[[ "$out" == *"ok:"* ]] || fail "clean repo should report ok; got: $out"
[[ "$out" != *"warning:"* ]] || fail "no iCloud warning expected outside iCloud; got: $out"
pass

# --- 2. The premise: icons plus a lost object break fsck and commit ----------
REPO="$TMP_PARENT/broken"
make_repo "$REPO"
seed_icons "$REPO"
LOST="$(stage_then_lose_object "$REPO" "companies/example-co/data/current.csv" $'col\n2\n')"
rc=0; git -C "$REPO" fsck --no-dangling > /dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail "premise: fsck should fail with icons and a lost object"
rc=0; git -C "$REPO" commit -qm "should fail" > "$TMP_PARENT/commit.out" 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail "premise: commit should fail before the fix"
grep -q "Error building trees" "$TMP_PARENT/commit.out" || fail "premise: expected 'Error building trees'"
pass

# --- 3. Report mode finds both icons and the lost object, changes nothing ---
rc=0; out="$("$RUN_BASH" "$SCRIPT" --root "$REPO" 2>&1)" || rc=$?
[ "$rc" -eq 2 ] || fail "report should exit 2 when icons are found, got $rc: $out"
[[ "$out" == *"found 2 Icon\\r file(s)"* ]] || fail "report should count 2 icons; got: $out"
[[ "$out" == *"objects/ab/Icon\\r"* ]] || fail "report should list objects/ab/Icon\\r; got: $out"
[[ "$out" == *"refs/Icon\\r"* ]] || fail "report should list refs/Icon\\r; got: $out"
[[ "$out" == *"$LOST"* ]] || fail "report should list the lost object $LOST; got: $out"
[ "$(count_icons "$REPO")" = "2" ] || fail "report mode must not delete anything"
pass

# --- 4. --fix removes both icons, restores the object, fsck and commit pass -
rc=0; out="$("$RUN_BASH" "$SCRIPT" --root "$REPO" --fix 2>&1)" || rc=$?
[ "$rc" -eq 0 ] || fail "--fix should exit 0, got $rc: $out"
[ "$(count_icons "$REPO")" = "0" ] || fail "--fix left Icon\\r files behind"
[ ! -e "$REPO/.git/objects/ab/$ICON" ] || fail "objects/ab/Icon\\r still present"
[ ! -e "$REPO/.git/refs/$ICON" ] || fail "refs/Icon\\r still present"
[[ "$out" == *"$LOST: restored from companies/example-co/data/current.csv"* ]] \
  || fail "--fix should restore $LOST from the working file; got: $out"
git -C "$REPO" fsck --no-dangling > /dev/null 2>&1 || fail "fsck should be clean after --fix"
git -C "$REPO" commit -qm "after fix" || fail "commit should succeed after --fix"
pass

# --- 5. Look-alike names are untouched ---------------------------------------
[ "$(cat "$REPO/Icons")" = "real icons file" ] || fail "work-tree Icons file changed"
[ -f "$REPO/.git/info/Icons" ] || fail ".git/info/Icons was deleted"
[ -f "$REPO/.git/info/Icon" ] || fail ".git/info/Icon was deleted"
git -C "$REPO" ls-files --error-unmatch Icons > /dev/null || fail "Icons left the index"
pass

# --- 6. Never invent data: a changed working file is not written ------------
REPO="$TMP_PARENT/changed"
make_repo "$REPO"
seed_icons "$REPO"
LOST="$(stage_then_lose_object "$REPO" "notes.md" $'staged text\n')"
printf 'edited after staging\n' > "$REPO/notes.md"
rc=0; out="$("$RUN_BASH" "$SCRIPT" --root "$REPO" --fix 2>&1)" || rc=$?
[ "$rc" -eq 2 ] || fail "--fix should exit 2 when an object cannot be restored, got $rc: $out"
[ "$(count_icons "$REPO")" = "0" ] || fail "--fix should still delete icons"
[[ "$out" == *"$LOST: working file notes.md hashes to"* ]] || fail "should say the working file differs; got: $out"
if git -C "$REPO" cat-file -e "$LOST" 2>/dev/null; then
  fail "an object was written although the working file does not match"
fi
pass

# --- 6b. Awkward paths: spaces, a tab and a leading dash ---------------------
REPO="$TMP_PARENT/awkward"
make_repo "$REPO"
mkdir -p "$REPO/dir with space"
LOST="$(stage_then_lose_object "$REPO" "dir with space/-lead"$'\t'"tab.csv" $'x\n')"
rc=0; out="$("$RUN_BASH" "$SCRIPT" --root "$REPO" --fix 2>&1)" || rc=$?
[ "$rc" -eq 0 ] || fail "awkward path --fix should exit 0, got $rc: $out"
git -C "$REPO" cat-file -e "$LOST" || fail "awkward path object was not restored"
git -C "$REPO" commit -qm "awkward" || fail "commit should succeed after awkward-path restore"
pass

# --- 7. Icons only, no lost object: fsck clean after --fix -------------------
REPO="$TMP_PARENT/icons-only"
make_repo "$REPO"
seed_icons "$REPO"
mkdir -p "$REPO/.git/logs/refs"
: > "$REPO/.git/logs/refs/$ICON"
rc=0; out="$("$RUN_BASH" "$SCRIPT" --root "$REPO" --fix 2>&1)" || rc=$?
[ "$rc" -eq 0 ] || fail "icons-only --fix should exit 0, got $rc: $out"
[[ "$out" == *"deleting 3 Icon\\r file(s)"* ]] || fail "should delete 3 icons; got: $out"
[ "$(count_icons "$REPO")" = "0" ] || fail "icons-only --fix left files"
pass

# --- 8. Linked worktree: scans the shared git dir ----------------------------
REPO="$TMP_PARENT/main-wt"
make_repo "$REPO"
git -C "$REPO" worktree add -q "$TMP_PARENT/linked" -b side
seed_icons "$REPO"
rc=0; out="$("$RUN_BASH" "$SCRIPT" --root "$TMP_PARENT/linked" 2>&1)" || rc=$?
[ "$rc" -eq 2 ] || fail "worktree report should exit 2, got $rc: $out"
[[ "$out" == *"found 2 Icon\\r file(s)"* ]] || fail "worktree report should find 2 icons; got: $out"
pass

# --- 9. iCloud Desktop warning ------------------------------------------------
mkdir -p "$HOME/Library/Mobile Documents/com~apple~CloudDocs/Desktop"
REPO="$HOME/Desktop/hq"
make_repo "$REPO"
rc=0; out="$("$RUN_BASH" "$SCRIPT" --root "$REPO" 2>&1)" || rc=$?
[ "$rc" -eq 0 ] || fail "warning must not change the exit code, got $rc"
[[ "$out" == *"warning:"*"iCloud-synced Desktop folder"* ]] || fail "expected an iCloud Desktop warning; got: $out"

# Desktop without iCloud sync: no warning.
rm -rf "$HOME/Library/Mobile Documents/com~apple~CloudDocs/Desktop"
out="$("$RUN_BASH" "$SCRIPT" --root "$REPO" 2>&1)" || true
[[ "$out" != *"warning:"* ]] || fail "no warning expected when Desktop is not synced; got: $out"

# Documents with iCloud sync, and iCloud Drive itself.
mkdir -p "$HOME/Library/Mobile Documents/com~apple~CloudDocs/Documents"
REPO="$HOME/Documents/hq"
make_repo "$REPO"
out="$("$RUN_BASH" "$SCRIPT" --root "$REPO" 2>&1)" || true
[[ "$out" == *"iCloud-synced Documents folder"* ]] || fail "expected an iCloud Documents warning; got: $out"
REPO="$HOME/Library/Mobile Documents/com~apple~CloudDocs/hq"
make_repo "$REPO"
out="$("$RUN_BASH" "$SCRIPT" --root "$REPO" 2>&1)" || true
[[ "$out" == *"inside iCloud Drive"* ]] || fail "expected an iCloud Drive warning; got: $out"
pass

# --- 10. Usage errors ----------------------------------------------------------
rc=0; "$RUN_BASH" "$SCRIPT" --bogus > /dev/null 2>&1 || rc=$?
[ "$rc" -eq 1 ] || fail "unknown argument should exit 1, got $rc"
rc=0; "$RUN_BASH" "$SCRIPT" --root "$TMP_PARENT/does-not-exist" > /dev/null 2>&1 || rc=$?
[ "$rc" -eq 1 ] || fail "missing root should exit 1, got $rc"
mkdir -p "$TMP_PARENT/not-a-repo"
rc=0; "$RUN_BASH" "$SCRIPT" --root "$TMP_PARENT/not-a-repo" > /dev/null 2>&1 || rc=$?
[ "$rc" -eq 1 ] || fail "non-repo root should exit 1, got $rc"
out="$("$RUN_BASH" "$SCRIPT" --help)"
[[ "$out" == *"--fix"* ]] || fail "--help should print usage"
pass

echo "git-icon-file-check: $PASS passed, 0 failed"
