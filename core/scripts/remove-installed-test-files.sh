#!/usr/bin/env bash
# hq-core: public
# remove-installed-test-files.sh — take the release's test and build tooling
# files out of an existing install.
#
# Usage: remove-installed-test-files.sh [hq-root] [--check] [--checker <file>]
#                                       [--backup-dir <dir>]
#
# Releases leave the test tree and the CI, build and release tooling out of the
# install (the rules are in release-install-excludes.rsync beside this script,
# a copy of the release's .github/release/install-excludes.rsync). An install
# made or updated before that still holds them, and `hq rescue` on an older
# `hq` keeps copying them in. /update-hq runs this script after rescue.
#
# The files to take out are the findings of hq-cli's installed-core check
# (`scripts/check-function-manifest.mjs --installed-core`, hq 5.345.221 or
# newer), the same check the release runs on its tarball, with the kept paths
# and tooling rules read from release-install-excludes.rsync. Only the
# release-owned trees core/, .claude/, .codex/, .grok/ and .agents/ are
# scanned. Never touched:
#   - every other top-level folder or file of the HQ root (.git, companies,
#     repos, personal, workspace, .hq state, the user's own folders, and a
#     root test/ or tests/ folder, which may be the user's);
#   - installed packs under core/packages/ (other than hq-pack-cowork, which
#     the release ships), company or pack skills (.claude/skills/<a>:<b>), the
#     company skill wrappers and every node_modules folder;
#   - *.test.mts / *.test.cts files, which the release rules do not exclude;
#   - the test-named files a shipped script runs (the "+" rules);
#   - a symlink, and any file whose folder resolves outside its own path under
#     the HQ root (a linked personal or company folder). These are reported as
#     kept.
# Files are moved, never deleted: each goes to the backup folder under its
# path relative to the HQ root (default ~/.hq/backups/update-hq-test-files-
# <UTC time>), so a local edit can be restored. Folders left empty by a move
# are removed.
#
# --check       move nothing; list each file the default run moves.
# --checker     the check-function-manifest.mjs to use (default: the one in
#               the global @indigoai-us/hq-cli package).
# --backup-dir  where moved files go.
#
# Exit status: 0 when no test or tooling file is left (other than kept links);
# 1 when --check found files, a move failed, or files are still reported after
# the moves; 2 when the check cannot run (no node, no checker, no rules file).
set -uo pipefail
unset CDPATH

HQ_ROOT=""
CHECK=0
CHECKER=""
BACKUP=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --check) CHECK=1; shift ;;
    --checker) [ "$#" -ge 2 ] || { echo "remove-installed-test-files: --checker needs a file" >&2; exit 2; }; CHECKER=$2; shift 2 ;;
    --backup-dir) [ "$#" -ge 2 ] || { echo "remove-installed-test-files: --backup-dir needs a folder" >&2; exit 2; }; BACKUP=$2; shift 2 ;;
    -*) echo "remove-installed-test-files: unknown option $1" >&2; exit 2 ;;
    *) HQ_ROOT=$1; shift ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
RULES="${HQ_INSTALL_EXCLUDES:-$SCRIPT_DIR/release-install-excludes.rsync}"
HQ_ROOT="${HQ_ROOT:-${CLAUDE_PROJECT_DIR:-$(pwd)}}"
[ -d "$HQ_ROOT/core" ] || { echo "remove-installed-test-files: $HQ_ROOT has no core folder" >&2; exit 2; }
ROOT_PHYS="$(cd -P "$HQ_ROOT" 2>/dev/null && pwd -P)" || { echo "remove-installed-test-files: cannot read $HQ_ROOT" >&2; exit 2; }
[ -r "$RULES" ] || { echo "remove-installed-test-files: cannot read the rules file $RULES" >&2; exit 2; }
command -v node >/dev/null 2>&1 || { echo "remove-installed-test-files: node is not on PATH; nothing moved" >&2; exit 2; }
if [ -z "$CHECKER" ]; then
  npm_root="$(npm root -g 2>/dev/null || true)"
  CHECKER="$npm_root/@indigoai-us/hq-cli/scripts/check-function-manifest.mjs"
fi
[ -r "$CHECKER" ] || { echo "remove-installed-test-files: the installed-core check is not available ($CHECKER is missing; it ships with hq 5.345.221 or newer); nothing moved" >&2; exit 2; }

