#!/usr/bin/env bash
# hq-core: public
# Keep the SessionStart hook fast: refresh the local access manifest at most
# once per day, outside the hook process. The server remains authoritative.
set -uo pipefail

is_hq_root() { [ -n "${1:-}" ] && [ -d "${1%/}/core" ] && [ -d "${1%/}/.claude" ]; }

ROOT="${CLAUDE_PROJECT_DIR:-}"
if ! is_hq_root "$ROOT"; then
  ROOT=""
  dir="$PWD"
  while [ -n "$dir" ] && [ "$dir" != "/" ]; do
    if is_hq_root "$dir"; then ROOT="$dir"; break; fi
    dir="$(dirname "$dir")"
  done
fi
is_hq_root "$ROOT" || exit 0

HQ_DIR="$ROOT/.hq"
MANIFEST="$HQ_DIR/vault-access.json"
if [ -f "$MANIFEST" ]; then
  NOW="$(date +%s)"
  MTIME="$(stat -c %Y "$MANIFEST" 2>/dev/null || stat -f %m "$MANIFEST" 2>/dev/null || true)"
  case "$NOW:$MTIME" in
    *[!0-9:]*|:*) exit 0 ;;
    *)
      AGE=$((NOW - MTIME))
      [ "$AGE" -lt 86400 ] && exit 0
      ;;
  esac
fi

mkdir -p "$HQ_DIR" || exit 0
# hq core refresh-vault-access needs hq-cli >= 5.307.0. A missing or older hq
# fails in the detached child with the floor message, as the forwarder did.
nohup bash -c '. "$1/core/scripts/lib/hq-cli-floor.sh" && hq_cli_floor_check refresh-vault-access.sh 5.307.0 && exec hq core refresh-vault-access --root "$1"' \
  refresh-vault-access "$ROOT" >> "$HQ_DIR/vault-access-refresh.log" 2>&1 < /dev/null &
exit 0
