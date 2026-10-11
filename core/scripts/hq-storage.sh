#!/usr/bin/env bash
# hq-core: public
# hq-storage.sh — report and prune the HQ root's local autosave history.
#
# HQ autosaves every edit as one commit in the HQ root repo
# (.claude/hooks/hq-autocommit.sh). Nothing prunes that history, so a long-lived
# HQ grows to tens of thousands of commits and many GiB of packs. This script
# shows where the space goes and squashes history older than a cutoff.
#
# Usage:
#   hq-storage.sh report --json [--root <hq>] [--no-cache]
#   hq-storage.sh prune --before <YYYY-MM-DD> [--dry-run] [--yes] [--force] [--no-backup] [--root <hq>]
#   hq-storage.sh large --json [--min-bytes N] [--root <hq>] [--no-cache]
#   hq-storage.sh strip-large --manifest <file.json> [--dry-run] [--yes] [--no-backup] [--root <hq>]
#   hq-storage.sh drop-backups [--expired] [--root <hq>]
#   hq-storage.sh reclaim [--root <hq>]
#   hq-storage.sh check [--for prune|strip-large] [--root <hq>]
#
# Every subcommand accepts --json; output is always JSON.
#
# large / strip-large: big-file offload, the main way to free space. See the
# "big files" section below. prune (date cutoff) stays as a secondary option.
#
# report: prints one JSON object (contract consumed by other HQ surfaces):
#   {root, git_dir_bytes, working_tree_bytes (tracked files in HEAD), commit_count, oldest_commit_at,
#    newest_commit_at, tranches:[{id,label,from,to,commit_count,est_bytes}],
#    holding_refs:[{name,commit_date}], holding_refs_count,
#    extra_refs (count of refs prune deletes or moves; see extra_refs below),
#    pending_reclaim_bytes, reclaim_after}
#   pending_reclaim_bytes is the on-disk size of objects only backup refs still
#   reach (see Recovery point); they are freed after reclaim_after (ISO date,
#   null without backups). Tranche estimates never include them.
#   git_dir_bytes is the object store size from `git count-objects -v`.
#   est_bytes is an ESTIMATE: the on-disk size of unique blobs first introduced
#   by commits in the tranche that nothing kept still reaches: not HEAD's tree,
#   and not any commit reachable from another branch or a tag (the refs prune
#   leaves alone), and not the trees of stash entries. It ignores delta-chain
#   effects and tree/commit objects. holding_refs lists those branches and tags
#   when they share
#   history with HEAD: while they exist, prune frees little or nothing. The
#   history part is cached for 10 minutes (HQ_STORAGE_CACHE_TTL seconds) under
#   workspace/.storage-cache/; prune, strip-large and reclaim clear the cache.
#   large caches its history part the same way (per --min-bytes); its current
#   files part is always measured live.
#
# prune: squashes every commit committed before the cutoff (UTC midnight) into
#   one root commit carrying the tree of the last pre-cutoff commit, replays the
#   newer first-parent commits on top byte-for-byte (only the parent line
#   changes; signatures are dropped; merges are flattened to their first parent
#   and side-branch commits drop out of history, their content stays in the
#   merge's tree). The new commits are built in one batch (one cat-file stream,
#   one hash-object call). It moves the current branch with a compare-and-swap,
#   deletes or moves extra refs (tool markers that would keep old history
#   alive), re-points stash entries onto the rewritten chain (see
#   prune_rewrite_stash), and runs gc (see "Undo history" below: no reflog
#   entry is expired early).
#   It refuses when it would free nothing (est_bytes 0, usually because a
#   holding ref still reaches the old history) unless --force: exit 4 with
#   {"refused":"nothing_to_free","holding_refs":[..],"holding_refs_count":N}
#   on stdout. It holds the autosave lock ($TMPDIR/hq-autocommit.lock) for the
#   whole run.
#
# Preconditions (prune and strip-large): no staged changes, no rebase/merge/
#   cherry-pick/revert/bisect in progress, no remote-tracking branches (HQ is
#   local-only), HEAD on a branch, and for prune that branch not checked out in
#   another worktree. A real run that fails one prints
#   {"refused":"<code>","message":"<plain text>"} on stdout and exits 5,
#   changing nothing. Codes: staged_changes, operation_in_progress,
#   remote_tracking_branches, detached_head, branch_in_other_worktree.
#   Dry runs report the same result as "would_refuse" (null when none).
#   `check` runs only these checks and always exits 0:
#   {"ok":true} or {"ok":false,"refused":..,"message":..}. Callers that do
#   work before the rewrite (offload uploads) run it first.
#
# Recovery point (prune and strip-large): before any ref moves, every ref is
#   copied under refs/hq-storage/backup/<epoch>-<pid>/. Those refs keep the old
#   history on disk, so the space is freed later: any prune, strip-large or
#   `drop-backups --expired` run after the grace period (HQ_STORAGE_BACKUP_GRACE_HOURS,
#   default 24) deletes the backup and gc reclaims it. `drop-backups` deletes
#   every backup now. `drop-backups --expired` is cheap and idempotent: with no
#   expired backup it takes no lock and runs no gc, and while the autosave lock
#   is held it skips ("skipped":"locked", exit 0), so callers can run it at the
#   start of every command. `reclaim` drops expired backups and, only when it
#   dropped one or the undo window below has passed, runs gc; it prints
#   {"dropped","freed_bytes",...}. --no-backup skips the backup ref; the old
#   history still stays in git's undo history (below). Stash entries are
#   backed up too (<id>/stash-log/<n>). Output carries backup_ref (null with
#   --no-backup), pending_reclaim_bytes and reclaim_after (ISO date the
#   pending bytes are freed by, null when nothing is pending). To undo within
#   the grace period:
#   `git update-ref refs/heads/<branch> refs/hq-storage/backup/<id>/heads/<branch>`.
#
# Linked worktrees: another worktree's HEAD (detached, or on a branch) keeps
#   the history it reaches. No command here moves or changes a worktree.
#   - Every "in use" count (pending bytes, prune's estimate, offload's
#     estimate) treats linked worktree HEADs as live, so space a worktree
#     keeps is never promised.
#   - prune lists such worktrees with its holders ("worktree:<path>").
#   - large marks each old big file a worktree still reaches (held_by) and
#     lists the worktrees (worktree_holders); strip-large leaves those files
#     alone (held_by_worktrees) and refuses with exit 4 when that leaves
#     nothing to free.
#
# Undo history: no command here expires a reflog entry before git would.
#   Every gc keeps git's defaults (gc.reflogExpire 90 days,
#   gc.reflogExpireUnreachable 30 days; the stash reflog never expires), so a
#   reset-away commit or a detached commit in a linked worktree stays
#   recoverable. The cost: history that prune or strip-large rewrote stays on
#   disk while recent reflog entries still reach it. Those runs record
#   <git-dir>/hq-storage-undo-pending (the epoch it is freed by: now +
#   HQ_STORAGE_UNDO_DAYS, default 30); report and the command output count the
#   bytes only reflogs or backups keep as pending_reclaim_bytes with that date,
#   never as freed. Once the date passes, `reclaim` or `drop-backups --expired`
#   runs gc (git expires the old entries itself) and clears the record.
#
# Git guard: block-hq-root-git-mutation.sh is a PreToolUse hook that inspects
# an agent's Bash command line. The git calls below run inside this script, so
# the hook never sees them. An agent invoking `bash core/scripts/hq-storage.sh`
# is not a git command and passes the guard unchanged. Only the owner should run
# prune; agents should use report and --dry-run.
#
# Never touches repos/ or nested repos: every git call is anchored with
# `git -C "$ROOT"` and only rewrites the HQ root's own objects and refs.

set -euo pipefail

