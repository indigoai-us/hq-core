#!/usr/bin/env bash
# hq-core: public
# Regression test for core/scripts/ci/backmerge-apply.sh (feedback_907e56d6).
#
# Bug: the hq-core -> hq-core-staging backmerge copied every path a release
# push changed onto staging, so staging edits made after the release cut were
# overwritten (PR 1674 was rolled back and had to be restored by 1684).
#
# Covers:
#   1. A path staging has not touched since the cut is applied.
#   2. A path staging changed after the cut is kept and reported as skipped.
#   3. A file new in hq-core is added (with its exec bit).
#   4. A file deleted in hq-core is deleted when staging still has the cut
#      copy, and kept (reported) when staging changed it.
#   5. A path staging already matches is left alone; staging-local trees are
#      never touched.
#   6. The summary file lists the skipped paths.
#   7. The backmerge workflow calls the helper instead of copying blindly.
#   8. A glob-like name (f[1].md) does not overwrite a staging edit to f1.md,
#      and a non-ASCII name is applied, not dropped as quoted.
# shellcheck disable=SC2015,SC2016 # pass/fail one-liners; literal $ in grep pattern
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SCRIPT="$ROOT/core/scripts/ci/backmerge-apply.sh"
WORKFLOW="$ROOT/.github/workflows/backmerge-to-staging.yml"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fails=0
ACCENT=$'caf\303\251 x.md'
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }

g() { git -C "$TMP/src" -c user.name=t -c user.email=t@example.invalid "$@"; }

# hq-core source repo: BEFORE commit (the cut) and AFTER commit (the push).
mkdir -p "$TMP/src/core/a" "$TMP/src/core/b"
g init -q
printf 'unchanged v1\n' > "$TMP/src/core/a/plain.md"
printf 'diverged v1\n' > "$TMP/src/core/a/diverged.md"
printf 'gone v1\n' > "$TMP/src/core/b/gone.md"
printf 'gone-diverged v1\n' > "$TMP/src/core/b/gone-diverged.md"
printf 'same v1\n' > "$TMP/src/core/b/same.md"
printf 'glob v1\n' > "$TMP/src/core/b/f[1].md"
printf 'f1 v1\n' > "$TMP/src/core/b/f1.md"
printf 'accent v1\n' > "$TMP/src/core/b/$ACCENT"
g add -A && g commit -qm before
BEFORE="$(g rev-parse HEAD)"

# Staging at the cut is a copy of BEFORE; then staging changes two paths and
# picks up one hq-core change on its own.
mkdir -p "$TMP/tgt"
cp -R "$TMP/src/core" "$TMP/tgt/core"
mkdir -p "$TMP/tgt/companies/x"
printf 'staging only\n' > "$TMP/tgt/companies/x/keep.md"
printf 'diverged STAGING\n' > "$TMP/tgt/core/a/diverged.md"
printf 'gone-diverged STAGING\n' > "$TMP/tgt/core/b/gone-diverged.md"
printf 'same v2\n' > "$TMP/tgt/core/b/same.md"
printf 'f1 STAGING\n' > "$TMP/tgt/core/b/f1.md"

# hq-core push.
printf 'unchanged v2\n' > "$TMP/src/core/a/plain.md"
printf 'diverged v2\n' > "$TMP/src/core/a/diverged.md"
mkdir -p "$TMP/src/core/new"
printf '#!/bin/sh\necho new\n' > "$TMP/src/core/new/tool.sh"
chmod +x "$TMP/src/core/new/tool.sh"
rm "$TMP/src/core/b/gone.md" "$TMP/src/core/b/gone-diverged.md"
printf 'same v2\n' > "$TMP/src/core/b/same.md"
printf 'glob v2\n' > "$TMP/src/core/b/f[1].md"
printf 'accent v2\n' > "$TMP/src/core/b/$ACCENT"
mkdir -p "$TMP/src/companies/x"
printf 'from core\n' > "$TMP/src/companies/x/keep.md"
g add -A && g commit -qm after
AFTER="$(g rev-parse HEAD)"

g diff -z --no-renames --name-status "$BEFORE" "$AFTER" > "$TMP/changes.z"
SRC_STATUS_BEFORE="$(g status --porcelain)"

