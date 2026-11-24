#!/usr/bin/env bash
# scaffold.sh: copy the tui-monitor template into a new folder under a new name.
#
# Usage:
#   bash .claude/skills/tui-monitor/scripts/scaffold.sh <dest-dir> <name>
#
# Example:
#   bash .claude/skills/tui-monitor/scripts/scaffold.sh personal/tools/boxmon boxmon
#
# <name> is lower case letters, digits and dashes, starting with a letter. The
# template's placeholder name "tuimon" (and "TUIMON" in environment variable
# names) becomes <name> in file names and file contents. The config file path
# follows: ~/.config/<name>/hosts. Refuses to write into a non-empty folder.
set -euo pipefail

if [ "$#" -ne 2 ]; then
  sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'
  exit 64
fi
dest="$1"
name="$2"
case "$name" in
  [a-z]*) ;;
  *) echo "scaffold: name must start with a lower case letter" >&2; exit 64 ;;
esac
if ! printf '%s' "$name" | grep -Eq '^[a-z][a-z0-9-]*$'; then
  echo "scaffold: name may hold only lower case letters, digits and dashes" >&2
  exit 64
fi
if [ -e "$dest" ] && [ -n "$(ls -A "$dest" 2>/dev/null)" ]; then
  echo "scaffold: $dest exists and is not empty" >&2
  exit 73
fi

src="$(cd "$(dirname "${BASH_SOURCE[0]}")/../template" && pwd -P)"
upper="$(printf '%s' "$name" | tr 'a-z-' 'A-Z_')"
mkdir -p "$dest"
for f in "$src"/*; do
  base="$(basename "$f")"
  out="$dest/${base//tuimon/$name}"
  sed -e "s/tuimon/$name/g" -e "s/TUIMON/$upper/g" "$f" > "$out"
  if [ -x "$f" ]; then chmod +x "$out"; fi
done
echo "scaffolded $name in $dest:"
ls -1 "$dest"
