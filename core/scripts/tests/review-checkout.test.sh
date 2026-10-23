#!/usr/bin/env bash
# hq-core: public
# Regression test for core/scripts/review-checkout.sh and the review guidance
# that points at it.
#
# Bug: local PR reviews made a fresh clone in /tmp per PR (often per PR head),
# reinstalled dependencies and ran the full test suite every time, ran several
# at once, and never deleted the clones. On one Mac that left 81 clones and
# kept fseventsd near 100% CPU.
#
# Covers:
#   1. Reviewing three PRs of one repo reuses one cached checkout under
#      workspace/review-cache and creates nothing in TMPDIR.
#   2. Ignored dependency dirs survive between PRs; `install` is `needed`
#      only for the first review and when a lockfile changed.
#   3. `affected` lists only the package and test the diff touches.
#   4. `heavy` never runs two commands at once, propagates the exit status,
#      and reclaims a lock left by a dead process.
#   5. `cleanup` removes the per-review scratch dir and PR ref and keeps the
#      cached checkout.
#   6. `stray` reports leftover per-PR clones and deletes nothing.
#   7. The /review skill and the core policy describe the cached-checkout
#      flow and no longer leave room for a fresh clone per PR.
#   8. One active review per cached checkout: a second PR's prepare during
#      an unreleased review exits 73 and leaves the first head and files; only
#      the owning PR's cleanup releases it; prepare and cleanup take the lock.

# shellcheck disable=SC2015,SC2012 # pass/fail one-liners; inode check via ls -di
set -euo pipefail

SRC_ROOT="$(git -C "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" rev-parse --show-toplevel)"
SCRIPT="$SRC_ROOT/core/scripts/review-checkout.sh"
T="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/review-checkout-test.XXXXXX")" && pwd -P)"
trap 'rm -rf "$T"' EXIT

FAILS=0
fail() { printf 'FAIL: %s\n' "$*" >&2; FAILS=$((FAILS + 1)); }
pass() { printf 'ok: %s\n' "$*"; }
kv() { printf '%s\n' "$1" | sed -n "s/^$2=//p" | head -1; }

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid
export GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
export GIT_CONFIG_NOSYSTEM=1 HOME="$T/home"
mkdir -p "$HOME"
git config --global init.defaultBranch main
git config --global uploadpack.allowFilter true

# --- fixture: an "origin" with refs/pull/<n>/head ---------------------------
SRC="$T/src"
ORIGIN="$T/origin.git"
git init -q "$SRC"
mkdir -p "$SRC/packages/app/src" "$SRC/packages/lib/src" "$SRC/scripts/tests"
printf 'node_modules/\n' > "$SRC/.gitignore"
printf '{"name":"app"}\n' > "$SRC/packages/app/package.json"
printf '{"name":"lib"}\n' > "$SRC/packages/lib/package.json"
printf 'export const a = 1;\n' > "$SRC/packages/app/src/a.ts"
printf 'export const b = 1;\n' > "$SRC/packages/lib/src/b.ts"
printf 'lock v1\n' > "$SRC/package-lock.json"
printf '#!/usr/bin/env bash\necho tool\n' > "$SRC/scripts/tool.sh"
printf '#!/usr/bin/env bash\necho test\n' > "$SRC/scripts/tests/tool.test.sh"
git -C "$SRC" add -A && git -C "$SRC" commit -qm base
git clone -q --bare "$SRC" "$ORIGIN"

mkpr() { # mkpr <n> <commit message> -- edits run in $SRC on a branch off main
  local n="$1" msg="$2"; shift 2
  git -C "$SRC" checkout -q -B "pr$n" main
  "$@"
  git -C "$SRC" add -A && git -C "$SRC" commit -qm "$msg"
  git -C "$SRC" push -q "$ORIGIN" "HEAD:refs/pull/$n/head"
  git -C "$SRC" checkout -q main
}
edit_app() { printf 'export const a = 2;\n' > "$SRC/packages/app/src/a.ts"; printf 'test\n' > "$SRC/packages/app/src/a.test.ts"; }
edit_tool() { printf '#!/usr/bin/env bash\necho tool2\n' > "$SRC/scripts/tool.sh"; }
edit_lock() { printf 'lock v2\n' > "$SRC/package-lock.json"; printf 'export const b = 2;\n' > "$SRC/packages/lib/src/b.ts"; }
mkpr 1 "pr1 app" edit_app
mkpr 2 "pr2 tool" edit_tool
mkpr 3 "pr3 lock" edit_lock

