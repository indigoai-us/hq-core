#!/usr/bin/env bash
# resolve-hook-perf-base.sh — print the base commit the master-hook process
# budget tests compare against, and make sure it exists locally.
#
# pr-checks.yml used to pass `github.event.pull_request.base.sha ||
# github.event.before` straight into `git fetch`. On workflow_dispatch (and
# schedule) both are empty, the fetch ran with an empty ref, and the budget
# tests failed with "HQ_HOOK_PERF_BASE_SHA or origin/main merge base is
# required" because actions/checkout had only one commit (hq-core-staging PR
# 1605, run 39802011996).
#
# Usage: resolve-hook-perf-base.sh <repo-root>
# Env:   HQ_HOOK_PERF_BASE_SHA     event base sha; empty on manual runs
#        HQ_HOOK_PERF_BASE_REMOTE  default origin
#        HQ_HOOK_PERF_BASE_BRANCH  default main
#
# With a sha: fetch it if missing and print it. Without one: fetch the default
# branch, deepen both sides until a merge base exists, print the merge base.
# Exit 2 when no base can be found; never print an empty line.
set -euo pipefail

root="${1:?usage: resolve-hook-perf-base.sh <repo-root>}"
base="${HQ_HOOK_PERF_BASE_SHA:-}"
remote="${HQ_HOOK_PERF_BASE_REMOTE:-origin}"
branch="${HQ_HOOK_PERF_BASE_BRANCH:-main}"

die() { echo "resolve-hook-perf-base: $*" >&2; exit 2; }

if [[ -n "$base" ]]; then
  [[ "$base" =~ ^[0-9a-f]{40}$ ]] || die "HQ_HOOK_PERF_BASE_SHA is not a 40-hex commit sha"
  if ! git -C "$root" cat-file -e "$base^{commit}" 2>/dev/null; then
    timeout 60s git -C "$root" fetch --quiet --no-tags --depth=1 "$remote" "$base" \
      || die "could not fetch base commit $base from $remote"
  fi
  printf '%s\n' "$base"
  exit 0
fi

# No event base: manual dispatch or schedule. Compare against the default
# branch's merge base, deepening the shallow checkout until one exists.
head_sha="$(git -C "$root" rev-parse HEAD)"
timeout 60s git -C "$root" fetch --quiet --no-tags --depth=1 "$remote" "$branch" \
  || die "could not fetch $remote/$branch"
branch_sha="$(git -C "$root" rev-parse FETCH_HEAD)"

depth=1
while ! base="$(git -C "$root" merge-base "$head_sha" "$branch_sha" 2>/dev/null)"; do
  depth=$((depth * 4))
  (( depth <= 1024 )) || die "no merge base between HEAD and $remote/$branch within 1024 commits"
  timeout 120s git -C "$root" fetch --quiet --no-tags --deepen="$depth" "$remote" "$branch" "$head_sha" \
    || die "could not deepen history from $remote"
done

[[ "$base" =~ ^[0-9a-f]{40}$ ]] || die "merge base is not a commit sha"
printf '%s\n' "$base"
