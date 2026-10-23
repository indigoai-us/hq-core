#!/usr/bin/env bash
# resolve-hook-perf-base.test.sh — the master-hook budget steps must get a real
# base commit on workflow_dispatch, where the event carries no base sha.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/../../.." && pwd)"
resolver="$repo_root/core/scripts/ci/resolve-hook-perf-base.sh"
workflow="$repo_root/.github/workflows/pr-checks.yml"

fail() { echo "FAIL: $*" >&2; exit 1; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

gitq() { git -c user.name=t -c user.email=t@example.invalid -c init.defaultBranch=main "$@"; }

# Origin: main with 6 commits, feature branched at main~2 with 3 commits.
origin="$tmp/origin"
gitq init -q "$origin"
for i in 1 2 3 4 5 6; do
  echo "$i" > "$origin/f"; gitq -C "$origin" add f; gitq -C "$origin" commit -q -m "main $i"
done
gitq -C "$origin" checkout -q -b feature main~2
for i in 1 2 3; do
  echo "feature $i" > "$origin/g"; gitq -C "$origin" add g; gitq -C "$origin" commit -q -m "feature $i"
done
expected_base="$(gitq -C "$origin" merge-base main feature)"
head_main="$(gitq -C "$origin" rev-parse main)"
gitq -C "$origin" checkout -q main

# Shallow checkout of the feature tip, the way actions/checkout leaves a
# workflow_dispatch run: one commit, no origin/main.
work="$tmp/work"
gitq clone -q --depth 1 --no-tags --branch feature "file://$origin" "$work"
[[ "$(gitq -C "$work" rev-list --count HEAD)" == 1 ]] || fail "fixture is not shallow"

# 1. Empty base sha (workflow_dispatch): resolver finds the merge base.
got="$(HQ_HOOK_PERF_BASE_SHA= bash "$resolver" "$work")"
[[ "$got" == "$expected_base" ]] || fail "expected merge base $expected_base, got '$got'"
gitq -C "$work" cat-file -e "$got^{commit}" || fail "merge base is not available locally"

# 2. Explicit base sha (pull_request): echoed back and fetched when missing.
work2="$tmp/work2"
gitq clone -q --depth 1 --no-tags --branch feature "file://$origin" "$work2"
got="$(HQ_HOOK_PERF_BASE_SHA="$head_main" bash "$resolver" "$work2")"
[[ "$got" == "$head_main" ]] || fail "explicit base not echoed: '$got'"
gitq -C "$work2" cat-file -e "$head_main^{commit}" || fail "explicit base was not fetched"

# 3. A malformed base sha is an error, not a silent fallback.
set +e
HQ_HOOK_PERF_BASE_SHA="not-a-sha" bash "$resolver" "$work2" >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" == 2 ]] || fail "malformed base should exit 2, got $rc"

# 4. Every step that takes its base from the event payload (empty on
#    workflow_dispatch) routes through the resolver instead of fetching the
#    raw value. Steps with a pinned literal sha are allowed to fetch directly.
bad="$(awk '
  /HQ_HOOK_PERF_BASE_SHA: \$\{\{ github\.event\./ { armed = NR }
  armed && NR - armed <= 8 && /fetch .*"\$HQ_HOOK_PERF_BASE_SHA"/ { print NR }
' "$workflow")"
[[ -z "$bad" ]] || fail "pr-checks.yml line(s) $bad fetch the event base sha directly (empty on workflow_dispatch)"
n="$(grep -c 'core/scripts/ci/resolve-hook-perf-base.sh' "$workflow" || true)"
[[ "$n" -ge 2 ]] || fail "expected both master-hook budget steps to call resolve-hook-perf-base.sh, found $n"

echo "PASS: resolve-hook-perf-base (4 cases)"
