#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
HELPER="${SESSION_JOURNAL:-$ROOT/core/scripts/session-journal.sh}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
title=$'Alpha\nBeta'

# A Windows Git Bash process reports OSTYPE=msys even with MSYSTEM removed,
# and Win32 cannot create the POSIX newline filename. POSIX bytes are exercised
# on Linux/macOS; the Windows job exercises the actual MSYS filename path.
case "${OSTYPE:-}" in
  msys*|cygwin*) ;;
  *)
    posix_root="$TMP/posix"
    mkdir -p "$posix_root"
    posix_path="$(env -u MSYSTEM HQ_ROOT="$posix_root" bash "$HELPER" write "$title")"
    [[ "${posix_path##*/}" == $'001-alpha\nbeta.md' ]] || { printf "FAIL: POSIX slug bytes changed: %q\n" "${posix_path##*/}" >&2; exit 1; }
    [[ -f "$posix_path" ]]
    ;;
esac

msys_root="$TMP/msys"
mkdir -p "$msys_root"
msys_path="$(MSYSTEM=MINGW64 HQ_ROOT="$msys_root" bash "$HELPER" write "$title")"
[[ "${msys_path##*/}" == "001-alpha-beta.md" ]] || { printf "FAIL: MSYS slug did not remove newline: %q\n" "${msys_path##*/}" >&2; exit 1; }
[[ -f "$msys_path" ]]

echo "session-journal newline slug: POSIX byte behavior and MSYS filename behavior"
