#!/usr/bin/env bash
# hq-core: public
# Regression test for core/scripts/detect-stale-review-base.sh — the detector
# for remote-tracking refs in an HQ root that have fallen far enough behind
# local HEAD that a review tool auto-selecting a base builds a whole-tree diff
# from one (the 2026-07-28 Codex desktop git-worker SIGTRAP / 5.5 GB RSS crash).
#
# Locks the load-bearing safety properties:
#   • a ref past either threshold is reported, and --check exits 1
#   • a ref within both thresholds is NOT reported, and --check exits 0
#   • --fix deletes only refs/remotes/*, never refs/heads/*, and leaves the
#     configured remote in place so `git fetch` still works
#   • a non-HQ directory (no core/core.yaml) is REFUSED
#   • an HQ-root-SHAPED repo nested inside another HQ root is REFUSED — a
#     repos/ clone of hq-core carries core/core.yaml too, so shape alone
#     cannot keep --fix away from working clones; position does
#   • an HQ root that is not a git repo, or has no remote-tracking refs, is
#     clean rather than an error
#   • --json stays parseable and reports the measured counts
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SCRIPT="$ROOT/core/scripts/detect-stale-review-base.sh"
[ -f "$SCRIPT" ] || { echo "FAIL: $SCRIPT not found" >&2; exit 1; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "ok: $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1" >&2; }

FIX="$(mktemp -d)"
trap 'rm -rf "$FIX"' EXIT

git_q() { git -C "$1" "${@:2}" >/dev/null 2>&1; }

# Build an HQ-root-shaped git repo with a remote whose tracking ref is stranded
# `$2` commits behind local HEAD, each commit touching a distinct path.
make_hq_root() { # <dir> <local-commits-after-push>
  local dir="$1" ahead="$2" i
  # The bare remote lives OUTSIDE the work tree — a bare repo nested inside it
  # would be swept up by `git add -A` and inflate the measured path counts.
  local upstream="${dir}-upstream"
  mkdir -p "$dir/core" "$upstream"
  printf 'version: test\n' > "$dir/core/core.yaml"
  git -C "$upstream" init -q --bare -b main
  git -C "$dir" init -q -b main
  git -C "$dir" config user.email hq@test.local
  git -C "$dir" config user.name "HQ Test"
  git -C "$dir" config commit.gpgsign false
  printf 'seed\n' > "$dir/seed.txt"
  git_q "$dir" add -A
  git_q "$dir" commit -m "seed"
  git_q "$dir" remote add origin "$upstream"
  git_q "$dir" push origin main
  # Local-only autosave commits the remote-tracking ref never receives.
  for i in $(seq 1 "$ahead"); do
    printf 'autosave %s\n' "$i" > "$dir/file-$i.txt"
    git_q "$dir" add -A
    git_q "$dir" commit -m "autosave(hq): file-$i.txt"
  done
}

# --- 1) stale root: past the path threshold ---------------------------------
STALE="$FIX/stale"
make_hq_root "$STALE" 12

out="$("$SCRIPT" --root "$STALE" --max-paths 5 --max-commits 5 2>&1)"
case "$out" in
  *"refs/remotes/origin/main"*) ok "stale ref is reported" ;;
  *) bad "stale ref not reported; got: $out" ;;
esac

"$SCRIPT" --root "$STALE" --max-paths 5 --max-commits 5 --check >/dev/null 2>&1
[ $? -eq 1 ] && ok "--check exits 1 when stale" || bad "--check should exit 1 when stale"

json="$("$SCRIPT" --root "$STALE" --max-paths 5 --max-commits 5 --json 2>/dev/null)"
case "$json" in
  *'"ref":"refs/remotes/origin/main"'*'"commits_ahead":12'*'"changed_paths":12'*)
    ok "--json reports ref with measured counts" ;;
  *) bad "--json malformed or wrong counts; got: $json" ;;
esac

# --- 2) thresholds are respected (not just "any remote is stale") ------------
out="$("$SCRIPT" --root "$STALE" --max-paths 500 --max-commits 500 2>&1)"
case "$out" in
  *clean*) ok "ref within both thresholds is not flagged" ;;
  *) bad "should be clean under generous thresholds; got: $out" ;;
esac

"$SCRIPT" --root "$STALE" --max-paths 500 --max-commits 500 --check >/dev/null 2>&1
[ $? -eq 0 ] && ok "--check exits 0 when within thresholds" || bad "--check should exit 0 when clean"

# Either threshold alone is sufficient to flag.
"$SCRIPT" --root "$STALE" --max-paths 500 --max-commits 5 --check >/dev/null 2>&1
[ $? -eq 1 ] && ok "commit threshold alone flags" || bad "commit threshold alone should flag"
"$SCRIPT" --root "$STALE" --max-paths 5 --max-commits 500 --check >/dev/null 2>&1
[ $? -eq 1 ] && ok "path threshold alone flags" || bad "path threshold alone should flag"

# --- 3) --fix removes the ref, and ONLY the ref ------------------------------
head_before="$(git -C "$STALE" rev-parse main)"
"$SCRIPT" --root "$STALE" --max-paths 5 --max-commits 5 --fix >/dev/null 2>&1

if git -C "$STALE" show-ref --verify -q refs/remotes/origin/main; then
  bad "--fix left the stale remote-tracking ref in place"
else
  ok "--fix deleted the stale remote-tracking ref"
fi

if [ "$(git -C "$STALE" rev-parse main)" = "$head_before" ]; then
  ok "--fix left refs/heads/main untouched"
