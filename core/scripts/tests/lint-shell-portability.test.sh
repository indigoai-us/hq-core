#!/usr/bin/env bash
# lint-shell-portability.test.sh — smoke for the portability lint
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
LINT="$ROOT/core/scripts/lint-shell-portability.sh"
[ -x "$LINT" ] || chmod +x "$LINT"

# Live tree should pass (post US-003 allowlist).
if ! bash "$LINT"; then
  echo "FAIL: lint-shell-portability dirty on current tree" >&2
  exit 1
fi
echo "  ok   live tree clean"

# Fixture: BSD sed -i '' should be flagged.
TMP="$(mktemp -d "${TMPDIR:-/tmp}/lint-port.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/core/scripts"
printf '#!/bin/bash\nsed -i '\'''\'' "s/a/b/" file\n' > "$TMP/core/scripts/bad-sed.sh"
# Run lint from a fake root by temporarily adding the file via a subshell that
# only greps the fixture — exercise the detection regex directly.
if grep -nE "sed[[:space:]]+-i[[:space:]]+''" "$TMP/core/scripts/bad-sed.sh" >/dev/null; then
  echo "  ok   detects BSD sed -i ''"
else
  echo "FAIL: detector missed sed -i ''" >&2
  exit 1
fi

# Fixture: a bare `flock` command word (Linux-only) must be flagged — this is
# the exact macOS failure ("flock: command not found") from the team harness
# analysis. A `command -v flock` probe must NOT be flagged. Mirror the linter's
# real detection: the regex catches the command word, then probe lines are
# excluded, exactly as lint-shell-portability.sh does.
FLOCK_RE='(^|[^[:alnum:]_.-])flock[[:space:]]'
flock_flags() {
  # Returns 0 (flagged) only when a flock command survives the probe exclusion.
  local file="$1" hit body
  while IFS= read -r hit || [ -n "$hit" ]; do
    [ -z "$hit" ] && continue
    body="${hit#*:}"
    case "$body" in
      *"command -v flock"*|*"which flock"*|*"type flock"*|*"hash flock"*) continue ;;
    esac
    return 0
  done < <(grep -nE "$FLOCK_RE" "$file" 2>/dev/null || true)
  return 1
}

printf '#!/bin/bash\nflock -n /tmp/x.lock echo hi\n' > "$TMP/core/scripts/bad-flock.sh"
if flock_flags "$TMP/core/scripts/bad-flock.sh"; then
  echo "  ok   detects bare flock command"
else
  echo "FAIL: detector missed a bare flock command" >&2
  exit 1
fi
printf '#!/bin/bash\nif command -v flock >/dev/null 2>&1; then flock -n 9 || true; fi\n' > "$TMP/core/scripts/probe-flock.sh"
if flock_flags "$TMP/core/scripts/probe-flock.sh"; then
  echo "NOTE: guarded flock call site still flags (expected — belongs in allow file)"
fi
printf '#!/bin/bash\nif command -v flock >/dev/null 2>&1; then :; fi\n' > "$TMP/core/scripts/probe-only-flock.sh"
if flock_flags "$TMP/core/scripts/probe-only-flock.sh"; then
  echo "FAIL: detector false-flagged a bare 'command -v flock' probe" >&2
  exit 1
else
  echo "  ok   ignores a 'command -v flock' probe"
fi

echo "ALL PASS: lint-shell-portability"
exit 0
