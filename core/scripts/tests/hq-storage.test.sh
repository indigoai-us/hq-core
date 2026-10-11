#!/usr/bin/env bash
# hq-core: public
# Tests for core/scripts/hq-storage.sh (report + prune of HQ autosave history).
#
# Builds a throwaway repo with backdated commits (GIT_COMMITTER_DATE) and checks:
#   - report JSON tranches and counts
#   - prune --dry-run changes nothing
#   - prune keeps newer commits' content and messages, drops old ones, leaves
#     the working tree and index untouched
#   - prune refuses while the autosave lock is held, with staged changes, and
#     when remote-tracking branches exist

set -euo pipefail

SRC_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SCRIPT="$SRC_ROOT/core/scripts/hq-storage.sh"
TMP="$(mktemp -d)"
export TMPDIR="$TMP/tmpdir"
mkdir -p "$TMPDIR"
trap 'rm -rf "$TMP"' EXIT

# Run the script under /bin/bash when it is bash 3.x (stock macOS): empty
# arrays under set -u abort there and nowhere else. Elsewhere use bash.
RUN_BASH="$(command -v bash)"
if [[ -x /bin/bash ]] && [[ "$(/bin/bash -c 'echo ${BASH_VERSINFO[0]}')" -lt 4 ]]; then RUN_BASH=/bin/bash; fi
echo "hq-storage tests run the script with: $RUN_BASH ($("$RUN_BASH" -c 'echo $BASH_VERSION'))"

PASS=0
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { PASS=$((PASS + 1)); }

# "now" for report tranches. It is the real clock (whole seconds) because git
# dates reflog entries from the commit dates the tests set, and git's reflog
# expiry (30/90 days) compares them with the real clock: the undo-history
# checks need recent entries to really be recent.
NOW="$(date -u +%s)"
export HQ_STORAGE_NOW="$NOW"
DAY=86400

REPO="$TMP/hq"
git init -q -b main "$REPO"
git -C "$REPO" config user.name t
git -C "$REPO" config user.email t@example.com
git -C "$REPO" config commit.gpgsign false

# commit <age-days> <file> <content>
commit_at() {
  local ts=$(( NOW - $1 * DAY ))
  printf '%s\n' "$3" >"$REPO/$2"
  git -C "$REPO" add -- "$2"
  GIT_AUTHOR_DATE="@$ts +0000" GIT_COMMITTER_DATE="@$ts +0000" \
    git -C "$REPO" commit -q -m "autosave(hq): $2 $1"
}