tmp="$(mktemp -d "${TMPDIR:-/tmp}/remove-installed-test-files.XXXXXX")" || exit 2
trap 'rm -rf "$tmp"' EXIT

# Only the release-owned trees are scanned: core/, .claude/, .codex/, .grok/
# and .agents/. Every other top-level entry of the HQ root (company, repo,
# personal and workspace folders, the user's own folders and files) is kept
# whole. Inside the scanned trees, installed packs, company or pack skills, the
# company skill wrappers, every node_modules folder and the "+" rules are kept.
# Tooling globs: the "-" rules (as installed-core-check.sh reads them for the
# release).
# The kept paths are collected NUL-separated in keep0, so any folder name
# (one starting with "#" or a space, or holding a newline) stays one exact
# entry. The checker's --keep-file reads one entry per line, trims it and skips
# "#" lines, so only names that survive that go into keep.txt; it is a hint
# that keeps the checker's report short. The authoritative filter is keep0,
# applied to the checker's findings below.
keep0="$tmp/keep0"
keep="$tmp/keep.txt"
: > "$keep0"
for e in "$HQ_ROOT"/* "$HQ_ROOT"/.[!.]* "$HQ_ROOT"/..?*; do
  [ -e "$e" ] || [ -L "$e" ] || continue
  name=${e##*/}
  case "$name" in core|.claude|.codex|.grok|.agents) [ -d "$e" ] && [ ! -L "$e" ] && continue ;; esac
  if [ -d "$e" ] && [ ! -L "$e" ]; then printf '%s/\0' "$name" >> "$keep0"; else printf '%s\0' "$name" >> "$keep0"; fi
done
printf '%s\0' .claude/skills/.hq-company-skill-wrappers/ >> "$keep0"
for tree in core .claude .codex .grok .agents; do
  [ -d "$HQ_ROOT/$tree" ] && [ ! -L "$HQ_ROOT/$tree" ] || continue
  find "$HQ_ROOT/$tree" -type d -name node_modules -prune -print0 | while IFS= read -r -d '' d; do
    printf '%s/\0' "${d#"$HQ_ROOT"/}"
  done >> "$keep0"
done
for d in "$HQ_ROOT"/core/packages/*/; do
  [ -d "$d" ] || continue
  name=${d%/}; name=${name##*/}
  [ "$name" = "hq-pack-cowork" ] || printf 'core/packages/%s/\0' "$name" >> "$keep0"
done
for d in "$HQ_ROOT"/.claude/skills/*:*/; do
  [ -d "$d" ] || continue
  name=${d%/}; name=${name##*/}
  printf '.claude/skills/%s/\0' "$name" >> "$keep0"
done
set --
while IFS= read -r line || [ -n "$line" ]; do
  line=${line%$'\r'}
  case "$line" in
    "+ /"*)
      path=${line#"+ /"}
      case "$path" in
        */\*\*\*) printf '%s\0' "${path%\*\*\*}" >> "$keep0" ;;
        */) ;;
        *) printf '%s\0' "$path" >> "$keep0" ;;
      esac ;;
    "- /"*)
      path=${line#"- /"}
      case "$path" in */) set -- "$@" --tooling "${path}**" ;; *) set -- "$@" --tooling "$path" ;; esac ;;
    "- "*)
      path=${line#"- "}
      case "$path" in */) set -- "$@" --tooling "**/${path}**" ;; *) set -- "$@" --tooling "**/${path}" ;; esac ;;
  esac
done < "$RULES"
[ "$#" -gt 0 ] || { echo "remove-installed-test-files: no rules read from $RULES" >&2; exit 2; }
node -e '
  const fs = require("fs");
  const safe = fs.readFileSync(process.argv[1], "utf8").split("\0").filter(Boolean)
    .filter((k) => !/[\r\n\\]/.test(k) && k === k.trim() && !k.startsWith("#"));
  fs.writeFileSync(process.argv[2], safe.map((k) => k + "\n").join(""));
' "$keep0" "$keep" || { echo "remove-installed-test-files: could not write the keep list; nothing moved" >&2; exit 2; }

