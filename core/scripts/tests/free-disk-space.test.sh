#!/usr/bin/env bash
# Safety regression for free-disk-space.sh.
# Fixtures are local temp git repos — no network.
# A full clone is never removed. A linked worktree with an unpushed side branch
# is kept. A linked worktree with an ignored .env is kept. Caches outside the
# developer allowlist survive. The default dry run deletes nothing.

set -euo pipefail

SRC_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$SRC_ROOT/scripts/free-disk-space.sh"

TMP=$(mktemp -d)
LIVE_PID=""
trap '[ -n "$LIVE_PID" ] && kill "$LIVE_PID" 2>/dev/null; rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

export HOME="$TMP/home"
export GIT_TERMINAL_PROMPT=0
mkdir -p "$HOME"
git config --global init.defaultBranch main
git config --global user.email "disk-test@example.com"
git config --global user.name "Disk Test"
git config --global commit.gpgsign false
git config --global advice.detachedHead false
# Hides untracked files from plain `git status`. The script must not honor it.
git config --global status.showUntrackedFiles no
mkdir -p "$TMP/no-hooks"
git config --global core.hooksPath "$TMP/no-hooks"

HQ="$TMP/hqroot"
mkdir -p "$HQ/workspace/worktrees"
# Real layout: HQ root is a git repo that ignores /workspace/.
git init -q "$HQ"
printf '/workspace/\n' > "$HQ/.gitignore"
git -C "$HQ" add .gitignore
GIT_AUTHOR_DATE=2020-01-01T00:00:00 GIT_COMMITTER_DATE=2020-01-01T00:00:00 \
  git -C "$HQ" commit -qm "root" --date=2020-01-01T00:00:00
run() { HQ_ROOT="$HQ" bash "$SCRIPT" "$@"; }

# Backdates the tree and, for a linked worktree, its HEAD and HEAD reflog.
backdate() {
  local gd
  find "$1" -exec touch -t 202001010000 {} +
  gd=$(git -C "$1" rev-parse --path-format=absolute --git-dir 2>/dev/null) || gd=""
  if [ -n "$gd" ]; then
    touch -t 202001010000 "$gd/HEAD" 2>/dev/null || true
    [ -f "$gd/logs/HEAD" ] && touch -t 202001010000 "$gd/logs/HEAD"
  fi
  return 0
}

make_origin() {
  local bare="$1" repo="$2"
  git init -q "$repo"
  printf 'hello\n' > "$repo/file.txt"
  git -C "$repo" add file.txt
  git -C "$repo" commit -qm "initial"
  git init -q --bare "$bare"
  git -C "$repo" remote add origin "$bare"
  git -C "$repo" push -q -u origin main
}

# ---- repo A: clean linked worktree, only rebuildable ignored files ----
BARE_A="$TMP/origin-a.git"
REPO_A="$TMP/repo-a"
make_origin "$BARE_A" "$REPO_A"
WT_SAFE="$HQ/workspace/worktrees/safe"
git -C "$REPO_A" worktree add -q -b wt-safe "$WT_SAFE" origin/main
printf 'node_modules/\n' > "$WT_SAFE/.gitignore"
git -C "$WT_SAFE" add .gitignore
git -C "$WT_SAFE" commit -qm "ignore node_modules"
git -C "$WT_SAFE" push -q -u origin wt-safe
mkdir -p "$WT_SAFE/node_modules"
printf 'x\n' > "$WT_SAFE/node_modules/pkg.js"
backdate "$WT_SAFE"

# ---- repo B: linked worktree, HEAD pushed, side branch unpushed ----
BARE_B="$TMP/origin-b.git"
REPO_B="$TMP/repo-b"
make_origin "$BARE_B" "$REPO_B"
WT_SIDE="$HQ/workspace/worktrees/side"
git -C "$REPO_B" worktree add -q -b wt-side "$WT_SIDE" origin/main
git -C "$WT_SIDE" push -q -u origin wt-side
git -C "$WT_SIDE" checkout -q -b side
printf 'wip\n' > "$WT_SIDE/wip.txt"
git -C "$WT_SIDE" add wip.txt
git -C "$WT_SIDE" commit -qm "unpushed side"
git -C "$WT_SIDE" checkout -q wt-side
backdate "$WT_SIDE"

# ---- repo C: linked worktree with ignored .env ----
BARE_C="$TMP/origin-c.git"
REPO_C="$TMP/repo-c"
make_origin "$BARE_C" "$REPO_C"
WT_ENV="$HQ/workspace/worktrees/with-env"
git -C "$REPO_C" worktree add -q -b wt-env "$WT_ENV" origin/main
printf '.env\n' > "$WT_ENV/.gitignore"
git -C "$WT_ENV" add .gitignore
git -C "$WT_ENV" commit -qm "ignore env"
git -C "$WT_ENV" push -q -u origin wt-env
printf 'SECRET=1\n' > "$WT_ENV/.env"
backdate "$WT_ENV"

# ---- full clone sitting where a worktree would (must never be removed) ----
WT_CLONE="$HQ/workspace/worktrees/full-clone"
git clone -q "$BARE_A" "$WT_CLONE"
git -C "$WT_CLONE" checkout -q -b side
printf 'local-only\n' > "$WT_CLONE/side.txt"
git -C "$WT_CLONE" add side.txt
git -C "$WT_CLONE" commit -qm "unpushed on clone"
git -C "$WT_CLONE" checkout -q main
backdate "$WT_CLONE"

# Grouped layout: worktrees/<repo>/<name>, untracked files inside build-dir names.
BARE_G="$TMP/origin-g.git"
REPO_G="$TMP/repo-g"
make_origin "$BARE_G" "$REPO_G"
WT_GROUP="$HQ/workspace/worktrees/myrepo/feature"
mkdir -p "$(dirname "$WT_GROUP")"
git -C "$REPO_G" worktree add -q -b feat "$WT_GROUP" origin/main
mkdir -p "$WT_GROUP/out" "$WT_GROUP/target"
printf 'uncommitted draft\n' > "$WT_GROUP/out/draft.md"
printf 'notes\n' > "$WT_GROUP/target/plan.txt"
backdate "$WT_GROUP"

# Idle real worktree: ignored node_modules may go; untracked src/keep.txt must stay.
WT_SLIM="$HQ/workspace/worktrees/myrepo/idle"
git -C "$REPO_G" worktree add -q -b idle "$WT_SLIM" origin/main
printf 'node_modules/\n' > "$WT_SLIM/.gitignore"
git -C "$WT_SLIM" add .gitignore
GIT_AUTHOR_DATE=2020-01-01T00:00:00 GIT_COMMITTER_DATE=2020-01-01T00:00:00 \
  git -C "$WT_SLIM" commit -qm "ignore nm" --date=2020-01-01T00:00:00
git -C "$WT_SLIM" push -q -u origin idle
mkdir -p "$WT_SLIM/node_modules" "$WT_SLIM/src"
printf 'x\n' > "$WT_SLIM/node_modules/pkg.js"
printf 'keep\n' > "$WT_SLIM/src/keep.txt"
backdate "$WT_SLIM"

# Untracked work hidden by status.showUntrackedFiles=no.
BARE_N="$TMP/origin-n.git"
REPO_N="$TMP/repo-n"
make_origin "$BARE_N" "$REPO_N"
WT_NOTES="$HQ/workspace/worktrees/grp/notes"
mkdir -p "$(dirname "$WT_NOTES")"
git -C "$REPO_N" worktree add -q -b wt-notes "$WT_NOTES" origin/main
git -C "$WT_NOTES" push -q -u origin wt-notes
git -C "$REPO_N" config status.showUntrackedFiles no
printf 'precious\n' > "$WT_NOTES/notes.md"
mkdir -p "$WT_NOTES/src/out"
printf 'uncommitted work\n' > "$WT_NOTES/src/out/new.ts"
backdate "$WT_NOTES"

# Detached HEAD commit abandoned on the branch, reachable only from this reflog.
BARE_D="$TMP/origin-d.git"
REPO_D="$TMP/repo-d"
make_origin "$BARE_D" "$REPO_D"
WT_DET="$HQ/workspace/worktrees/grp/detached"
git -C "$REPO_D" worktree add -q -b wt-det "$WT_DET" origin/main
git -C "$WT_DET" push -q -u origin wt-det
git -C "$WT_DET" checkout -q --detach
printf 'exp\n' > "$WT_DET/exp.txt"
git -C "$WT_DET" add exp.txt
git -C "$WT_DET" commit -qm "experiment"
LOST=$(git -C "$WT_DET" rev-parse HEAD)
git -C "$WT_DET" checkout -q wt-det
backdate "$WT_DET"

