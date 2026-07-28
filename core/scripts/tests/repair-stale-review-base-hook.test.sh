#!/usr/bin/env bash
# hq-core: public
# Regression test for .claude/hooks/repair-stale-review-base.sh — the
# SessionStart hook that auto-repairs stale review-base refs in a top-level HQ
# install (the 2026-07-28 Codex desktop git-worker SIGTRAP crash).
#
# Locks the load-bearing properties:
#   • a stale top-level HQ root is repaired at session start: the stranded
#     remote-tracking ref is deleted, a banner explains it, exit is 0
#   • the repair is ref-only: local branch, history, and remote config survive
#   • a second run on the now-clean root is silent
#   • HQ_NO_STALE_BASE_AUTOFIX=1 downgrades to an advisory: banner, no deletion
#   • a clone nested inside another HQ root is left alone, silently
#   • a clean root, a missing project dir, and a missing detector all stay
#     silent with exit 0 — session start is never blocked
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
HOOK="$ROOT/.claude/hooks/repair-stale-review-base.sh"
[ -f "$HOOK" ] || { echo "FAIL: $HOOK not found" >&2; exit 1; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "ok: $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1" >&2; }

FIX="$(mktemp -d)"
trap 'rm -rf "$FIX"' EXIT

git_q() { git -C "$1" "${@:2}" >/dev/null 2>&1; }

# HQ-root-shaped git repo whose remote-tracking ref is stranded behind local
# HEAD. Mirrors the fixture in detect-stale-review-base.test.sh; the bare
# remote lives outside the work tree.
make_hq_root() { # <dir> <local-commits-after-push>
  local dir="$1" ahead="$2" i
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
  for i in $(seq 1 "$ahead"); do
    printf 'autosave %s\n' "$i" > "$dir/file-$i.txt"
    git_q "$dir" add -A
    git_q "$dir" commit -m "autosave(hq): file-$i.txt"
  done
}

run_hook() { # <project-dir> [extra env as K=V ...]
  local dir="$1"; shift
  env "$@" CLAUDE_PROJECT_DIR="$dir" \
    HQ_REVIEW_BASE_MAX_PATHS=5 HQ_REVIEW_BASE_MAX_COMMITS=5 \
    bash "$HOOK" </dev/null 2>/dev/null
}

# --- 1) stale top-level root is repaired with a banner ------------------------
STALE="$FIX/stale"
make_hq_root "$STALE" 12
head_before="$(git -C "$STALE" rev-parse main)"

out="$(run_hook "$STALE")"; rc=$?
[ $rc -eq 0 ] && ok "hook exits 0 on repair" || bad "hook should exit 0 on repair (got $rc)"
case "$out" in
  *stale-review-base-repaired*) ok "repair banner emitted" ;;
  *) bad "expected repair banner; got: $out" ;;
esac

if git -C "$STALE" show-ref --verify -q refs/remotes/origin/main; then
  bad "stale remote-tracking ref survived the hook"
else
  ok "hook deleted the stale remote-tracking ref"
fi

[ "$(git -C "$STALE" rev-parse main)" = "$head_before" ] \
  && ok "local branch untouched" || bad "hook moved the local branch"
[ "$(git -C "$STALE" rev-list --count main)" -eq 13 ] \
  && ok "local history preserved" || bad "hook altered local history"
[ -n "$(git -C "$STALE" remote get-url origin 2>/dev/null)" ] \
  && ok "configured remote preserved" || bad "hook removed the remote"

# --- 2) second run on the now-clean root is silent ----------------------------
out="$(run_hook "$STALE")"; rc=$?
if [ $rc -eq 0 ] && [ -z "$out" ]; then
  ok "clean root is silent"
else
  bad "clean root should be silent with exit 0; rc=$rc got: $out"
fi

# --- 3) HQ_NO_STALE_BASE_AUTOFIX=1 advises without deleting -------------------
ADVISE="$FIX/advise"
make_hq_root "$ADVISE" 12

out="$(run_hook "$ADVISE" HQ_NO_STALE_BASE_AUTOFIX=1)"; rc=$?
[ $rc -eq 0 ] && ok "advisory mode exits 0" || bad "advisory mode should exit 0 (got $rc)"
case "$out" in
  *stale-review-base-advisory*) ok "advisory banner emitted" ;;
  *) bad "expected advisory banner; got: $out" ;;
esac
if git -C "$ADVISE" show-ref --verify -q refs/remotes/origin/main; then
  ok "advisory mode left the ref in place"
else
  bad "advisory mode deleted the ref"
fi

# --- 4) a nested HQ-shaped clone is left alone, silently ----------------------
OUTER="$FIX/outer"
mkdir -p "$OUTER/core"
printf 'version: test\n' > "$OUTER/core/core.yaml"
CLONE="$OUTER/repos/private/hq-core-staging"
mkdir -p "$(dirname "$CLONE")"
make_hq_root "$CLONE" 12

out="$(run_hook "$CLONE")"; rc=$?
if [ $rc -eq 0 ] && [ -z "$out" ]; then
  ok "nested clone is silent"
else
  bad "nested clone should be silent with exit 0; rc=$rc got: $out"
fi
if git -C "$CLONE" show-ref --verify -q refs/remotes/origin/main; then
  ok "nested clone's ref survived"
else
  bad "hook deleted a nested clone's remote-tracking ref"
fi

# --- 5) degenerate inputs never block session start ---------------------------
out="$(run_hook "$FIX/does-not-exist")"; rc=$?
[ $rc -eq 0 ] && [ -z "$out" ] \
  && ok "missing project dir is silent with exit 0" \
  || bad "missing project dir should be silent; rc=$rc got: $out"

PLAIN="$FIX/plain"
mkdir -p "$PLAIN/core"
printf 'version: test\n' > "$PLAIN/core/core.yaml"
out="$(run_hook "$PLAIN")"; rc=$?
[ $rc -eq 0 ] && [ -z "$out" ] \
  && ok "non-git HQ root is silent with exit 0" \
  || bad "non-git HQ root should be silent; rc=$rc got: $out"

echo
echo "repair-stale-review-base-hook.test.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