# findings <out>: one relative path per line; exit 0 clean, 1 findings, 2 error.
findings() {
  node "$CHECKER" --installed-core "$HQ_ROOT" --keep-file "$keep" "$@" --json > "$tmp/check.json" 2> "$tmp/check.err"
  local status=$?
  if [ "$status" -gt 1 ] || ! node -e '
    const fs = require("fs");
    const r = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
    const keep = fs.readFileSync(process.argv[3], "utf8").split("\0").filter(Boolean);
    const keepDirs = keep.filter((k) => k.endsWith("/"));
    const keepExact = new Set(keep.filter((k) => !k.endsWith("/")));
    const out = [];
    for (const p of r.problems || []) {
      if (p.rule !== "installed-test-file" && p.rule !== "installed-tooling-file") { console.error(p.message); process.exit(3); }
      // Exact keep entries, whatever the folder name holds.
      if (keepExact.has(p.file) || keepDirs.some((d) => p.file.startsWith(d))) continue;
      // The release rules do not leave out *.test.mts / *.test.cts, so a file
      // with that name may be a shipped one: never move it.
      if (/\.(test|spec)\.(mts|cts)$/.test(p.file)) continue;
      out.push(p.file);
    }
    // NUL-separated, so no file name can split into other paths.
    fs.writeFileSync(process.argv[2], out.map((f) => f + "\0").join(""));
  ' "$tmp/check.json" "$tmp/files.txt" "$keep0"; then
    cat "$tmp/check.err" >&2
    echo "remove-installed-test-files: the installed-core check failed${FINDINGS_PHASE:-; nothing moved}" >&2
    exit 2
  fi
}
findings "$@"

# A path is movable when it is a regular file and every folder on its path is
# the physical folder of that name under the HQ root (no linked folder).
movable() {
  local rel=$1 file="$HQ_ROOT/$1" parent_phys
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  case "$rel" in */*) parent_phys="$(cd -P "$HQ_ROOT/${rel%/*}" 2>/dev/null && pwd -P)" || return 1
    [ "$parent_phys" = "$ROOT_PHYS/${rel%/*}" ] || return 1 ;; esac
  return 0
}

total=0; kept=0; moved=0; failed=0
while IFS= read -r -d '' rel; do
  [ -n "$rel" ] || continue
  total=$((total + 1))
  if ! movable "$rel"; then
    kept=$((kept + 1))
    echo "remove-installed-test-files: kept $rel (a link, or its folder is linked elsewhere)" >&2
    continue
  fi
  if [ "$CHECK" -eq 1 ]; then
    echo "would move: $rel"
    continue
  fi
  [ -n "$BACKUP" ] || BACKUP="$HOME/.hq/backups/update-hq-test-files-$(date -u +%Y%m%dT%H%M%SZ)"
  dest="$BACKUP/$rel"
  if mkdir -p "${dest%/*}" && mv "$HQ_ROOT/$rel" "$dest"; then
    moved=$((moved + 1))
    d="$HQ_ROOT/${rel%/*}"
    while [ "$d" != "$HQ_ROOT" ] && [ "$d" != "$HQ_ROOT/core" ] && rmdir "$d" 2>/dev/null; do d=${d%/*}; done
  else
    failed=$((failed + 1))
    echo "remove-installed-test-files: could not move $rel" >&2
  fi
done < "$tmp/files.txt"

if [ "$CHECK" -eq 1 ]; then
  movable_count=$((total - kept))
  echo "remove-installed-test-files: $movable_count test or tooling file(s) to move, $kept kept"
  [ "$movable_count" -eq 0 ] && exit 0
  exit 1
fi

echo "remove-installed-test-files: moved $moved test or tooling file(s)${BACKUP:+ to $BACKUP}, $kept kept, $failed failed"
[ "$failed" -eq 0 ] || exit 1
# The same check again: only the kept links may remain.
FINDINGS_PHASE=" after the moves (see the backup folder)"
findings "$@"
left=$(tr -cd '\0' < "$tmp/files.txt" | wc -c | tr -d ' ')
if [ "$left" -gt "$kept" ]; then
  echo "remove-installed-test-files: $left test or tooling file(s) still installed" >&2
  exit 1
fi
if [ "$kept" -gt 0 ]; then
  echo "remove-installed-test-files: installed-core check clean except $kept kept link(s)"
else
  echo "remove-installed-test-files: installed-core check clean"
fi
exit 0