HQ="$T/hq"
mkdir -p "$HQ/workspace"
SCRATCH_TMP="$T/tmpdir"
mkdir -p "$SCRATCH_TMP"
rc() { TMPDIR="$SCRATCH_TMP" bash "$SCRIPT" "$@" --hq-root "$HQ" --remote-url "$ORIGIN"; }
CACHE="$HQ/workspace/review-cache"
CO="$CACHE/acme__widgets"

# --- 1 + 2: one cached checkout, install only when the lockfile moves -------
out1="$(rc prepare --repo acme/widgets --pr 1)" || { fail "prepare pr1 failed"; out1=''; }
[ "$(kv "$out1" checkout)" = "$CO" ] && pass "checkout path is workspace/review-cache/<owner>__<name>" \
  || fail "checkout path: $(kv "$out1" checkout)"
[ "$(kv "$out1" head)" = "$(git -C "$ORIGIN" rev-parse refs/pull/1/head)" ] && pass "pr1 head checked out" \
  || fail "pr1 head mismatch"
[ "$(kv "$out1" install)" = needed ] && pass "first review needs an install" || fail "pr1 install=$(kv "$out1" install)"
[ "$(kv "$out1" reports)" = "$HQ/workspace/reports/reviews" ] && [ -d "$HQ/workspace/reports/reviews" ] \
  && pass "reports dir is workspace/reports/reviews" || fail "reports dir: $(kv "$out1" reports)"

mkdir -p "$CO/node_modules/dep" && printf 'x\n' > "$CO/node_modules/dep/index.js"
printf 'stray scratch\n' > "$CO/untracked-probe.txt"
TMPDIR="$SCRATCH_TMP" bash "$SCRIPT" installed --repo acme/widgets --hq-root "$HQ" >/dev/null || fail "installed failed"
gitdir_before="$(cd "$CO/.git" && pwd -P)"
ino_before="$(ls -di "$CO/.git" | awk '{print $1}')"
rc cleanup --repo acme/widgets --pr 1 >/dev/null || fail "cleanup pr1 failed"
printf 'stray scratch\n' > "$CO/untracked-probe.txt"

out2="$(rc prepare --repo acme/widgets --pr 2)" || { fail "prepare pr2 failed"; out2=''; }
[ "$(kv "$out2" install)" = skip ] && pass "same lockfile skips the install" || fail "pr2 install=$(kv "$out2" install)"
[ -f "$CO/node_modules/dep/index.js" ] && pass "node_modules kept between PRs" || fail "node_modules was removed"
[ ! -e "$CO/untracked-probe.txt" ] && pass "untracked review leftovers cleared on the next prepare" \
  || fail "untracked file survived prepare"
[ "$(ls -di "$CO/.git" | awk '{print $1}')" = "$ino_before" ] && [ "$(cd "$CO/.git" && pwd -P)" = "$gitdir_before" ] \
  && pass "same checkout reused (no new clone)" || fail "checkout was re-cloned"

rc cleanup --repo acme/widgets --pr 2 >/dev/null || fail "cleanup pr2 failed"
out3="$(rc prepare --repo acme/widgets --pr 3)" || { fail "prepare pr3 failed"; out3=''; }
[ "$(kv "$out3" install)" = needed ] && pass "changed lockfile needs an install" || fail "pr3 install=$(kv "$out3" install)"
[ "$(kv "$out3" head)" = "$(git -C "$ORIGIN" rev-parse refs/pull/3/head)" ] && pass "pr3 head checked out" \
  || fail "pr3 head mismatch"

