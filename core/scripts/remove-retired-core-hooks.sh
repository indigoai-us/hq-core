#!/usr/bin/env bash
# hq-core: public
# remove-retired-core-hooks.sh — delete core hook files that a release retired
# but `hq rescue` left on disk.
#
# Usage: remove-retired-core-hooks.sh [hq-root] [--check]
#
# `hq rescue` keeps any file the new release no longer ships, so a retired
# core/hooks/<event>/*.sh leaf keeps running from master-hook.sh after the
# update that removed it. The retired Stop leaf 70-work-mesh-done.sh made a
# synchronous network report on every turn end (median ~14 s on affected
# installs) after US-010 replaced it with the enqueue-only
# 70-work-mesh-turn-end.sh.
#
# The retired files are the entries of core/functions.yaml whose state is
# removed and that carry released_sha256. A file is removed only when its
# sha256 matches one of those released copies. Carriage returns are stripped
# before hashing, so a CRLF checkout of a released copy still matches. A file
# with any other content is a local edit: it is reported and kept. A removed
# entry with no released_sha256 is never deleted by this script.
#
# The manifest is read from the release this script ships in (the folder above
# this script). If it cannot be read, or lists no removed file with a released
# sha256, nothing is removed and the script exits 1.
#
# A file is removed only when its folder is the physical folder its manifest
# path names under HQ_ROOT (core/hooks[/<event>], core/scripts, .codex[/hooks]).
# If a folder on that path is a symlink that resolves somewhere else
# (personal/, a company folder), the file is reported as "kept (outside
# <folder>)" and left alone.
#
# The retired Stop leaves in the manifest must match the skip list in
# .claude/hooks/master-hook.sh; remove-retired-core-hooks.test.sh checks that.
#
# The .codex entries are the legacy Codex hook layer (hooks.json plus per-hook
# .sh copies and hook-gate.sh) that predates hq-codex-hook-adapter.sh. Codex
# now runs the adapter from .codex/config.toml, which dispatches .claude/hooks.
# The legacy files were never in git; the sums are of the copies found on
# installs that still carry them. Shipped .codex files (the adapter,
# deny-core-edits.sh, the .cjs guards, hq-codex-hook.cmd) are never listed.
#
# The same legacy entries can sit in the user's Codex hooks file
# (${CODEX_HOME:-$HOME/.codex}/hooks.json); see the section near the end.
#
# --check  remove nothing; print each retired file (and the count of retired
#          Codex hook entries) still present and exit 1 when one is found.
# --list   print the retired list (path, space, sha256 of a released copy; one
#          line per released copy) and exit. Touches nothing.
#
# Exit status in default mode: 0, or 1 when a removal failed or the manifest
# could not be read.
set -uo pipefail
# cd prints the folder when CDPATH matches, which would corrupt the
# physical-path comparison below.
unset CDPATH

HQ_ROOT=""
CHECK=0
LIST=0
for arg in "$@"; do
  case "$arg" in
    --check) CHECK=1 ;;
    --list) LIST=1 ;;
    *) HQ_ROOT="$arg" ;;
  esac
done

