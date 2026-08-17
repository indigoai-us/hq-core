#!/usr/bin/env bash
# Regression test: worktree-gc.sh must remove only provably-safe stale worktrees
# and NEVER touch dirty, unmerged, too-recent, or in-use ones.
#
# Fixtures are local temp git repos — no network. The "pushable" origin is a bare
# repo whose PATH contains "github" so it satisfies the github-remote guard while
# `git fetch` stays fully offline.

set -euo pipefail

SRC_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"   # .../core
GC="$SRC_ROOT/scripts/worktree-gc.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

# ---- isolate git config ----
export HOME="$TMP"
export GIT_TERMINAL_PROMPT=0
git config --global init.defaultBranch main
git config --global user.email "[EMAIL]"
git config --global user.name "GC Test"
git config --global commit.gpgsign false
git config --global advice.detachedHead false

NOW=$(date -u +%s)
OLD_EPOCH=$((NOW - 30 * 86400))     # 30d — older than retention
YOUNG_EPOCH=$((NOW - 86400))        # 1d  — inside retention window

# ---- HQ root is itself a git repo (exercises the local-only path) ----
HQ="$TMP/hqroot"
mkdir -p "$HQ"
git -C "$HQ" init -q
echo root > "$HQ/README.md"
git -C "$HQ" add README.md
git -C "$HQ" commit -qm "hq root init"

mkdir -p "$HQ/workspace/worktrees" "$HQ/.claude/worktrees" "$HQ/workspace/sessions"

# ---- pushable github origin + working clone ----
BARE="$TMP/github.com-origin.git"     # path contains "github"
git init -q --bare "$BARE"
REPO="$TMP/repo"
git clone -q "$BARE" "$REPO"
echo hello > "$REPO/file.txt"
git -C "$REPO" add file.txt
git -C "$REPO" commit -qm "initial"
git -C "$REPO" push -q origin main
git -C "$REPO" fetch -q origin

gc_key() { printf '%s' "$(cd "$1" && pwd -P)" | cksum | cut -d' ' -f1; }
write_stamp() { # <wt> <epoch>
  local key; key=$(gc_key "$1")
  mkdir -p "$HQ/workspace/worktrees/.gc-meta"
  printf '{"createdAtEpoch":%s}' "$2" > "$HQ/workspace/worktrees/.gc-meta/$key.json"
}
mk_old_mtime() { touch -t 202001010000 "$1"; }   # far past → never "recent-activity"

# (a) clean + merged + old  → REMOVED
WT_A="$HQ/workspace/worktrees/case-a"
git -C "$REPO" worktree add -q -b wt-a "$WT_A" origin/main
write_stamp "$WT_A" "$OLD_EPOCH"; mk_old_mtime "$WT_A"

# (b) DIRTY  → never removed
WT_B="$HQ/workspace/worktrees/case-b"
git -C "$REPO" worktree add -q -b wt-b "$WT_B" origin/main
echo scratch > "$WT_B/uncommitted.txt"      # untracked → dirty
write_stamp "$WT_B" "$OLD_EPOCH"; mk_old_mtime "$WT_B"

# (c) local-only unmerged commit  → never removed
WT_C="$HQ/workspace/worktrees/case-c"
git -C "$REPO" worktree add -q -b wt-c "$WT_C" origin/main
echo local-only > "$WT_C/secret.txt"
git -C "$WT_C" add secret.txt
git -C "$WT_C" commit -qm "local-only work"   # ahead of origin, unpushed
write_stamp "$WT_C" "$OLD_EPOCH"; mk_old_mtime "$WT_C"

# (d) too-recent  → skipped
WT_D="$HQ/workspace/worktrees/case-d"
git -C "$REPO" worktree add -q -b wt-d "$WT_D" origin/main
write_stamp "$WT_D" "$YOUNG_EPOCH"; mk_old_mtime "$WT_D"

# (e) active-session referenced  → skipped
WT_E="$HQ/workspace/worktrees/case-e"
git -C "$REPO" worktree add -q -b wt-e "$WT_E" origin/main
write_stamp "$WT_E" "$OLD_EPOCH"; mk_old_mtime "$WT_E"
SID="11111111-2222-3333-4444-555555555555"
mkdir -p "$HQ/workspace/sessions/$SID"
{ echo "session_id: $SID"; echo "cwd: $(cd "$WT_E" && pwd -P)"; } > "$HQ/workspace/sessions/$SID/meta.yaml"

# (g) HQ-root local-only, merged into HQ main  → REMOVED (exercises is_hq_root)
WT_G="$HQ/.claude/worktrees/agent-test"
git -C "$HQ" worktree add -q -b agent-br "$WT_G" main
write_stamp "$WT_G" "$OLD_EPOCH"; mk_old_mtime "$WT_G"

run_gc() { HQ_ROOT="$HQ" bash "$GC" "$@"; }

# ---- (f) dry-run (default) makes NO changes ----
out=$(run_gc --dry-run 2>&1) || fail "dry-run exited non-zero"
for d in "$WT_A" "$WT_B" "$WT_C" "$WT_D" "$WT_E" "$WT_G"; do
  [[ -d "$d" ]] || fail "dry-run removed $d (must make no changes)"
done
echo "$out" | grep -q "would remove" || fail "dry-run did not report a would-remove candidate"
git -C "$REPO" worktree list | grep -q "case-a" || fail "dry-run pruned a worktree registration"

# default (no flag) is also dry-run
run_gc >/dev/null 2>&1 || fail "default run exited non-zero"
[[ -d "$WT_A" ]] || fail "default (no --apply) removed a worktree"

# ---- JSON summary shape ----
json=$(run_gc --dry-run --json 2>/dev/null) || fail "json run failed"
echo "$json" | jq -e '.examined >= 6' >/dev/null || fail "json.examined wrong"
echo "$json" | jq -e '.mode == "dry-run"' >/dev/null || fail "json.mode wrong"

# ---- apply: only safe ones go ----
run_gc --apply >/dev/null 2>&1 || fail "apply exited non-zero"

# (a) removed
[[ ! -d "$WT_A" ]] || fail "(a) clean+merged+old worktree was NOT removed"
git -C "$REPO" branch --list wt-a | grep -q wt-a && fail "(a) branch wt-a not deleted"
# (g) HQ-root merged removed
[[ ! -d "$WT_G" ]] || fail "(g) HQ-root merged worktree was NOT removed"
# (b) dirty preserved
[[ -d "$WT_B" ]] || fail "(b) DIRTY worktree was removed"
# (c) unmerged preserved
[[ -d "$WT_C" ]] || fail "(c) unmerged local-only worktree was removed"
[[ -f "$WT_C/secret.txt" ]] || fail "(c) local-only commit content lost"
# (d) too-recent preserved
[[ -d "$WT_D" ]] || fail "(d) too-recent worktree was removed"
# (e) active-session preserved
[[ -d "$WT_E" ]] || fail "(e) active-session worktree was removed"

echo "PASS: worktree-gc.test.sh"
