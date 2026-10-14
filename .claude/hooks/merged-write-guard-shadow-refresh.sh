#!/usr/bin/env bash
# Refresh the shadow-only hq-flags snapshot once at session start.
# Each session gets its own marker; flag changes are observed on the next SessionStart.
set -uo pipefail
export BASH_ENV=/dev/null
INPUT=""
while IFS= read -r line; do INPUT+="$line"; done
HOOK_SOURCE="${BASH_SOURCE[0]}"
case "$HOOK_SOURCE" in */*) ;; *) HOOK_SOURCE="./$HOOK_SOURCE" ;; esac
HOOK_DIR="${HOOK_SOURCE%/*}"
HOOK_ROOT="$(cd "$HOOK_DIR/../.." 2>/dev/null && pwd -P)" || exit 0
node "$HOOK_ROOT/.claude/hooks/merged-write-guard-shadow.cjs" --refresh <<< "$INPUT" || :
exit 0
