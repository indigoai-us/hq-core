#!/usr/bin/env bash
# hq-core: public
# Regression test for feedback_2827d720: keep the onboarding sentence correctly spelled.
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
GUIDE="$ROOT/core/docs/hq/USER-GUIDE.md"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

grep -qF 'take you from installation through your first shared worker' "$GUIDE" \
  || fail "USER-GUIDE onboarding sentence must spell installation correctly"

if grep -qF 'instalation' "$GUIDE"; then
  fail "USER-GUIDE contains the misspelling 'instalation'"
fi

echo "user-guide-spelling.test.sh: all checks passed"
