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
trap 'rm -rf "$TMP"' EXIT

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

backdate() {
  find "$1" -exec touch -t 202001010000 {} +
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
git -C "$WT_SUB" ls-files -s | grep -q '^160000 ' || fail "submodule gitlink missing"

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
git -C "$WT_SKIP" ls-files -v -- config.json | grep -q '^S ' || fail "skip-worktree tag is not S"
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
git -C "$WT_ASSUME" ls-files -v -- config.json | grep -q '^[a-z] ' || fail "assume-unchanged tag is not lowercase"
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
git -C "$WT_FORCED" ls-files -v -- build/keep.js | grep -q '^H ' || fail "forced file is not a normal tracked file"
git -C "$WT_FORCED" status --porcelain --untracked-files=all --ignore-submodules=none | grep -q 'build/keep.js' \
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
if git -C "$WT_NESTED" ls-files -s | grep -q '^160000 '; then
  fail "nested clone was recorded as a submodule"
fi

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
git -C "$REPO_A" worktree list | grep -q safe && fail "safe worktree still registered" || true
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
git -C "$WT_DET" reflog show HEAD --format='%H' | grep -q "$LOST" || fail "detached commit left the worktree HEAD reflog"
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

slim=$(run --apply slim-idle 7)
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

echo "PASS: free-disk-space.test.sh"
