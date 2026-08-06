#!/usr/bin/env bash
# hq-core: public
# Tests for git-pack-extension-check.sh.
#
# Every case is built on a REAL repository with a REAL packfile, and the
# central assertions run git itself: the point of this check is that git
# cannot see a pack whose extension is gone, so a test that only inspected
# filenames would not prove the failure or the repair.

set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
SCRIPT="$ROOT/core/scripts/git-pack-extension-check.sh"
TMP_PARENT="$(mktemp -d)"
trap 'rm -rf "$TMP_PARENT"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }

# Build a repo whose entire history lives in one packfile.
make_packed_repo() {
  local dir="$1"
  mkdir -p "$dir"
  git -C "$dir" init -q
  git -C "$dir" config user.email "pack-test@hq"
  git -C "$dir" config user.name "Pack Test"
  printf 'one\n'   > "$dir/a.md"
  printf 'two\n'   > "$dir/b.md"
  git -C "$dir" add -A
  git -C "$dir" commit -qm "seed"
  # Pack everything and drop the loose copies, so the pack is load-bearing.
  git -C "$dir" gc -q --aggressive --prune=now
}

pack_dir_of() { printf '%s\n' "$1/.git/objects/pack"; }

orphan_in() {
  find "$1" -maxdepth 1 -type f -name 'pack-*' ! -name '*.*' | head -1
}

# --- 1. Healthy repo: reports ok, exits 0, changes nothing ------------------
REPO="$TMP_PARENT/healthy"
make_packed_repo "$REPO"
before="$(ls "$(pack_dir_of "$REPO")" | sort | tr '\n' ' ')"
rc=0
out="$(bash "$SCRIPT" --root "$REPO" 2>&1)" || rc=$?
[[ $rc -eq 0 ]] || fail "healthy repo should exit 0, got $rc"
[[ "$out" == *"ok"* ]] || fail "healthy repo should report ok; got: $out"
after="$(ls "$(pack_dir_of "$REPO")" | sort | tr '\n' ' ')"
[[ "$before" == "$after" ]] || fail "healthy repo pack dir must be untouched"

# --- 2. The failure actually breaks git -------------------------------------
# Establishes the premise. If git tolerated a missing extension there would
# be nothing to detect, so assert the breakage before asserting the fix.
REPO="$TMP_PARENT/broken"
make_packed_repo "$REPO"
PD="$(pack_dir_of "$REPO")"
PACK="$(find "$PD" -maxdepth 1 -name '*.pack' | head -1)"
[[ -n "$PACK" ]] || fail "fixture produced no .pack file"
mv "$PACK" "${PACK%.pack}"

if git -C "$REPO" fsck >/dev/null 2>&1; then
  fail "premise broken: git fsck should fail once the .pack extension is gone"
fi

# --- 3. Report-only: finds it, exits 2, does NOT repair ---------------------
rc=0
out="$(bash "$SCRIPT" --root "$REPO" 2>&1)" || rc=$?
[[ $rc -eq 2 ]] || fail "orphan present should exit 2 in report mode, got $rc"
[[ "$out" == *"FOUND"* ]] || fail "report mode should say FOUND; got: $out"
[[ "$out" == *".pack"* ]] || fail "report mode should name the missing extension; got: $out"
[[ -n "$(orphan_in "$PD")" ]] || fail "report mode must not rename anything"

# --- 4. --fix repairs it, and git agrees the repo is healthy again ----------
rc=0
out="$(bash "$SCRIPT" --root "$REPO" --fix 2>&1)" || rc=$?
[[ $rc -eq 0 ]] || fail "--fix should exit 0 after repairing, got $rc ($out)"
[[ "$out" == *"REPAIRED"* ]] || fail "--fix should report REPAIRED; got: $out"
[[ -z "$(orphan_in "$PD")" ]] || fail "--fix should leave no extensionless pack file"

git -C "$REPO" fsck >/dev/null 2>&1 || fail "repo should pass fsck after repair"
git -C "$REPO" status --porcelain >/dev/null 2>&1 || fail "git status should work after repair"
git -C "$REPO" log --oneline >/dev/null 2>&1 || fail "git log should work after repair"

