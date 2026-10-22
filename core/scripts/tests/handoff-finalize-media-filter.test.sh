#!/usr/bin/env bash
# handoff-finalize-media-filter.test.sh — feedback_c682f3ad: a handoff must not
# sweep renders, recordings, or other large binaries into HQ root history.
#
# A changeset that named a project folder staged every file under it, and an
# ignored folder with a few tracked files was force-added whole. The HQ root
# history grew by gigabytes a day. These cases pin the filter:
#   1. media under a listed directory is unstaged and reported; text commits
#   2. a media file named directly still commits
#   3. any file above HQ_OFFLOAD_MIN_BYTES is unstaged, named or not
#   4. HQ_HANDOFF_ALLOW_MEDIA=1 lets directory media through
#   5. an ignored directory with tracked files updates only the tracked files
#      and reports the untracked ones
#   6. *.hqcloud placeholders under a listed directory still commit
#   7. a deleted file under a listed directory does not abort the run
#   8. an unreadable file under a listed directory is a stage failure
#   9. a file literally named `*` does not stage its siblings
#  10. a renamed tracked media file stays renamed in the commit
#  11. `a/./b` and `a//b` spellings neither dodge the cap nor lose "named"
#  12. handoff metadata commits under a tiny size cap

set -euo pipefail

SRC_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP_ROOT=$(mktemp -d)
trap 'rm -rf "$TMP_ROOT"' EXIT
# The finalizer honors an exported HQ_ROOT before its own location. Inside an
# HQ session that points at the real HQ, so clear it to keep every case in the
# scratch repos.
unset HQ_ROOT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_eq() {
  local actual="$1" expected="$2" label="$3"
  [[ "$actual" == "$expected" ]] || fail "$label: expected '$expected', got '$actual'"
}

in_head() { git cat-file -e "HEAD:$1" 2>/dev/null; }

skip_reason() { # skip_reason <payload> <path>
  jq -r --arg p "$2" '[.skipped_paths[]? | select(.path == $p) | .reason] | first // ""' <<<"$1"
}

# scaffold_repo <dir> — same minimal HQ-shaped repo as the commit-status test.
scaffold_repo() {
  local repo="$1"
  mkdir -p "$repo/core/scripts/lib" "$repo/workspace/baseline" "$repo/workspace/threads" "$repo/workspace/orchestrator"
  cp "$SRC_ROOT/scripts/handoff-finalize.sh" "$repo/core/scripts/handoff-finalize.sh"
  cp "$SRC_ROOT/scripts/lib/session-id.sh" "$repo/core/scripts/lib/session-id.sh"
  cp "$SRC_ROOT/scripts/hq-status-summary.sh" "$repo/core/scripts/hq-status-summary.sh"
  cp "$SRC_ROOT/scripts/lib/forwarder.sh" "$repo/core/scripts/lib/forwarder.sh"
  cp "$SRC_ROOT/scripts/lib/hq-cli-floor.sh" "$repo/core/scripts/lib/hq-cli-floor.sh"
  chmod +x "$repo/core/scripts/"*.sh

  cat > "$repo/core/scripts/rebuild-threads-index.sh" <<'SH'
#!/usr/bin/env bash
mkdir -p workspace/threads
echo "# Threads" > workspace/threads/INDEX.md
echo "- recent" > workspace/threads/recent.md
SH
  cat > "$repo/core/scripts/rebuild-orchestrator-index.sh" <<'SH'
#!/usr/bin/env bash
mkdir -p workspace/orchestrator
echo "# Orchestrator" > workspace/orchestrator/INDEX.md
SH
  chmod +x "$repo/core/scripts/rebuild-threads-index.sh" "$repo/core/scripts/rebuild-orchestrator-index.sh"

  cat > "$repo/workspace/baseline/hq-local-baseline.json" <<'JSON'
{"categories":[{"name":"baseline","patterns":["companies/*","workspace/*","repos/*","core/settings/*",".hq/*"]}]}
JSON

  git -C "$repo" init -q
  git -C "$repo" config user.email test@example.com
  git -C "$repo" config user.name "Handoff Media Filter Test"
  echo "base" > "$repo/tracked.txt"
  git -C "$repo" add tracked.txt core/scripts workspace/baseline/hq-local-baseline.json
  git -C "$repo" commit -qm "base"
}

