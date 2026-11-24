#!/bin/bash
# macOS: double-click (or `open`) to run tuimon in its own Terminal window.
# Resize the window (rows;cols) and set its title, then hand over to the launcher.
printf '\033[8;44;160t\033]0;tuimon\007'
sleep 0.3
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
exec "$here/tuimon" "$@"
