#!/usr/bin/env bash
# Decide GitHub auto-merge for an hq-core PR opened by promote-to-hq-core.yml.
#
# Stable releases (pr_type=release, version X.Y.Z with no prerelease suffix)
# open on hold: this script applies the hold-release label, disarms any armed
# auto-merge, and never arms it. A stable release merges or tags only after an
# explicit owner go, given by removing hold-release on the current head
# (owner decision 2026-10-21, feedback 2f573b2f-e948-4416-b23d-d21b501e6c02).
# Every new head is held again, so an earlier go never carries to new code.
#
# Prerelease (-alpha/-beta/-rc) release PRs and fix PRs keep the earlier
# behavior: auto-merge is armed unless a person applied hold-release.
#
# usage:
#   release-pr-auto-merge.sh is-stable <pr_type> <version>      exit 0 if stable
#   release-pr-auto-merge.sh prepare <repo> <pr> <pr_type> <version>
#       before a push that updates an existing PR
#   release-pr-auto-merge.sh apply <repo> <pr> <pr_type> <version> <head-sha>
#       after the PR is open on the pushed head
set -euo pipefail

usage() { echo "usage: $0 is-stable|prepare|apply ..." >&2; exit 64; }
HOLD_LABEL='hold-release'

is_stable() {
  [[ "$1" == 'release' && "$2" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
}
check_target() {
  [[ "$1" == 'indigoai-us/hq-core' ]] || usage
  [[ "$2" =~ ^[0-9]+$ ]] || usage
}
pr_state() {
  gh pr view "$2" --repo "$1" --json labels,autoMergeRequest
}
is_held() { jq -e --arg l "$HOLD_LABEL" 'any(.labels[]?.name; . == $l)' <<< "$1" >/dev/null; }
is_armed() { jq -e '.autoMergeRequest != null' <<< "$1" >/dev/null; }

hold_stable() {
  local repo="$1" pr="$2" state
  state="$(pr_state "$repo" "$pr")"
  if ! is_held "$state"; then
    gh pr edit "$pr" --repo "$repo" --add-label "$HOLD_LABEL" >/dev/null
  fi
  if is_armed "$state"; then
    gh pr merge "$pr" --repo "$repo" --disable-auto
  fi
  echo "::notice::PR #${pr} is a stable release: held with ${HOLD_LABEL}, auto-merge not armed. An owner go (removing ${HOLD_LABEL}) is required to merge or tag."
}

cmd="${1:-}"; shift || true
case "$cmd" in
  is-stable)
    [[ $# -eq 2 ]] || usage
    is_stable "$1" "$2"
    ;;
  prepare)
    [[ $# -eq 4 ]] || usage
    repo="$1" pr="$2" pr_type="$3" version="$4"
    check_target "$repo" "$pr"
    if is_stable "$pr_type" "$version"; then
      hold_stable "$repo" "$pr"
      exit 0
    fi
    # Non-stable: only a held PR is disarmed before its head moves.
    state="$(pr_state "$repo" "$pr")"
    if is_held "$state" && is_armed "$state"; then
      gh pr merge "$pr" --repo "$repo" --disable-auto
      echo "::notice::PR #${pr} has ${HOLD_LABEL}; disarmed auto-merge before updating its head."
    fi
    ;;
  apply)
    [[ $# -eq 5 ]] || usage
    repo="$1" pr="$2" pr_type="$3" version="$4" sha="$5"
    check_target "$repo" "$pr"
    [[ "$sha" =~ ^[0-9a-f]{40}$ ]] || usage
    if is_stable "$pr_type" "$version"; then
      hold_stable "$repo" "$pr"
      exit 0
    fi
    state="$(pr_state "$repo" "$pr")"
    if is_held "$state"; then
      echo "::notice::PR #${pr} has ${HOLD_LABEL}; not arming auto-merge."
    elif gh pr merge "$pr" --repo "$repo" --auto --squash --match-head-commit "$sha"; then
      echo "::notice::Armed auto-merge (squash) on PR #${pr} at ${sha}."
    else
      echo "::warning::Could not arm auto-merge on PR #${pr}."
    fi
    ;;
  *) usage ;;
esac