# Tracked build/ must not be deleted out from under a worktree.
BARE_T="$TMP/origin-t.git"
REPO_T="$TMP/repo-t"
make_origin "$BARE_T" "$REPO_T"
WT_TRACKED="$HQ/workspace/worktrees/grp/trackedbuild"
git -C "$REPO_T" worktree add -q -b wt-tracked "$WT_TRACKED" origin/main
mkdir -p "$WT_TRACKED/build"
printf 'script\n' > "$WT_TRACKED/build/release.sh"
git -C "$WT_TRACKED" add build
git -C "$WT_TRACKED" commit -qm "tracked build"
git -C "$WT_TRACKED" push -q -u origin wt-tracked
backdate "$WT_TRACKED"

# Ignored nested config/out is not a rebuildable top-level "out".
BARE_K="$TMP/origin-k.git"
REPO_K="$TMP/repo-k"
make_origin "$BARE_K" "$REPO_K"
WT_CREDS="$HQ/workspace/worktrees/grp/creds"
git -C "$REPO_K" worktree add -q -b wt-creds "$WT_CREDS" origin/main
printf 'config/out/\n' > "$WT_CREDS/.gitignore"
git -C "$WT_CREDS" add .gitignore
git -C "$WT_CREDS" commit -qm "ignore nested out"
git -C "$WT_CREDS" push -q -u origin wt-creds
mkdir -p "$WT_CREDS/config/out"
printf 'secret\n' > "$WT_CREDS/config/out/creds.json"
backdate "$WT_CREDS"

# Worktree that contains a submodule is never removed or half-cleared.
BARE_S="$TMP/origin-s.git"
REPO_S="$TMP/repo-s"
make_origin "$BARE_S" "$REPO_S"
SUB="$TMP/subrepo"
git init -q "$SUB"
printf 's\n' > "$SUB/s.txt"
git -C "$SUB" add s.txt
git -C "$SUB" commit -qm "sub"
WT_SUB="$HQ/workspace/worktrees/grp/with-sub"
git -C "$REPO_S" worktree add -q -b wt-sub "$WT_SUB" origin/main
git clone -q "$SUB" "$WT_SUB/vendor"
sub_sha=$(git -C "$SUB" rev-parse HEAD)
git -C "$WT_SUB" update-index --add --cacheinfo "160000,${sub_sha},vendor"
printf '[submodule "vendor"]\n\tpath = vendor\n\turl = %s\n' "$SUB" > "$WT_SUB/.gitmodules"
printf 'node_modules/\n' > "$WT_SUB/.gitignore"
git -C "$WT_SUB" add .gitmodules .gitignore
git -C "$WT_SUB" commit -qm "add submodule"
git -C "$WT_SUB" push -q -u origin wt-sub
mkdir -p "$WT_SUB/vendor/build" "$WT_SUB/node_modules"
printf 'inside\n' > "$WT_SUB/vendor/build/inside.txt"
printf 'nm\n' > "$WT_SUB/node_modules/a.js"
backdate "$WT_SUB"
git -C "$WT_SUB" ls-files -s | grep >/dev/null '^160000 ' || fail "submodule gitlink missing"

# skip-worktree and assume-unchanged hide local edits from git status and from
# git worktree remove. prune and slim-idle must keep both checkouts.
BARE_H="$TMP/origin-h.git"
REPO_H="$TMP/repo-h"
make_origin "$BARE_H" "$REPO_H"
WT_SKIP="$HQ/workspace/worktrees/grp/skipwt"
WT_ASSUME="$HQ/workspace/worktrees/grp/assume"
git -C "$REPO_H" worktree add -q -b wt-skip "$WT_SKIP" origin/main
printf '%s\n' '{}' > "$WT_SKIP/config.json"
printf 'node_modules/\n' > "$WT_SKIP/.gitignore"
git -C "$WT_SKIP" add config.json .gitignore
GIT_AUTHOR_DATE=2020-01-01T00:00:00 GIT_COMMITTER_DATE=2020-01-01T00:00:00 \
  git -C "$WT_SKIP" commit -qm "add config" --date=2020-01-01T00:00:00
git -C "$WT_SKIP" push -q -u origin wt-skip
git -C "$WT_SKIP" update-index --skip-worktree config.json
printf '%s\n' '{"token":"LOCAL-ONLY"}' > "$WT_SKIP/config.json"
mkdir -p "$WT_SKIP/node_modules"
printf 'x\n' > "$WT_SKIP/node_modules/pkg.js"
backdate "$WT_SKIP"
git -C "$WT_SKIP" ls-files -v -- config.json | grep >/dev/null '^S ' || fail "skip-worktree tag is not S"
[ -z "$(git -C "$WT_SKIP" status --porcelain --untracked-files=all --ignore-submodules=none)" ] \
  || fail "skip-worktree fixture is visible to status"

git -C "$REPO_H" worktree add -q -b wt-assume "$WT_ASSUME" origin/main
printf '%s\n' '{}' > "$WT_ASSUME/config.json"
printf 'node_modules/\n' > "$WT_ASSUME/.gitignore"
git -C "$WT_ASSUME" add config.json .gitignore
GIT_AUTHOR_DATE=2020-01-01T00:00:00 GIT_COMMITTER_DATE=2020-01-01T00:00:00 \
  git -C "$WT_ASSUME" commit -qm "add config" --date=2020-01-01T00:00:00
git -C "$WT_ASSUME" push -q -u origin wt-assume
git -C "$WT_ASSUME" update-index --assume-unchanged config.json
printf '%s\n' '{"edit":"LOCAL"}' > "$WT_ASSUME/config.json"
mkdir -p "$WT_ASSUME/node_modules"
printf 'x\n' > "$WT_ASSUME/node_modules/pkg.js"
backdate "$WT_ASSUME"
git -C "$WT_ASSUME" ls-files -v -- config.json | grep >/dev/null '^[a-z] ' || fail "assume-unchanged tag is not lowercase"
[ -z "$(git -C "$WT_ASSUME" status --porcelain --untracked-files=all --ignore-submodules=none)" ] \
  || fail "assume-unchanged fixture is visible to status"

# Force-added tracked file inside ignored build/. slim-idle must not delete the
# uncommitted edit, even if check-ignore still matches the directory.
BARE_F="$TMP/origin-f.git"
REPO_F="$TMP/repo-f"
make_origin "$BARE_F" "$REPO_F"
WT_FORCED="$HQ/workspace/worktrees/grp/forced"
git -C "$REPO_F" worktree add -q -b wt-forced "$WT_FORCED" origin/main
printf 'build/\n' > "$WT_FORCED/.gitignore"
mkdir -p "$WT_FORCED/build"
printf 'v1\n' > "$WT_FORCED/build/keep.js"
git -C "$WT_FORCED" add .gitignore
git -C "$WT_FORCED" add -f build/keep.js
GIT_AUTHOR_DATE=2020-01-01T00:00:00 GIT_COMMITTER_DATE=2020-01-01T00:00:00 \
  git -C "$WT_FORCED" commit -qm "force-add build" --date=2020-01-01T00:00:00
git -C "$WT_FORCED" push -q -u origin wt-forced
printf 'v2 uncommitted\n' > "$WT_FORCED/build/keep.js"
backdate "$WT_FORCED"
git -C "$WT_FORCED" ls-files -v -- build/keep.js | grep >/dev/null '^H ' || fail "forced file is not a normal tracked file"
git -C "$WT_FORCED" status --porcelain --untracked-files=all --ignore-submodules=none | grep >/dev/null 'build/keep.js' \
  || fail "forced-file edit is not a normal uncommitted change"

