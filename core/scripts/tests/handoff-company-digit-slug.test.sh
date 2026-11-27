#!/usr/bin/env bash
# handoff-company-digit-slug.test.sh — company slugs may start with a digit
# (feedback_3bf6fa3a).
#
# hq-session.sh accepts any slug made of letters, digits, `-` and `_`, so a
# company folder such as companies/31-cornwallis-crescent is valid. Verify
# resumework-resolve.sh does not require a letter-first company slug.
#
# Explicitly wired into .github/workflows/pr-checks.yml.

set -euo pipefail

SRC_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

if grep -n '\[a-z\]\[a-z0-9_-\]\*' "$SRC_ROOT/scripts/resumework-resolve.sh" >/dev/null; then
  fail "resumework-resolve.sh still requires a letter-first company slug"
fi
echo "ok 1 resumework-resolve.sh accepts digit-leading slugs"

echo "handoff-company-digit-slug.test.sh: 1/1 passed"
