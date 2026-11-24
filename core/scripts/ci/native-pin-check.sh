#!/usr/bin/env bash
# native-pin-check.sh: stop a pull request from changing a file the hq-hook
# engine answers natively without saying what happens to that pin.
#
# The Rust hook engine (hq-cli crates/hq-hook) answers a hook natively only
# when the installed script's SHA-256 is one it pins, in
# crates/hq-hook/core-pins.json or in a pin table in crates/hq-hook/src.
# When this repository changes a pinned file, every install on the new core
# falls back to bash for that hook until hq-cli pins the new bytes.
#
# The check compares two trees: --base, the branch the pull request merges
# into as it is now, and --head, the result of the merge (in Actions, the
# pull_request merge commit and its first parent). For each file that differs,
# it hashes the --base copy. When hq-cli pins that hash and does not also pin
# the --head copy, the file is flagged. A flagged file fails the check unless
# the pull request body, or a commit message in --base..--head, has a line:
#
#   Native-pin: pending hq-cli#1234
#   Native-pin: pending indigoai-us/hq-cli#1234
#   Native-pin: pending https://github.com/indigoai-us/hq-cli/pull/1234
#   Native-pin: bash-fallback <reason the bash fallback is acceptable>
#
# The bash-fallback reason must be at least two words and must not be the
# <reason> placeholder.
#
# One line acknowledges every flagged file in the pull request. Lines inside
# HTML comments or fenced code blocks in the body do not count.
#
# Files whose bytes hq-cli does not pin, and new files, never fail. Every git
# read that fails (for example a blob a partial clone cannot fetch) is an
# input error, never a pass.
#
# Usage:
#   native-pin-check.sh --repo <checkout> --base <commit> --head <commit> \
#     --pins <hq-cli checkout> [--pr-body-file <file>]
#
# Run locally on a branch that is up to date with main:
#   native-pin-check.sh --repo . --base origin/main --head HEAD --pins <hq-cli>
#
# --pins needs crates/hq-hook/core-pins.json and crates/hq-hook/src from
# hq-cli; a sparse checkout of those two paths is enough.
#
# Exit 0: no pinned file changed, or every such change is acknowledged.
# Exit 1: a pinned file changed with no acknowledgement.
# Exit 2: usage or input error.
set -euo pipefail

REPO=""
BASE=""
HEAD=""
PINS=""
BODY_FILE=""

usage() {
  printf 'usage: %s --repo DIR --base COMMIT --head COMMIT --pins DIR [--pr-body-file FILE]\n' "${0##*/}" >&2
  exit 2
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo) [ "$#" -ge 2 ] || usage; REPO="$2"; shift 2 ;;
    --base) [ "$#" -ge 2 ] || usage; BASE="$2"; shift 2 ;;
    --head) [ "$#" -ge 2 ] || usage; HEAD="$2"; shift 2 ;;
    --pins) [ "$#" -ge 2 ] || usage; PINS="$2"; shift 2 ;;
    --pr-body-file) [ "$#" -ge 2 ] || usage; BODY_FILE="$2"; shift 2 ;;
    *) printf 'unknown argument: %s\n' "$1" >&2; usage ;;
  esac
done

[ -n "$REPO" ] && [ -n "$BASE" ] && [ -n "$HEAD" ] && [ -n "$PINS" ] || usage

fail_input() {
  # stderr, so the message survives a call from inside $(...).
  if [ -n "${GITHUB_ACTIONS:-}" ]; then
    printf '::error title=native-pin-check::%s\n' "$1" >&2
  else
    printf 'native-pin-check: %s\n' "$1" >&2
  fi
  exit 2
}

[ -f "$PINS/crates/hq-hook/core-pins.json" ] || fail_input "no crates/hq-hook/core-pins.json under $PINS; cannot read the hq-cli pin list"
[ -d "$PINS/crates/hq-hook/src" ] || fail_input "no crates/hq-hook/src under $PINS; cannot read the hq-cli pin tables"
if [ -n "$BODY_FILE" ] && [ ! -r "$BODY_FILE" ]; then
  fail_input "cannot read the pull request body file $BODY_FILE"
fi