# path <space> sha256 of a released copy, one line per released copy, read
# from the removed entries of the function manifest. An entry is one line:
#   - {"id": "<path>", ..., "state": "removed", ..., "released_sha256": ["<sha256>", ...]}
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
MANIFEST="${HQ_FUNCTION_MANIFEST:-$SCRIPT_DIR/../functions.yaml}"
retired_from_manifest() {
  awk '
    /"state": "removed"/ && /"released_sha256": \[/ {
      line = $0
      if (!match(line, /"id": "[^"]+"/)) next
      id = substr(line, RSTART + 7, RLENGTH - 8)
      # Only a path inside the HQ root: never absolute, never through "..".
      if (id ~ /^\// || id ~ /(^|\/)\.\.(\/|$)/ || id ~ /[ \t\r]/ || index(id, "\\") > 0) next
      if (!match(line, /"released_sha256": \[[^]]*\]/)) next
      list = substr(line, RSTART + 20, RLENGTH - 21)
      n = split(list, sums, /[^0-9a-f]+/)
      for (i = 1; i <= n; i++) if (length(sums[i]) == 64) print id " " sums[i]
    }
  ' "$1"
}
load_retired() {
  if [ ! -r "$MANIFEST" ] || ! RETIRED="$(retired_from_manifest "$MANIFEST")"; then
    echo "remove-retired-core-hooks: cannot read the function manifest ($MANIFEST); nothing removed" >&2
    exit 1
  fi
  if [ -z "$RETIRED" ]; then
    echo "remove-retired-core-hooks: the function manifest ($MANIFEST) lists no removed file with a released sha256; nothing removed" >&2
    exit 1
  fi
}
if [ "$LIST" -eq 1 ]; then
  load_retired
  [ -z "$RETIRED" ] || printf '%s\n' "$RETIRED"
  exit 0
fi

HQ_ROOT="${HQ_ROOT:-${CLAUDE_PROJECT_DIR:-$(pwd)}}"
[ -d "$HQ_ROOT/core" ] || exit 0
ROOT_PHYS="$(cd -P "$HQ_ROOT" 2>/dev/null && pwd -P)" || exit 0
load_retired

# sha256 of the file with carriage returns removed.
sha256_of() {
  if command -v shasum >/dev/null 2>&1; then
    tr -d '\r' < "$1" 2>/dev/null | shasum -a 256 | cut -c1-64
  elif command -v sha256sum >/dev/null 2>&1; then
    tr -d '\r' < "$1" 2>/dev/null | sha256sum | cut -c1-64
  fi
}

found=0
failed=0
seen=" "
# Retired paths whose file matched a released copy (removed, or reported by
# --check as one the default run removes).
matched=" "
while read -r rel _; do
  [ -n "$rel" ] || continue
  case "$seen" in *" $rel "*) continue ;; esac
  seen="$seen$rel "
  file="$HQ_ROOT/$rel"
  [ -f "$file" ] && [ ! -L "$file" ] || continue
  parent_phys="$(cd -P "${file%/*}" 2>/dev/null && pwd -P)"
  if [ "$parent_phys" != "$ROOT_PHYS/${rel%/*}" ]; then
    echo "remove-retired-core-hooks: kept $rel (outside ${rel%/*}: its folder resolves to ${parent_phys:-an unreadable path})" >&2
    continue
  fi
  sum="$(sha256_of "$file")"
  [ -n "$sum" ] || continue
  if ! printf '%s\n' "$RETIRED" | grep -qxF "$rel $sum"; then
    echo "remove-retired-core-hooks: kept $rel (local edits; HQ no longer runs it, delete it by hand)" >&2
    continue
  fi
  found=1
  matched="$matched$rel "
  if [ "$CHECK" -eq 1 ]; then
    echo "remove-retired-core-hooks: retired file present: $rel"
  elif rm -f "$file" && [ ! -e "$file" ]; then
    echo "remove-retired-core-hooks: removed $rel"
  else
    failed=1
    echo "remove-retired-core-hooks: could not remove $rel; delete it by hand" >&2
  fi
done <<EOF
$RETIRED
EOF

# The legacy Codex layer could also be registered in the user's Codex hooks
# file (${CODEX_HOME:-$HOME/.codex}/hooks.json). Codex loads that file in every
# session, so inside this HQ root each legacy hook ran next to the adapter from
# .codex/config.toml. Remove only entries in the legacy gate form that point at
# this HQ root:
#   '<HQ_ROOT>/.codex/hooks/hook-gate.sh' <id> '<HQ_ROOT>/.codex/hooks/<id>.sh'
# where <id>.sh is one of the retired .codex/hooks scripts on the list above.
# Every other entry (the user's own hooks, including the user's own scripts in
# .codex/hooks/ run through hook-gate.sh, `hq install --global` adapter or
# shim entries, other HQ roots) is kept. A backup of the file is written under
# workspace/.hq-update-check/settings-backups/ before it is rewritten. If the
# file cannot be parsed when it is rewritten (another tool changed it after
# the count), the clean pass exits non-zero and nothing is written.
CODEX_HOOKS="${CODEX_HOME:-${HOME:-}/.codex}/hooks.json"
# Basenames of the retired legacy hook scripts (hook-gate.sh itself excluded).
RETIRED_CODEX_SCRIPTS="$(printf '%s\n' "$RETIRED" | sed -n 's#^\.codex/hooks/\([A-Za-z0-9._-]*\.sh\) .*#\1#p' | grep -vxF hook-gate.sh | sort -u | tr '\n' ' ')"
# Of those, the scripts whose hooks.json entries may go. A retired script that
# is still on disk after the file pass above (kept for local edits, a symlink,
# a folder outside .codex/hooks, or a failed removal) keeps its entry, so a
# user-edited copy keeps running. With --check nothing was removed, so a
# released copy the default run removes counts as gone.
CODEX_ENTRY_SCRIPTS=""
for name in $RETIRED_CODEX_SCRIPTS; do
  script="$HQ_ROOT/.codex/hooks/$name"
  if [ -e "$script" ] || [ -L "$script" ]; then
    [ "$CHECK" -eq 1 ] || continue
    case "$matched" in *" .codex/hooks/$name "*) ;; *) continue ;; esac
  fi
  CODEX_ENTRY_SCRIPTS="$CODEX_ENTRY_SCRIPTS$name "
done
CODEX_NODE_PROG='
const fs = require("fs");
const [file, mode, names, ...rawRoots] = process.argv.slice(1);
const retired = new Set(String(names || "").split(/\s+/).filter(Boolean));
const roots = [...new Set(rawRoots.filter(Boolean).map((r) => r.replace(/\/+$/, "")))];
const tokens = (s) => (s.match(/"[^"]*"|\u0027[^\u0027]*\u0027|\S+/g) || [])
  .map((t) => t.replace(/^"(.*)"$/s, "$1").replace(/^\u0027(.*)\u0027$/s, "$1"));
const legacy = (h) => {
  if (!h || typeof h !== "object" || h.type !== "command" || typeof h.command !== "string") return false;
  let t = tokens(h.command);
  if (["bash", "sh", "/bin/bash", "/bin/sh"].includes(t[0])) t = t.slice(1);
  if (t.length !== 3 || !/^[A-Za-z0-9._-]+$/.test(t[1])) return false;
  const script = t[1] + ".sh";
  if (!retired.has(script)) return false;
  return roots.some((r) => t[0] === r + "/.codex/hooks/hook-gate.sh"
    && t[2] === r + "/.codex/hooks/" + script);
};
// count: print 0 for a file that is not a hooks object. clean: exit 2 so the
// caller writes nothing (the file changed after the count pass).
const unusable = () => {
  if (mode === "count") { process.stdout.write("0"); process.exit(0); }
  process.exit(2);
};
let d;
try { d = JSON.parse(fs.readFileSync(file, "utf8")); } catch (_) { unusable(); }
if (!d || typeof d !== "object" || Array.isArray(d) || !d.hooks || typeof d.hooks !== "object" || Array.isArray(d.hooks)) {
  unusable();
}
let n = 0;
for (const [event, groups] of Object.entries(d.hooks)) {
  if (!Array.isArray(groups)) continue;
  const kept = groups.flatMap((g) => {
    if (!g || typeof g !== "object" || !Array.isArray(g.hooks)) return [g];
    const hooks = g.hooks.filter((h) => !legacy(h));
    n += g.hooks.length - hooks.length;
    if (hooks.length === g.hooks.length) return [g];
    return hooks.length ? [{ ...g, hooks }] : [];
  });
  if (kept.length) d.hooks[event] = kept; else delete d.hooks[event];
}
if (mode === "count") { process.stdout.write(String(n)); process.exit(0); }
if (Object.keys(d.hooks).length === 0) delete d.hooks;
process.stdout.write(Object.keys(d).length === 0 ? "" : JSON.stringify(d, null, 2) + "\n");
'
CODEX_NODE="$(command -v node 2>/dev/null || true)"
# The rewrite goes through a temp file next to hooks.json. Remove it on any
# exit, including an interrupt, so no stray copy is left beside the file.
tmp=""
trap '[ -z "$tmp" ] || rm -f "$tmp" 2>/dev/null' EXIT
trap 'exit 130' INT TERM HUP
if [ -f "$CODEX_HOOKS" ] && [ ! -L "$CODEX_HOOKS" ] && grep -q 'hook-gate\.sh' "$CODEX_HOOKS" 2>/dev/null; then
  if [ -z "$CODEX_NODE" ]; then
    echo "remove-retired-core-hooks: kept legacy entries in $CODEX_HOOKS (node is not installed; remove the hook-gate.sh entries by hand)" >&2
  else
    n="$("$CODEX_NODE" -e "$CODEX_NODE_PROG" "$CODEX_HOOKS" count "$CODEX_ENTRY_SCRIPTS" "$HQ_ROOT" "$ROOT_PHYS" 2>/dev/null | tr -dc '0-9')"
    if [ -n "$n" ] && [ "$n" -gt 0 ]; then
      found=1
      if [ "$CHECK" -eq 1 ]; then
        echo "remove-retired-core-hooks: retired Codex hook entries present: $n in $CODEX_HOOKS"
      else
        stamp="$(date -u +%Y%m%dT%H%M%SZ 2>/dev/null || echo now)-$$"
        backup_dir="$HQ_ROOT/workspace/.hq-update-check/settings-backups/$stamp"
        tmp="$CODEX_HOOKS.hq-retired-tmp.$$"
        if mkdir -p "$backup_dir" 2>/dev/null \
          && cp -p "$CODEX_HOOKS" "$backup_dir/codex-hooks.json" 2>/dev/null \
          && cp -p "$CODEX_HOOKS" "$tmp" 2>/dev/null \
          && "$CODEX_NODE" -e "$CODEX_NODE_PROG" "$CODEX_HOOKS" clean "$CODEX_ENTRY_SCRIPTS" "$HQ_ROOT" "$ROOT_PHYS" > "$tmp" 2>/dev/null \
          && if [ -s "$tmp" ]; then
               # Re-parse what was written before it replaces hooks.json.
               "$CODEX_NODE" -e 'JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"))' "$tmp" 2>/dev/null \
                 && mv "$tmp" "$CODEX_HOOKS" 2>/dev/null
             else
               rm -f "$tmp" "$CODEX_HOOKS" 2>/dev/null
             fi; then
          echo "remove-retired-core-hooks: removed $n retired Codex hook entries from $CODEX_HOOKS (backup: workspace/.hq-update-check/settings-backups/$stamp/codex-hooks.json)"
        else
          rm -f "$tmp" 2>/dev/null
          tmp=""
          failed=1
          echo "remove-retired-core-hooks: could not clean $CODEX_HOOKS; remove its hook-gate.sh entries by hand" >&2
        fi
      fi
    fi
  fi
fi

[ "$CHECK" -eq 1 ] && [ "$found" -eq 1 ] && exit 1
[ "$failed" -eq 1 ] && exit 1
exit 0