# Separate git clone nested inside an ignored top-level build/ directory.
# The unpushed commit is not a submodule gitlink, and parent status is clean.
BARE_V="$TMP/origin-v.git"
REPO_V="$TMP/repo-v"
make_origin "$BARE_V" "$REPO_V"
WT_NESTED="$HQ/workspace/worktrees/grp/nested"
git -C "$REPO_V" worktree add -q -b wt-nested "$WT_NESTED" origin/main
printf 'build/\n' > "$WT_NESTED/.gitignore"
git -C "$WT_NESTED" add .gitignore
GIT_AUTHOR_DATE=2020-01-01T00:00:00 GIT_COMMITTER_DATE=2020-01-01T00:00:00 \
  git -C "$WT_NESTED" commit -qm "ignore build" --date=2020-01-01T00:00:00
git -C "$WT_NESTED" push -q -u origin wt-nested
git init -q "$WT_NESTED/build/vendor"
printf 'work\n' > "$WT_NESTED/build/vendor/w.txt"
git -C "$WT_NESTED/build/vendor" add w.txt
git -C "$WT_NESTED/build/vendor" commit -qm "unpushed nested work"
NESTED_SHA=$(git -C "$WT_NESTED/build/vendor" rev-parse HEAD)
backdate "$WT_NESTED"
[ -z "$(git -C "$WT_NESTED" status --porcelain --untracked-files=all --ignore-submodules=none)" ] \
  || fail "nested clone is visible to parent status"
if git -C "$WT_NESTED" ls-files -s | grep >/dev/null '^160000 '; then
  fail "nested clone was recorded as a submodule"
fi

# Session-owned worktrees. Each is clean, pushed, has an upstream and was idle
# for years, so only session ownership keeps it. A live process with its cwd
# inside is the reported shape: an open session's worktree.
BARE_L="$TMP/origin-l.git"
REPO_L="$TMP/repo-l"
make_origin "$BARE_L" "$REPO_L"
WT_LIVE="$HQ/workspace/worktrees/grp/live"
git -C "$REPO_L" worktree add -q -b wt-live "$WT_LIVE" origin/main
git -C "$WT_LIVE" push -q -u origin wt-live
mkdir -p "$WT_LIVE/src"
backdate "$WT_LIVE"
(cd "$WT_LIVE/src" && exec sleep 600) &
LIVE_PID=$!
# A session transcript from the last 7 days recorded a cwd inside this one.
WT_SESS="$HQ/workspace/worktrees/grp/sess"
git -C "$REPO_L" worktree add -q -b wt-sess "$WT_SESS" origin/main
git -C "$WT_SESS" push -q -u origin wt-sess
backdate "$WT_SESS"
mkdir -p "$HOME/.codex/sessions/2026/10/14"
printf '{"type":"session_meta","payload":{},"cwd": "%s"}\n' "$WT_SESS" > "$HOME/.codex/sessions/2026/10/14/rollout.jsonl"
# Idle worktree with ignored node_modules, held by a live process: slim-idle
# must not clear it.
WT_SLIMLIVE="$HQ/workspace/worktrees/grp/slimlive"
git -C "$REPO_L" worktree add -q -b wt-slimlive "$WT_SLIMLIVE" origin/main
printf 'node_modules/\n' > "$WT_SLIMLIVE/.gitignore"
git -C "$WT_SLIMLIVE" add .gitignore
GIT_AUTHOR_DATE=2020-01-01T00:00:00 GIT_COMMITTER_DATE=2020-01-01T00:00:00 \
  git -C "$WT_SLIMLIVE" commit -qm "ignore nm" --date=2020-01-01T00:00:00
git -C "$WT_SLIMLIVE" push -q -u origin wt-slimlive
mkdir -p "$WT_SLIMLIVE/node_modules"
printf 'x\n' > "$WT_SLIMLIVE/node_modules/pkg.js"
printf '{"cwd":"%s/node_modules"}\n' "$WT_SLIMLIVE" >> "$HOME/.codex/sessions/2026/10/14/rollout.jsonl"
backdate "$WT_SLIMLIVE"

# Fixtures must be exercising the holes in `git status --porcelain`.
[ -z "$(git -C "$WT_SAFE" status --porcelain)" ] || fail "safe fixture is dirty"
[ -z "$(git -C "$WT_SIDE" status --porcelain)" ] || fail "side fixture is dirty"
[ -z "$(git -C "$WT_ENV" status --porcelain)" ] || fail "env fixture is dirty: $(git -C "$WT_ENV" status --porcelain)"
[ -f "$WT_ENV/.env" ] || fail "env fixture missing .env"
git -C "$WT_ENV" check-ignore -q .env || fail ".env is not ignored"
[ -d "$WT_CLONE/.git" ] || fail "full clone has no .git directory"
side_ahead=$(git -C "$WT_SIDE" rev-list --count side --not --remotes)
[ "$side_ahead" != "0" ] || fail "side branch has no unpushed commits"

# ---- caches outside the allowlist, plus one allowlisted dir ----
mkdir -p "$HOME/Library/Caches/Homebrew/pkg" \
  "$HOME/Library/Caches/com.apple.Safari" \
  "$HOME/Library/Caches/Slack" \
  "$HOME/.cache/qmd" \
  "$HOME/.cache/gh"
printf 'brew\n' > "$HOME/Library/Caches/Homebrew/pkg/a"
printf 'secret\n' > "$HOME/Library/Caches/com.apple.Safari/data"
printf 'secret\n' > "$HOME/Library/Caches/Slack/data"
printf 'index\n' > "$HOME/.cache/qmd/index"
printf 'gh\n' > "$HOME/.cache/gh/hosts"

NPM_MARKER="$TMP/npm-invoked"
mkdir -p "$TMP/bin"
cat > "$TMP/bin/npm" <<'EOF'
#!/bin/bash
printf 'npm\n' >> "${NPM_MARKER:?}"
exit 0
EOF
chmod +x "$TMP/bin/npm"
export PATH="$TMP/bin:$PATH"
export NPM_MARKER

# ---- HQ root git with unreachable loose objects, plus sync mirrors ----
# A 30-day-old autosave commit, then three loose blobs no commit reaches
# (what a failing autosave leaves behind).
printf 'saved\n' > "$HQ/saved.txt"
git -C "$HQ" add saved.txt
OLD_TS=$(( $(date +%s) - 30 * 86400 ))
GIT_AUTHOR_DATE="@$OLD_TS +0000" GIT_COMMITTER_DATE="@$OLD_TS +0000" \
  git -C "$HQ" commit -qm "autosave(hq): saved.txt"
HQ_SAVED_SHA=$(git -C "$HQ" rev-parse HEAD)
UNREACHABLE=""
for n in 1 2 3; do
  head -c 4096 /dev/urandom > "$TMP/render-$n.bin"
  UNREACHABLE="$UNREACHABLE $(git -C "$HQ" hash-object -w "$TMP/render-$n.bin")"
done
# prune-hq-history keeps git's one-hour grace period, so age these objects past
# it. FRESH is unreachable but just written (as by a git command still running)
# and must survive every mode.
for o in $UNREACHABLE; do
  perl -e '$t = time - 7200; utime($t, $t, @ARGV) or die' "$HQ/.git/objects/${o:0:2}/${o:2}"
done
head -c 4096 /dev/urandom > "$TMP/render-fresh.bin"
FRESH=$(git -C "$HQ" hash-object -w "$TMP/render-fresh.bin")
MIRROR_ROOT_T="$HOME/.hq/hq-root-git"
MIRROR="$MIRROR_ROOT_T/88e74d299052fb32"
MIRROR_LIVE="$MIRROR_ROOT_T/livemirror0001"
# A recovery copy is a git store of an HQ root; this one is a copy of $HQ, so
# every commit in it exists in the HQ root's git.
mkdir -p "$MIRROR_ROOT_T"
git clone -q --no-local --bare "$HQ" "$MIRROR"
mkdir -p "$MIRROR/objects/ab" "$MIRROR_LIVE/objects"
# cap_bytes is 2 GiB, computed so no 10-digit literal trips the PII phone scanner.
printf '{"disabled_at":"2026-09-02T07:00:37Z","measured_bytes":23378801803,"cap_bytes":%d,"reason":"staged_snapshot"}\n' "$((2 * 1024 * 1024 * 1024))" \
  > "$MIRROR/hq-sync-mirror-disabled.json"
# The mirror shares object files with the HQ root through hard links.
HQ_OBJ="$HQ/.git/objects/${HQ_SAVED_SHA:0:2}/${HQ_SAVED_SHA:2}"
ln "$HQ_OBJ" "$MIRROR/objects/ab/shared"
head -c 2048 /dev/urandom > "$MIRROR/objects/ab/own"
printf 'live\n' > "$MIRROR_LIVE/objects/keep"

