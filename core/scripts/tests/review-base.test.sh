#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
. "$ROOT/core/scripts/tests/lib/review-base.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
unset GITHUB_EVENT_NAME GITHUB_EVENT_PATH GITHUB_BASE_REF
repo="$TMP/repo"
git init -q --initial-branch=fixture-base "$repo"
git -C "$repo" config user.email test@example.invalid
git -C "$repo" config user.name Test
printf 'base\n' > "$repo/guard"
git -C "$repo" add guard
git -C "$repo" commit -qm base
base="$(git -C "$repo" rev-parse HEAD)"
git -C "$repo" update-ref refs/remotes/origin/main "$base"
git -C "$repo" checkout -qb feature
printf 'feature\n' > "$repo/feature"
git -C "$repo" add feature
git -C "$repo" commit -qm feature
[ "$(hq_test_review_base "$repo")" = "$base" ] # no local main
# An unrelated local main must neither break the suite nor replace origin's base.
other="$(printf 'unrelated\n' | git -C "$repo" commit-tree "$(git -C "$repo" rev-parse HEAD^{tree})")"
git -C "$repo" update-ref refs/heads/main "$other"
# Reproduce the old resolver: rev-parse succeeds but merge-base returns 1.
git -C "$repo" rev-parse --verify "main^{commit}" >/dev/null
if git -C "$repo" merge-base HEAD main >/dev/null; then
  echo "FAIL: stale unrelated main did not reproduce the original failure" >&2; exit 1
fi
[ "$(hq_test_review_base "$repo")" = "$base" ]
# Immutable PR base wins even if the remote branch has advanced onto the feature.
git -C "$repo" update-ref refs/remotes/origin/main HEAD
printf '{"pull_request":{"base":{"sha":"%s"}}}\n' "$base" > "$TMP/event.json"
export GITHUB_EVENT_NAME=pull_request GITHUB_EVENT_PATH="$TMP/event.json"
[ "$(hq_test_review_base "$repo")" = "$base" ]
# Changed legacy source is still detected against the PR base, never skipped.
printf 'changed\n' > "$repo/guard"
git -C "$repo" add guard
git -C "$repo" commit -qm changed-guard
if git -C "$repo" diff --quiet "$(hq_test_review_base "$repo")" HEAD -- guard; then
  echo 'FAIL: legacy guard change escaped comparison' >&2; exit 1
fi
printf '{}\n' > "$TMP/event.json"
if hq_test_review_base "$repo" >/dev/null 2>&1; then echo 'FAIL: missing PR base accepted' >&2; exit 1; fi
printf '{"pull_request":{"base":{"sha":"%040d"}}}\n' 0 > "$TMP/event.json"
if hq_test_review_base "$repo" >/dev/null 2>&1; then echo 'FAIL: unavailable PR base accepted' >&2; exit 1; fi
unset GITHUB_EVENT_NAME GITHUB_EVENT_PATH
git -C "$repo" update-ref -d refs/remotes/origin/main
if hq_test_review_base "$repo" >/dev/null 2>&1; then echo 'FAIL: unrelated-only local main accepted' >&2; exit 1; fi
git -C "$repo" update-ref refs/heads/main "$base"
[ "$(hq_test_review_base "$repo")" = "$base" ]
echo 'PASS: review base missing/stale local, exact PR, missing history and guard mutation cases'
