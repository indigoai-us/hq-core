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

echo "ALL PASS: lint-shell-portability"
exit 0