BASE_SHA="$(git -C "$REPO" rev-parse --verify --quiet "$BASE^{commit}")" || fail_input "base $BASE is not a commit in $REPO"
HEAD_SHA="$(git -C "$REPO" rev-parse --verify --quiet "$HEAD^{commit}")" || fail_input "head $HEAD is not a commit in $REPO"

if command -v sha256sum >/dev/null 2>&1; then
  hash_file() { sha256sum < "$1" | awk '{print $1}'; }
elif command -v shasum >/dev/null 2>&1; then
  hash_file() { shasum -a 256 < "$1" | awk '{print $1}'; }
else
  fail_input "neither sha256sum nor shasum is installed"
fi

work="$(mktemp -d "${TMPDIR:-/tmp}/native-pin-check.XXXXXX")"
trap 'rm -rf "$work"' EXIT

# Every SHA-256 hq-cli names. The empty file's hash is never a pin.
EMPTY_SHA256="e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
if ! grep -rhoE '[0-9a-f]{64}' "$PINS/crates/hq-hook/core-pins.json" "$PINS/crates/hq-hook/src" > "$work/all-hashes"; then
  : > "$work/all-hashes"
fi
grep -vxF "$EMPTY_SHA256" "$work/all-hashes" | sort -u > "$work/pins" || true
[ -s "$work/pins" ] || fail_input "hq-cli under $PINS names no SHA-256; the pin list format may have changed"

is_pinned() { grep -qxF "$1" "$work/pins"; }

# Where hq-cli names a hash, for the failure message.
pinned_in() {
  local found line out=""
  found="$(grep -rlF "$1" "$PINS/crates/hq-hook/core-pins.json" "$PINS/crates/hq-hook/src" 2>/dev/null || true)"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    line="${line#"$PINS"/}"
    out="${out:+$out,}$line"
  done <<< "$(printf '%s\n' "$found" | head -3)"
  printf '%s' "$out"
}

# entry_type COMMIT PATH: "blob" for a file or symlink, another git object
# type, or nothing when the path is absent. ls-tree reads only trees, which a
# blob-less partial clone has locally.
entry_type() {
  local out
  out="$(git -C "$REPO" ls-tree -z "$1" -- ":(literal)$2" | tr '\0' '\n')" \
    || fail_input "cannot list $2 at $1"
  [ -n "$out" ] || return 0
  printf '%s' "$out" | awk '{print $2; exit}'
}

# blob_hash COMMIT PATH: SHA-256 of the file's bytes. A blob that cannot be
# read is an input error.
blob_hash() {
  git -C "$REPO" cat-file blob "$1:$2" > "$work/blob" 2>"$work/blob.err" \
    || fail_input "cannot read $2 at $1: $(head -1 "$work/blob.err")"
  hash_file "$work/blob"
}

# The list of changed files, read in full before the loop so a failing diff
# is an input error.
git -C "$REPO" diff --no-renames --no-ext-diff --no-textconv --name-status -z "$BASE_SHA" "$HEAD_SHA" > "$work/changes" \
  || fail_input "git diff $BASE..$HEAD failed"
# One batched fetch of every changed blob in a partial clone, instead of one
# fetch per file in the loop below.
git -C "$REPO" diff --no-renames --no-ext-diff --no-textconv --numstat "$BASE_SHA" "$HEAD_SHA" > /dev/null 2>"$work/prefetch.err" \
  || fail_input "cannot read the changed files: $(head -1 "$work/prefetch.err")"

flagged=0
: > "$work/flagged"
while IFS= read -r -d '' status; do
  IFS= read -r -d '' path || fail_input "malformed git diff output"
  case "$status" in
    A*) continue ;;
  esac
  # Assigned first: a failure inside [ ... ] would not stop the script.
  base_type="$(entry_type "$BASE_SHA" "$path")"
  [ "$base_type" = "blob" ] || continue
  old="$(blob_hash "$BASE_SHA" "$path")"
  is_pinned "$old" || continue
  head_type="$(entry_type "$HEAD_SHA" "$path")"
  if [ "$head_type" = "blob" ]; then
    new="$(blob_hash "$HEAD_SHA" "$path")"
    [ "$new" = "$old" ] && continue
    is_pinned "$new" && continue
  else
    new="deleted"
  fi
  flagged=$((flagged + 1))
  printf '%s\t%s\t%s\t%s\n' "$path" "$old" "$new" "$(pinned_in "$old")" >> "$work/flagged"
