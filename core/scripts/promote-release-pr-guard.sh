#!/usr/bin/env bash
# promote-release-pr-guard.sh - decide whether a promote dispatch may update
# the hq-core release branch it targets.
#
# Usage: promote-release-pr-guard.sh <target-repo> <branch> <force:true|false>
#
# Promote runs only on workflow_dispatch, so each update of a release PR is a
# deliberate release cut. Rules:
#   - No open PR for <branch>: proceed (a new release PR is opened).
#   - Open PR labelled hold-release: refuse, always, even with force=true. A
#     person removes the hold before a new release head is cut.
#   - Open PR that is approved: refuse unless force=true. A new head dismisses
#     the approval and restarts every hq-core check.
#   - Otherwise: proceed and update the open PR in place.
# Exit 0 = proceed, 3 = refused, other = error. Writes `existing=<n>` (empty
# when no PR is open) to $GITHUB_OUTPUT when that variable is set.
set -euo pipefail
REPO="${1:?target repo required}"
BRANCH="${2:?branch required}"
FORCE="${3:-false}"
OUT="${GITHUB_OUTPUT:-/dev/null}"

EXISTING="$(gh pr list --repo "$REPO" --head "$BRANCH" --state open --json number --jq '.[0].number // empty')"
if [ -z "$EXISTING" ]; then
  echo "No open hq-core PR for ${BRANCH}; a new release PR will be opened."
  echo "existing=" >> "$OUT"
  exit 0
fi
echo "existing=${EXISTING}" >> "$OUT"

STATE="$(gh pr view "$EXISTING" --repo "$REPO" --json labels,reviewDecision,latestReviews \
  --jq '[(any(.labels[]?.name; . == "hold-release")), ((.reviewDecision == "APPROVED") or any(.latestReviews[]?.state; . == "APPROVED"))] | map(tostring) | join(" ")')"
read -r HELD APPROVED <<< "$STATE"
case "$HELD:$APPROVED" in
  true:true|true:false|false:true|false:false) ;;
  *) echo "::error::Could not read the state of hq-core PR #${EXISTING} (got '${STATE}'). Refusing to update it."; exit 3 ;;
esac

if [ "$HELD" = "true" ]; then
  echo "::error::hq-core PR #${EXISTING} (${BRANCH}) has hold-release. Refusing to update it. Remove the label, then dispatch again."
  exit 3
fi
if [ "$APPROVED" = "true" ]; then
  if [ "$FORCE" = "true" ]; then
    echo "::warning::hq-core PR #${EXISTING} (${BRANCH}) is approved; force=true, so its head will be replaced. The approval is dismissed and hq-core checks restart."
    exit 0
  fi
  echo "::error::hq-core PR #${EXISTING} (${BRANCH}) is already open and approved. Refusing to replace its head. Merge it, or dispatch again with force=true to replace it (this dismisses the approval and restarts checks)."
  exit 3
fi
echo "hq-core PR #${EXISTING} (${BRANCH}) is open, not approved and not held; it will be updated in place."