# ---- scan: a hung size probe cannot suppress the bounded inventory ----
REAL_DU="$(command -v du)"
mkdir -p "$TMP/scan-bin" "$HOME/Downloads" "$HOME/.npm/aa-fast" "$HOME/.npm/zz-slow"
head -c 65536 /dev/urandom > "$HOME/.npm/aa-fast/blob"
cat > "$TMP/scan-bin/du" <<EOF
#!/bin/bash
# Match every argument. GNU du and BSD du do not put the path in the same slot
# once options are split, and a child path is what makes the .npm area partial.
for a in "\$@"; do
  case "\$a" in
    "$HOME/.cache"|"$HOME/.cache/"*|*"/zz-slow"|*"/zz-slow/"*) sleep 5 ;;
  esac
done
exec "$REAL_DU" "\$@"
EOF
chmod +x "$TMP/scan-bin/du"
scan="$(PATH="$TMP/scan-bin:$PATH" HQ_FREE_DISK_SCAN_TIMEOUT_SECS=1 run scan)"
case "$scan" in
  *"largest reclaimable areas (bounded scan):"*) ;;
  *) fail "scan omitted the largest-area table: $scan" ;;
esac
case "$scan" in
  *"timeout"*"$HOME/.cache"*) ;;
  *) fail "scan omitted the timed-out area while keeping partial results: $scan" ;;
esac
case "$scan" in
  *"ok"*"$HQ/workspace/worktrees"*) ;;
  *) fail "scan lost completed area results when another probe timed out: $scan" ;;
esac
# A timed-out area still reports the entries measured in time, as a lower bound.
printf '%s\n' "$scan" | grep -E '>=[0-9.]+ KB  partial +'"$HOME/.npm"'$' >/dev/null \
  || fail "scan did not report a lower bound for the half-measured area: $scan"
printf '%s\n' "$scan" | grep -E '  ok +'"$HQ/.git"'$' >/dev/null || fail "scan did not size the HQ root git: $scan"
printf '%s\n' "$scan" | grep -E '  ok +'"$HOME/.hq"'$' >/dev/null || fail "scan did not size ~/.hq: $scan"
[ "$(printf '%s\n' "$scan" | grep -Ec '  (ok|partial|timeout|missing|error|unavailable)[[:space:]]+')" -le 10 ] \
  || fail "scan emitted more than the bounded ten area rows: $scan"
case "$scan" in
  *"hq-git $HQ/.git loose_objects="*) ;;
  *) fail "scan did not report HQ git loose vs packed size: $scan" ;;
esac
case "$scan" in
  *"warn autosave-stale"*"age_days=30"*) ;;
  *) fail "scan did not warn about a 30-day-old autosave commit: $scan" ;;
esac
case "$scan" in
  *"disabled-mirror $MIRROR disabled_at=2026-09-02T07:00:37Z reason=staged_snapshot measured=21.8 GB cap=2.0 GB"*) ;;
  *) fail "scan did not report the disabled mirror from its marker: $scan" ;;
esac
case "$scan" in
  *"HQ sync recovery copies; trash-disabled-mirror offers one only when every object in it (commits from refs, HEAD and reflogs, and unreferenced objects) exists in $HQ/.git"*) ;;
  *) fail "scan did not explain that the disabled copy is a recovery copy checked by refs: $scan" ;;
esac
case "$scan" in
  *"same objects"*) fail "scan claimed the recovery copy holds the same objects before any ref check: $scan" ;;
esac
case "$scan" in
  *"active-mirror $MIRROR_LIVE"*) ;;
  *) fail "scan did not list the active mirror as not offered: $scan" ;;
esac
for o in $UNREACHABLE; do
  git -C "$HQ" cat-file -e "$o" || fail "scan removed an unreachable object"
done

# ---- prune-hq-history: dry run, refusal without confirmation, lock, apply ----
LOCK_T="$TMP/locktmp"
mkdir -p "$LOCK_T"
dry_hq=$(TMPDIR="$LOCK_T" run prune-hq-history)
case "$dry_hq" in
  *"mode=dry-run"*"would-prune objects=3 "*) ;;
  *) fail "prune-hq-history dry run did not count three unreachable objects: $dry_hq" ;;
esac
printf '%s\n' "$dry_hq" | grep -E 'would-prune objects=3 disk=[0-9.]+ (KB|MB) disk_bytes=[1-9][0-9]*$' >/dev/null \
  || fail "prune-hq-history dry run did not size the objects on disk: $dry_hq"
case "$dry_hq" in
  *"may share objects with $HQ/.git; trash-disabled-mirror checks its refs first"*) ;;
  *) fail "prune-hq-history dry run did not note the recovery copy may share objects: $dry_hq" ;;
esac
for o in $UNREACHABLE; do
  git -C "$HQ" cat-file -e "$o" || fail "prune-hq-history dry run removed $o"
done

rc=0; out=$(TMPDIR="$LOCK_T" run --apply prune-hq-history) || rc=$?
[ "$rc" = 3 ] || fail "prune-hq-history --apply without --yes exited $rc: $out"
case "$out" in *refused*) ;; *) fail "prune-hq-history --apply without --yes did not refuse: $out" ;; esac
for o in $UNREACHABLE; do
  git -C "$HQ" cat-file -e "$o" || fail "unconfirmed prune-hq-history removed $o"
done

mkdir "$LOCK_T/hq-autocommit.lock"
rc=0; out=$(TMPDIR="$LOCK_T" run --apply --yes prune-hq-history) || rc=$?
[ "$rc" = 3 ] || fail "prune-hq-history ran while autosave held the lock (rc=$rc): $out"
case "$out" in *"reason=autosave-lock-held"*) ;; *) fail "prune-hq-history did not name the held lock: $out" ;; esac
[ -d "$LOCK_T/hq-autocommit.lock" ] || fail "prune-hq-history removed autosave's lock"
for o in $UNREACHABLE; do
  git -C "$HQ" cat-file -e "$o" || fail "prune-hq-history removed $o while the lock was held"
done
rmdir "$LOCK_T/hq-autocommit.lock"

# A repo that borrows the HQ root's objects (clone --shared writes alternates)
# would break if the HQ root pruned them, so prune refuses and changes nothing.
BORROWER="$HQ/repos/borrower"
mkdir -p "$HQ/repos"
git clone -q --shared "$HQ" "$BORROWER"
case "$(cat "$BORROWER/.git/objects/info/alternates")" in *"$HQ/.git/objects"*) ;; *) fail "fixture: clone --shared wrote no alternates to the HQ root" ;; esac
rc=0; out=$(TMPDIR="$LOCK_T" run --apply --yes prune-hq-history) || rc=$?
[ "$rc" = 3 ] || fail "prune-hq-history ran while a shared clone borrows the HQ root (rc=$rc): $out"
case "$out" in *"reason=borrowed-by $BORROWER"*) ;; *) fail "prune-hq-history did not name the borrowing repo: $out" ;; esac
for o in $UNREACHABLE; do
  git -C "$HQ" cat-file -e "$o" || fail "prune-hq-history removed $o while a shared clone borrows the HQ root"
done
git -C "$BORROWER" fsck --no-dangling >/dev/null 2>&1 || fail "the shared clone broke after the refused prune"
# A borrower inside an HQ sync recovery copy is found too.
MIRROR_SHARED="$HOME/.hq/hq-root-git/sharedclone00001"
git clone -q --bare --shared "$HQ" "$MIRROR_SHARED"
rm -rf "$BORROWER"
rc=0; out=$(TMPDIR="$LOCK_T" run prune-hq-history) || rc=$?
[ "$rc" = 3 ] || fail "prune-hq-history dry run did not refuse with a borrowing recovery copy (rc=$rc): $out"
case "$out" in *"reason=borrowed-by $MIRROR_SHARED"*) ;; *) fail "prune-hq-history missed a recovery copy that borrows the HQ root: $out" ;; esac
rm -rf "$MIRROR_SHARED" "$HQ/repos"