done < "$work/changes"

if [ "$flagged" -eq 0 ]; then
  printf 'native-pin-check: no file hq-cli pins changed (%s..%s)\n' "${BASE_SHA:0:12}" "${HEAD_SHA:0:12}"
  exit 0
fi

# Acknowledgement sources: the body without HTML comments or fenced code
# blocks, then every commit message in BASE..HEAD.
{
  if [ -n "$BODY_FILE" ]; then
    tr -d '\r' < "$BODY_FILE" | awk '
      {
        line = $0
        out = ""
        while (line != "") {
          if (in_comment) {
            end = index(line, "-->")
            if (end == 0) { line = ""; break }
            line = substr(line, end + 3)
            in_comment = 0
          } else {
            start = index(line, "<!--")
            if (start == 0) { out = out line; line = ""; break }
            out = out substr(line, 1, start - 1)
            line = substr(line, start + 4)
            in_comment = 1
          }
        }
        if (out ~ /^[ \t]*(```|~~~)/) { in_fence = !in_fence; next }
        if (!in_fence) print out
      }'
    printf '\n'
  fi
  git -C "$REPO" log --format='%B' "$BASE_SHA..$HEAD_SHA" || fail_input "cannot read commit messages in $BASE..$HEAD"
} > "$work/ack-sources"

PR_REF='((indigoai-us/)?hq-cli#[1-9][0-9]*|https://github\.com/indigoai-us/hq-cli/pull/[1-9][0-9]*)'
ACK_RE="^Native-pin:[[:space:]]*(pending[[:space:]]+${PR_REF}|bash-fallback[[:space:]]+[^<[:space:]][^[:space:]]*([[:space:]]+[^[:space:]]+)+)[[:space:]]*\$"
ack="$(grep -E "$ACK_RE" "$work/ack-sources" | head -1 || true)"

report() {
  while IFS=$'\t' read -r path old new where; do
    if [ "$new" = "deleted" ]; then
      printf '  %s: deleted; hq-cli pins %s (%s)\n' "$path" "${old:0:12}" "$where"
    else
      printf '  %s: hq-cli pins %s (%s)\n    new sha256 %s\n' "$path" "${old:0:12}" "$where" "$new"
    fi
  done < "$work/flagged"
}

# Workflow command property values escape %, CR, LF, ':' and ','.
annotation_value() {
  local v="$1"
  v="${v//'%'/%25}"
  v="${v//$'\r'/%0D}"
  v="${v//$'\n'/%0A}"
  v="${v//:/%3A}"
  v="${v//,/%2C}"
  printf '%s' "$v"
}

if [ -n "$ack" ]; then
  printf 'native-pin-check: %d file(s) hq-cli pins changed; acknowledged by "%s"\n' "$flagged" "$ack"
  report
  if [ -n "${GITHUB_ACTIONS:-}" ]; then
    printf '::notice title=native-pin-check::%d natively pinned file(s) changed; acknowledged: %s\n' "$flagged" "$ack"
  fi
  exit 0
fi

{
  printf 'native-pin-check: this pull request changes %d file(s) the hq-hook engine answers natively:\n' "$flagged"
  report
  cat <<'EOF'
Until hq-cli pins the new bytes, every install on this core runs these hooks
through bash. Either open the hq-cli pin pull request and add this line to the
pull request body (or a commit message):

  Native-pin: pending hq-cli#<number>

or accept the bash fallback knowingly, with the reason in words:

  Native-pin: bash-fallback <reason>
EOF
} >&2
if [ -n "${GITHUB_ACTIONS:-}" ]; then
  while IFS=$'\t' read -r path _old _new _where; do
    printf '::error file=%s,title=native-pin-check::hq-cli pins this file; add "Native-pin: pending hq-cli#<n>" or "Native-pin: bash-fallback <reason>" to the PR body\n' "$(annotation_value "$path")"
  done < "$work/flagged"
fi
exit 1