run_finalize() { # run_finalize <slug> <files-json>
  "$BASH" core/scripts/handoff-finalize.sh \
    --title "Handoff: $1" \
    --summary "$1" \
    --message "$1" \
    --files-touched-json "$2" \
    --slug "$1"
}

PROJ="companies/acme/projects/promo"

# ── 1 + 2. Directory media is filtered; a named media file commits ──────────
REPO="$TMP_ROOT/dir"
scaffold_repo "$REPO"
cd "$REPO"
mkdir -p "$PROJ/renders" "$PROJ/assets"
echo "# notes" > "$PROJ/notes.md"
printf 'fake video' > "$PROJ/renders/cut-v3.MP4"
printf 'fake image' > "$PROJ/renders/frame.png"
printf 'fake zip' > "$PROJ/renders/bundle.zip"
printf 'fake logo' > "$PROJ/assets/logo.png"

out=$(run_finalize "dir-media" "[\"$PROJ\",\"$PROJ/assets/logo.png\"]")
in_head "$PROJ/notes.md" || fail "text file under a listed directory must commit"
in_head "$PROJ/assets/logo.png" || fail "a media file named directly must commit"
for f in renders/cut-v3.MP4 renders/frame.png renders/bundle.zip; do
  in_head "$PROJ/$f" && fail "$f under a listed directory must not commit"
  assert_eq "$(skip_reason "$out" "$PROJ/$f")" "media-in-directory" "skip reason for $f"
done
jq -e --arg p "$PROJ/renders/frame.png" '.committed_paths | index($p) | not' <<<"$out" >/dev/null \
  || fail "unstaged media must not appear in committed_paths"
[[ -f "$PROJ/renders/cut-v3.MP4" ]] || fail "filtered media must stay on disk"
git diff --cached --quiet || fail "the filter must leave nothing staged behind"

# ── 3. Oversize files are skipped even when named ───────────────────────────
REPO="$TMP_ROOT/oversize"
scaffold_repo "$REPO"
cd "$REPO"
mkdir -p "$PROJ/inside"
head -c 4096 /dev/zero > "$PROJ/dump.bin"
head -c 4096 /dev/zero > "$PROJ/inside/big.log"
echo "small" > "$PROJ/inside/small.txt"

out=$(HQ_OFFLOAD_MIN_BYTES=1024 run_finalize "oversize" "[\"$PROJ/dump.bin\",\"$PROJ/inside\"]")
in_head "$PROJ/dump.bin" && fail "a named file above the cap must not commit"
in_head "$PROJ/inside/big.log" && fail "a directory file above the cap must not commit"
in_head "$PROJ/inside/small.txt" || fail "a small file next to an oversize one must commit"
assert_eq "$(skip_reason "$out" "$PROJ/dump.bin")" "oversize" "named oversize reason"
assert_eq "$(skip_reason "$out" "$PROJ/inside/big.log")" "oversize" "directory oversize reason"

# ── 4. HQ_HANDOFF_ALLOW_MEDIA=1 keeps the old behavior for media ────────────
REPO="$TMP_ROOT/allow"
scaffold_repo "$REPO"
cd "$REPO"
mkdir -p "$PROJ/renders"
printf 'fake video' > "$PROJ/renders/cut.mov"

out=$(HQ_HANDOFF_ALLOW_MEDIA=1 run_finalize "allow-media" "[\"$PROJ\"]")
in_head "$PROJ/renders/cut.mov" || fail "HQ_HANDOFF_ALLOW_MEDIA=1 must let directory media commit"
assert_eq "$(skip_reason "$out" "$PROJ/renders/cut.mov")" "" "allowed media must not be reported as skipped"