out=$(TMPDIR="$LOCK_T" run --apply --yes prune-hq-history)
case "$out" in *"pruned objects=3 "*) ;; *) fail "prune-hq-history apply did not prune three objects: $out" ;; esac
for o in $UNREACHABLE; do
  if git -C "$HQ" cat-file -e "$o" 2>/dev/null; then fail "prune-hq-history left unreachable $o"; fi
done
[ "$(git -C "$HQ" rev-parse HEAD)" = "$HQ_SAVED_SHA" ] || fail "prune-hq-history moved HEAD"
git -C "$HQ" cat-file -e HEAD:saved.txt || fail "prune-hq-history removed a reachable blob"
git -C "$HQ" cat-file -e "$FRESH" || fail "prune-hq-history removed an object inside the one-hour grace period"
git -C "$HQ" fsck --no-dangling >/dev/null 2>&1 || fail "HQ git fsck failed after prune-hq-history"
[ ! -e "$LOCK_T/hq-autocommit.lock" ] || fail "prune-hq-history did not release the autosave lock"
case "$out" in *"still-held-by $MIRROR"*) ;; *) fail "prune-hq-history did not point at the mirror still holding space: $out" ;; esac

# ---- trash-disabled-mirror: dry run, refusal, guards, apply ----
TRASH_T="$TMP/trash"
dry_m=$(run trash-disabled-mirror)
case "$dry_m" in *"would-trash $MIRROR"*) ;; *) fail "trash-disabled-mirror dry run did not offer the disabled mirror: $dry_m" ;; esac
case "$dry_m" in *"would-trash $MIRROR_LIVE"*) fail "trash-disabled-mirror offered the active mirror: $dry_m" ;; esac
printf '%s\n' "$dry_m" | grep -E "mirror-size $MIRROR size=[0-9.]+ KB hard_linked=[0-9.]+ KB" >/dev/null \
  || fail "trash-disabled-mirror dry run did not report size and hard-linked bytes: $dry_m"
printf "%s\n" "$dry_m" | grep -E "hard_linked_bytes=[1-9][0-9]*$" >/dev/null || fail "trash-disabled-mirror missed the hard-linked object: $dry_m"
[ -f "$MIRROR/hq-sync-mirror-disabled.json" ] || fail "trash-disabled-mirror dry run moved the mirror"
case "$dry_m" in *"refs-covered $MIRROR"*) ;; *) fail "trash-disabled-mirror did not report the ref check that passed: $dry_m" ;; esac

# A recovery copy holding a commit the HQ root lacks (another or a wiped HQ
# root) is kept, and so is one whose refs cannot be read.
MARKER_JSON='{"disabled_at":"2026-09-02T07:00:37Z","measured_bytes":1,"cap_bytes":2,"reason":"staged_snapshot"}'
MIRROR_MISS="$MIRROR_ROOT_T/otherroot0000001"
git clone -q --no-local --bare "$HQ" "$MIRROR_MISS"
MISS_TREE=$(git --git-dir="$MIRROR_MISS" mktree </dev/null)
MISS_SHA=$(GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid \
  git --git-dir="$MIRROR_MISS" commit-tree -p "$HQ_SAVED_SHA" -m "only in the recovery copy" "$MISS_TREE")
git --git-dir="$MIRROR_MISS" update-ref refs/heads/lost "$MISS_SHA"
if git -C "$HQ" cat-file -e "$MISS_SHA" 2>/dev/null; then fail "fixture: the HQ root already has the recovery-only commit"; fi
printf '%s\n' "$MARKER_JSON" > "$MIRROR_MISS/hq-sync-mirror-disabled.json"
MIRROR_BAD="$MIRROR_ROOT_T/unreadable000001"
mkdir -p "$MIRROR_BAD/objects/ab"
head -c 1024 /dev/urandom > "$MIRROR_BAD/objects/ab/junk"
printf '%s\n' "$MARKER_JSON" > "$MIRROR_BAD/hq-sync-mirror-disabled.json"
dry_r=$(run trash-disabled-mirror)
case "$dry_r" in *"kept $MIRROR_MISS reason=commit-missing-from-hq-root ($MISS_SHA)"*) ;; *) fail "trash-disabled-mirror did not keep a recovery copy with a ref the HQ root lacks: $dry_r" ;; esac
case "$dry_r" in *"would-trash $MIRROR_MISS"*) fail "trash-disabled-mirror offered a recovery copy with a missing ref: $dry_r" ;; esac
case "$dry_r" in *"kept $MIRROR_BAD reason=refs-unreadable"*) ;; *) fail "trash-disabled-mirror did not keep a recovery copy with unreadable refs: $dry_r" ;; esac
case "$dry_r" in *"would-trash $MIRROR_BAD"*) fail "trash-disabled-mirror offered a recovery copy with unreadable refs: $dry_r" ;; esac
case "$dry_r" in *"would-trash $MIRROR"*) ;; *) fail "trash-disabled-mirror stopped offering the covered recovery copy: $dry_r" ;; esac

# Branch and tag tips are not the whole history: a detached HEAD or a commit
# reachable only from a reflog that the HQ root lacks keeps the copy too.
tgit() {
  GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid git "$@"
}
MIRROR_DET="$MIRROR_ROOT_T/detachedhead0001"
git clone -q --no-local --bare "$HQ" "$MIRROR_DET"
DET_SHA=$(tgit --git-dir="$MIRROR_DET" commit-tree -p "$HQ_SAVED_SHA" -m "detached only" "$MISS_TREE")
git --git-dir="$MIRROR_DET" update-ref --no-deref HEAD "$DET_SHA"
printf '%s\n' "$MARKER_JSON" > "$MIRROR_DET/hq-sync-mirror-disabled.json"
MIRROR_RLOG="$MIRROR_ROOT_T/reflogonly000001"
git clone -q --no-local --bare "$HQ" "$MIRROR_RLOG"
RLOG_SHA=$(tgit --git-dir="$MIRROR_RLOG" commit-tree -p "$HQ_SAVED_SHA" -m "reflog only" "$MISS_TREE")
tgit -c core.logAllRefUpdates=always --git-dir="$MIRROR_RLOG" update-ref -m step refs/heads/scratch "$RLOG_SHA"
tgit -c core.logAllRefUpdates=always --git-dir="$MIRROR_RLOG" update-ref -m reset refs/heads/scratch "$HQ_SAVED_SHA"
[ -z "$(git --git-dir="$MIRROR_RLOG" for-each-ref --contains "$RLOG_SHA")" ] || fail "fixture: the reflog-only commit is on a ref"
case "$(git --git-dir="$MIRROR_RLOG" rev-list --reflog)" in *"$RLOG_SHA"*) ;; *) fail "fixture: the reflog does not hold the commit" ;; esac
printf '%s\n' "$MARKER_JSON" > "$MIRROR_RLOG/hq-sync-mirror-disabled.json"
for s in "$DET_SHA" "$RLOG_SHA"; do
  if git -C "$HQ" cat-file -e "$s" 2>/dev/null; then fail "fixture: the HQ root already has $s"; fi
done
dry_h=$(run trash-disabled-mirror)
case "$dry_h" in *"kept $MIRROR_DET reason=commit-missing-from-hq-root ($DET_SHA)"*) ;; *) fail "trash-disabled-mirror did not keep a copy whose detached HEAD the HQ root lacks: $dry_h" ;; esac
case "$dry_h" in *"would-trash $MIRROR_DET"*) fail "trash-disabled-mirror offered a copy with a detached HEAD the HQ root lacks: $dry_h" ;; esac
case "$dry_h" in *"kept $MIRROR_RLOG reason=commit-missing-from-hq-root ($RLOG_SHA)"*) ;; *) fail "trash-disabled-mirror did not keep a copy with a reflog-only commit: $dry_h" ;; esac
case "$dry_h" in *"would-trash $MIRROR_RLOG"*) fail "trash-disabled-mirror offered a copy with a reflog-only commit: $dry_h" ;; esac
case "$dry_h" in *"would-trash $MIRROR"*) ;; *) fail "trash-disabled-mirror stopped offering the fully covered copy: $dry_h" ;; esac