die() { printf 'hq-storage: %s\n' "$1" >&2; exit "${2:-1}"; }
usage() { awk '/^# Usage:/{u=1; next} u && /^#$/{exit} u' "$0" | sed 's/^# \{0,3\}//' >&2; exit 2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${HQ_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"

BACKUP_NS="refs/hq-storage/backup"
GRACE_HOURS="${HQ_STORAGE_BACKUP_GRACE_HOURS:-24}"
[[ "$GRACE_HOURS" =~ ^[0-9]+$ ]] || GRACE_HOURS=24
UNDO_DAYS="${HQ_STORAGE_UNDO_DAYS:-30}"
[[ "$UNDO_DAYS" =~ ^[0-9]+$ ]] || UNDO_DAYS=30
CACHE_TTL="${HQ_STORAGE_CACHE_TTL:-600}"
[[ "$CACHE_TTL" =~ ^[0-9]+$ ]] || CACHE_TTL=600

g() { git -C "$ROOT" -c gc.auto=0 "$@"; }

now_epoch() { printf '%s' "${HQ_STORAGE_NOW:-$(date -u +%s)}"; }

iso() { # epoch -> ISO8601 UTC
  date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ
}

day_epoch() { # YYYY-MM-DD -> epoch at 00:00 UTC
  date -u -j -f '%Y-%m-%d %H:%M:%S' "$1 00:00:00" +%s 2>/dev/null \
    || date -u -d "$1 00:00:00" +%s 2>/dev/null
}

need_jq() {
  command -v jq >/dev/null 2>&1 || die "jq is required for this command and was not found on PATH; install jq and retry" 2
}

git_dir_path() {
  local d
  d="$(g rev-parse --git-common-dir)"
  [[ "$d" == /* ]] || d="$ROOT/$d"
  printf '%s' "$d"
}

# Object store bytes (loose + packs + garbage). Much faster than du over .git.
git_dir_bytes() {
  g count-objects -v 2>/dev/null | awk '$1=="size:"||$1=="size-pack:"||$1=="size-garbage:" {s+=$2} END {printf "%d", (s+0)*1024}'
}

require_repo() {
  [[ -d "$ROOT" ]] || die "root not found: $ROOT"
  g rev-parse --verify -q HEAD >/dev/null || die "no commits in $ROOT"
}

json_escape() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }

clear_report_cache() { rm -f "$ROOT"/workspace/.storage-cache/report*.json "$ROOT"/workspace/.storage-cache/large-*.json 2>/dev/null || true; }

# Branches (except the current one) and tags: the refs prune never moves.
# refs/stash is not one: prune and strip-large rewrite stash entries onto the
# new history (stash_tree_objects covers what they keep). Prints "<ref> <sha>".
keeper_refs() {
  local cur
  cur="$(g symbolic-ref -q HEAD || true)"
  g for-each-ref --format='%(refname) %(objectname)' refs/heads refs/tags \
    | awk -v c="$cur" '$1 != c'
  # Detached linked worktree HEADs keep their history too (branches checked
  # out in worktrees are already in refs/heads).
  linked_worktree_heads | awk -F'\t' '$3 == "-" { n++; print "worktree:" n " " $2 }'
}

# Keeper refs that share history with <commit> (they reach its root commits),
# so prune cannot free that history while they exist. Sets HOLDING_JSON (JSON
# array body of {"name","commit_date"}), HOLDING_COUNT and HOLDING_NAMES (up to
# five names, comma-separated). Call it directly, not in $(...).
HOLDING_JSON="" HOLDING_COUNT=0 HOLDING_NAMES=""
holding_refs() {
  local commit="$1" root tmpf cur
  tmpf="$(mktemp)"
  cur="$(g symbolic-ref -q HEAD || true)"
  while read -r root; do
    g for-each-ref --contains "$root" \
      --format='%(refname) %(if)%(*committerdate)%(then)%(*committerdate:unix)%(else)%(committerdate:unix)%(end)' \
      refs/heads refs/tags >>"$tmpf"
  done < <(g rev-list --max-parents=0 "$commit")
  # Detached linked worktree HEADs that share history with HEAD.
  local wp hd br r
  while IFS=$'\t' read -r wp hd br; do
    [[ "$br" == - ]] || continue
    while read -r r; do
      if g merge-base --is-ancestor "$r" "$hd" 2>/dev/null; then
        printf 'worktree:%s %s\n' "$(worktree_label "$wp" | tr ' ' '_')" "$(g log -1 --format=%ct "$hd")" >>"$tmpf"
        break
      fi
    done < <(g rev-list --max-parents=0 "$commit")
  done < <(linked_worktree_heads)
  local out
  out="$(awk -v c="$cur" '$1 != c && !seen[$1]++' "$tmpf" | sort -k2,2nr -k1,1)"
  rm -f "$tmpf"
  HOLDING_COUNT="$(printf '%s\n' "$out" | grep -c . || true)"
  HOLDING_NAMES="$(printf '%s\n' "$out" | awk 'NF {print $1}' | head -5 | while read -r r; do readable_holder "$r"; printf '\n'; done | paste -sd, - | sed 's/,/, /g' || true)"
  HOLDING_JSON=""
  local name ts
  while read -r name ts; do
    [[ -n "$name" ]] || continue
    HOLDING_JSON="${HOLDING_JSON:+$HOLDING_JSON,}$(printf '{"name":"%s","commit_date":"%s"}' "$(json_escape "$name")" "$(iso "${ts:-0}")")"
  done <<<"$out"
}

# ---------------------------------------------------------------- stash

# Stash entries, oldest first: "<sha> <ct> <reflog subject>".
stash_entries() {
  g rev-parse -q --verify refs/stash >/dev/null 2>&1 || return 0
  g log -g --format='%H %ct %gs' refs/stash 2>/dev/null \
    | awk '{ a[NR]=$0 } END { for (i=NR; i>0; i--) print a[i] }'
}

# Rebuild refs/stash and its whole reflog from "<sha> <ct> <subject>" lines,
# oldest first (entry times come from <ct>). An empty file leaves no stash.
#
# Git has no single command that replaces a reflog, so the swap is made safe
# instead of instantaneous:
#   1. one transaction pins every old and new entry under
#      refs/hq-storage-stash-pin/<pid>/, so no entry is ever unreferenced;
#   2. the new chain is written in one pass and checked against the input;
#   3. on any failure the old chain is written back from the pins (which stay
#      on disk if even that fails), otherwise the pins go in one transaction.
# HQ_STORAGE_TEST_STASH_FAIL_AT=<n> makes step 2 fail before entry <n> (tests).
stash_write() {
  local f="$1" pin="refs/hq-storage-stash-pin/$$" old
  old="$(mktemp)"
  stash_entries >"$old"
  { awk -v p="$pin" '$1 != "" { print "create " p "/old/" (NR-1) " " $1 }' "$old"
    awk -v p="$pin" '$1 != "" { print "create " p "/new/" (NR-1) " " $1 }' "$f"
  } | g update-ref -m "hq-storage stash pin" --stdin     || { rm -f "$old"; die "could not pin stash entries; stash unchanged"; }
  if stash_write_chain "$f" && [[ "$(stash_entries | awk '{print $1}')" == "$(awk '$1 != "" {print $1}' "$f")" ]]; then
    :
  else
    if stash_write_chain "$old" && [[ "$(stash_entries | awk '{print $1}')" == "$(awk '$1 != "" {print $1}' "$old")" ]]; then
      g for-each-ref --format='delete %(refname)' "$pin" | g update-ref --stdin || true
      rm -f "$old"
      die "could not rewrite the stash list; it was restored as it was"
    fi
    rm -f "$old"
    die "could not rewrite the stash list; every entry is kept under $pin"
  fi
  g for-each-ref --format='delete %(refname)' "$pin" | g update-ref --stdin || true
  rm -f "$old"
}

# Writes refs/stash and its reflog from scratch (see stash_write). Returns
# non-zero on the first failed step instead of exiting.
stash_write_chain() {
  local f="$1" sha ct subj n=0
  g update-ref -d refs/stash 2>/dev/null || true
  while read -r sha ct subj; do
    [[ -n "$sha" ]] || continue
    if [[ -n "${HQ_STORAGE_TEST_STASH_FAIL_AT:-}" && "$n" -eq "$HQ_STORAGE_TEST_STASH_FAIL_AT" ]]; then
      HQ_STORAGE_TEST_STASH_FAIL_AT="" ; return 1
    fi
    GIT_COMMITTER_DATE="@$ct +0000" g update-ref --create-reflog -m "$subj" refs/stash "$sha" || return 1
    n=$(( n + 1 ))
  done <"$f"
}

# Object ids every stash entry keeps after a rewrite: the trees (and their
# contents) of each entry and of its parents (base, index, untracked).
stash_tree_objects() {
  local w c
  while read -r w _; do
    while read -r c; do
      g rev-parse "$c^{tree}"
      g ls-tree -r -t --full-tree "$c" | awk '{print $3}'
    done < <(printf '%s\n' "$w"; g rev-parse "$w^@")
  done < <(stash_entries)
}

# Writes a copy of commit <c> with parents <p>... (signatures dropped, every
# other byte kept) and prints its id.
commit_with_parents() {
  local c="$1"; shift
  g cat-file commit "$c" | perl -e '
    binmode STDIN; binmode STDOUT; local $/; my $b = <STDIN>;
    my $cut = index($b, "\n\n");
    my ($h, $m) = $cut < 0 ? ($b, "") : (substr($b, 0, $cut + 1), substr($b, $cut + 1));
    my @out; my $skip = 0;
    for my $l (split /(?<=\n)/, $h) {
      if ($skip && $l =~ /^ /) { next } $skip = 0;
      next if $l =~ /^parent /;
      if ($l =~ /^(gpgsig|gpgsig-sha256|mergetag) /) { $skip = 1; next }
      push @out, $l;
      push @out, map { "parent $_\n" } @ARGV if $l =~ /^tree /;
    }
    print join("", @out), $m;
  ' "$@" | g hash-object -t commit -w --stdin
}

# ---------------------------------------------------------------- report

report_json() {
  local use_cache="$1" now cache_dir cache_file
  require_repo
  now="$(now_epoch)"
  cache_dir="$ROOT/workspace/.storage-cache"
  cache_file="$cache_dir/report.json"

  # working_tree_bytes is the size of files tracked in HEAD. Walking the real
  # directory with du includes repos/ and takes minutes on a large HQ.
  local gdb wtb
  gdb="$(git_dir_bytes)"
  wtb="$(g ls-tree -r -l --full-tree HEAD | awk '$4 ~ /^[0-9]+$/ {s+=$4} END {printf "%d", s+0}')"

  # Cache file: line 1 = epoch written, line 2 = history JSON part. Valid for
  # CACHE_TTL seconds; HEAD is not part of the key (autosave moves it often).
  local history="" stamp=""
  if [[ "$use_cache" == 1 && -s "$cache_file" ]]; then
    stamp="$(head -1 "$cache_file")"
    if [[ "$stamp" =~ ^[0-9]+$ && "$now" -ge "$stamp" && $(( now - stamp )) -lt "$CACHE_TTL" ]]; then
      history="$(sed -n 2p "$cache_file")"
    fi
  fi
  if [[ -z "$history" ]]; then
    history="$(history_json "$now")"
    if [[ "$use_cache" == 1 ]] && mkdir -p "$cache_dir" 2>/dev/null; then
      printf '%s\n%s\n' "$now" "$history" >"$cache_file.tmp.$$" && mv -f "$cache_file.tmp.$$" "$cache_file"
    fi
  fi
  local xr
  xr="$(extra_refs | grep -c . || true)"
  printf '{"root":"%s","git_dir_bytes":%s,"working_tree_bytes":%s,%s,"extra_refs":%s%s}\n' \
    "$(json_escape "$ROOT")" "$gdb" "$wtb" "$history" "$xr" "$(pending_json)"
}

# ,"pending_reclaim_bytes":N,"reclaim_after":..: objects only backup refs
# reach (freed once the backups expire and reclaim, prune or strip-large runs).
# reclaim_after is the newest backup's expiry; null without backups.
undo_marker() { printf '%s/hq-storage-undo-pending' "$(git_dir_path)"; }

# Epoch in the undo marker, or empty.
undo_free_after() {
  local m v
  m="$(undo_marker)"
  [[ -f "$m" ]] || return 0
  v="$(tr -dc '0-9' <"$m")"
  printf '%s' "$v"
}

# Whether the undo marker's date has passed.
undo_due() {
  local v
  v="$(undo_free_after)"
  [[ -n "$v" ]] && (( $(now_epoch) >= v ))
}

# Sorted object ids reachable from live refs (not backups), HEAD, linked
# worktree HEADs, stash entries and every worktree's index -> file $1.
live_objects() {
  { live_tips; g rev-parse -q --verify HEAD 2>/dev/null || true; worktree_head_shas; } \
    | g rev-list --objects --stdin 2>/dev/null | awk 'NF {print $1}' >"$1.tmp"
  g ls-files -s 2>/dev/null | awk '{print $2}' >>"$1.tmp"
  # Linked worktrees' HEADs and indexes are in use too.
  local wt
  while IFS= read -r wt; do
    [[ -d "$wt" ]] || continue
    git -C "$wt" ls-files -s 2>/dev/null | awk '{print $2}' >>"$1.tmp"
  done < <(linked_worktree_paths)
  LC_ALL=C sort -u "$1.tmp" >"$1"
  rm -f "$1.tmp"
}

# Bytes on disk kept only by backups and (when $1 == 1) by reflogs.
held_bytes() {
  local with_reflogs="$1" tmpd
  tmpd="$(mktemp -d)"
  if [[ "$with_reflogs" == 1 ]]; then
    g rev-list --objects --all --reflog 2>/dev/null | awk 'NF {print $1}' | LC_ALL=C sort -u >"$tmpd/held"
  else
    g for-each-ref --format='%(objectname)' "$BACKUP_NS" \
      | g rev-list --objects --stdin 2>/dev/null | awk 'NF {print $1}' | LC_ALL=C sort -u >"$tmpd/held"
  fi
  live_objects "$tmpd/live"
  LC_ALL=C comm -23 "$tmpd/held" "$tmpd/live" \
    | g cat-file --batch-check='%(objectsize:disk)' 2>/dev/null \
    | awk '$1 ~ /^[0-9]+$/ {s+=$1} END {printf "%d", s+0}'
  rm -rf "$tmpd"
}

# ,"pending_reclaim_bytes":N,"reclaim_after":"<iso>"|null
# Bytes only backup refs keep, plus (while the undo marker is set) bytes only
# reflogs keep. reclaim_after is the latest of the backup grace end and the
# undo marker date. Without backups or a marker it is cheap (no object walk).
pending_json() {
  local ids latest=0 undo bytes=0 when=0
  ids="$(g for-each-ref --format='%(refname)' "$BACKUP_NS" | awk -F/ '{print $4}' | sort -u)"
  undo="$(undo_free_after)"
  if [[ -z "$ids" && -z "$undo" ]]; then printf ',"pending_reclaim_bytes":0,"reclaim_after":null'; return 0; fi
  if [[ -n "$ids" ]]; then
    latest="$(printf '%s\n' "$ids" | awk -F- '$1 ~ /^[0-9]+$/ && $1+0 > m { m=$1+0 } END { print m+0 }')"
    when=$(( latest + GRACE_HOURS * 3600 ))
  fi
  if [[ -n "$undo" ]]; then
    bytes="$(held_bytes 1)"
    (( undo > when )) && when="$undo"
  else
    bytes="$(held_bytes 0)"
  fi
  if [[ "${bytes:-0}" -eq 0 ]]; then printf ',"pending_reclaim_bytes":0,"reclaim_after":null'; return 0; fi
  printf ',"pending_reclaim_bytes":%s,"reclaim_after":"%s"' "$bytes" "$(iso "$when")"
}

# Prints the history part of the report (without braces): commit_count,
# oldest/newest, tranches, holding refs. One streamed `git log --raw` pass over
# HEAD and the keeper refs plus one `cat-file --batch-check` pass over unique
# blob ids.
history_json() {
  local now="$1" b7 b30 b90 b365 tmp
  b7=$(( now - 7 * 86400 )); b30=$(( now - 30 * 86400 ))
  b90=$(( now - 90 * 86400 )); b365=$(( now - 365 * 86400 ))
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp'" RETURN

  # Blobs in HEAD stay on disk after any prune: exclude them from estimates.
  # Stash entries keep their trees too (prune rewrites them, it never drops them).
  { g ls-tree -r --full-tree HEAD | awk '$2=="blob"{print $3}'; stash_tree_objects; } | sort -u >"$tmp/head"

  # Commits on HEAD (counted into tranches) and commits reachable from keeper
  # refs (their blobs stay on disk after a prune, same keep-set as prune).
  g rev-list HEAD >"$tmp/headc"
  keeper_refs | awk '{print $2}' >"$tmp/keepers"
  : >"$tmp/keepc"
  if [[ -s "$tmp/keepers" ]]; then
    g rev-list --stdin <"$tmp/keepers" >"$tmp/keepc"
  fi

  # Per commit: "C <ct> <sha>"; per changed path: raw line whose 4th field is
  # the new blob id. Newest first; we keep the OLDEST introducing tranche.
  { printf 'HEAD\n'; cat "$tmp/keepers"; } \
    | g log --stdin --raw --root --no-renames --no-abbrev --no-color --format='C %ct %H' \
    | awk -v b7="$b7" -v b30="$b30" -v b90="$b90" -v b365="$b365" -v hf="$tmp/headc" -v kf="$tmp/keepc" '
        BEGIN { while ((getline l < hf) > 0) inh[l]=1; while ((getline l < kf) > 0) kc[l]=1 }
        function tr(t) { return t>=b7?0:(t>=b30?1:(t>=b90?2:(t>=b365?3:4))) }
        $1=="C" { t=$2; h=($3 in inh); kp=($3 in kc); k=tr(t)
                  if (h) { n[k]++; if(!seen++){newest=t}; oldest=t }
                  next }
        /^:/ { if ($2=="160000") next; s=$4; if (s ~ /^0+$/) next
               if (kp) { kept[s]=1; next }
               if (h) first[s]=k }
        END {
          printf "%d %d %d %d %d %d %s %s\n", n[0]+0,n[1]+0,n[2]+0,n[3]+0,n[4]+0, seen+0, oldest+0, newest+0 > "/dev/stderr"
          for (s in first) if (!(s in kept)) print s, first[s]
        }' 2>"$tmp/counts" | sort -k1,1 >"$tmp/intro"

  # Drop blobs still in HEAD, then size the rest.
  join -v1 "$tmp/intro" "$tmp/head" >"$tmp/gone" || true
  awk '{print $1}' "$tmp/gone" \
    | g cat-file --batch-check='%(objectname) %(objectsize:disk)' 2>/dev/null \
    | awk '$2 ~ /^[0-9]+$/' | sort -k1,1 >"$tmp/sizes" || true
  local est
  est="$(join "$tmp/gone" "$tmp/sizes" | awk '{b[$2]+=$3} END{printf "%d %d %d %d %d", b[0]+0,b[1]+0,b[2]+0,b[3]+0,b[4]+0}')"

  local c0 c1 c2 c3 c4 cnt oldest newest e0 e1 e2 e3 e4
  read -r c0 c1 c2 c3 c4 cnt oldest newest <"$tmp/counts"
  read -r e0 e1 e2 e3 e4 <<<"$est"
  local o_iso="" n_iso=""
  [[ "$cnt" -gt 0 ]] && { o_iso="$(iso "$oldest")"; n_iso="$(iso "$newest")"; }
  local fo
  if [[ "$cnt" -gt 0 && "$oldest" -lt "$b365" ]]; then fo="$o_iso"; else fo="$(iso "$b365")"; fi
  holding_refs HEAD
  printf '"commit_count":%s,"oldest_commit_at":"%s","newest_commit_at":"%s","tranches":[' "$cnt" "$o_iso" "$n_iso"
  printf '{"id":"7d","label":"Last 7 days","from":"%s","to":"%s","commit_count":%s,"est_bytes":%s},' "$(iso "$b7")" "$(iso "$now")" "$c0" "$e0"
  printf '{"id":"30d","label":"7–30 days","from":"%s","to":"%s","commit_count":%s,"est_bytes":%s},' "$(iso "$b30")" "$(iso "$b7")" "$c1" "$e1"
  printf '{"id":"90d","label":"30–90 days","from":"%s","to":"%s","commit_count":%s,"est_bytes":%s},' "$(iso "$b90")" "$(iso "$b30")" "$c2" "$e2"
  printf '{"id":"365d","label":"90 days–1 year","from":"%s","to":"%s","commit_count":%s,"est_bytes":%s},' "$(iso "$b365")" "$(iso "$b90")" "$c3" "$e3"
  printf '{"id":"older","label":"Older than 1 year","from":"%s","to":"%s","commit_count":%s,"est_bytes":%s}]' "$fo" "$(iso "$b365")" "$c4" "$e4"
  printf ',"holding_refs":[%s],"holding_refs_count":%s' "$HOLDING_JSON" "$HOLDING_COUNT"
}

# ---------------------------------------------------------------- lock

LOCK_DIR="${TMPDIR:-/tmp}/hq-autocommit.lock"
LOCK_HELD=0
CLEANUP_DIR=""

process_birth_token() { LC_ALL=C ps -p "$1" -o lstart= 2>/dev/null | tr -d '[:space:]'; }

on_exit() {
  [[ -z "$CLEANUP_DIR" ]] || rm -rf "$CLEANUP_DIR"
  release_lock
}

take_lock() {
  # Same mkdir lock + owner file as hq-autocommit.sh. No stale recovery here:
  # a held lock means autosave (or another prune) is running, so we refuse.
  mkdir "$LOCK_DIR" 2>/dev/null || die "autosave lock is held ($LOCK_DIR); try again shortly" 3
  LOCK_HELD=1
  printf 'pid=%s\nbirth=%s\n' "$$" "$(process_birth_token "$$")" >"$LOCK_DIR/owner" 2>/dev/null || true
  trap on_exit EXIT
}

release_lock() {
  [[ "$LOCK_HELD" == 1 ]] || return 0
  rm -f -- "$LOCK_DIR/owner" 2>/dev/null || true
  rmdir "$LOCK_DIR" 2>/dev/null || true
  LOCK_HELD=0
}

# ---------------------------------------------------------------- backups

# Copies every ref (outside refs/hq-storage/) under a new backup namespace and
# prints the namespace.
write_backup() {
  local ns
  ns="$BACKUP_NS/$(now_epoch)-$$"
  g for-each-ref --format='%(refname) %(objectname)' \
    | awk -v ns="$ns" '$1 !~ /^refs\/hq-storage\// { r=$1; sub(/^refs\//, "", r); print "create " ns "/" r " " $2 }' \
    | g update-ref -m "hq-storage backup" --stdin \
    || die "could not write the backup refs; nothing changed"
  # Older stash entries live only in the stash reflog: keep each one too.
  stash_entries | awk -v ns="$ns" '{ print "create " ns "/stash-log/" (NR-1) " " $1 }' \
    | g update-ref -m "hq-storage backup" --stdin \
    || die "could not write the stash backup refs; nothing changed"
  printf '%s' "$ns"
}

# backup_ids all|expired: backup namespace ids (read-only, cheap).
backup_ids() {
  local mode="$1" now limit
  now="$(now_epoch)"
  limit=$(( GRACE_HOURS * 3600 ))
  g for-each-ref --format='%(refname)' "$BACKUP_NS" \
    | awk -F/ '{print $4}' | sort -u \
    | awk -v m="$mode" -v now="$now" -v lim="$limit" '
        { split($0, p, "-"); if (m == "all" || (p[1] ~ /^[0-9]+$/ && now - p[1] >= lim)) print }'
}

# drop_backups all|expired: deletes backup namespaces; prints how many.
drop_backups_refs() {
  local ids n=0 id
  ids="$(backup_ids "$1")"
  for id in $ids; do
    g for-each-ref --format='delete %(refname)' "$BACKUP_NS/$id" | g update-ref --stdin
    n=$(( n + 1 ))
  done
  printf '%s' "$n"
}

# gc that keeps git's undo history: reflogs expire only on git's own defaults
# (gc.reflogExpire 90 days, gc.reflogExpireUnreachable 30 days; the stash
# reflog never), so commits reachable only from a reflog (resets, rebases,
# checkouts away, detached commits in linked worktrees) survive. Objects that
# nothing (ref, reflog, index) reaches are pruned now; callers hold the
# autosave lock.
gc_keep_undo() {
  g -c 'gc.refs/stash.reflogExpire=never' -c 'gc.refs/stash.reflogExpireUnreachable=never' \
    gc --prune=now --quiet
}

# After prune or strip-large: gc, then record when the rewritten history that
# only reflogs still reach will be gone (now + UNDO_DAYS), or clear the record
# when nothing is held.
gc_after_rewrite() {
  gc_keep_undo
  if [[ "$(held_bytes 1)" -gt 0 ]]; then
    printf '%s\n' "$(( $(now_epoch) + UNDO_DAYS * 86400 ))" >"$(undo_marker)"
  else
    rm -f "$(undo_marker)"
  fi
}

# After the undo date passed: gc (git drops the old entries itself) and clear
# the record.
gc_undo_due() {
  gc_keep_undo
  rm -f "$(undo_marker)"
}

drop_backups_cmd() {
  local mode=all
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --expired) mode=expired; shift ;;
      --json|--yes) shift ;;
      --root) ROOT="${2:-}"; shift 2 ;;
      *) usage ;;
    esac
  done
  require_repo
  local before n after skipped=""
  before="$(git_dir_bytes)"
  # Cheap path: nothing to drop means no lock and no gc. --expired skips
  # (exit 0) while the autosave lock is held; the next call retries.
  if [[ -z "$(backup_ids "$mode")" ]] && ! undo_due; then
    n=0
  elif [[ "$mode" == expired && -d "$LOCK_DIR" ]]; then
    n=0 skipped=',"skipped":"locked"'
  else
    take_lock
    n="$(drop_backups_refs "$mode")"
    if [[ "$n" -gt 0 ]] || undo_due; then
      clear_report_cache
      if undo_due; then gc_undo_due; else gc_keep_undo; fi
    fi
  fi
  after="$(git_dir_bytes)"
  printf '{"dropped":%s,"dropped_backups":%s,"freed_bytes":%s,"git_dir_bytes_before":%s,"git_dir_bytes_after":%s%s}\n' \
    "$n" "$n" "$(( before > after ? before - after : 0 ))" "$before" "$after" "$skipped"
}

# reclaim: drop expired backups and gc what they held, and gc once the undo
# date has passed. Otherwise it does nothing: no lock, no gc. It never expires
# a reflog entry early (see gc_keep_undo).
reclaim_cmd() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --json|--yes) shift ;;
      --root) ROOT="${2:-}"; shift 2 ;;
      *) usage ;;
    esac
  done
  require_repo
  local before n=0 after
  before="$(git_dir_bytes)"
  if [[ -n "$(backup_ids expired)" ]] || undo_due; then
    take_lock
    n="$(drop_backups_refs expired)"
    if undo_due; then gc_undo_due
    elif [[ "$n" -gt 0 ]]; then gc_keep_undo
    fi
  fi
  clear_report_cache
  after="$(git_dir_bytes)"
  printf '{"dropped":%s,"freed_bytes":%s,"git_dir_bytes_before":%s,"git_dir_bytes_after":%s}\n' \
    "$n" "$(( before > after ? before - after : 0 ))" "$before" "$after"
}

backup_json() { # $1 = backup ns or "" -> ,"backup_ref":..,"pending_reclaim_bytes":..,"reclaim_after":..
  if [[ -n "$1" ]]; then
    printf ',"backup_ref":"%s"' "$1"
  else
    printf ',"backup_ref":null'
  fi
  pending_json
}

# ---------------------------------------------------------------- prune

# Branches checked out in linked worktrees (not the main one): "<ref>" lines.
linked_worktree_branches() {
  g worktree list --porcelain | awk '
    /^worktree / { n++ } /^branch / && n > 1 { print $2 }'
}

linked_worktree_paths() {
  g worktree list --porcelain | awk '/^worktree / { n++; if (n > 1) { sub(/^worktree /, ""); print } }'
}

# Linked worktrees: "<path>\t<HEAD sha>\t<branch ref or ->" lines.
linked_worktree_heads() {
  g worktree list --porcelain | awk '
    function out() { if (n > 1 && p != "" && h != "") print p "\t" h "\t" b; p = "" }
    /^worktree / { out(); n++; p = substr($0, 10); h = ""; b = "-"; next }
    /^HEAD / { h = $2; next }
    /^branch / { b = $2; next }
    END { out() }'
}

# Readable name for a worktree path: relative to HQ when inside it.
worktree_label() {
  case "$1" in
    "$ROOT"/*) printf '%s' "${1#"$ROOT"/}" ;;
    *) printf '%s' "$1" ;;
  esac
}

# Readable name for a holder: "branch x", "tag v1", "stash", "worktree p".
readable_holder() {
  case "$1" in
    refs/heads/*) printf 'branch %s' "${1#refs/heads/}" ;;
    refs/tags/*) printf 'tag %s' "${1#refs/tags/}" ;;
    refs/stash) printf 'changes set aside with git stash' ;;
    worktree:*) printf 'worktree %s' "${1#worktree:}" ;;
    *) printf '%s' "${1#refs/}" ;;
  esac
}

# worktree_held <file of "<sha> ..." lines> <out>: writes "<sha>\t<path>"
# for each listed blob a linked worktree's HEAD still reaches. One log walk
# over the worktree HEADs' history, then one commit-only rev-list per
# distinct HEAD (cheap), so many worktrees stay affordable.
worktree_held() {
  local list="$1" out="$2" tw h
  : >"$out"
  [[ -s "$list" ]] || return 0
  tw="$(mktemp -d)"
  linked_worktree_heads >"$tw/wt"
  if [[ -s "$tw/wt" ]]; then
    cut -f2 "$tw/wt" | sort -u >"$tw/heads"
    # "<blob> <commit>" for every commit whose diff writes a listed blob.
    g log --stdin --raw --root --no-renames --no-abbrev --no-color \
        --diff-merges=first-parent --format='C %H' <"$tw/heads" \
      | awk 'FILENAME == ARGV[1] { b[$1] = 1; next }
             /^C / { c = $2; next }
             /^:/ { if ($4 in b) print $4, c }' "$list" - | sort -u >"$tw/intro"
    if [[ -s "$tw/intro" ]]; then
      while read -r h; do
        g rev-list "$h" >"$tw/commits"
        awk 'FILENAME == ARGV[1] { c[$1] = 1; next } ($2 in c) { print $1 }' "$tw/commits" "$tw/intro" \
          | sort -u >"$tw/hb"
        [[ -s "$tw/hb" ]] || continue
        awk -F'\t' -v h="$h" '$2 == h { print $1 }' "$tw/wt" | while IFS= read -r wp; do
          awk -v p="$(worktree_label "$wp")" '{ print $1 "\t" p }' "$tw/hb"
        done >>"$out"
      done <"$tw/heads"
    fi
  fi
  rm -rf "$tw"
}

# JSON array body of worktrees in a worktree_held file: {"path","branch"}.
worktree_holders_json() {
  local held="$1" label wp hd br first=1
  [[ -s "$held" ]] || return 0
  while IFS=$'\t' read -r wp hd br; do
    label="$(worktree_label "$wp")"
    awk -F'\t' -v p="$label" '$2 == p { f = 1; exit } END { exit !f }' "$held" || continue
    [[ "$first" == 1 ]] || printf ','
    first=0
    if [[ "$br" == - ]]; then
      printf '{"path":"%s","branch":null,"head":"%s"}' "$(json_escape "$label")" "$hd"
    else
      printf '{"path":"%s","branch":"%s","head":"%s"}' "$(json_escape "$label")" "$(json_escape "${br#refs/heads/}")" "$hd"
    fi
  done < <(linked_worktree_heads)
}

# preflight_check <prune|strip-large>: sets PF_CODE and PF_MSG and returns 1
# when a precondition fails (see "Preconditions"); read-only.
preflight_check() {
  local what="$1" gd m n
  PF_CODE="" PF_MSG=""
  gd="$(git_dir_path)"
  if [[ -n "$(g diff --cached --name-only)" ]]; then
    PF_CODE=staged_changes
    PF_MSG="HQ has staged changes. Nothing was changed. Try again after the next autosave."
    return 1
  fi
  for m in rebase-merge rebase-apply MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD BISECT_LOG; do
    if [[ -e "$gd/$m" ]]; then
      PF_CODE=operation_in_progress
      PF_MSG="A git operation ($m) is in progress in HQ. Nothing was changed. Finish or abort it, then try again."
      return 1
    fi
  done
  n="$(g for-each-ref --format='%(refname)' refs/remotes | grep -c . || true)"
  if [[ "$n" -gt 0 ]]; then
    PF_CODE=remote_tracking_branches
    PF_MSG="HQ has $n remote-tracking branch(es) under refs/remotes. HQ history is local-only, so it is not rewritten while they exist. Nothing was changed."
    return 1
  fi
  if ! BRANCH="$(g symbolic-ref -q --short HEAD)"; then
    PF_CODE=detached_head
    PF_MSG="HQ is not on a branch (detached HEAD). Nothing was changed. Check out the HQ branch, then try again."
    return 1
  fi
  if [[ "$what" == prune ]] && linked_worktree_branches | grep -qx "refs/heads/$BRANCH"; then
    PF_CODE=branch_in_other_worktree
    PF_MSG="The HQ branch $BRANCH is also checked out in another worktree. Nothing was changed."
    return 1
  fi
  return 0
}

# preflight <prune|strip-large>: refuse (JSON on stdout, exit 5) when a
# precondition fails.
preflight() {
  preflight_check "$1" && return 0
  printf '{"refused":"%s","message":"%s"}\n' "$PF_CODE" "$(json_escape "$PF_MSG")"
  die "$PF_MSG" 5
}

# would_refuse_json <prune|strip-large>: ,"would_refuse":null|{code,message}
would_refuse_json() {
  if preflight_check "$1"; then
    printf ',"would_refuse":null'
  else
    printf ',"would_refuse":{"code":"%s","message":"%s"}' "$PF_CODE" "$(json_escape "$PF_MSG")"
  fi
}

check_cmd() {
  local what=strip-large
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --for) what="${2:-}"; shift 2 ;;
      --json) shift ;;
      --root) ROOT="${2:-}"; shift 2 ;;
      *) usage ;;
    esac
  done
  [[ "$what" == prune || "$what" == strip-large ]] || usage
  require_repo
  if preflight_check "$what"; then
    printf '{"ok":true}\n'
  else
    printf '{"ok":false,"refused":"%s","message":"%s"}\n' "$PF_CODE" "$(json_escape "$PF_MSG")"
  fi
}

prune() {
  local before="" dry=0 yes=0 force=0 backup=1
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --before) before="${2:-}"; shift 2 ;;
      --dry-run) dry=1; shift ;;
      --yes) yes=1; shift ;;
      --force) force=1; shift ;;
      --no-backup) backup=0; shift ;;
      --json) shift ;;
      --root) ROOT="${2:-}"; shift 2 ;;
      *) usage ;;
    esac
  done
  [[ "$before" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || die "--before must be YYYY-MM-DD"
  local cutoff
  cutoff="$(day_epoch "$before")" || die "invalid date: $before"
  [[ -n "$cutoff" ]] || die "invalid date: $before"
  require_repo
  # --dry-run is read-only, so it skips the refusals and the lock.
  if [[ "$dry" != 1 ]]; then
    preflight prune
    take_lock
  fi
  BRANCH="${BRANCH:-$(g symbolic-ref -q --short HEAD || true)}"

  local tmp
  tmp="$(mktemp -d)"
  CLEANUP_DIR="$tmp"
  trap on_exit EXIT

  local tip list
  tip="$(g rev-parse HEAD)"
  list="$tmp/list"
  # First-parent chain, oldest first: "<sha> <ct>". Merge commits kept after
  # the cutoff are flattened to one parent; their tree (content) is unchanged.
  g rev-list --first-parent --reverse --format='%H %ct' "$tip" | grep -v '^commit ' >"$list"

  # Boundary: last commit (in history order) committed before the cutoff.
  local idx total base="" remove=0 merges=0
  total="$(g rev-list --count "$tip")"
  idx="$(awk -v c="$cutoff" '$2 < c { i=NR } END { print i+0 }' "$list")"
  if [[ "$idx" -gt 1 ]]; then
    base="$(sed -n "${idx}p" "$list" | awk '{print $1}')"
    remove=$(( $(g rev-list --count "$base") - 1 ))  # collapse into one root
    merges="$(g rev-list --merges --count "$base..$tip")"
  fi

  # Refs other than the current branch and backups (tags, stash, tool markers)
  # keep old objects alive; gc cannot reclaim what they still reach.
  local retained
  retained="$(g for-each-ref --format='%(refname)' | grep -v -x -F "refs/heads/$BRANCH" | grep -v '^refs/hq-storage/' | grep -c . || true)"

  # Extra refs (see extra_refs): each one is either moved to its rewritten
  # commit or deleted. Plan lines: "keep <ref> <old-sha>" / "drop <ref> <sha>".
  local plan drop_count
  plan="$tmp/plan"
  : >"$plan"
  if [[ "$remove" -gt 0 ]]; then
    sed -n "$(( idx + 1 )),\$p" "$list" | awk '{print $1}' >"$tmp/kept"
    extra_refs | awk 'NR==FNR { k[$1]=1; next }
      { print (($3=="commit" && ($2 in k)) ? "keep" : "drop"), $1, $2 }' "$tmp/kept" - >"$plan"
  fi
  drop_count="$(awk '$1=="drop"' "$plan" | grep -c . || true)"

  if [[ "$remove" -le 0 ]]; then
    if [[ "$dry" == 1 ]]; then printf '{"would_remove_commits":0,"est_bytes":0,"retained_refs":%s,"holding_refs":[],"holding_refs_count":0,"refs_to_remove":0,"refs_to_remove_sample":[]%s}\n' "$retained" "$(would_refuse_json prune)"; return 0; fi
    local b
    b="$(git_dir_bytes)"
    printf '{"removed_commits":0,"refs_removed":0,"before":{"git_dir_bytes":%s},"after":{"git_dir_bytes":%s}%s}\n' "$b" "$b" "$(backup_json "")"
    return 0
  fi

  local est
  est="$(estimate_bytes "$base")"
  holding_refs "$base"

  local nf_msg
  nf_msg="Pruning would free nothing: $HOLDING_COUNT branches, tags or worktrees still use this history (${HOLDING_NAMES:-none listed}). They may hold work that exists nowhere else. Nothing was changed."

  if [[ "$dry" == 1 ]]; then
    local sample wr
    sample="$(awk '$1=="drop" {print $2}' "$plan" | head -5 | while read -r r; do printf '"%s"\n' "$(json_escape "$r")"; done | paste -sd, -)"
    wr="$(would_refuse_json prune)"
    # A precondition refusal comes first; otherwise predict exit 4.
    if [[ "$wr" == ',"would_refuse":null' && "$est" -eq 0 && "$force" != 1 ]]; then
      wr="$(printf ',"would_refuse":{"code":"nothing_to_free","message":"%s","holding_refs":[%s],"holding_refs_count":%s}' \
        "$(json_escape "$nf_msg")" "$HOLDING_JSON" "$HOLDING_COUNT")"
    fi
    printf '{"would_remove_commits":%s,"est_bytes":%s,"flattened_merges":%s,"retained_refs":%s,"holding_refs":[%s],"holding_refs_count":%s,"refs_to_remove":%s,"refs_to_remove_sample":[%s]%s}\n' \
      "$remove" "$est" "$merges" "$retained" "$HOLDING_JSON" "$HOLDING_COUNT" "$drop_count" "$sample" "$wr"
    return 0
  fi

  if [[ "$est" -eq 0 && "$force" != 1 ]]; then
    printf '{"refused":"nothing_to_free","message":"%s","holding_refs":[%s],"holding_refs_count":%s}\n' "$(json_escape "$nf_msg")" "$HOLDING_JSON" "$HOLDING_COUNT"
    die "$nf_msg (--force rewrites anyway and frees only what they do not use.)" 4
  fi

  if [[ "$yes" != 1 ]]; then
    [[ -t 0 ]] || die "refusing without --yes (no terminal for confirmation)"
    printf 'Squash %s commits before %s in %s into one, flatten %s merges to their first parent (side-branch commits drop out of history; their content stays), and delete %s extra refs? This rewrites history. [y/N] ' \
      "$(( remove + 1 ))" "$before" "$ROOT" "$merges" "$drop_count" >&2
    local ans; read -r ans
    [[ "$ans" == y || "$ans" == Y || "$ans" == yes ]] || die "aborted"
  fi

  drop_backups_refs expired >/dev/null
  local before_bytes
  before_bytes="$(git_dir_bytes)"

  # Build every new commit in one batch: one cat-file stream in, one perl
  # filter that swaps the parent line and computes each new id, one
  # hash-object call that writes them. Message bytes are copied unchanged.
  local fmt algo
  fmt="$(g rev-parse --show-object-format 2>/dev/null || echo sha1)"
  case "$fmt" in sha1) algo=1 ;; sha256) algo=256 ;; *) die "unsupported object format: $fmt" ;; esac
  mkdir -p "$tmp/obj"
  { printf '%s\n' "$base"; cat "$tmp/kept"; } \
    | g cat-file --batch \
    | perl -e '
        use strict; use warnings; use Digest::SHA;
        my ($dir, $algo, $rootmsg, $mapf, $pathsf) = @ARGV;
        binmode STDIN;
        open(my $map, ">", $mapf) or die; open(my $paths, ">", $pathsf) or die;
        my $prev = ""; my $n = 0;
        while (defined(my $h = <STDIN>)) {
          my ($sha, $type, $size) = $h =~ /^(\S+) (\S+) (\d+)\n$/ or die "bad batch header: $h";
          $type eq "commit" or die "not a commit: $sha";
          my $body = ""; my $left = $size;
          while ($left > 0) { my $r = read(STDIN, my $c, $left); die "short read" unless $r; $body .= $c; $left -= $r }
          read(STDIN, my $nl, 1);
          my $cut = index($body, "\n\n");
          my ($hdr, $msg) = $cut < 0 ? ($body, "") : (substr($body, 0, $cut + 1), substr($body, $cut + 2));
          my @out; my $skip = 0;
          for my $l (split /(?<=\n)/, $hdr) {
            if ($skip && $l =~ /^ /) { next } $skip = 0;
            next if $l =~ /^parent /;
            if ($l =~ /^(gpgsig|gpgsig-sha256|mergetag) /) { $skip = 1; next }
            push @out, $l;
            push @out, "parent $prev\n" if $l =~ /^tree / && $prev ne "";
          }
          $msg = $rootmsg if $n == 0;
          my $new = join("", @out) . "\n" . $msg;
          my $id = Digest::SHA->new($algo)->add("commit " . length($new) . "\0" . $new)->hexdigest;
          my $f = "$dir/$n"; open(my $o, ">", $f) or die; binmode $o; print $o $new; close $o;
          print $paths "$f\n"; print $map "$sha $id\n";
          $prev = $id; $n++;
        }
      ' "$tmp/obj" "$algo" "hq-storage: squashed $(( remove + 1 )) autosave commits before $before
" "$tmp/map" "$tmp/paths" \
    || die "could not build the new commits; nothing changed"
  g hash-object -t commit -w --no-filters --stdin-paths <"$tmp/paths" >"$tmp/written" \
    || die "could not write the new commits; nothing changed"
  awk '{print $2}' "$tmp/map" | cmp -s - "$tmp/written" || die "new commit ids disagree with git; nothing changed"
  local new
  new="$(tail -1 "$tmp/written")"

  [[ "$(g rev-parse "$new^{tree}")" == "$(g rev-parse "$tip^{tree}")" ]] \
    || die "rewritten tip tree differs from original; branch not moved"
  [[ "$(g rev-list --count "$new")" == "$(( $(wc -l <"$tmp/kept") + 1 ))" ]] \
    || die "rewritten history has the wrong commit count; branch not moved"
  local meta_old meta_new
  meta_old="$(g log -z --first-parent --format='%an %ae %at %cn %ce %ct %B' "$base..$tip" | cksum)"
  meta_new="$(g log -z --format='%an %ae %at %cn %ce %ct %B' "$new" --not "$(g rev-list --max-parents=0 "$new")" | cksum)"
  [[ "$meta_old" == "$meta_new" ]] || die "commit authors, dates or messages changed; branch not moved"

  local bref=""
  [[ "$backup" != 1 ]] || bref="$(write_backup)"
  g update-ref -m "hq-storage prune --before $before" "refs/heads/$BRANCH" "$new" "$tip" \
    || die "branch moved during prune; nothing changed"

  # Move kept extra refs to their rewritten commits and delete the rest, in one
  # transaction. Old values are checked, so a ref that moved meanwhile aborts it.
  awk 'NR==FNR { m[$1]=$2; next }
    $1=="keep" { print "update " $2 " " m[$3] " " $3; next }
    { print "delete " $2 " " $3 }' "$tmp/map" "$plan" \
    | g update-ref -m "hq-storage prune --before $before" --stdin \
    || die "extra refs changed during prune; branch already rewritten, refs left as they were"

  prune_rewrite_stash "$tmp" "$base" "$(head -1 "$tmp/written")"

  clear_report_cache
  gc_after_rewrite

  printf '{"removed_commits":%s,"total_commits_before":%s,"flattened_merges":%s,"retained_refs":%s,"refs_removed":%s,"est_bytes":%s,"before":{"git_dir_bytes":%s},"after":{"git_dir_bytes":%s}%s}\n' \
    "$(( total - $(g rev-list --count HEAD) ))" "$total" "$merges" "$retained" "$drop_count" "$est" "$before_bytes" "$(git_dir_bytes)" "$(backup_json "$bref")"
}

# Re-point stash entries onto the rewritten chain so a stash neither blocks
# prune nor keeps old history alive. Each entry <W> has parents <B> (HEAD when
# stashed), <I> (index, parent B) and optionally <U> (untracked files, a root).
# B maps to its rewritten copy; a B that is pre-cutoff, or otherwise shares
# history with the boundary, is copied onto the new root with its tree
# unchanged. I and W are copied onto the new parents. Trees never change, so
# `git stash apply` applies the same change. Entries on unrelated history stay
# as they are. The reflog is rebuilt in order with the same subjects.
# $1 = tmp dir (holds map), $2 = boundary commit, $3 = new root.
prune_rewrite_stash() {
  local tmp="$1" base="$2" root="$3"
  stash_entries >"$tmp/stash-old"
  [[ -s "$tmp/stash-old" ]] || return 0
  : >"$tmp/stash-new"
  local w ct subj b i u nb ni nw
  while read -r w ct subj; do
    b="" i="" u=""
    read -r b i u <<<"$(g rev-parse "$w^@" | tr '\n' ' ')" || true
    nw="$w"
    if [[ -n "$i" ]]; then
      nb="$(awk -v s="$b" '$1 == s { print $2; exit }' "$tmp/map")"
      if [[ -z "$nb" ]] && g merge-base "$b" "$base" >/dev/null 2>&1; then
        nb="$(commit_with_parents "$b" "$root")"
      fi
      if [[ -n "$nb" && "$nb" != "$b" ]]; then
        ni="$(commit_with_parents "$i" "$nb")"
        nw="$(commit_with_parents "$w" "$nb" "$ni" ${u:+"$u"})"
      fi
    fi
    printf '%s %s %s\n' "$nw" "$ct" "$subj" >>"$tmp/stash-new"
  done <"$tmp/stash-old"
  cmp -s "$tmp/stash-old" "$tmp/stash-new" || stash_write "$tmp/stash-new"
}

# Extra refs: every ref outside refs/heads/*, refs/tags/*, refs/remotes/*,
# refs/stash and the backup namespace (tool markers such as
# refs/cmux/last-turn/*, refs/original/*, refs/replace/*). Prints
# "<ref> <sha> <type>".
#
# Prune rule: an extra ref whose commit is on the replayed (post-cutoff)
# first-parent chain is moved to the rewritten copy of that commit. Every other
# extra ref is deleted: it points at pre-cutoff history, at a commit that is
# not on the rewritten branch (so it would still reach the old history), or at
# a non-commit object. Branches, tags, stash and remotes are never touched.
extra_refs() {
  g for-each-ref --format='%(refname) %(objectname) %(objecttype)' \
    | awk '$1 !~ /^refs\/(heads|tags|remotes|hq-storage)\// && $1 != "refs/stash"'
}

# Estimate bytes freed by dropping history up to <base>: objects reachable from
# <base> that stay unreachable after the prune. Kept: HEAD's history after
# <base>, <base>'s tree, and everything reachable from refs prune leaves alone
# (other branches, tags), and stash entries' trees. Extra refs are deleted or moved, so they keep
# nothing extra. Backups are temporary and not counted as keepers.
estimate_bytes() {
  local base="$1" old="${TMPDIR:-/tmp}/hqs-old.$$" new="${TMPDIR:-/tmp}/hqs-new.$$"
  { g rev-list --objects "$base" | awk 'NF{print $1}' | sort -u >"$old"; } || true
  g rev-list --objects "$base"..HEAD | awk 'NF{print $1}' >"$new"
  g ls-tree -r --full-tree "$base" | awk '{print $3}' >>"$new"
  keeper_refs | awk '{print $2}' | g rev-list --objects --stdin | awk 'NF{print $1}' >>"$new"
  stash_tree_objects >>"$new"
  sort -u -o "$new" "$new"
  comm -23 "$old" "$new" \
    | g cat-file --batch-check='%(objectsize:disk)' 2>/dev/null \
    | awk '$1 ~ /^[0-9]+$/ {s+=$1} END {printf "%d", s+0}'
  rm -f "$old" "$new"
}

# ---------------------------------------------------------------- big files
#
# Big-file offload (contract: owner-approved design 2026-10-09). The hq CLI
# uploads big blobs to the personal vault, verifies them, then calls
# strip-large with a manifest. This script never uploads anything.

MIN_BYTES_DEFAULT=52428800 # 50 MiB

min_bytes_from() { # $1 = explicit value or ""
  local v="${1:-${HQ_OFFLOAD_MIN_BYTES:-$MIN_BYTES_DEFAULT}}"
  [[ "$v" =~ ^[0-9]+$ && "$v" -gt 0 ]] || die "--min-bytes must be a positive integer"
  printf '%s' "$v"
}

# perl helper shared by large: JSON string escaping for any path bytes.
PERL_JS='sub js { my $s = shift; $s =~ s/(["\\])/\\$1/g; $s =~ s/\n/\\n/g; $s =~ s/\r/\\r/g; $s =~ s/\t/\\t/g; $s =~ s/([\x00-\x1f])/sprintf("\\u%04x", ord($1))/ge; return "\"$s\"" }'

# large --json: blobs above the threshold in history (any ref) and current
# working-tree files above it (tracked or untracked, not ignored, not *.hqcloud).
# history.blobs[].last_seen_at is the newest commit (committer date) that wrote
# the blob at one of its paths. Unreachable objects are not listed. Paths are
# read NUL-separated, so any byte in a path is safe.
large() {
  local min="" json=0 cache=1
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --json) json=1; shift ;;
      --no-cache) cache=0; shift ;;
      --min-bytes) min="${2:-}"; shift 2 ;;
      --root) ROOT="${2:-}"; shift 2 ;;
      *) usage ;;
    esac
  done
  [[ "$json" == 1 ]] || usage
  need_jq
  min="$(min_bytes_from "$min")"
  require_repo
  local now tmp
  now="$(now_epoch)"
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp'" RETURN

  # History part cache: line 1 = epoch written, line 2 = JSON. Same TTL as
  # report; prune, strip-large and reclaim delete it.
  # The cache is keyed on the linked worktree HEADs too: checking out in a
  # worktree changes which old files it holds.
  local wtkey cache_file hist="" stamp=""
  wtkey="$(linked_worktree_heads | cksum | awk '{print $1}')"
  cache_file="$ROOT/workspace/.storage-cache/large-$min-$wtkey.json"
  if [[ "$cache" == 1 && -s "$cache_file" ]]; then
    stamp="$(head -1 "$cache_file")"
    if [[ "$stamp" =~ ^[0-9]+$ && "$now" -ge "$stamp" && $(( now - stamp )) -lt "$CACHE_TTL" ]]; then
      hist="$(sed -n 2p "$cache_file")"
    fi
  fi
  if [[ -z "$hist" ]]; then
  # 1. Every blob above the threshold in the object store (one batch pass).
  # disk_bytes is the compressed size in the object store, which is what an
  # offload frees; bytes is the file size.
  g cat-file --batch-all-objects --batch-check='%(objecttype) %(objectname) %(objectsize) %(objectsize:disk)' \
    | awk -v m="$min" '$1=="blob" && $3 > m {print $2, $3, $4}' | sort -k1,1 >"$tmp/big"

  # 2. One streamed walk of all refs: which of those blobs are reachable, at
  # which paths, and the newest commit that wrote each. Commits come newest
  # first, so the first hit per blob is its last_seen_at. -z output: one
  # JSON line per (blob, path).
  : >"$tmp/seen"
  if [[ -s "$tmp/big" ]]; then
    g log --all --raw -z --root --no-renames --no-abbrev --no-color \
        --diff-merges=first-parent --format='C %ct' \
      | perl -e "$PERL_JS"'
          my $bigf = shift; my %big; my %sp; my $t = 0; my $want = "";
          open(my $b, "<", $bigf) or die; while (<$b>) { my ($s) = split / /; $big{$s} = 1 }
          local $/ = "\0"; binmode STDIN;
          while (defined(my $tok = <STDIN>)) {
            chomp $tok; $tok =~ s/^\n//;
            if ($want ne "") { my $s = $want; $want = ""; next if $sp{"$s\0$tok"}++; print "{\"sha\":\"$s\",\"t\":$t,\"path\":", js($tok), "}\n"; next }
            if ($tok =~ /^C (\d+)$/) { $t = $1; next }
            if ($tok =~ /^:\S+ \S+ \S+ (\S+) \S+$/) { $want = $big{$1} ? $1 : ""; if ($want eq "") { <STDIN> } next }
          }' "$tmp/big" >"$tmp/seen"
  fi
  g ls-tree -r --full-tree HEAD | awk '$2=="blob"{print $3}' | sort -u >"$tmp/head"
  # Old big files a linked worktree's HEAD still reaches: offloading them
  # frees nothing while that worktree stays where it is.
  worktree_held "$tmp/big" "$tmp/held"
  printf '[%s]' "$(worktree_holders_json "$tmp/held")" >"$tmp/holders"

  hist="$(jq -cn --rawfile big "$tmp/big" --rawfile head "$tmp/head" --rawfile held "$tmp/held" \
      --slurpfile holders "$tmp/holders" --slurpfile seen "$tmp/seen" '
    ($big | split("\n") | map(select(length>0) | split(" ") | {key: .[0], value: [(.[1]|tonumber), (.[2]|tonumber)]}) | from_entries) as $size
    | ($head | split("\n") | map(select(length>0) | {key: ., value: true}) | from_entries) as $inhead
    | ($held | split("\n") | map(select(length>0) | split("\t")) | group_by(.[0])
       | map({key: .[0][0], value: (map(.[1]) | unique)}) | from_entries) as $heldby
    | $seen
    | group_by(.sha)
    | map({sha: .[0].sha, bytes: $size[.[0].sha][0], disk_bytes: $size[.[0].sha][1], paths: (map(.path) | unique),
           last_seen_at: (map(.t) | max | todate), in_head: ($inhead[.[0].sha] // false),
           held_by: ($heldby[.[0].sha] // [])})
    | sort_by(-.bytes)
    | (map(select(.in_head | not) | select(.held_by | length > 0))) as $h
    | {count: length, bytes: (map(.bytes) | add // 0), disk_bytes: (map(.disk_bytes) | add // 0),
       held_count: ($h | length), held_bytes: ($h | map(.bytes) | add // 0),
       worktree_holders: $holders[0], blobs: .}')"
    if [[ "$cache" == 1 ]] && mkdir -p "${cache_file%/*}" 2>/dev/null; then
      printf '%s\n%s\n' "$now" "$hist" >"$cache_file.tmp.$$" && mv -f "$cache_file.tmp.$$" "$cache_file"
    fi
  fi

  # 3. Current files: tracked + untracked (not ignored). Placeholders excluded.
  (cd "$ROOT" && git ls-files -z --cached --others --exclude-standard) \
    | (cd "$ROOT" && perl -e "$PERL_JS"'
        my ($min, $now) = @ARGV; my %done; local $/ = "\0";
        while (defined(my $p = <STDIN>)) {
          chomp $p; next if $done{$p}++ || $p =~ /\.hqcloud\z/;
          next if -l $p || !-f _;
          my @st = stat(_); next unless $st[7] > $min;
          printf "{\"path\":%s,\"bytes\":%d,\"mtime\":%d,\"idle_days\":%d}\n", js($p), $st[7], $st[9], int(($now - $st[9]) / 86400);
        }' "$min" "$now") >"$tmp/cur"
  local cur
  cur="$(jq -n --slurpfile cur "$tmp/cur" '
    $cur | map(.mtime |= todate) | sort_by(-.bytes)
    | {count: length, bytes: (map(.bytes) | add // 0), files: .}')"

  jq -cn --argjson min "$min" --argjson h "$hist" --argjson c "$cur" \
    '{min_bytes: $min, history: $h, current: $c}'
}

# strip-large --manifest <file>: rewrite history so every listed blob is
# replaced by its pointer text. One `git fast-export --no-data` stream (blobs
# referenced by id, so no file content passes through the pipe), a perl filter
# that swaps blob ids on `M` lines, and one `git fast-import --force` into the
# same repo. Commits, authors, dates and messages are kept; branches, tags
# (annotated and lightweight) and extra refs are re-pointed by the same stream,
# so an old tag maps to the rewritten copy of its commit. The working tree and
# the index are never touched.
#
# Manifest checks (any failure stops the run before anything changes): every
# pointer_text starts with "HQ-CLOUD-FILE v1", its `git-blob:` line equals the
# entry's sha, and its `size:` line equals the blob's size. A pointer carries
# one path; the CLI writes the blob's first path (`paths[0]` from `large`), so a
# blob stored at several paths shows that one path at every location.
#
# Listed blobs that are in HEAD's tree, the index, or a linked worktree's index
# are never replaced (reported in skipped_current): stripping a current file
# would leave the index and the working file disagreeing. A branch checked out
# in a linked worktree whose history holds a listed blob makes the run refuse.
#
# Refs that existed before are checked afterwards: same set of refs, same
# commit count, same HEAD tree, same commit metadata. If any check fails every
# ref is restored to its old value before gc. Every stash entry (the whole
# refs/stash reflog) is rewritten in place through temporary refs
# refs/hq-storage-stash/<n>, so no extra stash entry appears and no old entry
# keeps a big blob alive; other reflogs are expired.
strip_large() {
  local manifest="" dry=0 yes=0 backup=1
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --manifest) manifest="${2:-}"; shift 2 ;;
      --dry-run) dry=1; shift ;;
      --yes) yes=1; shift ;;
      --no-backup) backup=0; shift ;;
      --json) shift ;;
      --root) ROOT="${2:-}"; shift 2 ;;
      *) usage ;;
    esac
  done
  need_jq
  [[ -n "$manifest" && -r "$manifest" ]] || die "--manifest <file.json> is required and must be readable"
  jq -e '.blobs | type == "array"' "$manifest" >/dev/null 2>&1 || die "manifest must be {\"blobs\":[{\"sha\",\"pointer_text\"}]}"
  jq -e '[.blobs[] | (.sha | type == "string" and test("^[0-9a-f]{40}$")) and (.pointer_text | type == "string" and length > 0)] | all' \
    "$manifest" >/dev/null || die "every manifest entry needs a 40-hex sha and a non-empty pointer_text"
  require_repo
  if [[ "$dry" != 1 ]]; then preflight strip-large; take_lock; fi

  local tmp
  tmp="$(mktemp -d)"
  CLEANUP_DIR="$tmp"
  trap on_exit EXIT

  # Listed blobs that exist in this repo: "<sha> <size> <disk-size>".
  jq -r '.blobs[].sha' "$manifest" | sort -u \
    | g cat-file --batch-check='%(objectname) %(objecttype) %(objectsize) %(objectsize:disk)' 2>/dev/null \
    | awk '$2=="blob" {print $1, $3, $4}' >"$tmp/listed"

  # Current blobs (HEAD tree, index, linked worktree indexes) are skipped.
  {
    g ls-tree -r --full-tree HEAD | awk '$2=="blob"{print $3}'
    g ls-files -s | awk '{print $2}'
    local wt
    while IFS= read -r wt; do
      git -C "$wt" ls-files -s 2>/dev/null | awk '{print $2}'
    done < <(linked_worktree_paths)
  } | sort -u >"$tmp/current"
  # FILENAME, not NR==FNR: the first file may be empty.
  awk 'FILENAME == ARGV[1] { c[$1]=1; next } ($1 in c) { print $1 }' "$tmp/current" "$tmp/listed" >"$tmp/skipped"
  awk 'FILENAME == ARGV[1] { c[$1]=1; next } !($1 in c)' "$tmp/skipped" "$tmp/listed" >"$tmp/present"
  # Blobs a linked worktree's HEAD still reaches are left alone: replacing
  # them frees nothing, and a branch checked out there must not move.
  worktree_held "$tmp/present" "$tmp/held"
  cut -f1 "$tmp/held" | sort -u >"$tmp/heldids"
  awk 'FILENAME == ARGV[1] { c[$1]=1; next } !($1 in c)' "$tmp/heldids" "$tmp/present" >"$tmp/free"
  local listed_present held_json holders_json
  listed_present="$(grep -c . "$tmp/present" || true)"
  mv -f "$tmp/free" "$tmp/present"
  held_json="$(awk '{printf "%s\"%s\"", (NR>1?",":""), $1}' "$tmp/heldids")"
  holders_json="$(worktree_holders_json "$tmp/held")"

  # Validate every pointer for a present blob and write it to a file:
  # "<sha> <pointer-file>" lines in $tmp/ptrs.
  mkdir -p "$tmp/ptr"
  jq -r '.blobs[] | "\(.sha) \(.pointer_text | @base64)"' "$manifest" \
    | perl -MMIME::Base64 -e '
        my ($presentf, $dir) = @ARGV; my %size;
        open(my $p, "<", $presentf) or die; while (<$p>) { my ($s, $n) = split / /; $size{$s} = $n }
        my %done;
        while (my $l = <STDIN>) {
          chomp $l; my ($sha, $b64) = split / /, $l, 2;
          next unless exists $size{$sha}; next if $done{$sha}++;
          my $t = decode_base64($b64);
          $t =~ /\AHQ-CLOUD-FILE v1\n/ or do { print STDERR "pointer for $sha does not start with HQ-CLOUD-FILE v1\n"; exit 3 };
          my ($gb) = $t =~ /^git-blob: (\S+)$/m;
          defined $gb && $gb eq $sha or do { print STDERR "pointer for $sha names git-blob " . ($gb // "(none)") . "\n"; exit 3 };
          my ($sz) = $t =~ /^size: (\d+)$/m;
          defined $sz && $sz == $size{$sha} or do { print STDERR "pointer for $sha has size " . ($sz // "(none)") . ", blob has $size{$sha}\n"; exit 3 };
          open(my $o, ">", "$dir/$sha") or die; binmode $o; print $o $t; close $o;
          print "$sha $dir/$sha\n";
        }' "$tmp/present" "$tmp/ptr" >"$tmp/ptrs" \
    || die "manifest rejected (see above); nothing changed"

  local present est skipped_json
  present="$(grep -c . "$tmp/present" || true)"
  est="$(awk '{s+=$3} END {printf "%d", s+0}' "$tmp/present")"
  skipped_json="$(awk '{printf "%s\"%s\"", (NR>1?",":""), $1}' "$tmp/skipped")"

  local held_tail nf_msg=""
  held_tail="$(printf ',"held_by_worktrees":[%s],"worktree_holders":[%s]' "$held_json" "$holders_json")"
  if [[ "$present" -eq 0 && -s "$tmp/heldids" ]]; then
    nf_msg="Offloading would free nothing: $(cut -f2 "$tmp/held" | sort -u | grep -c .) worktree(s) still use this history ($(cut -f2 "$tmp/held" | sort -u | head -5 | sed 's/^/worktree /' | paste -sd, - | sed 's/,/, /g')). HQ never changes other worktrees. Nothing was changed."
  fi

  if [[ "$dry" == 1 ]]; then
    local wr
    wr="$(would_refuse_json strip-large)"
    if [[ "$wr" == ',"would_refuse":null' && -n "$nf_msg" ]]; then
      wr="$(printf ',"would_refuse":{"code":"nothing_to_free","message":"%s","worktree_holders":[%s]}' "$(json_escape "$nf_msg")" "$holders_json")"
    fi
    printf '{"dry_run":true,"listed_blobs":%s,"present_blobs":%s,"skipped_current":[%s],"est_freed_bytes":%s,"commit_count":%s%s%s}\n' \
      "$(jq '.blobs | length' "$manifest")" "$present" "$skipped_json" "$est" "$(g rev-list --all --count)" "$held_tail" "$wr"
    return 0
  fi
  if [[ -n "$nf_msg" ]]; then
    printf '{"refused":"nothing_to_free","message":"%s","listed_present":%s%s}\n' "$(json_escape "$nf_msg")" "$listed_present" "$held_tail"
    die "$nf_msg" 4
  fi
  if [[ "$present" -eq 0 ]]; then
    local b
    b="$(git_dir_bytes)"
    printf '{"rewritten_commits":0,"replaced_blobs":0,"skipped_current":[%s],"freed_bytes":0,"git_dir_bytes_before":%s,"git_dir_bytes_after":%s%s%s}\n' \
      "$skipped_json" "$b" "$b" "$held_tail" "$(backup_json "")"
    return 0
  fi

  # A branch checked out in a linked worktree must not move under it.
  local br
  while read -r br; do
    [[ -n "$br" ]] || continue
    if g rev-list --objects "$br" | awk 'NR==FNR { p[$1]=1; next } ($1 in p) { f=1; exit } END { exit !f }' "$tmp/present" -; then
      die "branch ${br#refs/heads/} is checked out in another worktree and holds a listed blob; refusing"
    fi
  done < <(linked_worktree_branches)

  if [[ "$yes" != 1 ]]; then
    [[ -t 0 ]] || die "refusing without --yes (no terminal for confirmation)"
    printf 'Replace %s big files in the history of %s with cloud pointers? This rewrites history. [y/N] ' "$present" "$ROOT" >&2
    local ans; read -r ans
    [[ "$ans" == y || "$ans" == Y || "$ans" == yes ]] || die "aborted"
  fi

  drop_backups_refs expired >/dev/null
  local before_bytes head_tree count_before meta_before
  before_bytes="$(git_dir_bytes)"
  head_tree="$(g rev-parse 'HEAD^{tree}')"
  count_before="$(live_tips | g rev-list --stdin --count)"
  meta_before="$(meta_sum)"
  g for-each-ref --format='%(refname) %(objectname)' | grep -v '^refs/hq-storage/' >"$tmp/refs-before" || true
  stash_entries >"$tmp/stash-old"

  # Pointer blobs: "<old-sha> <pointer-sha>" for every present listed blob.
  awk '{print $2}' "$tmp/ptrs" | g hash-object -w --no-filters --stdin-paths >"$tmp/ptr-ids" \
    || die "could not write pointer blobs; nothing changed"
  awk '{print $1}' "$tmp/ptrs" | paste -d' ' - "$tmp/ptr-ids" | sort -u -k1,1 >"$tmp/map"

  # Export to a file first: a failed export must never reach fast-import,
  # which would otherwise move refs for a partial stream. Backup refs are not
  # exported, so they keep pointing at the old history.
  # refs/stash itself is not exported (fast-import would add a new entry);
  # each stash entry goes through a temporary ref instead.
  local signed=() refs=() r n=0
  if g fast-export -h 2>&1 | grep -q -e '--signed-commits'; then signed=(--signed-commits=strip); fi
  while read -r r _; do [[ "$r" == refs/stash ]] || refs+=("$r"); done <"$tmp/refs-before"
  while read -r r _; do
    g update-ref "refs/hq-storage-stash/$n" "$r" || { restore_all "$tmp"; die "could not write temporary stash refs; nothing changed"; }
    refs+=("refs/hq-storage-stash/$n"); n=$(( n + 1 ))
  done <"$tmp/stash-old"
  g fast-export --no-data --reencode=no --signed-tags=strip ${signed[@]+"${signed[@]}"} \
      --tag-of-filtered-object=rewrite --show-original-ids ${refs[@]+"${refs[@]}"} >"$tmp/stream" \
    || { restore_all "$tmp"; die "fast-export failed; nothing changed"; }

  # Filter: copy the stream byte-exactly, honouring `data <n>` payloads
  # (messages may hold any bytes), and swap blob ids on file-modify lines.
  # Within each commit, deletes are emitted before modifies: fast-export can
  # print `M dir/file` before `D dir` when a symlink is replaced by a
  # directory, and fast-import would then drop the new files. Paths are
  # distinct within one commit, so deletes-first gives the same tree.
  perl -e '
    my ($mapf, $countf) = @ARGV; my %m; my %hit; my (@d, @mm);
    open(my $mf, "<", $mapf) or die; while (<$mf>) { chomp; my ($a, $b) = split / /; $m{$a} = $b }
    binmode STDIN; binmode STDOUT;
    sub flush { print @d, @mm; @d = (); @mm = () }
    while (defined(my $l = <STDIN>)) {
      if ($l =~ /^D /) { push @d, $l; next }
      if ($l =~ /^M /) {
        if ($l =~ /^M (100644|100755) ([0-9a-f]{40}) (.*)$/s && exists $m{$2}) {
          $hit{$2}++; $l = "M $1 $m{$2} $3";
        }
        push @mm, $l; next;
      }
      flush();
      if ($l =~ /^data (\d+)\n$/) {
        print $l; my $n = $1; my $buf = "";
        while ($n > 0) { my $r = read(STDIN, my $c, $n); die "short data" unless $r; $buf .= $c; $n -= $r }
        print $buf; next;
      }
      print $l;
    }
    flush();
    open(my $cf, ">", $countf) or die; print $cf scalar(keys %hit), "\n";
  ' "$tmp/map" "$tmp/replaced" <"$tmp/stream" >"$tmp/stream.new" \
    || { restore_all "$tmp"; die "stream filter failed; nothing changed"; }

  local bref=""
  [[ "$backup" != 1 ]] || bref="$(write_backup)"

  # Commits whose parents and trees are unchanged hash to the same id, so the
  # number of new ids is the number of rewritten commits.
  live_tips | g rev-list --stdin >"$tmp/commits-before"
  g fast-import --force --quiet --export-marks="$tmp/marks" <"$tmp/stream.new" \
    || { restore_all "$tmp"; die "fast-import failed; refs restored"; }

  # Rebuild the stash reflog from the rewritten entries, same order and subjects.
  : >"$tmp/stash-new"
  n=0
  local sct ssubj
  while read -r _ sct ssubj; do
    printf '%s %s %s\n' "$(g rev-parse "refs/hq-storage-stash/$n")" "$sct" "$ssubj" >>"$tmp/stash-new"
    g update-ref -d "refs/hq-storage-stash/$n"
    n=$(( n + 1 ))
  done <"$tmp/stash-old"
  cmp -s "$tmp/stash-old" "$tmp/stash-new" || stash_write "$tmp/stash-new"

  # Verify, then either restore every ref or continue.
  local bad=""
  g for-each-ref --format='%(refname)' | grep -v '^refs/hq-storage/' | sort >"$tmp/names-after" || true
  awk '{print $1}' "$tmp/refs-before" | sort >"$tmp/names-before"
  cmp -s "$tmp/names-before" "$tmp/names-after" || bad="ref set changed"
  # Backups reach the old commits, so count only the live refs.
  [[ -n "$bad" || "$(live_tips | g rev-list --stdin --count)" == "$count_before" ]] || bad="commit count changed"
  [[ -n "$bad" || "$(g rev-parse 'HEAD^{tree}')" == "$head_tree" ]] || bad="HEAD tree changed"
  [[ -n "$bad" || "$(meta_sum)" == "$meta_before" ]] || bad="commit authors, dates or messages changed"
  if [[ -n "$bad" ]]; then
    restore_all "$tmp"
    die "verification failed ($bad); every ref restored, nothing removed"
  fi

  local rewritten
  rewritten="$(live_tips | g rev-list --stdin | sort | comm -13 <(sort "$tmp/commits-before") - | grep -c . || true)"

  clear_report_cache
  gc_after_rewrite

  local after_bytes
  after_bytes="$(git_dir_bytes)"
  printf '{"rewritten_commits":%s,"replaced_blobs":%s,"skipped_current":[%s],"freed_bytes":%s,"git_dir_bytes_before":%s,"git_dir_bytes_after":%s%s%s}\n' \
    "$rewritten" "$(cat "$tmp/replaced")" "$skipped_json" "$(( before_bytes > after_bytes ? before_bytes - after_bytes : 0 ))" "$before_bytes" "$after_bytes" "$held_tail" "$(backup_json "$bref")"
}

restore_refs() { # $1 = "<ref> <sha>" lines; delete refs that did not exist (backups kept)
  local f="$1"
  {
    awk '{print "update " $1 " " $2}' "$f"
    g for-each-ref --format='%(refname)' | grep -v '^refs/hq-storage/' \
      | awk 'NR==FNR { k[$1]=1; next } !($1 in k) { print "delete " $1 }' "$f" -
  } | g update-ref --stdin
}

# Restores every ref from $1/refs-before (deleting temporary stash refs) and
# the whole stash reflog from $1/stash-old.
restore_all() {
  restore_refs "$1/refs-before"
  if [[ -s "$1/stash-old" ]]; then stash_write "$1/stash-old"; fi
}

# Tips of every ref except backups (backups keep the old history), plus every
# stash entry (older ones live only in the stash reflog).
live_tips() {
  g for-each-ref --format='%(refname) %(objectname)' | awk '$1 !~ /^refs\/hq-storage\// && $1 != "refs/stash" {print $2}'
  stash_entries | awk '{print $1}'
}

# HEADs of linked worktrees (detached or on a branch), one sha per line.
worktree_head_shas() { linked_worktree_heads | cut -f2 | sort -u; }

# Checksum of every commit's author, committer, dates and message, order-free.
# Backup refs are excluded so old and new history are not mixed.
meta_sum() {
  live_tips | g log --stdin -z --format='%an %ae %at %cn %ce %ct %B' | sort -z | cksum | awk '{print $1 $2}'
}

# ---------------------------------------------------------------- main

cmd="${1:-}"; shift || true
case "$cmd" in
  report)
    json=0 cache=1
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --json) json=1; shift ;;
        --root) ROOT="${2:-}"; shift 2 ;;
        --no-cache) cache=0; shift ;;
        *) usage ;;
      esac
    done
    [[ "$json" == 1 ]] || usage
    report_json "$cache"
    ;;
  prune) prune "$@" ;;
  large) large "$@" ;;
  strip-large) strip_large "$@" ;;
  drop-backups) drop_backups_cmd "$@" ;;
  reclaim) reclaim_cmd "$@" ;;
  check) check_cmd "$@" ;;
  *) usage ;;
esac