# ── 5. Ignored directory with tracked files: no force-add of the rest ───────
REPO="$TMP_ROOT/ignored"
scaffold_repo "$REPO"
cd "$REPO"
mkdir -p "$PROJ/out"
printf '%s/out/\n' "$PROJ" > .gitignore
echo "v1" > "$PROJ/out/manifest.json"
git add .gitignore
git add -f "$PROJ/out/manifest.json"
git commit -qm "track one file in an ignored directory"
echo "v2" > "$PROJ/out/manifest.json"
printf 'fake video' > "$PROJ/out/final.mp4"
echo "scratch" > "$PROJ/out/scratch.txt"

out=$(run_finalize "ignored-dir" "[\"$PROJ/out\"]")
assert_eq "$(git show "HEAD:$PROJ/out/manifest.json")" "v2" "tracked file in ignored directory must update"
in_head "$PROJ/out/final.mp4" && fail "ignored media must not be force-added"
in_head "$PROJ/out/scratch.txt" && fail "ignored untracked files must not be force-added"
assert_eq "$(jq -r '.stage_failures | length' <<<"$out")" "0" "ignored-dir stage_failures"
assert_eq "$(skip_reason "$out" "$PROJ/out/final.mp4")" "ignored-untracked" "ignored media is reported"
assert_eq "$(skip_reason "$out" "$PROJ/out/scratch.txt")" "ignored-untracked" "ignored text is reported"

# ── 6. .hqcloud placeholders are never filtered ─────────────────────────────
REPO="$TMP_ROOT/hqcloud"
scaffold_repo "$REPO"
cd "$REPO"
mkdir -p "$PROJ/renders"
printf '{"offloaded":true}' > "$PROJ/renders/cut.mp4.hqcloud"

out=$(HQ_OFFLOAD_MIN_BYTES=4 run_finalize "hqcloud" "[\"$PROJ\"]")
in_head "$PROJ/renders/cut.mp4.hqcloud" || fail ".hqcloud placeholder must commit"

# ── 7. A deleted file in a listed directory does not abort the run ──────────
REPO="$TMP_ROOT/deleted"
scaffold_repo "$REPO"
cd "$REPO"
mkdir -p "$PROJ"
echo "old" > "$PROJ/gone.md"
git add "$PROJ/gone.md"
git commit -qm "track a file that will be deleted"
rm "$PROJ/gone.md"
echo "# new" > "$PROJ/new.md"
printf 'fake image' > "$PROJ/shot.png"

out=$(run_finalize "deleted" "[\"$PROJ\"]") || fail "a deleted file must not abort the finalizer"
assert_eq "$(jq -r '.hq_commit_status' <<<"$out")" "committed" "deleted-file commit status"
in_head "$PROJ/gone.md" && fail "the deletion must commit"
in_head "$PROJ/new.md" || fail "a new text file next to a deletion must commit"
in_head "$PROJ/shot.png" && fail "directory media next to a deletion must still be filtered"
git diff --cached --quiet || fail "deleted-file case left files staged"

# ── 8. An unreadable file is a stage failure, not a silent drop ────────────
REPO="$TMP_ROOT/unreadable"
scaffold_repo "$REPO"
cd "$REPO"
mkdir -p "$PROJ"
echo "ok" > "$PROJ/ok.md"
git add "$PROJ/ok.md"
git commit -qm "track a file in the project"
echo "secret draft" > "$PROJ/locked.md"
chmod 000 "$PROJ/locked.md"

rc=0
out=$(run_finalize "unreadable" "[\"$PROJ\"]") || rc=$?
chmod 644 "$PROJ/locked.md"
assert_eq "$rc" "4" "unreadable-file exit code"
assert_eq "$(jq -r '.hq_commit_status' <<<"$out")" "stage-failed" "unreadable-file commit status"
assert_eq "$(jq -r --arg p "$PROJ" '.stage_failures | index($p) != null' <<<"$out")" "true" "unreadable dir listed in stage_failures"