# Objects no ref or reflog reaches still keep the copy: a dangling commit, a
# blob only the copy holds, and staged work in a non-bare copy.
MIRROR_DANG="$MIRROR_ROOT_T/danglingcommit01"
git clone -q --no-local --bare "$HQ" "$MIRROR_DANG"
DANG_SHA=$(tgit --git-dir="$MIRROR_DANG" commit-tree -p "$HQ_SAVED_SHA" -m "dangling only" "$MISS_TREE")
case "$(git --git-dir="$MIRROR_DANG" rev-list --all --reflog HEAD)" in *"$DANG_SHA"*) fail "fixture: the dangling commit is reachable" ;; esac
printf '%s\n' "$MARKER_JSON" > "$MIRROR_DANG/hq-sync-mirror-disabled.json"
MIRROR_BLOB="$MIRROR_ROOT_T/blobonly00000001"
git clone -q --no-local --bare "$HQ" "$MIRROR_BLOB"
BLOB_SHA=$(printf 'only in the copy\n' | git --git-dir="$MIRROR_BLOB" hash-object -w --stdin)
printf '%s\n' "$MARKER_JSON" > "$MIRROR_BLOB/hq-sync-mirror-disabled.json"
MIRROR_STAGED="$MIRROR_ROOT_T/stagedwork000001"
git clone -q --no-local "$HQ" "$MIRROR_STAGED"
printf 'staged, not committed\n' > "$MIRROR_STAGED/wip.txt"
git -C "$MIRROR_STAGED" add wip.txt
STAGED_BLOB=$(git -C "$MIRROR_STAGED" rev-parse :wip.txt)
printf '%s\n' "$MARKER_JSON" > "$MIRROR_STAGED/hq-sync-mirror-disabled.json"
for s in "$DANG_SHA" "$BLOB_SHA" "$STAGED_BLOB"; do
  if git -C "$HQ" cat-file -e "$s" 2>/dev/null; then fail "fixture: the HQ root already has $s"; fi
done
dry_u=$(run trash-disabled-mirror)
case "$dry_u" in *"kept $MIRROR_DANG reason=object-missing-from-hq-root ($DANG_SHA)"*) ;; *) fail "trash-disabled-mirror did not keep a copy whose only extra object is a dangling commit: $dry_u" ;; esac
case "$dry_u" in *"kept $MIRROR_BLOB reason=object-missing-from-hq-root ($BLOB_SHA)"*) ;; *) fail "trash-disabled-mirror did not keep a copy whose only extra object is a blob: $dry_u" ;; esac
case "$dry_u" in *"kept $MIRROR_STAGED reason="*) ;; *) fail "trash-disabled-mirror did not keep a non-bare copy with staged work: $dry_u" ;; esac
for m in "$MIRROR_DANG" "$MIRROR_BLOB" "$MIRROR_STAGED"; do
  case "$dry_u" in *"would-trash $m"*) fail "trash-disabled-mirror offered $m: $dry_u" ;; esac
done
case "$dry_u" in *"would-trash $MIRROR"*) ;; *) fail "trash-disabled-mirror stopped offering the copy whose objects all exist in the HQ root: $dry_u" ;; esac
# A clean non-bare copy whose objects all exist still has an index, so it is kept.
git -C "$MIRROR_STAGED" rm -q --cached wip.txt
rm -f "$MIRROR_STAGED/wip.txt"
git -C "$MIRROR_STAGED" prune --expire=now
dry_u=$(run trash-disabled-mirror)
case "$dry_u" in *"kept $MIRROR_STAGED reason=non-bare-copy-has-index"*) ;; *) fail "trash-disabled-mirror did not keep a non-bare copy with an index: $dry_u" ;; esac
rm -rf "$MIRROR_STAGED"

# A shallow HQ root cannot prove it holds a copy's history: keep every copy.
printf '%s\n' "$HQ_SAVED_SHA" > "$HQ/.git/shallow"
dry_s=$(run trash-disabled-mirror)
rm -f "$HQ/.git/shallow"
case "$dry_s" in *"kept $MIRROR reason=hq-root-shallow"*) ;; *) fail "trash-disabled-mirror did not keep the copy when the HQ root is shallow: $dry_s" ;; esac
case "$dry_s" in *"would-trash"*) fail "trash-disabled-mirror offered a copy while the HQ root is shallow: $dry_s" ;; esac

# "disabled_at": null is not disabled.
MIRROR_NULL="$MIRROR_ROOT_T/nullmarker000001"
git clone -q --no-local --bare "$HQ" "$MIRROR_NULL"
printf '{"disabled_at": null,"measured_bytes":1,"cap_bytes":2,"reason":"staged_snapshot"}\n' > "$MIRROR_NULL/hq-sync-mirror-disabled.json"
dry_n=$(run trash-disabled-mirror)
case "$dry_n" in *"kept $MIRROR_NULL reason=marker-without-disabled_at"*) ;; *) fail "trash-disabled-mirror treated disabled_at null as disabled: $dry_n" ;; esac

# An alternates entry spelled through a symlink, or relative to the HQ root's
# objects dir, still names the copy, so the copy is kept.
printf '%s\n' "$MARKER_JSON" > "$MIRROR_NULL/hq-sync-mirror-disabled.json"
ln -s "$MIRROR_NULL" "$TMP/mirror-link"
printf '%s\n' "$TMP/mirror-link/objects" > "$HQ/.git/objects/info/alternates"
dry_l=$(run trash-disabled-mirror)
case "$dry_l" in *"kept $MIRROR_NULL reason=hq-git-borrows-objects"*) ;; *) fail "a symlinked alternates entry did not keep the borrowed copy: $dry_l" ;; esac
REL=$(python3 -c 'import os,sys;print(os.path.relpath(sys.argv[1],sys.argv[2]))' "$MIRROR_NULL/objects" "$HQ/.git/objects")
printf '%s\n' "$REL" > "$HQ/.git/objects/info/alternates"
dry_l=$(run trash-disabled-mirror)
case "$dry_l" in *"kept $MIRROR_NULL reason=hq-git-borrows-objects"*) ;; *) fail "a relative alternates entry did not keep the borrowed copy: $dry_l" ;; esac
rm -f "$HQ/.git/objects/info/alternates" "$TMP/mirror-link"
rm -rf "$MIRROR_NULL"

rc=0; out=$(HQ_FREE_DISK_TRASH_DIR="$TRASH_T" run --apply trash-disabled-mirror) || rc=$?
[ "$rc" = 3 ] || fail "trash-disabled-mirror --apply without --yes exited $rc: $out"
case "$out" in *refused*) ;; *) fail "trash-disabled-mirror --apply without --yes did not refuse: $out" ;; esac
[ -d "$MIRROR" ] || fail "unconfirmed trash-disabled-mirror moved the mirror"
[ ! -e "$TRASH_T" ] || fail "unconfirmed trash-disabled-mirror wrote to the Trash"

# A mirror the HQ root borrows objects from (alternates) is never moved.
MIRROR_ALT="$MIRROR_ROOT_T/borrowed00000001"
git clone -q --no-local --bare "$HQ" "$MIRROR_ALT"
printf '{"disabled_at":"2026-09-02T07:00:37Z","measured_bytes":1,"cap_bytes":2,"reason":"staged_snapshot"}\n' \
  > "$MIRROR_ALT/hq-sync-mirror-disabled.json"
printf '%s\n' "$MIRROR_ALT/objects" > "$HQ/.git/objects/info/alternates"

out=$(HQ_FREE_DISK_TRASH_DIR="$TRASH_T" run --apply --yes trash-disabled-mirror)
case "$out" in *"trashed $MIRROR -> $TRASH_T/hq-sync-mirror-88e74d299052fb32-"*) ;; *) fail "trash-disabled-mirror did not move the mirror to the Trash: $out" ;; esac
[ ! -e "$MIRROR" ] || fail "trash-disabled-mirror left the mirror in place"
ls "$TRASH_T"/hq-sync-mirror-88e74d299052fb32-*/hq-sync-mirror-disabled.json >/dev/null 2>&1 \
  || fail "the trashed mirror is not intact in the Trash"
