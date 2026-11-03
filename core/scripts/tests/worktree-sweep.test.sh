#!/usr/bin/env bash
# Regression: worktree-sweep.sh reports only dirty or unpushed worktrees and
# stays read-only.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
HELPER="$ROOT/core/scripts/worktree-sweep.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
[ -f "$HELPER" ] || fail "missing helper: $HELPER"

G="git -c user.email=t@example.com -c user.name=t"
mkdir -p "$TMP/root/workspace/worktrees/repo"
$G init -q "$TMP/origin-seed"
$G -C "$TMP/origin-seed" commit -q --allow-empty -m init
$G clone -q --bare "$TMP/origin-seed" "$TMP/origin.git"
for n in clean dirty ahead; do
  $G clone -q "$TMP/origin.git" "$TMP/root/workspace/worktrees/repo/$n"
done
echo x > "$TMP/root/workspace/worktrees/repo/dirty/f.txt"
$G -C "$TMP/root/workspace/worktrees/repo/ahead" commit -q --allow-empty -m local

OUT="$(bash "$HELPER" --root "$TMP/root")"
printf '%s\n' "$OUT" | grep 'repo/dirty.*dirty=1' >/dev/null || fail "dirty worktree not reported"
printf '%s\n' "$OUT" | grep 'repo/ahead.*ahead=1' >/dev/null || fail "ahead worktree not reported"
printf '%s\n' "$OUT" | grep 'repo/clean' >/dev/null && fail "clean worktree must not be reported"
[ -f "$TMP/root/workspace/worktrees/repo/dirty/f.txt" ] || fail "sweep must not modify worktrees"
echo "worktree-sweep: ok (dirty and ahead reported, clean omitted, read-only)"
