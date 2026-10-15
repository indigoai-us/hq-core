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
LIVE_PID=""
trap '[[ -n "$LIVE_PID" ]] && kill "$LIVE_PID" 2>/dev/null; rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

# ---- isolate git config ----
export HOME="$TMP"
export GIT_TERMINAL_PROMPT=0
git config --global init.defaultBranch main
git config --global user.email "gc-test@example.com"
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
# far past → never "recent-activity": the directory plus its HEAD and HEAD reflog.
mk_old_mtime() {
  local gd
  touch -t 202001010000 "$1"
  gd=$(git -C "$1" rev-parse --path-format=absolute --git-dir)
  touch -t 202001010000 "$gd/HEAD" "$gd/logs/HEAD"
}

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

# (h) jq.exe CRLF scalar output must not enter Bash arithmetic.
WT_H="$HQ/workspace/worktrees/case-h"
git -C "$REPO" worktree add -q -b wt-h "$WT_H" origin/main
write_stamp "$WT_H" "$YOUNG_EPOCH"; mk_old_mtime "$WT_H"

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

# (i) clean + merged + old, but a live process has its cwd inside → skipped
#     [live-session]. This is the reported shape: an open session's worktree.
WT_I="$HQ/workspace/worktrees/case-i"
git -C "$REPO" worktree add -q -b wt-i "$WT_I" origin/main
mkdir -p "$WT_I/src"
write_stamp "$WT_I" "$OLD_EPOCH"
(cd "$WT_I/src" && exec sleep 600) &
LIVE_PID=$!
mk_old_mtime "$WT_I"

# (j) clean + merged + old, no process inside, but a session transcript written
#     in the last 7 days recorded a cwd inside it → skipped [recent-session].
WT_J="$HQ/workspace/worktrees/case-j"
git -C "$REPO" worktree add -q -b wt-j "$WT_J" origin/main
write_stamp "$WT_J" "$OLD_EPOCH"; mk_old_mtime "$WT_J"
mkdir -p "$HOME/.claude/projects/p1"
printf '{"type":"user","cwd":"%s/docs","sessionId":"s1"}\n' "$WT_J" > "$HOME/.claude/projects/p1/s1.jsonl"
# A transcript older than the window does not hold case-a.
printf '{"type":"user","cwd":"%s","sessionId":"s0"}\n' "$WT_A" > "$HOME/.claude/projects/p1/s0.jsonl"
touch -t 202001010000 "$HOME/.claude/projects/p1/s0.jsonl"

# (k) clean + old, branch pushed to origin at the same tip (not merged into
#     main), no session → REMOVED.
WT_K="$HQ/workspace/worktrees/case-k"
git -C "$REPO" worktree add -q -b wt-k "$WT_K" origin/main
echo pushed > "$WT_K/pushed.txt"
git -C "$WT_K" add pushed.txt
git -C "$WT_K" commit -qm "pushed work"
git -C "$WT_K" push -q -u origin wt-k
write_stamp "$WT_K" "$OLD_EPOCH"; mk_old_mtime "$WT_K"

# (m) clean + pushed + old directory, but a commit landed in the last 2h (HEAD
#     reflog is fresh) → skipped [recent-activity].
WT_M="$HQ/workspace/worktrees/case-m"
git -C "$REPO" worktree add -q -b wt-m "$WT_M" origin/main
write_stamp "$WT_M" "$OLD_EPOCH"; mk_old_mtime "$WT_M"
echo fresh > "$WT_M/fresh.txt"
git -C "$WT_M" add fresh.txt
git -C "$WT_M" commit -qm "fresh commit"
git -C "$WT_M" push -q -u origin wt-m
touch -t 202001010000 "$WT_M"

phys() { (cd "$1" && pwd -P); }
P_B=$(phys "$WT_B"); P_C=$(phys "$WT_C"); P_I=$(phys "$WT_I"); P_J=$(phys "$WT_J"); P_K=$(phys "$WT_K"); P_M=$(phys "$WT_M")

run_gc() { HQ_ROOT="$HQ" bash "$GC" "$@"; }

# ---- (f) dry-run (default) makes NO changes ----
out=$(run_gc --dry-run 2>&1) || fail "dry-run exited non-zero"
for d in "$WT_A" "$WT_B" "$WT_C" "$WT_D" "$WT_E" "$WT_G" "$WT_I" "$WT_J" "$WT_K" "$WT_M"; do
  [[ -d "$d" ]] || fail "dry-run removed $d (must make no changes)"