case "$out" in *"kept $MIRROR_ALT reason=hq-git-borrows-objects"*) ;; *) fail "trash-disabled-mirror did not keep a mirror the HQ root borrows from: $out" ;; esac
[ -d "$MIRROR_ALT/objects" ] || fail "trash-disabled-mirror moved a mirror the HQ root borrows from"
[ -f "$MIRROR_LIVE/objects/keep" ] || fail "trash-disabled-mirror touched the active mirror"
[ -f "$MIRROR_MISS/hq-sync-mirror-disabled.json" ] || fail "trash-disabled-mirror --apply moved a recovery copy with a missing ref"
git --git-dir="$MIRROR_MISS" cat-file -e "$MISS_SHA" || fail "the kept recovery copy lost its commit"
[ -f "$MIRROR_DET/hq-sync-mirror-disabled.json" ] || fail "trash-disabled-mirror --apply moved a copy with an uncovered detached HEAD"
git --git-dir="$MIRROR_RLOG" cat-file -e "$RLOG_SHA" || fail "trash-disabled-mirror --apply moved a copy with a reflog-only commit"
git --git-dir="$MIRROR_DANG" cat-file -e "$DANG_SHA" || fail "trash-disabled-mirror --apply moved a copy with a dangling commit"
git --git-dir="$MIRROR_BLOB" cat-file -e "$BLOB_SHA" || fail "trash-disabled-mirror --apply moved a copy with a copy-only blob"
[ -f "$MIRROR_BAD/objects/ab/junk" ] || fail "trash-disabled-mirror --apply moved a recovery copy with unreadable refs"
case "$out" in *"Trash is emptied"*) ;; *) fail "trash-disabled-mirror did not say the space returns after emptying the Trash: $out" ;; esac
git -C "$HQ" cat-file -e HEAD:saved.txt || fail "HQ git lost a blob after the mirror moved"
# A longer alternates path that only contains the mirror string is not a borrow.
MIRROR_SUB="$MIRROR_ROOT_T/borrowed00000001-extra"
mkdir -p "$MIRROR_SUB/objects" "$MIRROR_ALT"
printf '{"disabled_at":"2026-09-02T07:00:37Z","measured_bytes":1,"cap_bytes":2,"reason":"staged_snapshot"}\n' \
  > "$MIRROR_SUB/hq-sync-mirror-disabled.json"
printf '%s\n' "# note" "$MIRROR_SUB/objects" > "$HQ/.git/objects/info/alternates"
out=$(HQ_FREE_DISK_TRASH_DIR="$TRASH_T" run --apply --yes trash-disabled-mirror)
case "$out" in *"trashed $MIRROR_ALT ->"*) ;; *) fail "substring alternates line kept a mirror that is not borrowed: $out" ;; esac
[ ! -e "$MIRROR_ALT" ] || fail "substring alternates match left the unborrowed mirror"
[ -d "$MIRROR_SUB/objects" ] || fail "whole-line alternates match trashed the borrowed mirror"
rm -f "$HQ/.git/objects/info/alternates"

# ---- dry run deletes nothing ----
dry=$(run prune-backed-up 6)
[ ! -f "$NPM_MARKER" ] || fail "dry-run prune invoked npm"
for d in "$WT_SAFE" "$WT_SIDE" "$WT_ENV" "$WT_CLONE" "$WT_GROUP" "$WT_NOTES" "$WT_DET" "$WT_TRACKED" "$WT_CREDS" "$WT_SUB" "$WT_SLIM" "$WT_SKIP" "$WT_ASSUME" "$WT_FORCED" "$WT_NESTED"; do
  [ -d "$d" ] || fail "dry-run removed $d"
done
[ -f "$WT_GROUP/out/draft.md" ] || fail "dry-run removed grouped draft"
[ -f "$WT_NOTES/notes.md" ] || fail "dry-run removed notes.md"
[ -f "$WT_TRACKED/build/release.sh" ] || fail "dry-run removed tracked build/release.sh"
[ -f "$WT_ENV/.env" ] || fail "dry-run removed .env"
git -C "$WT_CLONE" cat-file -e side:side.txt || fail "dry-run dropped the full-clone side branch"
case "$dry" in
  *mode=dry-run*) ;;
  *) fail "dry-run did not say mode=dry-run: $dry" ;;
esac
case "$dry" in
  *"would-remove $WT_SAFE"*) ;;
  *) fail "dry-run did not report the safe worktree: $dry" ;;
esac
case "$dry" in
  *"reason=full-clone"*) ;;
  *) fail "dry-run did not keep the full clone: $dry" ;;
esac
case "$dry" in
  *"reason=unpushed-branch:"*) ;;
  *) fail "dry-run did not keep the unpushed side branch: $dry" ;;
esac
case "$dry" in
  *"reason=ignored:"*) ;;
  *) fail "dry-run did not keep ignored files: $dry" ;;
esac
case "$dry" in
  *"kept $WT_SKIP reason=hidden-local-changes"*) ;;
  *) fail "dry-run did not keep the skip-worktree checkout: $dry" ;;
esac
case "$dry" in
  *"kept $WT_ASSUME reason=hidden-local-changes"*) ;;
  *) fail "dry-run did not keep the assume-unchanged checkout: $dry" ;;
esac
case "$dry" in
  *"kept $WT_NESTED reason=nested-git:build"*) ;;
  *) fail "dry-run did not keep the nested git clone: $dry" ;;
esac
[ -f "$WT_NESTED/build/vendor/w.txt" ] || fail "dry-run removed the nested clone file"
case "$dry" in
  *"kept $WT_LIVE reason=live-session"*) ;;
  *) fail "dry-run did not keep the live-session worktree: $dry" ;;
esac
case "$dry" in
  *"kept $WT_SESS reason=recent-session"*) ;;
  *) fail "dry-run did not keep the recent-session worktree: $dry" ;;
esac
case "$dry" in
  *deleted=0*) ;;
  *) fail "dry-run reported a deletion: $dry" ;;
esac

cache_dry=$(run caches)
[ ! -f "$NPM_MARKER" ] || fail "cache dry-run invoked npm"
[ -f "$HOME/Library/Caches/Homebrew/pkg/a" ] || fail "cache dry-run removed Homebrew"
[ -f "$HOME/Library/Caches/com.apple.Safari/data" ] || fail "cache dry-run removed Safari"
[ -f "$HOME/Library/Caches/Slack/data" ] || fail "cache dry-run removed Slack"
[ -f "$HOME/.cache/qmd/index" ] || fail "cache dry-run removed qmd"
[ -f "$HOME/.cache/gh/hosts" ] || fail "cache dry-run removed gh"
case "$cache_dry" in
  *"would-remove $HOME/Library/Caches/Homebrew"*) ;;
  *) fail "cache dry-run did not list Homebrew: $cache_dry" ;;
esac
case "$cache_dry" in
  *Safari*|*Slack*) fail "cache dry-run listed a non-allowlisted cache: $cache_dry" ;;
esac

# ---- apply: only the safe linked worktree goes ----
apply=$(run --apply prune-backed-up 6)
[ ! -d "$WT_SAFE" ] || fail "apply left the safe worktree in place: $apply"
git -C "$REPO_A" worktree list | grep >/dev/null safe && fail "safe worktree still registered" || true
[ -d "$WT_SIDE" ] || fail "apply removed the worktree with an unpushed side branch: $apply"
git -C "$WT_SIDE" rev-parse --verify --quiet side >/dev/null || fail "unpushed side branch was lost"
[ -d "$WT_ENV" ] || fail "apply removed the worktree with .env: $apply"
[ -f "$WT_ENV/.env" ] || fail "apply deleted .env"
grep -q 'SECRET=1' "$WT_ENV/.env" || fail ".env contents changed"
[ -d "$WT_CLONE" ] || fail "apply removed a full clone: $apply"
[ -d "$WT_CLONE/.git" ] || fail "apply deleted the full clone .git directory"
git -C "$WT_CLONE" cat-file -e side:side.txt || fail "apply deleted the full clone side branch"
case "$apply" in
  *"removed $WT_SAFE"*) ;;
  *) fail "apply did not report removing the safe worktree: $apply" ;;
esac
[ -d "$WT_NOTES" ] || fail "apply removed worktree with untracked files hidden by status config: $apply"
[ -f "$WT_NOTES/notes.md" ] || fail "apply deleted notes.md"
grep -q precious "$WT_NOTES/notes.md" || fail "notes.md contents changed"
[ -f "$WT_NOTES/src/out/new.ts" ] || fail "apply deleted src/out/new.ts"
[ -d "$WT_DET" ] || fail "apply removed worktree with a detached reflog commit: $apply"
git -C "$WT_DET" cat-file -t "$LOST" >/dev/null || fail "detached commit object lost"
git -C "$WT_DET" reflog show HEAD --format='%H' | grep >/dev/null "$LOST" || fail "detached commit left the worktree HEAD reflog"
case "$apply" in
  *"reason=reflog-not-pushed:"*) ;;
  *) fail "apply did not report the reflog commit: $apply" ;;
