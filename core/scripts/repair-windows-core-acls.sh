#!/usr/bin/env bash
# repair-windows-core-acls.sh — reset NTFS DENY ACEs on HQ core files.
#
# Git Bash/MSYS chmod maps POSIX modes onto NTFS using DENY ACEs. On some
# Windows checkouts that leaves the owner unable to read a subset of core/
# files (POSIX ls still shows -rw-r--r--). This script is hook-independent
# and sources nothing from core/, so it still runs when check-hq-hooks.sh
# itself is unreadable.
#
# Usage:
#   bash core/scripts/repair-windows-core-acls.sh [--root <hq-root>]
#
# No-op on non-Windows hosts (exit 0).

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: repair-windows-core-acls.sh [--root <hq-root>]

Resets NTFS ACLs on core/ and .claude/hooks so Windows Git Bash DENY ACEs
cannot hide HQ files from their owner. Safe to re-run. No-op off Windows.
EOF
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
HQ_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd -P)"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --root)
      [ "$#" -ge 2 ] || { echo "--root requires a path" >&2; usage >&2; exit 64; }
      HQ_ROOT="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "unknown argument: $1" >&2
      usage >&2
      exit 64
      ;;
  esac
done

if [ ! -d "$HQ_ROOT" ]; then
  echo "repair-windows-core-acls: HQ root does not exist: $HQ_ROOT" >&2
  exit 2
fi
HQ_ROOT="$(cd "$HQ_ROOT" && pwd -P)"

is_windows=0
case "${OSTYPE:-}" in msys*|cygwin*|win32*) is_windows=1 ;; esac
if [ "$is_windows" -eq 0 ]; then
  case "$(uname -s 2>/dev/null || true)" in MINGW*|MSYS*|CYGWIN*) is_windows=1 ;; esac
fi
if [ "$is_windows" -eq 0 ]; then
  echo "repair-windows-core-acls: not Windows; nothing to do"
  exit 0
fi

if ! command -v icacls >/dev/null 2>&1; then
  echo "repair-windows-core-acls: icacls not on PATH" >&2
  exit 2
fi

native_path() {
  if command -v cygpath >/dev/null 2>&1; then
    cygpath -w "$1" 2>/dev/null || printf '%s' "$1"
  else
    printf '%s' "$1"
  fi
}

user="${USERNAME:-${USER:-}}"
if [ -z "$user" ]; then
  echo "repair-windows-core-acls: USERNAME is empty" >&2
  exit 2
fi

repaired=0
failed=0
for rel in core .claude/hooks; do
  dir="$HQ_ROOT/$rel"
  [ -d "$dir" ] || continue
  native="$(native_path "$dir")"
  icacls "$native" /reset /T /C /Q >/dev/null 2>&1 || true
  icacls "$native" /remove:d "$user" /T /C /Q >/dev/null 2>&1 || true
  if icacls "$native" /grant:r "${user}:(OI)(CI)(RX)" /T /C /Q >/dev/null 2>&1; then
    repaired=$((repaired + 1))
  else
    echo "repair-windows-core-acls: icacls grant failed for $rel" >&2
    failed=$((failed + 1))
  fi
done

unreadable=0
for rel in core .claude/hooks; do
  dir="$HQ_ROOT/$rel"
  [ -d "$dir" ] || continue
  while IFS= read -r f || [ -n "$f" ]; do
    [ -n "$f" ] || continue
    if [ ! -r "$f" ]; then
      echo "repair-windows-core-acls: still unreadable: ${f#"$HQ_ROOT"/}" >&2
      unreadable=$((unreadable + 1))
    fi
  done <<EOF
$(find "$dir" -type f 2>/dev/null || true)
EOF
done

if [ "$unreadable" -gt 0 ] || [ "$failed" -gt 0 ]; then
  echo "repair-windows-core-acls: FAIL ($unreadable file(s) still unreadable)" >&2
  echo "  Run from Command Prompt as the HQ owner:" >&2
  echo "    icacls \"$(native_path "$HQ_ROOT/core")\" /reset /T /C /Q" >&2
  echo "    icacls \"$(native_path "$HQ_ROOT/core")\" /grant:r \"%USERNAME%:(OI)(CI)(RX)\" /T" >&2
  exit 2
fi

echo "repair-windows-core-acls: PASS (reset $repaired tree(s) for $user)"
exit 0