done
[[ "$out" == *"would remove"* ]] || fail "dry-run did not report a would-remove candidate"
git -C "$REPO" worktree list | grep -q "case-a" || fail "dry-run pruned a worktree registration"

# Every skip carries a printed reason.
for pair in "dirty|$P_B" "unpushed|$P_C" "live-session|$P_I" "recent-session|$P_J" "recent-activity|$P_M"; do
  reason="${pair%%|*}"; wtp="${pair#*|}"
  printf '%s\n' "$out" | grep -Fq "skip  [$reason] $wtp" || fail "dry-run did not print [$reason] for $wtp: $out"
done
printf '%s\n' "$out" | grep -F "$P_K" | grep -q "would remove" || fail "(k) pushed stale worktree not a candidate: $out"

# default (no flag) is also dry-run
run_gc >/dev/null 2>&1 || fail "default run exited non-zero"
[[ -d "$WT_A" ]] || fail "default (no --apply) removed a worktree"

# ---- JSON summary shape ----
json=$(run_gc --dry-run --json 2>/dev/null) || fail "json run failed"
echo "$json" | jq -e '.examined >= 6' >/dev/null || fail "json.examined wrong"
echo "$json" | jq -e '.mode == "dry-run"' >/dev/null || fail "json.mode wrong"

REAL_JQ="$(command -v jq)"
mkdir -p "$TMP/crlf-bin"
cat > "$TMP/crlf-bin/jq" <<'STUB'
#!/usr/bin/env bash
if [ "${1:-}" = "-r" ] && [ "${2:-}" = '.createdAtEpoch // empty' ]; then
  : > "$CRLF_JQ_READ_MARKER"
  set +e
  "$REAL_JQ" "$@" | sed 's/$/\r/'
  jq_rc=${PIPESTATUS[0]}
  set -e
  exit "$jq_rc"
fi
exec "$REAL_JQ" "$@"
STUB
chmod +x "$TMP/crlf-bin/jq"
CRLF_JQ_READ_MARKER="$TMP/crlf-jq-read"
crlf_output="$(PATH="$TMP/crlf-bin:$PATH" REAL_JQ="$REAL_JQ" CRLF_JQ_READ_MARKER="$CRLF_JQ_READ_MARKER" HQ_ROOT="$HQ" bash "$GC" --dry-run 2>&1)" \
  || fail "worktree-gc failed with CRLF jq timestamp output: $crlf_output"
[[ -f "$CRLF_JQ_READ_MARKER" ]] || fail "worktree-gc did not read a stamped epoch under the CRLF jq stub"
printf '%s\n' "$crlf_output" | grep -Fq "[too-recent] $(phys "$WT_H")" \
  || fail "CRLF jq timestamp changed the too-recent classification for $WT_H: $crlf_output"
echo "PASS: worktree-gc normalizes CRLF jq epoch values before arithmetic"

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
[[ -d "$WT_H" ]] || fail "(h) CRLF-stamped too-recent worktree was removed"
# (e) active-session preserved
[[ -d "$WT_E" ]] || fail "(e) active-session worktree was removed"

# (i) live session preserved
[[ -d "$WT_I" ]] || fail "(i) worktree with a live process cwd inside was removed"
# (j) recent session transcript preserved
[[ -d "$WT_J" ]] || fail "(j) worktree recorded as a recent session cwd was removed"
# (k) clean, pushed, unowned, stale → removed
[[ ! -d "$WT_K" ]] || fail "(k) clean+pushed+old unowned worktree was NOT removed"
git -C "$REPO" cat-file -e origin/wt-k:pushed.txt || fail "(k) pushed work missing from origin"
# (m) recent commit preserved
[[ -d "$WT_M" ]] || fail "(m) worktree with a commit in the last 2h was removed"

# The session window is configurable; at 0 hours the transcript no longer holds (j).
out0=$(HQ_WORKTREE_SESSION_WINDOW_HOURS=0 run_gc --dry-run 2>&1) || fail "window=0 run failed"
printf '%s\n' "$out0" | grep -F "$P_J" | grep -q "would remove" || fail "(j) still held with a 0h session window: $out0"

kill "$LIVE_PID" 2>/dev/null || true
wait "$LIVE_PID" 2>/dev/null || true
LIVE_PID=""

echo "PASS: worktree-gc.test.sh"