clones="$(find "$CACHE" -mindepth 1 -maxdepth 1 -type d ! -name '.*' | wc -l | tr -d ' ')"
[ "$clones" = 1 ] && pass "three PRs, one cached checkout" || fail "expected 1 cached checkout, found $clones"
leftover="$(find "$SCRATCH_TMP" -mindepth 1 | head -5)"
[ -z "$leftover" ] && pass "nothing written to TMPDIR" || fail "TMPDIR not empty: $leftover"

# --- 3: affected -------------------------------------------------------------
rc cleanup --repo acme/widgets --pr 3 >/dev/null || fail "cleanup pr3 failed"
rc prepare --repo acme/widgets --pr 1 >/dev/null || fail "re-prepare pr1 failed"
aff1="$(rc affected --repo acme/widgets)" || fail "affected pr1 failed"
printf '%s\n' "$aff1" | grep -x 'package=packages/app' >/dev/null && pass "affected lists the touched package" \
  || fail "affected pr1 missing packages/app: $aff1"
printf '%s\n' "$aff1" | grep 'packages/lib' >/dev/null && fail "affected pr1 lists untouched packages/lib" \
  || pass "affected leaves untouched packages out"
printf '%s\n' "$aff1" | grep -x 'test=packages/app/src/a.test.ts' >/dev/null && pass "affected lists the changed test" \
  || fail "affected pr1 missing a.test.ts: $aff1"
rc cleanup --repo acme/widgets --pr 1 >/dev/null || fail "cleanup pr1 (affected) failed"
rc prepare --repo acme/widgets --pr 2 >/dev/null || fail "re-prepare pr2 failed"
aff2="$(rc affected --repo acme/widgets)" || fail "affected pr2 failed"
printf '%s\n' "$aff2" | grep -x 'test=scripts/tests/tool.test.sh' >/dev/null && pass "affected maps a script to its test" \
  || fail "affected pr2 missing scripts/tests/tool.test.sh: $aff2"

# --- 4: heavy lock -----------------------------------------------------------
HEAVY_LOG="$T/heavy.log"
: > "$HEAVY_LOG"
job() { # job <name>: holds a "running" marker for 1s and logs overlap
  TMPDIR="$SCRATCH_TMP" bash "$SCRIPT" heavy --hq-root "$HQ" -- bash -c '
    if [ -e "$1/running" ]; then echo OVERLAP >> "$1/heavy.log"; fi
    : > "$1/running"; echo "start $2" >> "$1/heavy.log"; sleep 1
    rm -f "$1/running"; echo "end $2" >> "$1/heavy.log"' _ "$T" "$1" 2>/dev/null
}
job a & pa=$!
job b & pb=$!
job c & pc=$!
wait "$pa" "$pb" "$pc" || fail "a heavy job failed"
grep -q OVERLAP "$HEAVY_LOG" && fail "heavy commands overlapped: $(tr '\n' ' ' < "$HEAVY_LOG")" \
  || pass "heavy commands ran one at a time"
[ "$(grep -c '^end ' "$HEAVY_LOG")" = 3 ] && pass "all three heavy commands ran" || fail "heavy log: $(cat "$HEAVY_LOG")"
[ ! -e "$CACHE/.heavy.lock" ] && pass "heavy lock released" || fail "heavy lock left behind"

set +e
TMPDIR="$SCRATCH_TMP" bash "$SCRIPT" heavy --hq-root "$HQ" -- bash -c 'exit 7' 2>/dev/null
st=$?
set -e
[ "$st" = 7 ] && pass "heavy propagates the command's exit status" || fail "heavy exit status $st, want 7"

mkdir -p "$CACHE/.heavy.lock"
bash -c 'exit 0' & deadpid=$!
wait "$deadpid"
printf '%s\n' "$deadpid" > "$CACHE/.heavy.lock/pid"
if TMPDIR="$SCRATCH_TMP" HQ_REVIEW_LOCK_TIMEOUT=10 bash "$SCRIPT" heavy --hq-root "$HQ" -- true 2>/dev/null; then
  pass "stale lock from a dead process is reclaimed"
else
  fail "stale lock was not reclaimed"
fi

