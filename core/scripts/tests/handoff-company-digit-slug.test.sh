#!/usr/bin/env bash
# handoff-company-digit-slug.test.sh — company slugs may start with a digit
# (feedback_3bf6fa3a).
#
# hq-session.sh accepts any slug made of letters, digits, `-` and `_`, so a
# company folder such as companies/31-cornwallis-crescent is valid. The handoff
# scripts used `^[a-z]...` and rejected it: handoff-finalize.sh --company
# failed with "invalid or missing owner company". This test runs the finalizer
# with a digit-leading company and checks the owner check accepts it, while an
# invalid slug and a missing company folder are still refused.
#
# Explicitly wired into .github/workflows/pr-checks.yml.

set -euo pipefail

SRC_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

REPO="$TMP_ROOT/hq"
mkdir -p "$REPO/core/scripts/lib" "$REPO/companies/31-cornwallis-crescent"
cp "$SRC_ROOT/scripts/handoff-finalize.sh" "$REPO/core/scripts/handoff-finalize.sh"
cp "$SRC_ROOT/scripts/lib/session-id.sh" "$REPO/core/scripts/lib/session-id.sh"
chmod +x "$REPO/core/scripts/handoff-finalize.sh"
touch "$REPO/companies/31-cornwallis-crescent/.keep"
git -C "$REPO" init -q
git -C "$REPO" config user.email test@example.com
git -C "$REPO" config user.name "Handoff Digit Slug Test"
git -C "$REPO" add core companies
git -C "$REPO" commit -q -m init

run_finalize() { # <company> -> stderr in $TMP_ROOT/err, rc echoed
  local rc=0
  HQ_ROOT="$REPO" HQ_SESSION_ID="handoff-digit-slug-test" \
    bash "$REPO/core/scripts/handoff-finalize.sh" \
    --title "Handoff: digit slug" --summary "digit-leading company" --company "$1" \
    >"$TMP_ROOT/out" 2>"$TMP_ROOT/err" || rc=$?
  echo "$rc"
}

rc="$(run_finalize 31-cornwallis-crescent)"
grep -q 'invalid or missing owner company' "$TMP_ROOT/err" \
  && fail "digit-leading company was rejected (rc $rc): $(cat "$TMP_ROOT/err")"
echo "ok 1 digit-leading company passes the owner check (rc $rc)"

rc="$(run_finalize 'Bad Slug')"
grep -q 'invalid or missing owner company' "$TMP_ROOT/err" \
  || fail "an invalid slug must still be refused (rc $rc): $(cat "$TMP_ROOT/err")"
echo "ok 2 invalid slug still refused"

rc="$(run_finalize 42-missing)"
grep -q 'invalid or missing owner company' "$TMP_ROOT/err" \
  || fail "a company with no folder must still be refused (rc $rc): $(cat "$TMP_ROOT/err")"
echo "ok 3 missing company folder still refused"

for f in handoff-finalize.sh handoff-post.sh resumework-resolve.sh; do
  if grep -n '\[a-z\]\[a-z0-9_-\]\*' "$SRC_ROOT/scripts/$f" >/dev/null; then
    fail "$f still requires a letter-first company slug"
  fi
done
echo "ok 4 handoff scripts accept digit-leading slugs"

echo "handoff-company-digit-slug.test.sh: 4/4 passed"
