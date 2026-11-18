#!/usr/bin/env bash
# installed-core-check.sh: run the hq-cli installed-core check on a release tree.
#
# Usage: installed-core-check.sh <release tree> [--checker <check-function-manifest.mjs>]
#
# release.yml runs this on the release tarball after it is built, so the check
# reads the files an install receives. It runs hq-cli's
# `scripts/check-function-manifest.mjs --installed-core`, the same rules hq-cli
# applies to installed cores (US-031), and fails on any test or tooling file.
#
# The checker comes from the published hq-cli package at CHECKER_CLI_VERSION
# (npm pack, no global install). --checker points at a local copy instead.
#
# Kept paths and tooling globs are read from install-excludes.rsync, so this
# file has no second list to keep in step:
#   "+ /<path>/***" and "+ /<file>"   -> --keep (the release ships them)
#   "- /<dir>/"                       -> --tooling '<dir>/**'
#   "- /<path>"                       -> --tooling '<path>'
#   "- <dir>/" (unanchored)           -> --tooling '**/<dir>/**'
#   "- <name>" (unanchored)           -> --tooling '**/<name>'
# The unanchored rules are passed too because the checker's built-in test
# names leave some of them out (*.test.tsx, *.test.ps1, ...).
# check-staged-tree.sh stays the independent check.
#
# Exit 0: no findings. Exit 1: findings. Exit 2: invalid arguments or setup.
set -euo pipefail

# First hq-cli release with --installed-core (indigoai-us/hq-cli#2780).
CHECKER_CLI_VERSION="5.345.221"
# dist.integrity of that version on registry.npmjs.org. The packed tarball must
# match it, so a mirror or cache cannot hand the release a different checker.
CHECKER_CLI_INTEGRITY="sha512-otPNGy7qemZ290EfrMZ/ExjoVAn59F+iVA0klyxit69+egAB9V5WnTYE0pMm+b5JopWB/XR6MwpEbCYzt2TzUQ=="

usage() {
  echo "usage: installed-core-check.sh <release tree> [--checker <check-function-manifest.mjs>]" >&2
  exit 2
}

[ "$#" -ge 1 ] || usage
tree=$1
shift
checker=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --checker)
      [ "$#" -ge 2 ] || usage
      checker=$2
      shift 2
      ;;
    *) usage ;;
  esac
done
[ -d "$tree" ] || { echo "installed-core-check: $tree is not a folder" >&2; exit 2; }

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
excludes="$here/install-excludes.rsync"
[ -r "$excludes" ] || { echo "installed-core-check: cannot read $excludes" >&2; exit 2; }

tmp=$(mktemp -d "${TMPDIR:-/tmp}/installed-core-check.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

if [ -z "$checker" ]; then
  # npm pack of a registry version runs no package scripts; --ignore-scripts
  # keeps it that way. Only check-function-manifest.mjs runs from the package.
  if ! npm pack "@indigoai-us/hq-cli@${CHECKER_CLI_VERSION}" --silent --ignore-scripts --pack-destination "$tmp" > "$tmp/pack.out"; then
    echo "installed-core-check: npm pack @indigoai-us/hq-cli@${CHECKER_CLI_VERSION} failed" >&2
    exit 2
  fi
  tgz="$tmp/$(tail -n 1 "$tmp/pack.out")"
  [ -f "$tgz" ] || { echo "installed-core-check: npm pack wrote no tarball" >&2; exit 2; }
  got=$(node -e 'const c=require("crypto"),f=require("fs");process.stdout.write("sha512-"+c.createHash("sha512").update(f.readFileSync(process.argv[1])).digest("base64"))' "$tgz") \
    || { echo "installed-core-check: cannot hash $tgz" >&2; exit 2; }
  if [ "$got" != "$CHECKER_CLI_INTEGRITY" ]; then
    echo "installed-core-check: @indigoai-us/hq-cli@${CHECKER_CLI_VERSION} integrity $got does not match $CHECKER_CLI_INTEGRITY" >&2
    exit 2
  fi
  tar -xzf "$tgz" -C "$tmp" package/scripts/check-function-manifest.mjs \
    || { echo "installed-core-check: cannot unpack the checker from $tgz" >&2; exit 2; }
  checker="$tmp/package/scripts/check-function-manifest.mjs"
fi
[ -r "$checker" ] || { echo "installed-core-check: checker not found at $checker" >&2; exit 2; }

keep_file="$tmp/keep.txt"
: > "$keep_file"
tooling=()
while IFS= read -r line || [ -n "$line" ]; do
  line=${line%$'\r'}
  case "$line" in
    "+ /"*)
      path=${line#"+ /"}
      case "$path" in
        */\*\*\*) printf '%s\n' "${path%\*\*\*}" >> "$keep_file" ;;
        */) ;; # a folder rule that only lets the kept files below be reached
        *) printf '%s\n' "$path" >> "$keep_file" ;;
      esac
      ;;
    "- /"*)
      path=${line#"- /"}
      case "$path" in
        */) tooling+=(--tooling "${path}**") ;;
        *) tooling+=(--tooling "$path") ;;
      esac
      ;;
    "- "*)
      path=${line#"- "}
      case "$path" in
        */) tooling+=(--tooling "**/${path}**") ;;
        *) tooling+=(--tooling "**/${path}") ;;
      esac
      ;;
  esac
done < "$excludes"

[ -s "$keep_file" ] || { echo "installed-core-check: no kept paths read from $excludes" >&2; exit 2; }
[ "${#tooling[@]}" -gt 0 ] || { echo "installed-core-check: no tooling rules read from $excludes" >&2; exit 2; }

set +e
node "$checker" --installed-core "$tree" --keep-file "$keep_file" "${tooling[@]}" > "$tmp/checker.out" 2>&1
status=$?
set -e
cat "$tmp/checker.out"
# Node exits 1 on an uncaught error too: exit 1 counts as findings only when
# the checker printed its failure summary.
if [ "$status" -eq 1 ] && ! grep -q '^function manifest check failed: ' "$tmp/checker.out"; then
  status=3
fi
case "$status" in
  0) echo "installed-core-check: no test or tooling files in $tree" ;;
  1) echo "::error::installed-core-check: the release tree contains test or tooling files (see above)" >&2 ;;
  *) echo "installed-core-check: checker failed with exit $status" >&2; status=2 ;;
esac
exit "$status"