mkdir -p "$CACHE/.heavy.lock"
printf '%s\n' "$$" > "$CACHE/.heavy.lock/pid"
set +e
TMPDIR="$SCRATCH_TMP" bash "$SCRIPT" heavy --hq-root "$HQ" --timeout 1 -- true 2>/dev/null
st=$?
set -e
[ "$st" = 75 ] && pass "live lock holder blocks until timeout (75)" || fail "live lock: exit $st, want 75"
[ "$(cat "$CACHE/.heavy.lock/pid")" = "$$" ] && pass "a waiter never removes a live holder's lock" \
  || fail "live holder's lock was taken"
rm -rf "$CACHE/.heavy.lock"

# --- 5: cleanup --------------------------------------------------------------
scr2="$(kv "$out2" scratch)"
if [ -n "$scr2" ] && [ -d "$scr2" ]; then
  printf 'log\n' > "$scr2/review.log"
else
  fail "pr2 scratch dir missing before cleanup"
  scr2="$T/no-scratch"
fi
rc cleanup --repo acme/widgets --pr 2 >/dev/null || fail "cleanup failed"
[ ! -e "$scr2" ] && pass "cleanup removes the per-review scratch dir" || fail "scratch dir survived cleanup"
git -C "$CO" rev-parse -q --verify refs/review/pr-2 >/dev/null && fail "pr ref survived cleanup" \
  || pass "cleanup deletes the PR ref"
[ -d "$CO/.git" ] && [ -f "$CO/node_modules/dep/index.js" ] && pass "cleanup keeps the cached checkout" \
  || fail "cleanup removed the cached checkout"

# --- 8: one active review per cached checkout (review of bundle #1602) -------
# Repro: prepare PR1, leave that review unreleased, prepare PR2. Before the
# fix PR1's checkout HEAD moved to PR2's head.
head1="$(git -C "$ORIGIN" rev-parse refs/pull/1/head)"
o81="$(rc prepare --repo acme/widgets --pr 1)" || fail "prepare pr1 (active review) failed"
scr81="$(kv "$o81" scratch)"
printf 'reviewer one wip\n' > "$CO/reviewer-one.txt"
set +e
err82="$(rc prepare --repo acme/widgets --pr 2 2>&1 >/dev/null)"
st=$?
set -e
[ "$st" = 73 ] && pass "second prepare during an active review is refused (73)" || fail "second prepare exit $st, want 73"
[ "$(git -C "$CO" rev-parse HEAD)" = "$head1" ] && pass "second prepare does not move the first review's head" \
  || fail "first review's head moved to $(git -C "$CO" rev-parse HEAD)"
printf '%s\n' "$err82" | grep 'PR 1' >/dev/null && pass "refusal names the active review" || fail "refusal message: $err82"
[ -f "$CO/reviewer-one.txt" ] && pass "refused prepare leaves the active review's files" || fail "active review's file removed"
[ ! -e "$CACHE/.scratch/acme__widgets-pr-2" ] && pass "refused prepare creates no scratch" || fail "refused prepare made scratch"
rc prepare --repo acme/widgets --pr 1 >/dev/null && pass "the active review can prepare its own PR again" \
  || fail "re-prepare of the active PR refused"
printf 'reviewer one wip\n' > "$CO/reviewer-one.txt"

rc cleanup --repo acme/widgets --pr 2 >/dev/null || fail "cleanup of a non-active PR failed"
[ -f "$CO/reviewer-one.txt" ] && [ "$(git -C "$CO" rev-parse HEAD)" = "$head1" ] \
  && pass "another PR's cleanup leaves the active review alone" || fail "another PR's cleanup touched the active review"
set +e
rc prepare --repo acme/widgets --pr 2 >/dev/null 2>&1; st=$?
set -e
[ "$st" = 73 ] && pass "another PR's cleanup does not release the checkout" || fail "checkout released by PR2 cleanup (exit $st)"

