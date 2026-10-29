#!/usr/bin/env bash
# hq-core: public
# Apply the files an hq-core main push changed onto an hq-core-staging clone,
# without overwriting staging work made after the release cut.
#
# Usage: backmerge-apply.sh <source-repo> <target-dir> <base-ref> <after-ref> <changes.z>
#
#   source-repo  git checkout of hq-core containing both refs
#   target-dir   working tree of the hq-core-staging clone
#   base-ref     hq-core commit before the push (the BEFORE state)
#   after-ref    hq-core commit after the push
#   changes.z    `git diff -z --no-renames --name-status base after` output
#                (NUL-separated, so any path name survives unquoted)
#
# A path is applied only when the staging copy still equals the BEFORE state
# (both absent counts as equal, so files new in hq-core are added). If staging
# changed the path since the cut, the staging copy is kept and the path is
# listed under "skipped (staging diverged)". Paths where staging already
# equals the AFTER state are left alone. Deletions follow the same rule.
#
# Prints one line per path and a summary. With BACKMERGE_SUMMARY_FILE set,
# appends a markdown summary there (for $GITHUB_STEP_SUMMARY). Exits 0 unless
# arguments are wrong or a git read fails.
set -euo pipefail

if [ "$#" -ne 5 ]; then
  echo "usage: $0 <source-repo> <target-dir> <base-ref> <after-ref> <changes.z>" >&2
  exit 2
fi
SRC="$1" TGT="$2" BASE="$3" AFTER="$4" CHANGES="$5"
TGT="$(cd "$TGT" && pwd)"

# Trees that belong to staging alone and never come from hq-core.
is_local() {
  case "$1" in
    companies/*|personal/*|repos/*|workspace/*|.obsidian/*|.git/*) return 0 ;;
    *) return 1 ;;
  esac
}

# Blob id of <ref>:<path> in the source repo, or empty when absent.
blob_at() {
  git -C "$SRC" rev-parse -q --verify "$1:$2" 2>/dev/null || true
}

# Blob id of the staging working-tree entry, or empty when absent.
target_blob() {
  local p="$TGT/$1"
  if [ -L "$p" ]; then
    printf '%s' "$(readlink "$p")" | git -C "$SRC" hash-object --stdin
  elif [ -f "$p" ]; then
    git -C "$SRC" hash-object --no-filters -- "$p"
  elif [ -e "$p" ]; then
    echo "non-file"
  fi
}

# Write <after-ref>:<path> into the target with its mode (file, exec, symlink)
# through a throwaway index, so the source checkout is not modified.
IDX="$(mktemp)"
rm -f "$IDX"
trap 'rm -f "$IDX"' EXIT
write_after() {
  rm -f -- "$TGT/$1"
  # Literal pathspec: a name like f[1].md must not also match f1.md.
  GIT_INDEX_FILE="$IDX" GIT_LITERAL_PATHSPECS=1 \
    git -C "$SRC" --work-tree="$TGT" checkout "$AFTER" -- "$1"
}

applied=() deleted=() skipped=() current=()

while IFS= read -r -d '' STATUS && IFS= read -r -d '' PATHNAME; do
  [ -z "${STATUS:-}" ] && continue
  if is_local "$PATHNAME"; then
    echo "skip (staging-local): $PATHNAME"
    continue
  fi
  before="$(blob_at "$BASE" "$PATHNAME")"
  after="$(blob_at "$AFTER" "$PATHNAME")"
  have="$(target_blob "$PATHNAME")"
  if [ -z "$before" ] && [ -z "$after" ]; then
    echo "::error::backmerge: $PATHNAME is in the change list but missing at both refs" >&2
    exit 1
  fi

  if [ "$have" = "$after" ]; then
    current+=("$PATHNAME"); echo "already current: $PATHNAME"; continue
  fi
  if [ "$have" != "$before" ]; then
    skipped+=("$PATHNAME"); echo "skipped (staging diverged): $PATHNAME"
    echo "::warning file=$PATHNAME::backmerge kept the staging copy; staging changed it after the cut, reconcile by hand"
    continue
  fi
  if [ -z "$after" ]; then
    rm -f -- "$TGT/$PATHNAME"
    deleted+=("$PATHNAME"); echo "deleted: $PATHNAME"
  else
    write_after "$PATHNAME"
    applied+=("$PATHNAME"); echo "applied: $PATHNAME"
  fi
done < "$CHANGES"

echo "----- backmerge summary -----"
echo "applied: ${#applied[@]}  deleted: ${#deleted[@]}  already current: ${#current[@]}  skipped (staging diverged): ${#skipped[@]}"
for p in ${skipped[@]+"${skipped[@]}"}; do echo "  skipped: $p"; done

if [ -n "${BACKMERGE_SUMMARY_FILE:-}" ]; then
  {
    echo "### Backmerge summary"
    echo "- applied: ${#applied[@]}, deleted: ${#deleted[@]}, already current: ${#current[@]}, skipped: ${#skipped[@]}"
    if [ "${#skipped[@]}" -gt 0 ]; then
      echo ""
      echo "Skipped because staging changed them after the cut (staging copy kept):"
      for p in "${skipped[@]}"; do echo "- \`$p\`"; done
    fi
  } >> "$BACKMERGE_SUMMARY_FILE"
fi