# ── 9. A file named `*` is a literal path, not a glob ──────────────────────
REPO="$TMP_ROOT/literal"
scaffold_repo "$REPO"
cd "$REPO"
mkdir -p "$PROJ/d"
echo "star" > "$PROJ/d/*"
printf 'fake video' > "$PROJ/d/clip.mp4"
echo "other" > "$PROJ/d/other.md"

out=$(run_finalize "literal" "[\"$PROJ/d/*\"]")
in_head "$PROJ/d/*" || fail "a file literally named * must commit"
in_head "$PROJ/d/clip.mp4" && fail "a * file name must not stage its media siblings"
in_head "$PROJ/d/other.md" && fail "a * file name must not stage its siblings"

# ── 10. Renaming a tracked media file keeps the new name ───────────────────
REPO="$TMP_ROOT/rename"
scaffold_repo "$REPO"
cd "$REPO"
mkdir -p "$PROJ/media"
printf 'fake image bytes for rename detection' > "$PROJ/media/a.png"
git add "$PROJ/media/a.png"
git commit -qm "track media"
mv "$PROJ/media/a.png" "$PROJ/media/b.png"

out=$(run_finalize "rename" "[\"$PROJ\"]")
in_head "$PROJ/media/a.png" && fail "the old media name must be gone after a rename"
in_head "$PROJ/media/b.png" || fail "a renamed tracked media file must commit under its new name"
assert_eq "$(skip_reason "$out" "$PROJ/media/b.png")" "" "renamed media must not be reported as skipped"

# ── 11. Path spellings: `./` cannot dodge the cap, `//` keeps a file named ─
REPO="$TMP_ROOT/spelling"
scaffold_repo "$REPO"
cd "$REPO"
mkdir -p "$PROJ/assets"
echo "small" > "$PROJ/grow.log"
git add "$PROJ/grow.log"
git commit -qm "track a log that will grow"
head -c 4096 /dev/zero > "$PROJ/big.bin"
head -c 4096 /dev/zero > "$PROJ/grow.log"
printf 'fake logo' > "$PROJ/assets/logo.png"

out=$(HQ_OFFLOAD_MIN_BYTES=1024 run_finalize "spelling" \
  "[\"$PROJ/./big.bin\",\"$PROJ/grow.log\",\"companies/acme/projects//promo/assets/logo.png\"]")
in_head "$PROJ/big.bin" && fail "a ./ spelling must not dodge the size cap"
assert_eq "$(skip_reason "$out" "$PROJ/big.bin")" "oversize" "./ spelling oversize reason"
assert_eq "$(git show "HEAD:$PROJ/grow.log")" "small" "a tracked file grown past the cap must not commit"
assert_eq "$(skip_reason "$out" "$PROJ/grow.log")" "oversize" "grown tracked file reason"
in_head "$PROJ/assets/logo.png" || fail "a media file named with // must count as named"

# ── 12. Handoff metadata commits under a tiny cap ──────────────────────────
REPO="$TMP_ROOT/metadata"
scaffold_repo "$REPO"
cd "$REPO"
mkdir -p "$PROJ"
echo "# notes" > "$PROJ/notes.md"

out=$(HQ_OFFLOAD_MIN_BYTES=4 run_finalize "metadata" "[\"$PROJ/notes.md\"]")
thread_id=$(jq -r '.thread_id' <<<"$out")
in_head "workspace/threads/$thread_id.json" || fail "the thread file must commit under a tiny cap"
in_head "workspace/threads/INDEX.md" || fail "the threads index must commit under a tiny cap"
in_head "workspace/orchestrator/INDEX.md" || fail "the orchestrator index must commit under a tiny cap"
in_head "$PROJ/notes.md" && fail "a changeset file above the tiny cap must not commit"

echo "PASS: handoff-finalize-media-filter"