# The lock covers prepare and cleanup, not only heavy.
mkdir -p "$CACHE/.heavy.lock"
printf '%s\n' "$$" > "$CACHE/.heavy.lock/pid"
set +e
HQ_REVIEW_LOCK_TIMEOUT=1 rc prepare --repo acme/widgets --pr 1 >/dev/null 2>&1; stp=$?
HQ_REVIEW_LOCK_TIMEOUT=1 rc cleanup --repo acme/widgets --pr 1 >/dev/null 2>&1; stc=$?
set -e
[ "$stp" = 75 ] && pass "prepare waits on the review lock" || fail "prepare under a held lock exit $stp, want 75"
[ "$stc" = 75 ] && pass "cleanup waits on the review lock" || fail "cleanup under a held lock exit $stc, want 75"
[ -d "$scr81" ] && [ -f "$CO/reviewer-one.txt" ] && pass "nothing cleaned while the lock was held" \
  || fail "cleanup ran without the lock"
rm -rf "$CACHE/.heavy.lock"

rc cleanup --repo acme/widgets --pr 1 >/dev/null || fail "cleanup of the active review failed"
[ ! -e "$CO/reviewer-one.txt" ] && pass "owner's cleanup clears its working files" || fail "owner's cleanup left files"
o82="$(rc prepare --repo acme/widgets --pr 2)" || fail "prepare pr2 after release failed"
[ "$(kv "$o82" head)" = "$(git -C "$ORIGIN" rev-parse refs/pull/2/head)" ] && pass "released checkout serves the next review" \
  || fail "pr2 head after release mismatch"
rc cleanup --repo acme/widgets --pr 2 >/dev/null || fail "final cleanup pr2 failed"
[ ! -e "$(git -C "$CO" rev-parse --absolute-git-dir)/hq-review-active" ] && pass "cleanup removes the active-review record" \
  || fail "active-review record left behind"

# --- 6: stray report ---------------------------------------------------------
FAKE_TMP="$T/faketmp"
mkdir -p "$FAKE_TMP/rv-12" "$FAKE_TMP/other"
git init -q "$FAKE_TMP/rv-12"
stray="$(bash "$SCRIPT" stray --hq-root "$HQ" --dir "$FAKE_TMP")" || fail "stray failed"
printf '%s\n' "$stray" | grep "^stray=$FAKE_TMP/rv-12" >/dev/null && pass "stray reports a leftover review clone" \
  || fail "stray output: $stray"
printf '%s\n' "$stray" | grep other >/dev/null && fail "stray reported a non-review dir" || pass "stray ignores other dirs"
[ -d "$FAKE_TMP/rv-12/.git" ] && pass "stray deletes nothing" || fail "stray deleted a clone"

# --- input validation ---------------------------------------------------------
for bad in 'acme' '../x/y' 'acme/../x' 'a b/c'; do
  if rc prepare --repo "$bad" --pr 1 >/dev/null 2>&1; then fail "accepted bad --repo '$bad'"; fi
done
if rc prepare --repo acme/widgets --pr '1;x' >/dev/null 2>&1; then fail "accepted bad --pr"; fi
pass "bad --repo and --pr rejected"

# --- 7: review guidance points at the cached-checkout flow ---------------------
SKILL="$SRC_ROOT/.claude/skills/review/SKILL.md"
POLICY="$SRC_ROOT/core/policies/hq-pr-review-light-local-footprint.md"
grep -q 'core/scripts/review-checkout.sh' "$SKILL" && pass "/review skill uses review-checkout.sh" \
  || fail "/review skill does not mention core/scripts/review-checkout.sh"
if grep -iE 'fresh[^.]{0,30}clone' "$SKILL" | grep -viqE 'never|do not|instead of'; then
  fail "/review skill still allows a fresh clone per PR"
fi
[ -f "$POLICY" ] && pass "core policy exists" || fail "missing $POLICY"
for needle in 'review-checkout.sh' 'workspace/review-cache' 'workspace/reports/reviews' 'heavy' 'cleanup' 'CI'; do
  grep -q "$needle" "$POLICY" 2>/dev/null || fail "policy does not mention $needle"
done
grep -q 'review-checkout.sh' "$SRC_ROOT/.claude/skills/super-conductor/SKILL.md" \
  && pass "super-conductor review duty uses review-checkout.sh" \
  || fail "super-conductor SKILL.md does not mention review-checkout.sh"

if [ "$FAILS" -gt 0 ]; then
  printf '\n%s check(s) failed\n' "$FAILS" >&2
  exit 1
fi
printf '\nreview-checkout: all checks passed\n'