OUT="$(BACKMERGE_SUMMARY_FILE="$TMP/summary.md" bash "$SCRIPT" "$TMP/src" "$TMP/tgt" "$BEFORE" "$AFTER" "$TMP/changes.z")"
echo "$OUT"

# 1. unchanged path applied
[ "$(cat "$TMP/tgt/core/a/plain.md")" = "unchanged v2" ] && pass "unchanged path applied" || fail "unchanged path not applied"

# 2. post-cut change preserved and reported
[ "$(cat "$TMP/tgt/core/a/diverged.md")" = "diverged STAGING" ] && pass "diverged path kept" || fail "diverged path overwritten"
grep -qx 'skipped (staging diverged): core/a/diverged.md' <<<"$OUT" && pass "diverged path reported" || fail "diverged path not reported"

# 3. new file added with mode
[ "$(cat "$TMP/tgt/core/new/tool.sh" 2>/dev/null)" = "$(printf '#!/bin/sh\necho new')" ] && pass "new file added" || fail "new file missing"
[ -x "$TMP/tgt/core/new/tool.sh" ] && pass "new file keeps exec bit" || fail "new file lost exec bit"

# 4. deletions
[ ! -e "$TMP/tgt/core/b/gone.md" ] && pass "deleted file removed" || fail "deleted file still present"
[ "$(cat "$TMP/tgt/core/b/gone-diverged.md" 2>/dev/null)" = "gone-diverged STAGING" ] && pass "diverged file not deleted" || fail "diverged file deleted"
grep -qx 'skipped (staging diverged): core/b/gone-diverged.md' <<<"$OUT" && pass "diverged deletion reported" || fail "diverged deletion not reported"

# 5. already current + staging-local
grep -qx 'already current: core/b/same.md' <<<"$OUT" && pass "already-current path left alone" || fail "already-current path not detected"
[ "$(cat "$TMP/tgt/companies/x/keep.md")" = "staging only" ] && pass "staging-local tree untouched" || fail "staging-local tree overwritten"
[ "$(g status --porcelain)" = "$SRC_STATUS_BEFORE" ] && pass "source checkout not modified" || fail "source checkout modified"

# 8. glob-like and non-ASCII names
[ "$(cat "$TMP/tgt/core/b/f[1].md")" = "glob v2" ] && pass "glob-like name applied" || fail "glob-like name not applied"
[ "$(cat "$TMP/tgt/core/b/f1.md")" = "f1 STAGING" ] && pass "glob-like name does not touch f1.md" || fail "glob-like name overwrote f1.md"
[ "$(cat "$TMP/tgt/core/b/$ACCENT")" = "accent v2" ] && pass "non-ASCII name applied" || fail "non-ASCII name dropped"
grep -q '::warning file=core/a/diverged.md::' <<<"$OUT" && pass "skipped path raises a workflow warning" || fail "no warning for skipped path"

# 6. summary file
grep -q 'skipped: 2' "$TMP/summary.md" && grep -q 'core/a/diverged.md' "$TMP/summary.md" \
  && grep -q 'core/b/gone-diverged.md' "$TMP/summary.md" && pass "summary lists skipped paths" || fail "summary incomplete"

# Re-run is idempotent: nothing applied the second time.
OUT2="$(bash "$SCRIPT" "$TMP/src" "$TMP/tgt" "$BEFORE" "$AFTER" "$TMP/changes.z")"
grep -q 'applied: 0  deleted: 0' <<<"$OUT2" && pass "re-run is a no-op" || fail "re-run changed files"

# 7. workflow wiring
grep -q 'core/scripts/ci/backmerge-apply.sh' "$WORKFLOW" && pass "workflow calls backmerge-apply.sh" || fail "workflow does not call helper"
if grep -qE 'cp "source/\$PATHNAME"' "$WORKFLOW"; then fail "workflow still copies blindly"; else pass "workflow has no blind copy"; fi

if [ "$fails" -gt 0 ]; then
  echo "$fails check(s) failed"
  exit 1
fi
echo "all backmerge-apply checks passed"