# --- 5. Extension is chosen from magic bytes, not from guesswork ------------
# A .idx that lost its extension must come back as .idx, not .pack.
REPO="$TMP_PARENT/idx"
make_packed_repo "$REPO"
PD="$(pack_dir_of "$REPO")"
IDX="$(find "$PD" -maxdepth 1 -name '*.idx' | head -1)"
[[ -n "$IDX" ]] || fail "fixture produced no .idx file"
mv "$IDX" "${IDX%.idx}"
bash "$SCRIPT" --root "$REPO" --fix >/dev/null 2>&1 || fail "--fix should repair an orphaned .idx"
[[ -f "$IDX" ]] || fail "orphaned .idx must be restored with the .idx extension"
git -C "$REPO" fsck >/dev/null 2>&1 || fail "repo should pass fsck after .idx repair"

# --- 6. Never overwrite an existing target ---------------------------------
REPO="$TMP_PARENT/collide"
make_packed_repo "$REPO"
PD="$(pack_dir_of "$REPO")"
PACK="$(find "$PD" -maxdepth 1 -name '*.pack' | head -1)"
cp "$PACK" "${PACK%.pack}"          # orphan alongside a still-present .pack
sum_before="$(md5sum < "$PACK")"
rc=0
out="$(bash "$SCRIPT" --root "$REPO" --fix 2>&1)" || rc=$?
[[ $rc -eq 2 ]] || fail "a colliding target should exit 2, got $rc"
[[ "$out" == *"already exists"* ]] || fail "collision should be named explicitly; got: $out"
sum_after="$(md5sum < "$PACK")"
[[ "$sum_before" == "$sum_after" ]] || fail "an existing .pack must never be overwritten"

# --- 7. Unknown magic bytes are reported, never renamed --------------------
REPO="$TMP_PARENT/unknown"
make_packed_repo "$REPO"
PD="$(pack_dir_of "$REPO")"
printf 'not a packfile at all\n' > "$PD/pack-deadbeef"
rc=0
out="$(bash "$SCRIPT" --root "$REPO" --fix 2>&1)" || rc=$?
[[ $rc -eq 2 ]] || fail "unknown-magic orphan should exit 2, got $rc"
[[ "$out" == *"not a pack/idx/rev signature"* ]] || fail "unknown magic should be explained; got: $out"
[[ -f "$PD/pack-deadbeef" ]] || fail "a file with unknown magic must be left exactly where it is"
[[ ! -e "$PD/pack-deadbeef.pack" ]] || fail "a file with unknown magic must never be renamed to .pack"

# --- 8. Non-repository root is an error, not a false clean bill ------------
rc=0
bash "$SCRIPT" --root "$TMP_PARENT/not-a-repo-at-all" >/dev/null 2>&1 || rc=$?
[[ $rc -eq 1 ]] || fail "a missing root should exit 1, got $rc"

# --- 9. Linked worktrees resolve to the shared object store ----------------
# Packs live in the common git dir; a worktree must not report a false clean.
REPO="$TMP_PARENT/wt-main"
make_packed_repo "$REPO"
WT="$TMP_PARENT/wt-linked"
git -C "$REPO" worktree add -q -b probe "$WT" >/dev/null 2>&1
PD="$(pack_dir_of "$REPO")"
PACK="$(find "$PD" -maxdepth 1 -name '*.pack' | head -1)"
mv "$PACK" "${PACK%.pack}"
rc=0
bash "$SCRIPT" --root "$WT" >/dev/null 2>&1 || rc=$?
[[ $rc -eq 2 ]] || fail "checking from a linked worktree should find the shared store's orphan, got $rc"
bash "$SCRIPT" --root "$WT" --fix >/dev/null 2>&1 || fail "--fix from a linked worktree should repair"
git -C "$REPO" fsck >/dev/null 2>&1 || fail "repo should pass fsck after worktree-side repair"

echo "git-pack-extension-check: ok"