# iso <epoch>: ISO8601 UTC, as the script prints it.
iso() { date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
UNDO_AFTER="$(iso $((NOW + 30*DAY)))"

# age_out <repo>: reclaim as if the 30-day undo window has passed: the
# script's clock is past the undo date, and git's reflog expiry treats every
# entry as old (git itself uses the real clock). Prints reclaim's JSON.
age_out() {
  HQ_STORAGE_NOW=$((NOW + 31*DAY)) GIT_CONFIG_COUNT=2 \
    GIT_CONFIG_KEY_0=gc.reflogExpire GIT_CONFIG_VALUE_0=now \
    GIT_CONFIG_KEY_1=gc.reflogExpireUnreachable GIT_CONFIG_VALUE_1=now \
    "$RUN_BASH" "$SCRIPT" reclaim --json --root "$1"
}

# older than 1 year: 3 commits; 90d-1y: 2; 30-90d: 2; 7-30d: 1; last 7d: 2
commit_at 500 a.txt "a-v1-$(head -c 4000 /dev/zero | tr '\0' x)"
commit_at 450 a.txt "a-v2"
commit_at 400 b.txt "b-v1"
commit_at 200 a.txt "a-v3"
commit_at 100 c.txt "c-v1"
commit_at 60 c.txt "c-v2"
commit_at 40 d.txt "d-v1"
commit_at 20 d.txt "d-v2"
commit_at 3 e.txt "e-v1"
commit_at 1 e.txt "e-v2"
echo "untracked" >"$REPO/scratch.txt"

# ---------------------------------------------------------------- report
R="$("$RUN_BASH" "$SCRIPT" report --json --root "$REPO")"
echo "$R" | jq -e . >/dev/null || fail "report is not JSON: $R"
[[ "$(echo "$R" | jq -r .commit_count)" == 10 ]] || fail "commit_count"
[[ "$(echo "$R" | jq -r '[.tranches[].id]|join(",")')" == "7d,30d,90d,365d,older" ]] || fail "tranche ids"
[[ "$(echo "$R" | jq -r '[.tranches[].commit_count]|join(",")')" == "2,1,2,2,3" ]] || fail "tranche counts: $R"
[[ "$(echo "$R" | jq -r '.tranches[4].label')" == "Older than 1 year" ]] || fail "label"
[[ "$(echo "$R" | jq -r .oldest_commit_at)" == "$(date -u -r $((NOW - 500*DAY)) +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d @$((NOW - 500*DAY)) +%Y-%m-%dT%H:%M:%SZ)" ]] || fail "oldest_commit_at"
for k in git_dir_bytes working_tree_bytes; do
  [[ "$(echo "$R" | jq -r ".$k|type")" == number ]] || fail "$k not a number"
done
# Older tranche introduced the large a-v1 blob, which HEAD no longer has.
[[ "$(echo "$R" | jq -r '.tranches[4].est_bytes')" -gt 0 ]] || fail "older est_bytes should be > 0"
# Latest e-v2 is in HEAD; e-v1 is gone. Tranche keys exist on every entry.
[[ "$(echo "$R" | jq -r '[.tranches[]|has("from") and has("to") and has("est_bytes")]|all')" == true ]] || fail "tranche fields"
# Cache is written under workspace/.storage-cache and reused.
ls "$REPO"/workspace/.storage-cache/report.json >/dev/null 2>&1 || fail "cache not written"
# (sizes are measured live; the history part comes from the cache)
[[ "$("$RUN_BASH" "$SCRIPT" report --json --root "$REPO" | jq -c '.tranches,.commit_count')" == "$(echo "$R" | jq -c '.tranches,.commit_count')" ]] || fail "cached report differs"
rm -rf "$REPO/workspace"
ok

# Cutoff 2026-...: compute from NOW-300 days (between 400d and 200d commits).
CUT="$(date -u -r $((NOW - 300*DAY)) +%Y-%m-%d 2>/dev/null || date -u -d @$((NOW - 300*DAY)) +%Y-%m-%d)"

# ---------------------------------------------------------------- dry-run
HEAD0="$(git -C "$REPO" rev-parse HEAD)"
D="$("$RUN_BASH" "$SCRIPT" prune --before "$CUT" --dry-run --root "$REPO")"
[[ "$(echo "$D" | jq -r .would_remove_commits)" == 2 ]] || fail "dry-run count: $D"
[[ "$(echo "$D" | jq -r .est_bytes)" -gt 0 ]] || fail "dry-run est_bytes: $D"
[[ "$(git -C "$REPO" rev-parse HEAD)" == "$HEAD0" ]] || fail "dry-run moved HEAD"
[[ "$(git -C "$REPO" rev-list --count HEAD)" == 10 ]] || fail "dry-run changed history"
ok

# ---------------------------------------------------------------- refusals
mkdir "$TMPDIR/hq-autocommit.lock"
if "$RUN_BASH" "$SCRIPT" prune --before "$CUT" --yes --root "$REPO" 2>/dev/null; then fail "prune ran while lock held"; fi
[[ -d "$TMPDIR/hq-autocommit.lock" ]] || fail "prune removed someone else's lock"
rmdir "$TMPDIR/hq-autocommit.lock"
[[ "$(git -C "$REPO" rev-parse HEAD)" == "$HEAD0" ]] || fail "lock refusal moved HEAD"
ok

echo staged >"$REPO/f.txt"; git -C "$REPO" add f.txt
if "$RUN_BASH" "$SCRIPT" prune --before "$CUT" --yes --root "$REPO" 2>/dev/null; then fail "prune ran with staged index"; fi
git -C "$REPO" rm -q --cached f.txt; rm -f "$REPO/f.txt"
ok

git -C "$REPO" update-ref refs/remotes/origin/main HEAD
if "$RUN_BASH" "$SCRIPT" prune --before "$CUT" --yes --root "$REPO" 2>/dev/null; then fail "prune ran with remote-tracking branch"; fi
git -C "$REPO" update-ref -d refs/remotes/origin/main
ok

if "$RUN_BASH" "$SCRIPT" prune --before "$CUT" --root "$REPO" </dev/null 2>/dev/null; then fail "prune ran without --yes and no tty"; fi
ok

# ---------------------------------------------------------------- prune
echo "local edit" >>"$REPO/e.txt" # dirty unstaged working tree must survive
WT_BEFORE="$(cd "$REPO" && find . -path ./.git -prune -o -type f -print | sort | xargs cat | shasum)"
NEW_MSGS="$(git -C "$REPO" log --format='%s|%an|%ae|%at|%ct' -7 HEAD)"
NEW_TREES="$(git -C "$REPO" log --format='%T' -7 HEAD)"
OUT="$("$RUN_BASH" "$SCRIPT" prune --before "$CUT" --yes --no-backup --json --root "$REPO")"
# --no-backup: no backup ref, but the old history stays in git's undo
# history, so the output reports it as pending until the undo date.
echo "$OUT" | jq -e --arg u "$UNDO_AFTER" '.before.git_dir_bytes and .after.git_dir_bytes and .backup_ref == null and .pending_reclaim_bytes > 0 and .reclaim_after == $u' >/dev/null || fail "prune output: $OUT"
[[ "$(echo "$OUT" | jq -r .removed_commits)" == 2 ]] || fail "removed_commits: $OUT"
[[ "$(git -C "$REPO" rev-list --count HEAD)" == 8 ]] || fail "expected 8 commits after prune"
[[ "$(git -C "$REPO" log --format='%s|%an|%ae|%at|%ct' -7 HEAD)" == "$NEW_MSGS" ]] || fail "newer commit metadata changed"
[[ "$(git -C "$REPO" log --format='%T' -7 HEAD)" == "$NEW_TREES" ]] || fail "newer commit trees changed"
ROOTC="$(git -C "$REPO" rev-list --max-parents=0 HEAD)"
git -C "$REPO" log -1 --format=%s "$ROOTC" | grep -q '^hq-storage: squashed 3 autosave commits' || fail "root message"
[[ "$(git -C "$REPO" show "$ROOTC:a.txt")" == "a-v2" ]] || fail "root tree is not the last pre-cutoff tree"
[[ "$(git -C "$REPO" show "$ROOTC:b.txt")" == "b-v1" ]] || fail "root tree missing b.txt"
WT_AFTER="$(cd "$REPO" && find . -path ./.git -prune -o -type f -print | sort | xargs cat | shasum)"
[[ "$WT_BEFORE" == "$WT_AFTER" ]] || fail "working tree changed"
[[ "$(git -C "$REPO" status --porcelain)" == $' M e.txt\n?? scratch.txt' ]] || fail "status changed: $(git -C "$REPO" status --porcelain)"
# Undo kept: the old blob a-v1 and the HEAD reflog survive prune, and report
# shows the space as pending (with the date), not freed.
OLD_BLOB="$(printf '%s\n' "a-v1-$(head -c 4000 /dev/zero | tr '\0' x)" | git -C "$REPO" hash-object --stdin)"
git -C "$REPO" cat-file -e "$OLD_BLOB" || fail "prune removed the old blob while reflog entries still reach it"
[[ "$(git -C "$REPO" reflog show --format=%H HEAD)" == *"$HEAD0"* ]] || fail "prune expired the HEAD reflog entry for the old tip"
R="$("$RUN_BASH" "$SCRIPT" report --json --no-cache --root "$REPO")"
echo "$R" | jq -e --arg u "$UNDO_AFTER" '.pending_reclaim_bytes > 0 and .reclaim_after == $u' >/dev/null || fail "report pending after prune: $R"
# Inside the window reclaim does nothing.
C="$("$RUN_BASH" "$SCRIPT" reclaim --json --root "$REPO")"
echo "$C" | jq -e '.freed_bytes == 0' >/dev/null || fail "reclaim inside the undo window: $C"
git -C "$REPO" cat-file -e "$OLD_BLOB" || fail "reclaim freed the blob inside the undo window"
# Once the entries age past the window, reclaim frees it and nothing is pending.
C="$(age_out "$REPO")"
if git -C "$REPO" cat-file -e "$OLD_BLOB" 2>/dev/null; then fail "old blob still present after the undo window: $C"; fi
R="$(HQ_STORAGE_NOW=$((NOW + 31*DAY)) "$RUN_BASH" "$SCRIPT" report --json --no-cache --root "$REPO")"
echo "$R" | jq -e '.pending_reclaim_bytes == 0 and .reclaim_after == null' >/dev/null || fail "pending after the undo window: $R"
[[ ! -d "$TMPDIR/hq-autocommit.lock" ]] || fail "lock not released"
ok

# Nothing older than cutoff left: second prune is a no-op.
[[ "$("$RUN_BASH" "$SCRIPT" prune --before "$CUT" --dry-run --root "$REPO" | jq -r .would_remove_commits)" == 0 ]] || fail "second dry-run"
ok

# ---------------------------------------------------------------- merges + refs
# A merge kept after the cutoff is flattened to its first parent with the same
# tree; other refs are reported as retained.
REPO="$TMP/hq2"
git init -q -b main "$REPO"
git -C "$REPO" config user.name t
git -C "$REPO" config user.email t@example.com
git -C "$REPO" config commit.gpgsign false
commit_at 500 a.txt "old"
commit_at 400 a.txt "old2"
git -C "$REPO" tag keep-old
git -C "$REPO" checkout -q -b side
commit_at 50 s.txt "side"
git -C "$REPO" checkout -q main
commit_at 40 a.txt "new"
ts=$(( NOW - 30 * DAY ))
GIT_AUTHOR_DATE="@$ts +0000" GIT_COMMITTER_DATE="@$ts +0000" git -C "$REPO" merge -q --no-ff -m "merge side" side
git -C "$REPO" branch -q -D side
TIP_TREE="$(git -C "$REPO" rev-parse 'HEAD^{tree}')"
D="$("$RUN_BASH" "$SCRIPT" prune --before "$CUT" --dry-run --root "$REPO")"
[[ "$(echo "$D" | jq -r .flattened_merges)" == 1 ]] || fail "flattened_merges: $D"
[[ "$(echo "$D" | jq -r .retained_refs)" == 1 ]] || fail "retained_refs: $D"
# The tag still reaches the old history: nothing to free, and it is named.
echo "$D" | jq -e '.est_bytes == 0 and .holding_refs_count == 1 and .holding_refs[0].name == "refs/tags/keep-old" and (.holding_refs[0].commit_date | test("^[0-9]{4}-"))' >/dev/null || fail "holding refs: $D"
R2="$("$RUN_BASH" "$SCRIPT" report --json --no-cache --root "$REPO")"
echo "$R2" | jq -e '.holding_refs_count == 1 and ([.tranches[].est_bytes] | add) == 0' >/dev/null || fail "report must not promise bytes a tag holds: $R2"
HEAD_HQ2="$(git -C "$REPO" rev-parse HEAD)"
set +e; ROUT="$("$RUN_BASH" "$SCRIPT" prune --before "$CUT" --yes --root "$REPO" 2>"$TMP/err4")"; RC=$?; set -e
ERR="$(cat "$TMP/err4")"
[[ "$RC" == 4 ]] || fail "prune with nothing to free must refuse (rc 4), got $RC: $ERR"
# Readable names in core's own text; the JSON keeps the ref names.
echo "$ERR" | grep -q 'tag keep-old' || fail "refusal does not name the holding tag: $ERR"
if echo "$ERR" | grep -q 'refs/'; then fail "refusal text shows raw ref names: $ERR"; fi
echo "$ROUT" | jq -e '.holding_refs[0].name == "refs/tags/keep-old" and (.message | test("tag keep-old"))' >/dev/null || fail "refusal JSON: $ROUT"
# Exit 4 also prints a JSON object on stdout, so callers need not parse stderr.
echo "$ROUT" | jq -e '.refused == "nothing_to_free" and .holding_refs_count == 1 and .holding_refs[0].name == "refs/tags/keep-old"' >/dev/null \
  || fail "refusal JSON on stdout: $ROUT"
[[ "$(git -C "$REPO" rev-parse HEAD)" == "$HEAD_HQ2" ]] || fail "refused prune moved HEAD"
OUT="$("$RUN_BASH" "$SCRIPT" prune --before "$CUT" --yes --force --no-backup --root "$REPO")"
[[ "$(git -C "$REPO" rev-parse 'HEAD^{tree}')" == "$TIP_TREE" ]] || fail "merge flatten changed tree"
[[ "$(git -C "$REPO" rev-list --merges --count HEAD)" == 0 ]] || fail "merge not flattened"
[[ "$(git -C "$REPO" log --format=%s HEAD)" == $'merge side\nautosave(hq): a.txt 40\nhq-storage: squashed 2 autosave commits before '"$CUT" ]] || fail "merge history: $(git -C "$REPO" log --format=%s HEAD)"
git -C "$REPO" rev-parse -q --verify keep-old >/dev/null || fail "prune deleted another ref"
ok

# ---------------------------------------------------------------- extra refs
# Tool markers (refs/cmux/last-turn/*, refs/original/*) pointing at pre-cutoff
# commits are deleted; one on a kept commit is moved to its rewritten copy;
# branches, tags and stash survive; gc then frees the old objects. Branch,
# tag and stash here sit on an unrelated orphan line: one that reached the old
# commits would keep them alive (the estimate check below covers that case).
REPO="$TMP/hq3"
git init -q -b main "$REPO"
git -C "$REPO" config user.name t
git -C "$REPO" config user.email t@example.com
git -C "$REPO" config commit.gpgsign false
BIG="$(head -c 20000 /dev/urandom | base64)"
commit_at 500 big.txt "$BIG"
OLD1="$(git -C "$REPO" rev-parse HEAD)"
commit_at 450 big.txt "small"
OLD2="$(git -C "$REPO" rev-parse HEAD)"
commit_at 400 a.txt "x"
commit_at 50 a.txt "y"
NEWC="$(git -C "$REPO" rev-parse HEAD)"
commit_at 10 a.txt "z"
git -C "$REPO" checkout -q --orphan other
git -C "$REPO" rm -rq --cached .
commit_at 5 o.txt "orphan"
git -C "$REPO" tag v-other
echo stash-me >>"$REPO/o.txt"; git -C "$REPO" stash -q
ORPH="$(git -C "$REPO" rev-parse HEAD)"
git -C "$REPO" checkout -q -f main
git -C "$REPO" clean -fdq
git -C "$REPO" update-ref refs/cmux/last-turn/s1 "$OLD1"
git -C "$REPO" update-ref refs/cmux/last-turn/s2 "$OLD2"
git -C "$REPO" update-ref refs/original/refs/heads/main "$OLD1"
git -C "$REPO" update-ref refs/cmux/last-turn/s3 "$NEWC"
BIG_BLOB="$(printf '%s\n' "$BIG" | git -C "$REPO" hash-object --stdin)"
R="$("$RUN_BASH" "$SCRIPT" report --json --root "$REPO" --no-cache)"
[[ "$(echo "$R" | jq -r .extra_refs)" == 4 ]] || fail "report extra_refs: $R"
[[ "$(echo "$R" | jq -r '[.tranches[].id]|join(",")')" == "7d,30d,90d,365d,older" ]] || fail "report fields changed"
D="$("$RUN_BASH" "$SCRIPT" prune --before "$CUT" --dry-run --root "$REPO")"
[[ "$(echo "$D" | jq -r .refs_to_remove)" == 3 ]] || fail "refs_to_remove: $D"
[[ "$(echo "$D" | jq -r '.refs_to_remove_sample|length')" == 3 ]] || fail "refs_to_remove_sample: $D"
echo "$D" | jq -e '.refs_to_remove_sample|index("refs/cmux/last-turn/s1")' >/dev/null || fail "sample missing s1: $D"
# The estimate covers the big blob that only old history and old refs reach.
[[ "$(echo "$D" | jq -r .est_bytes)" -gt 10000 ]] || fail "est_bytes too small: $D"
[[ "$(git -C "$REPO" for-each-ref refs/cmux | grep -c .)" == 3 ]] || fail "dry-run deleted refs"
git -C "$REPO" gc -q --prune=now
objects() { git -C "$REPO" count-objects -v | awk '/^(count|in-pack):/ {s+=$2} END {print s}'; }
OBJ_BEFORE="$(objects)"
STASH_BEFORE="$(git -C "$REPO" rev-parse refs/stash)"
OUT="$("$RUN_BASH" "$SCRIPT" prune --before "$CUT" --yes --no-backup --root "$REPO")"
[[ "$(echo "$OUT" | jq -r .refs_removed)" == 3 ]] || fail "refs_removed: $OUT"
for r in refs/cmux/last-turn/s1 refs/cmux/last-turn/s2 refs/original/refs/heads/main; do
  if git -C "$REPO" rev-parse -q --verify "$r" >/dev/null; then fail "$r not removed"; fi
done
S3="$(git -C "$REPO" rev-parse -q --verify refs/cmux/last-turn/s3)" || fail "post-cutoff ref removed"
[[ "$S3" != "$NEWC" ]] || fail "post-cutoff ref not moved to rewritten commit"
git -C "$REPO" merge-base --is-ancestor "$S3" HEAD || fail "moved ref not on rewritten branch"
[[ "$(git -C "$REPO" log -1 --format=%s "$S3")" == "autosave(hq): a.txt 50" ]] || fail "moved ref points at wrong commit"
git -C "$REPO" rev-parse -q --verify refs/heads/other >/dev/null || fail "other branch removed"
[[ "$(git -C "$REPO" rev-parse refs/tags/v-other)" == "$ORPH" ]] || fail "tag changed"
[[ "$(git -C "$REPO" rev-parse refs/heads/other)" == "$ORPH" ]] || fail "branch changed"
[[ "$(git -C "$REPO" rev-parse refs/stash)" == "$STASH_BEFORE" ]] || fail "stash changed"
# Undo kept: recent reflog entries still reach the blob until they age out.
git -C "$REPO" cat-file -e "$BIG_BLOB" || fail "undo history dropped early (big old blob still present after gc)"
age_out "$REPO" >/dev/null
if git -C "$REPO" cat-file -e "$BIG_BLOB" 2>/dev/null; then fail "big old blob still present after gc (after the undo window)"; fi
OBJ_AFTER="$(objects)"
[[ "$OBJ_AFTER" -lt "$OBJ_BEFORE" ]] || fail "object count did not drop: $OBJ_BEFORE -> $OBJ_AFTER"
ok

# A kept tag on old history keeps a big blob alive, and the estimate says so.
BIG2="$(head -c 20000 /dev/urandom | base64)"
commit_at 4 big2.txt "$BIG2"
git -C "$REPO" tag v-pin
commit_at 3 big2.txt "gone"
CUT2="$(date -u -r $((NOW - 2*DAY)) +%Y-%m-%d 2>/dev/null || date -u -d @$((NOW - 2*DAY)) +%Y-%m-%d)"
E1="$("$RUN_BASH" "$SCRIPT" prune --before "$CUT2" --dry-run --root "$REPO" | jq -r .est_bytes)"
git -C "$REPO" tag -d v-pin >/dev/null
E2="$("$RUN_BASH" "$SCRIPT" prune --before "$CUT2" --dry-run --root "$REPO" | jq -r .est_bytes)"
[[ "$E2" -gt "$(( E1 + 10000 ))" ]] || fail "estimate ignores kept tag: with=$E1 without=$E2"
ok

# ---------------------------------------------------------------- big files
# Fresh repo: a big blob in old commits (OLD, later overwritten), a big blob
# still in HEAD (CUR), a small file, an annotated tag and a lightweight tag on
# old history, a side branch, and an extra ref.
BR="$TMP/big"
git init -q -b main "$BR"
git -C "$BR" config user.name t; git -C "$BR" config user.email t@example.com
git -C "$BR" config commit.gpgsign false; git -C "$BR" config tag.gpgsign false
bc() { # bc <age-days> <file> <content-file|text> <msg>
  local ts=$(( NOW - $1 * DAY ))
  mkdir -p "$(dirname "$BR/$2")"
  if [[ -f "$3" ]]; then cp "$3" "$BR/$2"; else printf '%s\n' "$3" >"$BR/$2"; fi
  git -C "$BR" add -- "$2"
  GIT_AUTHOR_DATE="@$ts +0000" GIT_COMMITTER_DATE="@$ts +0000" git -C "$BR" commit -q -m "$4"
}
head -c 300000 /dev/urandom >"$TMP/old.bin"
head -c 200000 /dev/urandom >"$TMP/cur.bin"
bc 50 notes.md "hello" "first: notes"
bc 40 media/promo.mp4 "$TMP/old.bin" "add promo"
git -C "$BR" tag -a v1 -m "release v1"
git -C "$BR" tag light
bc 30 media/promo.mp4 "small now" "shrink promo"
git -C "$BR" branch side
bc 20 media/clip.mov "$TMP/cur.bin" "add clip"
bc 10 notes.md "hello again" $'multi\n\nline message'
# A symlink replaced by a directory (real HQ history has these): fast-export
# prints the new files before deleting the link, which would drop them.
ln -s notes.md "$BR/skill"
git -C "$BR" add skill; git -C "$BR" commit -q -m "skill as link"
rm "$BR/skill"; mkdir "$BR/skill"; printf 'real\n' >"$BR/skill/SKILL.md"
git -C "$BR" add -A skill; git -C "$BR" commit -q -m "skill as dir"
git -C "$BR" update-ref refs/cmux/last-turn/x HEAD~3
OLD="$(git -C "$BR" hash-object "$TMP/old.bin")"
CUR="$(git -C "$BR" hash-object "$TMP/cur.bin")"

L="$("$RUN_BASH" "$SCRIPT" large --json --min-bytes 100000 --root "$BR")"
echo "$L" | jq -e '.min_bytes == 100000 and .history.count == 2' >/dev/null || fail "large history count: $L"
echo "$L" | jq -e --arg o "$OLD" '.history.blobs[] | select(.sha == $o) | .in_head == false and .paths == ["media/promo.mp4"] and .bytes == 300000' >/dev/null || fail "large old blob: $L"
echo "$L" | jq -e --arg c "$CUR" '.history.blobs[] | select(.sha == $c) | .in_head == true' >/dev/null || fail "large head blob: $L"
echo "$L" | jq -e '.current.count == 1 and .current.files[0].path == "media/clip.mov" and .current.files[0].bytes == 200000' >/dev/null || fail "large current: $L"
ok

pointer() { # pointer <sha> <size>
  printf 'HQ-CLOUD-FILE v1\npath: media/promo.mp4\nsize: %s\nsha256: 00\ngit-blob: %s\nvault: personal\n' "$2" "$1"
}
mkman() { # mkman <sha>... -> manifest path (sizes read from the repo)
  local m="$TMP/manifest.json" s
  for s in "$@"; do jq -n --arg s "$s" --arg p "$(pointer "$s" "$(git -C "$BR" cat-file -s "$s")")" '{sha: $s, pointer_text: $p}'; done \
    | jq -s '{blobs: .}' >"$m"
  printf '%s' "$m"
}
MAN="$(mkman "$OLD" "$CUR")"

# Lock contention refuses and changes nothing.
SNAP="$(git -C "$BR" for-each-ref --format='%(refname) %(objectname)')"
mkdir "$TMPDIR/hq-autocommit.lock"
if "$RUN_BASH" "$SCRIPT" strip-large --manifest "$MAN" --yes --root "$BR" 2>/dev/null; then fail "strip-large ran while lock held"; fi
[[ -d "$TMPDIR/hq-autocommit.lock" ]] || fail "strip-large removed someone else's lock"
rmdir "$TMPDIR/hq-autocommit.lock"
[[ "$(git -C "$BR" for-each-ref --format='%(refname) %(objectname)')" == "$SNAP" ]] || fail "lock refusal changed refs"
ok

# Dry run changes nothing.
D="$("$RUN_BASH" "$SCRIPT" strip-large --manifest "$MAN" --dry-run --root "$BR")"
echo "$D" | jq -e --arg c "$CUR" '.present_blobs == 1 and .skipped_current == [$c]' >/dev/null || fail "strip dry-run: $D"
[[ "$(git -C "$BR" for-each-ref --format='%(refname) %(objectname)')" == "$SNAP" ]] || fail "dry run changed refs"
ok

msgs() { git -C "$BR" log --all --format='%an %ae %at %ct %B' | sort; }
MSGS0="$(msgs)"; COUNT0="$(git -C "$BR" rev-list --all --count)"
V1_MSG0="$(git -C "$BR" cat-file tag v1 | sed '1,/^$/d')"
BR_TIP0="$(git -C "$BR" rev-parse HEAD)"
WT0="$(cksum <"$BR/media/clip.mov")"
echo "local edit" >>"$BR/notes.md"
OUT="$("$RUN_BASH" "$SCRIPT" strip-large --manifest "$MAN" --yes --no-backup --json --root "$BR")"
echo "$OUT" | jq -e --arg c "$CUR" --arg u "$UNDO_AFTER" '.replaced_blobs == 1 and .skipped_current == [$c] and .rewritten_commits > 0 and .pending_reclaim_bytes > 250000 and .reclaim_after == $u' >/dev/null \
  || fail "strip-large output: $OUT"
# strip-large keeps the undo history: the pre-rewrite tip stays in HEAD's reflog.
[[ "$(git -C "$BR" reflog show --format=%H HEAD)" == *"$BR_TIP0"* ]] || fail "strip-large expired the HEAD reflog"
git -C "$BR" cat-file -e "$BR_TIP0" || fail "strip-large removed the pre-rewrite tip"
ok
[[ "$(git -C "$BR" rev-list --all --count)" == "$COUNT0" ]] || fail "commit count changed"
[[ "$(msgs)" == "$MSGS0" ]] || fail "authors, dates or messages changed"
ok
# Only listed blobs replaced: big ones gone from the object store; small file history intact.
# Undo kept: recent reflog entries still reach the blob until they age out.
git -C "$BR" cat-file -e "$OLD" || fail "undo history dropped early (old big blob still in repo)"
age_out "$BR" >/dev/null
if git -C "$BR" cat-file -e "$OLD" 2>/dev/null; then fail "old big blob still in repo (after the undo window)"; fi
git -C "$BR" cat-file -e "$CUR" 2>/dev/null || fail "current big blob (in HEAD) must never be stripped"
[[ -z "$(git -C "$BR" diff --name-only -- media/clip.mov)" ]] || fail "index and working file disagree for a current file"
git -C "$BR" show v1:media/promo.mp4 | grep -q "^git-blob: $OLD$" || fail "v1 promo is not the pointer"
[[ "$(git -C "$BR" show HEAD~3:notes.md)" == "hello" ]] || fail "small file history changed"
[[ "$(git -C "$BR" show side:media/promo.mp4)" == "small now" ]] || fail "side branch content changed"
[[ "$(git -C "$BR" show HEAD:skill/SKILL.md)" == "real" ]] || fail "symlink-to-directory change lost its files"
ok
# Tags re-pointed to the equivalent rewritten commit.
[[ "$(git -C "$BR" log -1 --format=%s 'v1^{commit}')" == "add promo" ]] || fail "v1 not on rewritten 'add promo'"
[[ "$(git -C "$BR" rev-parse 'v1^{commit}')" == "$(git -C "$BR" rev-parse light)" ]] || fail "light and v1 disagree"
git -C "$BR" merge-base --is-ancestor 'v1^{commit}' HEAD || fail "v1 not in rewritten history"
[[ "$(git -C "$BR" cat-file tag v1 | sed '1,/^$/d')" == "$V1_MSG0" ]] || fail "tag message changed"
git -C "$BR" merge-base --is-ancestor "$(git -C "$BR" rev-parse refs/cmux/last-turn/x)" HEAD || fail "extra ref not re-pointed"
[[ "$(git -C "$BR" log -1 --format=%s refs/cmux/last-turn/x)" == "add clip" ]] || fail "extra ref on wrong commit"
ok
# Working tree untouched (big file stays, unstaged edit survives).
[[ "$(cksum <"$BR/media/clip.mov")" == "$WT0" ]] || fail "working tree big file changed"
grep -q "local edit" "$BR/notes.md" || fail "unstaged edit lost"
git -C "$BR" fsck --no-progress >/dev/null 2>&1 || fail "fsck failed after strip"
ok


# ---------------------------------------------------------------- review fixes
# mkrepo <dir>: fresh repo with the test identity.
mkrepo() {
  git init -q -b main "$1"
  git -C "$1" config user.name t; git -C "$1" config user.email t@example.com
  git -C "$1" config commit.gpgsign false; git -C "$1" config tag.gpgsign false
}
# cat <repo> <age-days> <file> <content>
cat_commit() {
  local ts=$(( NOW - $2 * DAY ))
  printf '%s\n' "$4" >"$1/$3"
  git -C "$1" add -- "$3"
  GIT_AUTHOR_DATE="@$ts +0000" GIT_COMMITTER_DATE="@$ts +0000" git -C "$1" commit -q -m "autosave(hq): $3 $2"
}

# C1: prune keeps every stash entry, not only the newest.
SR="$TMP/stash"
mkrepo "$SR"
cat_commit "$SR" 500 a.txt "$(head -c 20000 /dev/urandom | base64)"
cat_commit "$SR" 400 a.txt "a2"
cat_commit "$SR" 10 a.txt "a3"
echo one >>"$SR/a.txt"; git -C "$SR" stash push -q -m first
echo two >>"$SR/a.txt"; git -C "$SR" stash push -q -m second
STASHES0="$(git -C "$SR" stash list --format='%gs %T')"
[[ "$(printf '%s\n' "$STASHES0" | grep -c .)" == 2 ]] || fail "setup: expected two stashes"
SP0="$(git -C "$SR" stash show -p 'stash@{0}')"; SP1="$(git -C "$SR" stash show -p 'stash@{1}')"
"$RUN_BASH" "$SCRIPT" prune --before "$CUT" --yes --force --no-backup --root "$SR" >/dev/null
# Entries are re-pointed onto the new history: same subjects, trees and diffs.
[[ "$(git -C "$SR" stash list --format='%gs %T')" == "$STASHES0" ]] || fail "prune lost stash entries: $(git -C "$SR" stash list)"
[[ "$(git -C "$SR" stash show -p 'stash@{0}')" == "$SP0" && "$(git -C "$SR" stash show -p 'stash@{1}')" == "$SP1" ]] || fail "stash diffs changed"
git -C "$SR" stash show -p 'stash@{1}' | grep -q '^+one' || fail "older stash entry unreadable after prune"
git -C "$SR" fsck --no-progress >/dev/null 2>&1 || fail "fsck failed after prune with stashes"
ok

# Prune keeps message bytes exactly (no newline added) and builds commits in
# one batch: a message without a trailing newline round-trips unchanged.
MR="$TMP/msg"
mkrepo "$MR"
cat_commit "$MR" 500 a.txt "$(head -c 20000 /dev/urandom | base64)"
cat_commit "$MR" 400 a.txt "a2"
printf 'x\n' >"$MR/b.txt"; git -C "$MR" add b.txt
ts=$(( NOW - 10 * DAY ))
printf 'no newline at end' | GIT_AUTHOR_DATE="@$ts +0000" GIT_COMMITTER_DATE="@$ts +0000" git -C "$MR" commit -q --cleanup=verbatim -F -
BODY0="$(git -C "$MR" cat-file commit HEAD | sed '/^parent /d' | od -c)"
"$RUN_BASH" "$SCRIPT" prune --before "$CUT" --yes --no-backup --root "$MR" >/dev/null
[[ "$(git -C "$MR" cat-file commit HEAD | sed '/^parent /d' | od -c)" == "$BODY0" ]] || fail "prune changed message bytes"
[[ "$(git -C "$MR" cat-file commit HEAD | tail -c 1 | od -An -c | tr -d ' ')" == "d" ]] || fail "prune added a trailing newline"
ok

# F2: by default prune keeps a backup of every ref; the old history stays
# until drop-backups (or a run after the grace period) and can be restored.
BK="$TMP/backup"
mkrepo "$BK"
BIGB="$(head -c 20000 /dev/urandom | base64)"
cat_commit "$BK" 500 big.txt "$BIGB"
cat_commit "$BK" 400 big.txt "small"
cat_commit "$BK" 10 a.txt "new"
OLD_TIP="$(git -C "$BK" rev-parse HEAD)"
BIGB_ID="$(printf '%s\n' "$BIGB" | git -C "$BK" hash-object --stdin)"
OUT="$("$RUN_BASH" "$SCRIPT" prune --before "$CUT" --yes --root "$BK")"
BREF="$(echo "$OUT" | jq -r .backup_ref)"
[[ "$BREF" == refs/hq-storage/backup/* ]] || fail "backup_ref missing: $OUT"
# Space is freed when both the 24 h backup and the 30-day undo window end.
[[ "$(echo "$OUT" | jq -r .reclaim_after)" == "$UNDO_AFTER" ]] || fail "reclaim_after: $OUT"
[[ "$(git -C "$BK" rev-parse "$BREF/heads/main")" == "$OLD_TIP" ]] || fail "backup does not hold the old tip"
git -C "$BK" cat-file -e "$BIGB_ID" || fail "old blob gone before the grace period"
R3="$("$RUN_BASH" "$SCRIPT" report --json --no-cache --root "$BK")"
[[ "$(echo "$R3" | jq -r .extra_refs)" == 0 ]] || fail "backup refs counted as extra refs: $R3"
# A run inside the grace period keeps the backup.
D="$("$RUN_BASH" "$SCRIPT" drop-backups --expired --root "$BK")"
[[ "$(echo "$D" | jq -r .dropped_backups)" == 0 ]] || fail "backup dropped inside grace: $D"
# After the grace period it is dropped and gc frees the old blob.
D="$(HQ_STORAGE_NOW=$((NOW + 24*3600)) "$RUN_BASH" "$SCRIPT" drop-backups --expired --json --root "$BK")"
[[ "$(echo "$D" | jq -r .dropped_backups)" == 1 ]] || fail "expired backup not dropped: $D"
[[ -z "$(git -C "$BK" for-each-ref refs/hq-storage)" ]] || fail "backup refs left behind"
# Undo kept: recent reflog entries still reach the blob until they age out.
git -C "$BK" cat-file -e "$BIGB_ID" || fail "undo history dropped early (old blob still present after backup drop)"
age_out "$BK" >/dev/null
if git -C "$BK" cat-file -e "$BIGB_ID" 2>/dev/null; then fail "old blob still present after backup drop (after the undo window)"; fi
ok

# C3: report tranches use the same keep-set as prune: a branch forked from
# HEAD holds all old history, so nothing is promised and the branch is named.
HR="$TMP/holding"
mkrepo "$HR"
cat_commit "$HR" 500 big.txt "$(head -c 20000 /dev/urandom | base64)"
cat_commit "$HR" 400 big.txt "small"
cat_commit "$HR" 10 a.txt "new"
R4="$("$RUN_BASH" "$SCRIPT" report --json --no-cache --root "$HR")"
[[ "$(echo "$R4" | jq '.tranches[4].est_bytes')" -gt 10000 ]] || fail "older tranche should be reclaimable: $R4"
[[ "$(echo "$R4" | jq '.holding_refs_count')" == 0 ]] || fail "no holding refs expected: $R4"
git -C "$HR" branch claude/x HEAD
R4="$("$RUN_BASH" "$SCRIPT" report --json --no-cache --root "$HR")"
echo "$R4" | jq -e '([.tranches[].est_bytes] | add) == 0 and .holding_refs_count == 1 and .holding_refs[0].name == "refs/heads/claude/x"' >/dev/null || fail "branch holding history not reflected: $R4"
D="$("$RUN_BASH" "$SCRIPT" prune --before "$CUT" --dry-run --json --root "$HR")"
echo "$D" | jq -e '.est_bytes == 0 and .holding_refs_count == 1' >/dev/null || fail "prune dry-run holding: $D"
ok

# Report cache: keyed on time, not HEAD; reused within the TTL, rebuilt after.
"$RUN_BASH" "$SCRIPT" report --json --root "$HR" >/dev/null
cat_commit "$HR" 0 c.txt "c"
[[ "$("$RUN_BASH" "$SCRIPT" report --json --root "$HR" | jq .commit_count)" == 3 ]] || fail "cache not reused within TTL"
[[ "$(HQ_STORAGE_NOW=$((NOW + 601)) "$RUN_BASH" "$SCRIPT" report --json --root "$HR" | jq .commit_count)" == 4 ]] || fail "cache not rebuilt after TTL"
ok

# Linked worktree: prune refuses when the branch is checked out elsewhere.
git -C "$HR" branch -q -D claude/x
git -C "$HR" worktree add -q --force "$TMP/hr-wt" main 2>/dev/null
if "$RUN_BASH" "$SCRIPT" prune --before "$CUT" --yes --force --root "$HR" 2>/dev/null; then fail "prune ran with branch checked out in another worktree"; fi
git -C "$HR" worktree remove --force "$TMP/hr-wt"
ok

# F1: strip-large rejects a pointer that does not match its blob, and with a
# backup (default) keeps the old blob until drop-backups.
SL="$TMP/strip2"
mkrepo "$SL"
head -c 150000 /dev/urandom >"$TMP/s2.bin"
cp "$TMP/s2.bin" "$SL/v.bin"; git -C "$SL" add v.bin; git -C "$SL" commit -q -m "add v"
printf 'x\n' >"$SL/v.bin"; git -C "$SL" add v.bin; git -C "$SL" commit -q -m "shrink v"
S2="$(git -C "$SL" hash-object "$TMP/s2.bin")"
SNAP2="$(git -C "$SL" for-each-ref --format='%(refname) %(objectname)')"
badman() { jq -n --arg s "$S2" --arg p "$1" '{blobs: [{sha: $s, pointer_text: $p}]}' >"$TMP/bad.json"; }
for bad in \
  "$(printf 'NOT-A-POINTER\nsize: 150000\ngit-blob: %s\n' "$S2")" \
  "$(printf 'HQ-CLOUD-FILE v1\nsize: 150000\ngit-blob: %s\n' "$OLD")" \
  "$(printf 'HQ-CLOUD-FILE v1\nsize: 149999\ngit-blob: %s\n' "$S2")" \
  "$(printf 'HQ-CLOUD-FILE v1\ngit-blob: %s\n' "$S2")"; do
  badman "$bad"
  if "$RUN_BASH" "$SCRIPT" strip-large --manifest "$TMP/bad.json" --yes --root "$SL" 2>/dev/null; then fail "bad pointer accepted: $bad"; fi
  if "$RUN_BASH" "$SCRIPT" strip-large --manifest "$TMP/bad.json" --dry-run --root "$SL" 2>/dev/null; then fail "bad pointer accepted in dry run: $bad"; fi
done
[[ "$(git -C "$SL" for-each-ref --format='%(refname) %(objectname)')" == "$SNAP2" ]] || fail "rejected manifest changed refs"
git -C "$SL" cat-file -e "$S2" || fail "rejected manifest removed the blob"
ok

# Linked worktree with a branch whose history holds a listed blob: refuse.
git -C "$SL" branch side HEAD~1
git -C "$SL" worktree add -q "$TMP/sl-wt" side
badman "$(pointer "$S2" 150000)"
# While the linked worktree's index holds the blob, it is skipped as current.
OUT="$("$RUN_BASH" "$SCRIPT" strip-large --manifest "$TMP/bad.json" --dry-run --root "$SL")"
echo "$OUT" | jq -e --arg s "$S2" '.present_blobs == 0 and .skipped_current == [$s]' >/dev/null || fail "linked worktree index blob not skipped: $OUT"
printf 'y\n' >"$TMP/sl-wt/v.bin"; git -C "$TMP/sl-wt" commit -qam "side edit"
SL_HEAD="$(git -C "$SL" rev-parse HEAD)"
RC=0; OUT="$("$RUN_BASH" "$SCRIPT" strip-large --manifest "$TMP/bad.json" --yes --root "$SL" 2>"$TMP/sl.err")" || RC=$?
[[ "$RC" == 4 ]] || fail "strip-large with a holding branch in another worktree: rc $RC $(cat "$TMP/sl.err")"
echo "$OUT" | jq -e --arg s "$S2" '.refused == "nothing_to_free" and .held_by_worktrees == [$s] and .worktree_holders[0].branch == "side" and (.message | test("worktree"))' >/dev/null \
  || fail "worktree refusal JSON: $OUT"
[[ "$(git -C "$SL" rev-parse HEAD)" == "$SL_HEAD" && "$(git -C "$TMP/sl-wt" rev-parse HEAD)" != "" ]] || fail "worktree refusal changed refs"
git -C "$SL" worktree remove --force "$TMP/sl-wt"
git -C "$SL" branch -q -D side
ok

OUT="$("$RUN_BASH" "$SCRIPT" strip-large --manifest "$TMP/bad.json" --yes --json --root "$SL")"
echo "$OUT" | jq -e '.replaced_blobs == 1 and (.backup_ref | startswith("refs/hq-storage/backup/")) and (.reclaim_after | test("Z$"))' >/dev/null || fail "strip-large backup output: $OUT"
git -C "$SL" show HEAD~1:v.bin | grep -q "^git-blob: $S2$" || fail "pointer not written"
git -C "$SL" cat-file -e "$S2" || fail "blob removed before the grace period"
D="$("$RUN_BASH" "$SCRIPT" drop-backups --root "$SL")"
[[ "$(echo "$D" | jq -r .dropped_backups)" == 1 ]] || fail "drop-backups: $D"
# Undo kept: recent reflog entries still reach the blob until they age out.
git -C "$SL" cat-file -e "$S2" || fail "undo history dropped early (blob still present after drop-backups)"
age_out "$SL" >/dev/null
if git -C "$SL" cat-file -e "$S2" 2>/dev/null; then fail "blob still present after drop-backups (after the undo window)"; fi
git -C "$SL" fsck --no-progress >/dev/null 2>&1 || fail "fsck failed after drop-backups"
ok

# large: paths with a newline are reported intact; a clear error without jq.
NL="$TMP/nl"
mkrepo "$NL"
head -c 150000 /dev/urandom >"$NL/$(printf 'a\nb.bin')"
git -C "$NL" add -A; git -C "$NL" commit -q -m "nl"
L="$("$RUN_BASH" "$SCRIPT" large --json --min-bytes 100000 --root "$NL")"
echo "$L" | jq -e '.history.blobs[0].paths == ["a\nb.bin"] and .current.files[0].path == "a\nb.bin"' >/dev/null || fail "newline path: $L"
NOJQ="$TMP/nojq"; mkdir -p "$NOJQ"
for t in git awk sed sort mktemp dirname perl date cat grep; do ln -sf "$(command -v "$t")" "$NOJQ/$t"; done
set +e; ERR="$(PATH="$NOJQ" "$RUN_BASH" "$SCRIPT" large --json --root "$NL" 2>&1)"; RC=$?; set -e
[[ "$RC" == 2 ]] && echo "$ERR" | grep -q 'jq is required' || fail "large without jq: rc=$RC $ERR"
ok

# N2: a normal stash on main neither blocks prune nor keeps old history alive.
# Prune frees the old blob without --force, and every stash still applies.
NS="$TMP/nstash"
mkrepo "$NS"
NSBIG="$(head -c 20000 /dev/urandom | base64)"
cat_commit "$NS" 500 big.txt "$NSBIG"
NSBIG_ID="$(git -C "$NS" rev-parse HEAD:big.txt)"
cat_commit "$NS" 400 big.txt "small"
cat_commit "$NS" 300 a.txt "a1"
echo old-stash >>"$NS/a.txt"; git -C "$NS" stash push -q -m "pre-cutoff stash"
cat_commit "$NS" 10 a.txt "a3"
echo new-stash >>"$NS/a.txt"; echo untracked >"$NS/u.txt"; git -C "$NS" stash push -q -u -m "recent stash"
SUBJ0="$(git -C "$NS" stash list --format='%gs')"
D="$("$RUN_BASH" "$SCRIPT" prune --before "$CUT" --dry-run --root "$NS")"
echo "$D" | jq -e '.est_bytes > 10000 and .holding_refs_count == 0' >/dev/null || fail "stash still holds history: $D"
OUT="$("$RUN_BASH" "$SCRIPT" prune --before "$CUT" --yes --no-backup --root "$NS")" || fail "prune refused with a normal stash"
# Undo kept: recent reflog entries still reach the blob until they age out.
git -C "$NS" cat-file -e "$NSBIG_ID" || fail "undo history dropped early (stash kept the pruned blob alive)"
age_out "$NS" >/dev/null
if git -C "$NS" cat-file -e "$NSBIG_ID" 2>/dev/null; then fail "stash kept the pruned blob alive (after the undo window)"; fi
[[ "$(git -C "$NS" stash list --format='%gs')" == "$SUBJ0" ]] || fail "stash entries changed: $(git -C "$NS" stash list)"
if git -C "$NS" stash list | grep -q fast-import; then fail "extra stash entry"; fi
git -C "$NS" merge-base --is-ancestor "$(git -C "$NS" rev-parse 'stash@{1}^1')" HEAD || fail "old stash base not on new history"
[[ "$(git -C "$NS" rev-list --count 'stash@{0}^1')" == "$(git -C "$NS" rev-list --count HEAD)" ]] || fail "recent stash base not the rewritten tip"
git -C "$NS" fsck --no-progress >/dev/null 2>&1 || fail "fsck failed after prune with stash"
git -C "$NS" checkout -q -- .
git -C "$NS" stash apply -q 'stash@{0}' && grep -q new-stash "$NS/a.txt" && [[ -f "$NS/u.txt" ]] || fail "recent stash does not apply"
git -C "$NS" checkout -q -- . && rm -f "$NS/u.txt"
# The pre-cutoff stash applies cleanly onto its (rewritten) base.
git -C "$NS" checkout -q --detach 'stash@{1}^1'
git -C "$NS" stash apply -q 'stash@{1}' && grep -q old-stash "$NS/a.txt" || fail "pre-cutoff stash does not apply"
git -C "$NS" reset -q --hard && git -C "$NS" checkout -q main
ok

# N7 + N1: during the grace period report shows the backup's bytes as pending
# (not as reclaimable tranches); drop-backups --expired is cheap and skips
# while locked; reclaim drops the expired backup and frees the space.
PR="$TMP/pending"
mkrepo "$PR"
cat_commit "$PR" 500 big.txt "$(head -c 20000 /dev/urandom | base64)"
PRBIG_ID="$(git -C "$PR" rev-parse HEAD:big.txt)"
cat_commit "$PR" 400 big.txt "small"
cat_commit "$PR" 10 a.txt "new"
R5="$("$RUN_BASH" "$SCRIPT" report --json --no-cache --root "$PR")"
echo "$R5" | jq -e '.pending_reclaim_bytes == 0 and .reclaim_after == null' >/dev/null || fail "pending without backups: $R5"
OUT="$("$RUN_BASH" "$SCRIPT" prune --before "$CUT" --yes --root "$PR")"
R5="$("$RUN_BASH" "$SCRIPT" report --json --no-cache --root "$PR")"
echo "$R5" | jq -e --argjson o "$OUT" '.pending_reclaim_bytes > 10000 and .reclaim_after == $o.reclaim_after and ([.tranches[].est_bytes] | add) < 10000' >/dev/null \
  || fail "report during grace: $R5"
D="$("$RUN_BASH" "$SCRIPT" drop-backups --expired --root "$PR")"
echo "$D" | jq -e '.dropped == 0 and .freed_bytes == 0' >/dev/null || fail "drop-backups --expired inside grace: $D"
mkdir "$TMPDIR/hq-autocommit.lock"
D="$(HQ_STORAGE_NOW=$((NOW + 25*3600)) "$RUN_BASH" "$SCRIPT" drop-backups --expired --root "$PR")" || fail "drop-backups --expired failed while locked"
rmdir "$TMPDIR/hq-autocommit.lock"
echo "$D" | jq -e '.dropped == 0 and .skipped == "locked"' >/dev/null || fail "locked drop-backups: $D"
git -C "$PR" cat-file -e "$PRBIG_ID" || fail "blob gone while locked"
C="$(HQ_STORAGE_NOW=$((NOW + 25*3600)) "$RUN_BASH" "$SCRIPT" reclaim --json --root "$PR")"
echo "$C" | jq -e '.dropped == 1' >/dev/null || fail "reclaim: $C"
# Undo kept: recent reflog entries still reach the blob, and report still
# counts it as pending with the undo date.
git -C "$PR" cat-file -e "$PRBIG_ID" || fail "undo history dropped early (reclaim left the pruned blob)"
R5="$(HQ_STORAGE_NOW=$((NOW + 25*3600)) "$RUN_BASH" "$SCRIPT" report --json --no-cache --root "$PR")"
echo "$R5" | jq -e --arg u "$UNDO_AFTER" '.pending_reclaim_bytes > 10000 and .reclaim_after == $u' >/dev/null || fail "pending after backup reclaim: $R5"
# Idempotent: nothing left to drop, nothing freed inside the window.
D="$(HQ_STORAGE_NOW=$((NOW + 25*3600)) "$RUN_BASH" "$SCRIPT" drop-backups --expired --root "$PR")"
echo "$D" | jq -e '.dropped == 0 and .freed_bytes == 0' >/dev/null || fail "second drop-backups: $D"
C="$(HQ_STORAGE_NOW=$((NOW + 25*3600)) "$RUN_BASH" "$SCRIPT" reclaim --root "$PR")"
echo "$C" | jq -e '.dropped == 0 and .freed_bytes == 0' >/dev/null || fail "second reclaim: $C"
# After the window: drop-backups --expired alone frees it (no lock held).
D="$(HQ_STORAGE_NOW=$((NOW + 31*DAY)) GIT_CONFIG_COUNT=2 GIT_CONFIG_KEY_0=gc.reflogExpire GIT_CONFIG_VALUE_0=now \
  GIT_CONFIG_KEY_1=gc.reflogExpireUnreachable GIT_CONFIG_VALUE_1=now "$RUN_BASH" "$SCRIPT" drop-backups --expired --root "$PR")"
echo "$D" | jq -e '.freed_bytes > 0' >/dev/null || fail "drop-backups after the undo window: $D"
if git -C "$PR" cat-file -e "$PRBIG_ID" 2>/dev/null; then fail "reclaim left the pruned blob (after the undo window)"; fi
R5="$(HQ_STORAGE_NOW=$((NOW + 31*DAY)) "$RUN_BASH" "$SCRIPT" report --json --no-cache --root "$PR")"
echo "$R5" | jq -e '.pending_reclaim_bytes == 0 and .reclaim_after == null' >/dev/null || fail "pending after the undo window: $R5"
ok

# N4: a linked worktree's HEAD reflog keeps pruned commits only until its
# entries age past the undo window; after that they are freed.
WR="$TMP/wtreflog"
mkrepo "$WR"
cat_commit "$WR" 500 big.txt "$(head -c 20000 /dev/urandom | base64)"
WRBIG_ID="$(git -C "$WR" rev-parse HEAD:big.txt)"
WROLD="$(git -C "$WR" rev-parse HEAD)"
cat_commit "$WR" 400 big.txt "small"
cat_commit "$WR" 10 a.txt "new"
git -C "$WR" worktree add -q --detach "$TMP/wr-wt" "$WROLD"
git -C "$TMP/wr-wt" checkout -q --orphan wt-side
git -C "$TMP/wr-wt" rm -rqf .
echo side >"$TMP/wr-wt/side.txt"; git -C "$TMP/wr-wt" add side.txt
git -C "$TMP/wr-wt" -c user.name=t -c user.email=t@example.com commit -q -m side
grep -q "$WROLD" "$WR/.git/worktrees/wr-wt/logs/HEAD" || fail "setup: worktree HEAD reflog does not hold the old commit"
"$RUN_BASH" "$SCRIPT" prune --before "$CUT" --yes --no-backup --root "$WR" >/dev/null
# Undo kept: recent reflog entries still reach the blob until they age out.
git -C "$WR" cat-file -e "$WRBIG_ID" || fail "undo history dropped early (linked worktree HEAD reflog kept the pruned blob)"
age_out "$WR" >/dev/null
if git -C "$WR" cat-file -e "$WRBIG_ID" 2>/dev/null; then fail "linked worktree HEAD reflog kept the pruned blob (after the undo window)"; fi
git -C "$WR" fsck --no-progress >/dev/null 2>&1 || fail "fsck failed after prune with a linked worktree"
git -C "$WR" worktree remove --force "$TMP/wr-wt"
ok

# N3: strip-large rewrites the stash reflog in place: no extra entry, no old
# entry keeps the big blob alive, and both stashes still apply.
SS="$TMP/stripstash"
mkrepo "$SS"
head -c 300000 /dev/urandom >"$SS/big.bin"; git -C "$SS" add big.bin
GIT_COMMITTER_DATE="@$(( NOW - 100*DAY )) +0000" git -C "$SS" commit -q -m "big"
SSBIG="$(git -C "$SS" rev-parse HEAD:big.bin)"
echo one >"$SS/n.txt"; git -C "$SS" add n.txt; git -C "$SS" commit -q -m "n"
echo s1 >>"$SS/n.txt"; git -C "$SS" stash push -q -m "first"
git -C "$SS" rm -q big.bin; git -C "$SS" commit -q -m "drop big"
echo s2 >>"$SS/n.txt"; git -C "$SS" stash push -q -m "second"
SUBJ0="$(git -C "$SS" stash list --format='%gs')"
cat >"$TMP/ss-man.json" <<EOF
{"blobs":[{"sha":"$SSBIG","pointer_text":$(printf 'HQ-CLOUD-FILE v1
git-blob: %s
size: 300000
' "$SSBIG" | jq -Rs .)}]}
EOF
OUT="$("$RUN_BASH" "$SCRIPT" strip-large --manifest "$TMP/ss-man.json" --yes --no-backup --root "$SS")"
echo "$OUT" | jq -e '.replaced_blobs == 1' >/dev/null || fail "strip with stash: $OUT"
[[ "$(git -C "$SS" stash list --format='%gs')" == "$SUBJ0" ]] || fail "stash list changed: $(git -C "$SS" stash list --format='%gs')"
# Undo kept: recent reflog entries still reach the blob until they age out.
git -C "$SS" cat-file -e "$SSBIG" || fail "undo history dropped early (stash reflog kept the big blob alive)"
age_out "$SS" >/dev/null
if git -C "$SS" cat-file -e "$SSBIG" 2>/dev/null; then fail "stash reflog kept the big blob alive (after the undo window)"; fi
[[ -z "$(git -C "$SS" for-each-ref refs/hq-storage-stash)" ]] || fail "temporary stash refs left behind"
git -C "$SS" fsck --no-progress >/dev/null 2>&1 || fail "fsck failed after strip-large with stashes"
git -C "$SS" stash apply -q 'stash@{0}' && grep -q s2 "$SS/n.txt" || fail "newest stash does not apply"
git -C "$SS" checkout -q -- .
git -C "$SS" stash show -p 'stash@{1}' | grep -q '^+s1' || fail "older stash unreadable"
ok

# large caches its history part (status calls it twice); --no-cache and
# strip-large / reclaim bypass or clear it. Current files are always live.
LC="$TMP/largecache"
mkrepo "$LC"
head -c 150000 /dev/urandom >"$LC/one.bin"; git -C "$LC" add one.bin; git -C "$LC" commit -q -m one
[[ "$("$RUN_BASH" "$SCRIPT" large --json --min-bytes 100000 --root "$LC" | jq .history.count)" == 1 ]] || fail "large first run"
ls "$LC"/workspace/.storage-cache/large-100000-*.json >/dev/null 2>&1 || fail "large cache not written"
head -c 150000 /dev/urandom >"$LC/two.bin"; git -C "$LC" add two.bin; git -C "$LC" commit -q -m two
L="$("$RUN_BASH" "$SCRIPT" large --json --min-bytes 100000 --root "$LC")"
echo "$L" | jq -e '.history.count == 1 and .current.count == 2' >/dev/null || fail "large cache not reused (history) or current not live: $L"
[[ "$("$RUN_BASH" "$SCRIPT" large --json --min-bytes 100000 --no-cache --root "$LC" | jq .history.count)" == 2 ]] || fail "large --no-cache"
[[ "$(HQ_STORAGE_NOW=$((NOW + 601)) "$RUN_BASH" "$SCRIPT" large --json --min-bytes 100000 --root "$LC" | jq .history.count)" == 2 ]] || fail "large cache not rebuilt after TTL"
"$RUN_BASH" "$SCRIPT" reclaim --root "$LC" >/dev/null
if ls "$LC"/workspace/.storage-cache/large-*.json >/dev/null 2>&1; then fail "reclaim did not clear the large cache"; fi
ok

# B1: report (status), reclaim with no backups, and reclaim after dropping an
# expired backup never expire reflogs, so commits reachable only from a reflog
# survive: one reset away in the main checkout, and one made on a detached HEAD
# in a linked worktree that was then checked away from.
RL="$TMP/reflogkeep"
mkrepo "$RL"
cat_commit "$RL" 500 big.txt "$(head -c 20000 /dev/urandom | base64)"
cat_commit "$RL" 400 big.txt "small"
cat_commit "$RL" 10 a.txt "base"
cat_commit "$RL" 5 a.txt "reset-away"
RESET_AWAY="$(git -C "$RL" rev-parse HEAD)"
git -C "$RL" reset -q --hard HEAD~1
git -C "$RL" worktree add -q --detach "$TMP/reflogkeep-wt" HEAD
# The worktree then rests on an unrelated commit, so it does not hold HQ's
# history (a worktree HEAD on that history would make prune refuse; see the
# worktree-holder tests).
WT_HOME="$(git -C "$RL" commit-tree "$(git -C "$RL" mktree </dev/null)" -m home)"
printf 'detached\n' >"$TMP/reflogkeep-wt/d.txt"
git -C "$TMP/reflogkeep-wt" add d.txt
git -C "$TMP/reflogkeep-wt" commit -q -m detached
DETACHED="$(git -C "$TMP/reflogkeep-wt" rev-parse HEAD)"
git -C "$TMP/reflogkeep-wt" checkout -q --detach "$WT_HOME"
# reflog_kept <label>: both commits still exist and are still in their reflogs.
reflog_kept() {
  [[ "$(git -C "$RL" cat-file -t "$RESET_AWAY" 2>/dev/null)" == commit ]] || fail "$1: reset-away commit lost"
  [[ "$(git -C "$TMP/reflogkeep-wt" cat-file -t "$DETACHED" 2>/dev/null)" == commit ]] || fail "$1: detached worktree commit lost"
  [[ "$(git -C "$RL" reflog show --format=%H HEAD)" == *"$RESET_AWAY"* ]] || fail "$1: HEAD reflog entry for reset-away commit lost"
  [[ "$(git -C "$TMP/reflogkeep-wt" reflog show --format=%H HEAD)" == *"$DETACHED"* ]] || fail "$1: worktree HEAD reflog entry lost"
  git -C "$RL" fsck --no-progress >/dev/null 2>&1 || fail "$1: fsck failed"
}
"$RUN_BASH" "$SCRIPT" report --json --no-cache --root "$RL" >/dev/null
reflog_kept "report"
C="$("$RUN_BASH" "$SCRIPT" reclaim --json --root "$RL")"
echo "$C" | jq -e '.dropped == 0 and .freed_bytes == 0' >/dev/null || fail "reclaim with no backups did work: $C"
reflog_kept "reclaim with no backups"
# Not-yet-expired backup: reclaim still does nothing.
OUT="$("$RUN_BASH" "$SCRIPT" prune --before "$CUT" --yes --root "$RL")"
# prune keeps the undo history too: both reflog-only commits survive it.
reflog_kept "prune"
# Fresh reflog-only commits for the reclaim checks below.
cat_commit "$RL" 4 a.txt "reset-away-2"
RESET_AWAY="$(git -C "$RL" rev-parse HEAD)"
git -C "$RL" reset -q --hard HEAD~1
git -C "$TMP/reflogkeep-wt" checkout -q --detach "$WT_HOME"
printf 'detached2\n' >"$TMP/reflogkeep-wt/d.txt"
git -C "$TMP/reflogkeep-wt" add d.txt
git -C "$TMP/reflogkeep-wt" commit -q -m detached2
DETACHED="$(git -C "$TMP/reflogkeep-wt" rev-parse HEAD)"
git -C "$TMP/reflogkeep-wt" checkout -q --detach "$WT_HOME"
C="$("$RUN_BASH" "$SCRIPT" reclaim --json --root "$RL")"
echo "$C" | jq -e '.dropped == 0' >/dev/null || fail "reclaim dropped a backup inside grace: $C"
reflog_kept "reclaim inside grace"
C="$(HQ_STORAGE_NOW=$((NOW + 25*3600)) "$RUN_BASH" "$SCRIPT" reclaim --json --root "$RL")"
echo "$C" | jq -e '.dropped == 1 and .freed_bytes > 0' >/dev/null || fail "reclaim after expiry: $C"
reflog_kept "reclaim after expired backup drop"
"$RUN_BASH" "$SCRIPT" report --json --no-cache --root "$RL" >/dev/null
reflog_kept "report after reclaim"
ok

# reclaim with no expired backup takes no lock and never runs gc: it succeeds
# while the autosave lock is held and leaves loose objects alone.
LK="$TMP/reclaimlock"
mkrepo "$LK"
cat_commit "$LK" 1 a.txt "x"
LOOSE0="$(git -C "$LK" count-objects | awk '{print $1}')"
mkdir "$TMPDIR/hq-autocommit.lock"
C="$("$RUN_BASH" "$SCRIPT" reclaim --json --root "$LK")" || fail "reclaim with no backups blocked on the lock"
rmdir "$TMPDIR/hq-autocommit.lock"
echo "$C" | jq -e '.dropped == 0' >/dev/null || fail "reclaim no-op output: $C"
[[ "$(git -C "$LK" count-objects | awk '{print $1}')" == "$LOOSE0" ]] || fail "reclaim with no backups ran gc"
ok

# stash_write: a failure partway through rebuilding the stash list restores
# the old list, and no entry is ever left unreferenced.
SA="$TMP/stashatomic"
mkrepo "$SA"
cat_commit "$SA" 500 big.txt "$(head -c 20000 /dev/urandom | base64)"
cat_commit "$SA" 400 big.txt "small"
cat_commit "$SA" 10 a.txt "base"
echo one >>"$SA/a.txt"; git -C "$SA" stash push -q -m first
echo two >>"$SA/a.txt"; git -C "$SA" stash push -q -m second
echo three >>"$SA/a.txt"; git -C "$SA" stash push -q -m third
SL0="$(git -C "$SA" stash list --format='%H %gs')"
if HQ_STORAGE_TEST_STASH_FAIL_AT=1 "$RUN_BASH" "$SCRIPT" prune --before "$CUT" --yes --force --no-backup --root "$SA" >"$TMP/sa.out" 2>"$TMP/sa.err"; then
  fail "prune did not report the injected stash failure"
fi
grep -q 'stash list' "$TMP/sa.err" || fail "stash failure message: $(cat "$TMP/sa.err")"
[[ "$(git -C "$SA" stash list --format='%H %gs')" == "$SL0" ]] || fail "stash list not restored after a failed rewrite: $(git -C "$SA" stash list)"
[[ -z "$(git -C "$SA" for-each-ref refs/hq-storage-stash-pin)" ]] || fail "stash pins left after a restore"
git -C "$SA" fsck --no-progress >/dev/null 2>&1 || fail "fsck after a failed stash rewrite"
# Without the failure, the rewrite completes and leaves no pins.
"$RUN_BASH" "$SCRIPT" prune --before "$CUT" --yes --force --no-backup --root "$SA" >/dev/null 2>&1 || true
[[ "$(git -C "$SA" stash list --format='%gs' | tr '\n' ,)" == "On main: third,On main: second,On main: first," ]] || fail "stash subjects after rewrite: $(git -C "$SA" stash list)"
[[ -z "$(git -C "$SA" for-each-ref refs/hq-storage-stash-pin)" ]] || fail "stash pins left after a rewrite"
ok

# E2E-B1: pending_reclaim_bytes counts only objects the backup alone keeps.
# A big file that HEAD still has is shared by the old and the rewritten
# history, so it is not pending.
PE="$TMP/pendingexact"
mkrepo "$PE"
cat_commit "$PE" 500 keep.txt "$(head -c 60000 /dev/urandom | base64)"
cat_commit "$PE" 450 old.txt "$(head -c 20000 /dev/urandom | base64)"
cat_commit "$PE" 400 old.txt "small"
cat_commit "$PE" 10 a.txt "new"
OUT="$("$RUN_BASH" "$SCRIPT" prune --before "$CUT" --yes --root "$PE")"
R6="$("$RUN_BASH" "$SCRIPT" report --json --no-cache --root "$PE")"
echo "$R6" | jq -e '.pending_reclaim_bytes > 10000 and .pending_reclaim_bytes < 40000' >/dev/null \
  || fail "pending counts objects the rewritten history still uses: $(echo "$R6" | jq .pending_reclaim_bytes)"
ok

# E2E-B3 / M2: a failed precondition is a structured refusal (JSON on stdout,
# exit 5) with plain text; dry runs and `check` predict it; nothing changes.
PC="$TMP/precheck"
mkrepo "$PC"
cat_commit "$PC" 500 a.txt "old"
cat_commit "$PC" 450 a.txt "old2"
cat_commit "$PC" 10 a.txt "new"
C="$("$RUN_BASH" "$SCRIPT" check --root "$PC")"
echo "$C" | jq -e '.ok == true' >/dev/null || fail "check on a clean repo: $C"
git -C "$PC" update-ref refs/remotes/origin/main HEAD
PC_HEAD="$(git -C "$PC" rev-parse HEAD)"
C="$("$RUN_BASH" "$SCRIPT" check --for strip-large --root "$PC")"
echo "$C" | jq -e '.ok == false and .refused == "remote_tracking_branches" and (.message | test("Nothing was changed"))' >/dev/null || fail "check refusal: $C"
D="$("$RUN_BASH" "$SCRIPT" prune --before "$CUT" --dry-run --root "$PC")"
echo "$D" | jq -e '.would_refuse.code == "remote_tracking_branches"' >/dev/null || fail "prune dry run does not predict the refusal: $D"
printf '{"blobs":[]}' >"$TMP/pc-manifest.json"
D="$("$RUN_BASH" "$SCRIPT" strip-large --manifest "$TMP/pc-manifest.json" --dry-run --root "$PC")"
echo "$D" | jq -e '.would_refuse.code == "remote_tracking_branches"' >/dev/null || fail "strip-large dry run does not predict the refusal: $D"
RC=0; OUT="$("$RUN_BASH" "$SCRIPT" prune --before "$CUT" --yes --root "$PC" 2>"$TMP/pc.err")" || RC=$?
[[ "$RC" == 5 ]] || fail "precondition refusal exit: $RC"
echo "$OUT" | jq -e '.refused == "remote_tracking_branches"' >/dev/null || fail "precondition refusal JSON: $OUT"
[[ "$(git -C "$PC" rev-parse HEAD)" == "$PC_HEAD" ]] || fail "precondition refusal moved HEAD"
git -C "$PC" update-ref -d refs/remotes/origin/main
D="$("$RUN_BASH" "$SCRIPT" prune --before "$CUT" --dry-run --root "$PC")"
echo "$D" | jq -e '.would_refuse == null' >/dev/null || fail "clean dry run would_refuse: $D"
# M2: the nothing-to-free refusal never tells the user to delete branches.
git -C "$PC" branch keepme HEAD
RC=0; "$RUN_BASH" "$SCRIPT" prune --before "$CUT" --yes --root "$PC" >/dev/null 2>"$TMP/pc.err" || RC=$?
[[ "$RC" == 4 ]] || fail "holding-ref refusal exit: $RC"
if grep -qi 'delete' "$TMP/pc.err"; then fail "refusal suggests deleting: $(cat "$TMP/pc.err")"; fi
grep -q 'Nothing was changed' "$TMP/pc.err" || fail "refusal does not say nothing changed: $(cat "$TMP/pc.err")"
ok

# F1: a linked worktree whose HEAD (detached) is on old history keeps the old
# big files it reaches. large marks them, strip-large leaves them alone, and
# pending counts only what will really be freed; once the undo window passes,
# exactly that is freed and nothing is promised for the held file.
WH="$TMP/wtholder"
mkrepo "$WH"
mkdir -p "$WH/media"
head -c 150000 /dev/urandom >"$WH/media/one.bin"; git -C "$WH" add media; git -C "$WH" commit -q -m one
ONE="$(git -C "$WH" rev-parse HEAD:media/one.bin)"
git -C "$WH" rm -q media/one.bin; git -C "$WH" commit -q -m gone-one
# The worktree's HEAD reaches one.bin through history only (not its index).
git -C "$WH" worktree add -q --detach "$TMP/wtholder-wt" HEAD
mkdir -p "$WH/media"; head -c 150000 /dev/urandom >"$WH/media/two.bin"; git -C "$WH" add media; git -C "$WH" commit -q -m two
TWO="$(git -C "$WH" rev-parse HEAD:media/two.bin)"
git -C "$WH" rm -q media/two.bin; git -C "$WH" commit -q -m gone-two
L="$("$RUN_BASH" "$SCRIPT" large --json --min-bytes 100000 --no-cache --root "$WH")"
echo "$L" | jq -e --arg o "$ONE" --arg t "$TWO" '
  (.history.blobs[] | select(.sha == $o) | .held_by | length) == 1
  and (.history.blobs[] | select(.sha == $t) | .held_by) == []
  and .history.held_count == 1 and .history.held_bytes == 150000
  and (.history.worktree_holders | length) == 1 and .history.worktree_holders[0].branch == null' >/dev/null || fail "large worktree holders: $L"
whman() { # whman <sha>... -> manifest with pointers
  local s
  for s in "$@"; do jq -n --arg s "$s" --arg p "$(printf 'HQ-CLOUD-FILE v1\npath: media/x\nsize: 150000\nsha256: 00\ngit-blob: %s\nvault: personal\n' "$s")" '{sha: $s, pointer_text: $p}'; done \
    | jq -s '{blobs: .}' >"$TMP/wh-man.json"
}
# Only the held file: the dry run predicts the refusal, the real run refuses (exit 4), nothing changes.
whman "$ONE"
D="$("$RUN_BASH" "$SCRIPT" strip-large --manifest "$TMP/wh-man.json" --dry-run --root "$WH")"
echo "$D" | jq -e --arg o "$ONE" '.est_freed_bytes == 0 and .held_by_worktrees == [$o] and .would_refuse.code == "nothing_to_free" and (.would_refuse.worktree_holders | length) == 1' >/dev/null \
  || fail "strip-large dry run with only held files: $D"
WH_HEAD="$(git -C "$WH" rev-parse HEAD)"
RC=0; OUT="$("$RUN_BASH" "$SCRIPT" strip-large --manifest "$TMP/wh-man.json" --yes --no-backup --root "$WH" 2>"$TMP/wh.err")" || RC=$?
[[ "$RC" == 4 ]] || fail "strip-large with only held files: rc $RC"
echo "$OUT" | jq -e '.refused == "nothing_to_free"' >/dev/null || fail "held refusal JSON: $OUT"
if grep -q 'refs/' "$TMP/wh.err"; then fail "held refusal text shows raw refs: $(cat "$TMP/wh.err")"; fi
[[ "$(git -C "$WH" rev-parse HEAD)" == "$WH_HEAD" ]] || fail "held refusal changed history"
# Both files: only the free one is replaced, and pending is about its size, not both.
whman "$ONE" "$TWO"
D="$("$RUN_BASH" "$SCRIPT" strip-large --manifest "$TMP/wh-man.json" --dry-run --root "$WH")"
echo "$D" | jq -e --arg o "$ONE" '.present_blobs == 1 and .held_by_worktrees == [$o] and .would_refuse == null' >/dev/null || fail "strip-large partial dry run: $D"
OUT="$("$RUN_BASH" "$SCRIPT" strip-large --manifest "$TMP/wh-man.json" --yes --no-backup --root "$WH")"
echo "$OUT" | jq -e --arg o "$ONE" '.replaced_blobs == 1 and .held_by_worktrees == [$o] and .pending_reclaim_bytes > 140000 and .pending_reclaim_bytes < 200000' >/dev/null \
  || fail "strip-large partial: $OUT"
R="$("$RUN_BASH" "$SCRIPT" report --json --no-cache --root "$WH")"
echo "$R" | jq -e '.pending_reclaim_bytes > 140000 and .pending_reclaim_bytes < 200000' >/dev/null || fail "report pending with a worktree holder: $(echo "$R" | jq .pending_reclaim_bytes)"
[[ "$(git -C "$TMP/wtholder-wt" rev-parse HEAD)" != "$(git -C "$WH" rev-parse HEAD)" ]] || fail "worktree moved"
C="$(age_out "$WH")"
echo "$C" | jq -e '.freed_bytes > 100000' >/dev/null || fail "aged reclaim with a worktree holder: $C"
if git -C "$WH" cat-file -e "$TWO" 2>/dev/null; then fail "free file not freed after the undo window"; fi
git -C "$WH" cat-file -e "$ONE" || fail "file the worktree uses was removed"
R="$(HQ_STORAGE_NOW=$((NOW + 31*DAY)) "$RUN_BASH" "$SCRIPT" report --json --no-cache --root "$WH")"
echo "$R" | jq -e '.pending_reclaim_bytes == 0' >/dev/null || fail "pending after the undo window: $R"
ok

# Prune: a detached worktree on old history is a holder (named readably), the
# dry run predicts the exit-4 refusal, and no freed-by date is promised.
PW="$TMP/prunewt"
mkrepo "$PW"
cat_commit "$PW" 500 big.txt "$(head -c 20000 /dev/urandom | base64)"
cat_commit "$PW" 450 big.txt "small"
cat_commit "$PW" 400 a.txt "x"
git -C "$PW" worktree add -q --detach "$TMP/prunewt-wt" HEAD
cat_commit "$PW" 10 a.txt "new"
D="$("$RUN_BASH" "$SCRIPT" prune --before "$CUT" --dry-run --root "$PW")"
echo "$D" | jq -e '.est_bytes == 0 and .would_refuse.code == "nothing_to_free" and (.would_refuse.holding_refs | map(.name) | any(startswith("worktree:")))
  and (.would_refuse.message | test("worktree")) and (.would_refuse.message | test("refs/") | not)' >/dev/null || fail "prune dry run with a worktree holder: $D"
RC=0; "$RUN_BASH" "$SCRIPT" prune --before "$CUT" --yes --root "$PW" >/dev/null 2>"$TMP/pw.err" || RC=$?
[[ "$RC" == 4 ]] || fail "prune with a worktree holder: rc $RC $(cat "$TMP/pw.err")"
grep -q 'worktree ' "$TMP/pw.err" || fail "prune refusal does not name the worktree: $(cat "$TMP/pw.err")"
git -C "$PW" worktree remove --force "$TMP/prunewt-wt"
# A tag holder: same would_refuse prediction.
git -C "$PW" tag keep HEAD~1
D="$("$RUN_BASH" "$SCRIPT" prune --before "$CUT" --dry-run --root "$PW")"
echo "$D" | jq -e '.would_refuse.code == "nothing_to_free" and (.would_refuse.message | test("tag keep"))' >/dev/null || fail "prune dry run with a tag holder: $D"
git -C "$PW" tag -d keep >/dev/null
D="$("$RUN_BASH" "$SCRIPT" prune --before "$CUT" --dry-run --root "$PW")"
echo "$D" | jq -e '.would_refuse == null and .est_bytes > 0' >/dev/null || fail "prune dry run without holders: $D"
ok

# C2: the empty-array path (no --signed-commits on this git) under bash 3.2.
if [[ "$RUN_BASH" == /bin/bash ]]; then
  if git fast-export -h 2>&1 | grep -q -e '--signed-commits'; then
    echo "note: this git has --signed-commits; the empty-array path ran only via the linter check"
  fi
  ok
else
  echo "skip: /bin/bash is bash 4+ here; the bash 3.2 empty-array path runs on macOS"
fi
echo "PASS: hq-storage ($PASS checks)"