esac
if [ -d "$WT_TRACKED" ] && [ ! -f "$WT_TRACKED/build/release.sh" ]; then
  fail "apply half-deleted tracked build/release.sh"
fi
git -C "$REPO_T" cat-file -e wt-tracked:build/release.sh || fail "tracked build/release.sh is not in git"
[ -d "$WT_CREDS" ] || fail "apply removed worktree with nested ignored creds: $apply"
[ -f "$WT_CREDS/config/out/creds.json" ] || fail "apply deleted config/out/creds.json"
grep -q secret "$WT_CREDS/config/out/creds.json" || fail "creds.json contents changed"
case "$apply" in
  *"reason=ignored:"*) ;;
  *) fail "apply did not report ignored blockers: $apply" ;;
esac
[ -d "$WT_SUB" ] || fail "apply removed a worktree that has a submodule: $apply"
[ -f "$WT_SUB/vendor/build/inside.txt" ] || fail "apply deleted a file inside a submodule"
[ -f "$WT_SUB/node_modules/a.js" ] || fail "apply cleared a submodule worktree"
case "$apply" in
  *"reason=submodule"*) ;;
  *) fail "apply did not keep the submodule worktree: $apply" ;;
esac
[ -d "$WT_SKIP" ] || fail "apply removed the skip-worktree checkout: $apply"
grep -q 'LOCAL-ONLY' "$WT_SKIP/config.json" || fail "apply lost the skip-worktree token"
[ -f "$WT_SKIP/node_modules/pkg.js" ] || fail "apply cleared the skip-worktree checkout"
case "$apply" in
  *"kept $WT_SKIP reason=hidden-local-changes"*) ;;
  *) fail "apply did not report skip-worktree: $apply" ;;
esac
[ -d "$WT_ASSUME" ] || fail "apply removed the assume-unchanged checkout: $apply"
grep -q 'LOCAL' "$WT_ASSUME/config.json" || fail "apply lost the assume-unchanged edit"
[ -f "$WT_ASSUME/node_modules/pkg.js" ] || fail "apply cleared the assume-unchanged checkout"
case "$apply" in
  *"kept $WT_ASSUME reason=hidden-local-changes"*) ;;
  *) fail "apply did not report assume-unchanged: $apply" ;;
esac
[ -f "$WT_FORCED/build/keep.js" ] || fail "apply deleted tracked build/keep.js"
grep -q 'v2 uncommitted' "$WT_FORCED/build/keep.js" || fail "apply lost the uncommitted edit in build/keep.js"
[ -d "$WT_NESTED" ] || fail "apply removed the worktree that holds a nested git clone: $apply"
[ -f "$WT_NESTED/build/vendor/w.txt" ] || fail "apply deleted the nested clone file"
grep -q work "$WT_NESTED/build/vendor/w.txt" || fail "apply changed the nested clone file"
[ "$(git -C "$WT_NESTED/build/vendor" rev-parse HEAD)" = "$NESTED_SHA" ] || fail "apply lost the nested commit"
case "$apply" in
  *"kept $WT_NESTED reason=nested-git:build"*) ;;
  *) fail "apply did not report the nested git clone: $apply" ;;
esac

[ -d "$WT_LIVE" ] || fail "apply removed a worktree with a live process cwd inside: $apply"
case "$apply" in
  *"kept $WT_LIVE reason=live-session"*) ;;
  *) fail "apply did not report the live-session worktree: $apply" ;;
esac
[ -d "$WT_SESS" ] || fail "apply removed a worktree recorded as a recent session cwd: $apply"
case "$apply" in
  *"kept $WT_SESS reason=recent-session"*) ;;
  *) fail "apply did not report the recent-session worktree: $apply" ;;
esac

slim=$(run --apply slim-idle 7)
[ -f "$WT_SLIMLIVE/node_modules/pkg.js" ] || fail "slim-idle cleared a session-owned worktree: $slim"
case "$slim" in
  *"kept $WT_SLIMLIVE reason=recent-session"*) ;;
  *) fail "slim-idle did not report the session-owned worktree: $slim" ;;
esac
[ -f "$WT_GROUP/out/draft.md" ] || fail "slim-idle deleted grouped out/draft.md: $slim"
[ -f "$WT_GROUP/target/plan.txt" ] || fail "slim-idle deleted grouped target/plan.txt: $slim"
[ -f "$WT_NOTES/src/out/new.ts" ] || fail "slim-idle deleted src/out/new.ts: $slim"
[ -f "$WT_SLIM/src/keep.txt" ] || fail "slim-idle deleted untracked src/keep.txt: $slim"
[ ! -e "$WT_SLIM/node_modules" ] || fail "slim-idle left ignored node_modules in an idle worktree: $slim"
case "$slim" in
  *"removed $WT_SLIM/node_modules"*) ;;
  *) fail "slim-idle did not report removing idle node_modules: $slim" ;;
esac
grep -q 'LOCAL-ONLY' "$WT_SKIP/config.json" || fail "slim-idle lost the skip-worktree token: $slim"
[ -f "$WT_SKIP/node_modules/pkg.js" ] || fail "slim-idle cleared a skip-worktree checkout: $slim"
case "$slim" in
  *"kept $WT_SKIP reason=hidden-local-changes"*) ;;
  *) fail "slim-idle did not keep the skip-worktree checkout: $slim" ;;
esac
grep -q 'LOCAL' "$WT_ASSUME/config.json" || fail "slim-idle lost the assume-unchanged edit: $slim"
[ -f "$WT_ASSUME/node_modules/pkg.js" ] || fail "slim-idle cleared an assume-unchanged checkout: $slim"
case "$slim" in
  *"kept $WT_ASSUME reason=hidden-local-changes"*) ;;
  *) fail "slim-idle did not keep the assume-unchanged checkout: $slim" ;;
esac
[ -f "$WT_FORCED/build/keep.js" ] || fail "slim-idle deleted tracked build/keep.js: $slim"
grep -q 'v2 uncommitted' "$WT_FORCED/build/keep.js" || fail "slim-idle lost the uncommitted edit in build/keep.js: $slim"
[ -f "$WT_NESTED/build/vendor/w.txt" ] || fail "slim-idle deleted the nested clone file: $slim"
grep -q work "$WT_NESTED/build/vendor/w.txt" || fail "slim-idle changed the nested clone file"
[ "$(git -C "$WT_NESTED/build/vendor" rev-parse HEAD)" = "$NESTED_SHA" ] || fail "slim-idle lost the nested commit"
case "$slim" in
  *"kept $WT_NESTED reason=nested-git:build"*) ;;
  *) fail "slim-idle did not keep the nested git clone: $slim" ;;
esac

cache_apply=$(run --apply caches)
[ -f "$NPM_MARKER" ] || fail "apply did not run npm cache clean"
[ ! -e "$HOME/Library/Caches/Homebrew" ] || fail "apply left the Homebrew cache"
[ ! -e "$HOME/.cache/gh" ] || fail "apply left the gh cache"
[ -f "$HOME/Library/Caches/com.apple.Safari/data" ] || fail "apply deleted Safari cache"
[ -f "$HOME/Library/Caches/Slack/data" ] || fail "apply deleted Slack cache"
[ -f "$HOME/.cache/qmd/index" ] || fail "apply deleted the qmd cache"
case "$cache_apply" in
  *"removed $HOME/Library/Caches/Homebrew"*) ;;
  *) fail "apply did not report the Homebrew cache: $cache_apply" ;;
esac
case "$cache_apply" in
  *Safari*|*Slack*|*qmd*) fail "apply reported a non-allowlisted cache: $cache_apply" ;;
esac

# The script must not wipe every app cache.
if grep -E 'Library/Caches/?["'\'']?\*' "$SCRIPT" >/dev/null; then
  fail "script still globs ~/Library/Caches"
fi

kill "$LIVE_PID" 2>/dev/null || true
wait "$LIVE_PID" 2>/dev/null || true
LIVE_PID=""

echo "PASS: free-disk-space.test.sh"