else
  bad "--fix moved or removed the local branch"
fi

if [ -n "$(git -C "$STALE" remote get-url origin 2>/dev/null)" ]; then
  ok "--fix left the configured remote in place"
else
  bad "--fix removed the remote itself"
fi

# Local commits must survive: the repair is ref-only, never history rewriting.
if [ "$(git -C "$STALE" rev-list --count main)" -eq 13 ]; then
  ok "--fix preserved all local history"
else
  bad "--fix altered local history"
fi

"$SCRIPT" --root "$STALE" --max-paths 5 --max-commits 5 --check >/dev/null 2>&1
[ $? -eq 0 ] && ok "root is clean after --fix" || bad "root still flagged after --fix"

# The deletion is recoverable — this is why --fix is safe to run.
git_q "$STALE" fetch origin
if git -C "$STALE" show-ref --verify -q refs/remotes/origin/main; then
  ok "a later fetch recreates the ref (repair is recoverable)"
else
  bad "fetch did not restore the ref"
fi

# --- 4) a non-HQ directory is refused ---------------------------------------
# This is the guard that keeps --fix away from repos/ clones, where a tracking
# ref far behind local HEAD is completely normal.
NOTHQ="$FIX/not-hq"
mkdir -p "$NOTHQ"
git -C "$NOTHQ" init -q -b main
git -C "$NOTHQ" config user.email hq@test.local
git -C "$NOTHQ" config user.name "HQ Test"
printf 'x\n' > "$NOTHQ/x.txt"
git_q "$NOTHQ" add -A
git_q "$NOTHQ" commit -m "x"

"$SCRIPT" --root "$NOTHQ" --fix >/dev/null 2>&1
[ $? -eq 2 ] && ok "non-HQ directory is refused (exit 2)" || bad "non-HQ directory should exit 2"

# --- 4b) an HQ-root-shaped clone NESTED inside an HQ root is refused ---------
# A repos/ clone of hq-core ships core/core.yaml, so it passes the shape check.
# The 2026-07-28 gap: --fix pointed at such a clone would have deleted remote
# refs a working clone legitimately depends on. Position is the discriminator:
# real HQ roots are never nested inside another HQ root.
OUTER="$FIX/outer"
mkdir -p "$OUTER/core"
printf 'version: test\n' > "$OUTER/core/core.yaml"
CLONE="$OUTER/repos/private/hq-core-staging"
mkdir -p "$(dirname "$CLONE")"
make_hq_root "$CLONE" 12   # stale-shaped on purpose: nesting alone must refuse it

"$SCRIPT" --root "$CLONE" --max-paths 5 --max-commits 5 --fix >/dev/null 2>&1
if [ $? -eq 2 ]; then
  ok "nested HQ-shaped clone is refused (exit 2)"
else
  bad "nested HQ-shaped clone should exit 2"
fi

if git -C "$CLONE" show-ref --verify -q refs/remotes/origin/main; then
  ok "nested clone's remote-tracking ref survived the refused --fix"
else
  bad "nested clone's remote-tracking ref was deleted despite the refusal"
fi

# A symlink to the nested clone must not dodge the position check.
LINK="$FIX/looks-top-level"
ln -s "$CLONE" "$LINK"
"$SCRIPT" --root "$LINK" --max-paths 5 --max-commits 5 --fix >/dev/null 2>&1
if [ $? -eq 2 ] && git -C "$CLONE" show-ref --verify -q refs/remotes/origin/main; then
  ok "symlinked path to a nested clone is still refused"
else
  bad "symlink dodged the nesting guard"
fi

# --- 5) HQ root that is not a git repo is clean, not an error ---------------
PLAIN="$FIX/plain"
mkdir -p "$PLAIN/core"
printf 'version: test\n' > "$PLAIN/core/core.yaml"
out="$("$SCRIPT" --root "$PLAIN" 2>&1)"; rc=$?
if [ $rc -eq 0 ] && case "$out" in *clean*) true ;; *) false ;; esac; then
  ok "non-git HQ root reports clean"
else
  bad "non-git HQ root should report clean; rc=$rc got: $out"
fi

# --- 6) HQ root with no remote at all is clean -------------------------------
NOREMOTE="$FIX/no-remote"
mkdir -p "$NOREMOTE/core"
printf 'version: test\n' > "$NOREMOTE/core/core.yaml"
git -C "$NOREMOTE" init -q -b main
git -C "$NOREMOTE" config user.email hq@test.local
git -C "$NOREMOTE" config user.name "HQ Test"
git_q "$NOREMOTE" add -A
git_q "$NOREMOTE" commit -m "seed"
out="$("$SCRIPT" --root "$NOREMOTE" 2>&1)"; rc=$?
if [ $rc -eq 0 ] && case "$out" in *clean*) true ;; *) false ;; esac; then
  ok "HQ root with no remote-tracking refs reports clean"
else
  bad "no-remote HQ root should report clean; rc=$rc got: $out"
fi

# --- 7) argument validation --------------------------------------------------
"$SCRIPT" --root "$STALE" --max-paths abc >/dev/null 2>&1
[ $? -eq 2 ] && ok "non-numeric --max-paths rejected" || bad "non-numeric --max-paths should exit 2"
"$SCRIPT" --root "$STALE" --bogus-flag >/dev/null 2>&1
[ $? -eq 2 ] && ok "unknown flag rejected" || bad "unknown flag should exit 2"

echo
echo "detect-stale-review-base.test.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
