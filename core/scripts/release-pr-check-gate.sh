#!/usr/bin/env bash
# Gate hq-core release merges on every check and commit status for the exact PR head.
# This script runs in hq-core-staging's trusted promotion workflow with the
# hq-audit-bot installation token. It polls hq-core; its own staging workflow
# checks are outside the target repository's PR check list.
set -euo pipefail

usage() {
  echo "usage: $0 <owner/repo> <pr-number> <head-sha> [max-wait-seconds] [poll-seconds]" >&2
  exit 64
}
fail() { echo "::error::$*" >&2; exit 1; }
[[ $# -ge 3 && $# -le 5 ]] || usage
TARGET_REPO="$1"
PR_NUMBER="$2"
EXPECTED_SHA="$3"
MAX_WAIT_SECONDS="${4:-600}"
POLL_SECONDS="${5:-30}"
[[ "$TARGET_REPO" == 'indigoai-us/hq-core' ]] || usage
[[ "$PR_NUMBER" =~ ^[0-9]+$ ]] || usage
[[ "$EXPECTED_SHA" =~ ^[0-9a-f]{40}$ ]] || usage
[[ "$MAX_WAIT_SECONDS" =~ ^[0-9]+$ && "$POLL_SECONDS" =~ ^[0-9]+$ ]] || usage

pr_info="$(gh pr view "$PR_NUMBER" --repo "$TARGET_REPO" --json headRefOid,autoMergeRequest,labels)"
actual_sha="$(jq -r '.headRefOid // empty' <<< "$pr_info")"
[[ "$actual_sha" == "$EXPECTED_SHA" ]] || fail "PR #$PR_NUMBER head changed before gate: expected $EXPECTED_SHA, found ${actual_sha:-missing}."

has_hold_label() {
  jq -e 'any(.labels[]?.name; . == "hold-release")' <<< "$1" >/dev/null
}
disable_auto_merge_if_armed() {
  local info="$1"
  if jq -e '.autoMergeRequest != null' <<< "$info" >/dev/null; then
    gh pr merge "$PR_NUMBER" --repo "$TARGET_REPO" --disable-auto
  fi
}

if has_hold_label "$pr_info"; then
  disable_auto_merge_if_armed "$pr_info"
  echo "::notice::hold-release is present on hq-core PR #$PR_NUMBER; the release gate will not merge it."
  exit 0
fi
# Disable legacy auto-merge before polling so required checks cannot merge the
# PR independently of this all-check gate.
disable_auto_merge_if_armed "$pr_info"

check_pages_file=''
status_pages_file=''
cleanup_check_pages() {
  [[ -z "$check_pages_file" ]] || rm -f -- "$check_pages_file"
  [[ -z "$status_pages_file" ]] || rm -f -- "$status_pages_file"
}
trap cleanup_check_pages EXIT
check_pages_file="$(mktemp)"
status_pages_file="$(mktemp)"

started_at="$SECONDS"
while :; do
  gh api --paginate --slurp "repos/${TARGET_REPO}/commits/${EXPECTED_SHA}/check-runs?per_page=100" > "$check_pages_file"
  gh api --paginate --slurp "repos/${TARGET_REPO}/commits/${EXPECTED_SHA}/statuses?per_page=100" > "$status_pages_file"
  report="$(jq -n --slurpfile check_pages "$check_pages_file" --slurpfile status_pages "$status_pages_file" '
    [ $check_pages[0][]? | .check_runs[]? ] as $runs
    | [ $status_pages[0][]? | if type == "array" then .[] else .statuses[]? end ] as $status_history
    | ($status_history | group_by(.context) | map(max_by(.created_at))) as $statuses
    | {
        check_count: ($runs | length),
        status_count: ($statuses | length),
        retryable: (
          [$runs[] | select(.status == "completed") | . as $run
            | select((["cancelled", "stale"] | index($run.conclusion)) != null)
            | ((.name // ("check-run " + (.id|tostring))) + " (" + .conclusion + ")")]
        ),
        pending: (
          [$runs[] | select(.status != "completed") | (.name // ("check-run " + (.id|tostring)))]
          + [$statuses[] | select(.state == "pending") | .context]
        ),
        failed: (
          [$runs[] | select(.status == "completed") | . as $run
            | select(( ["success", "skipped", "neutral", "cancelled", "stale"] | index($run.conclusion) ) == null)
            | ((.name // ("check-run " + (.id|tostring))) + " (" + (.conclusion // "missing conclusion") + ")")]
          + [$statuses[] | select(.state != "success") | (.context + " (" + (.state // "missing state") + ")")]
        )
      }
  ')"
  failed="$(jq -r '.failed | join("\n")' <<< "$report")"
  retryable="$(jq -r '.retryable | join("\n")' <<< "$report")"
  if [[ -n "$failed" ]]; then
    latest_info="$(gh pr view "$PR_NUMBER" --repo "$TARGET_REPO" --json headRefOid,autoMergeRequest,labels)"
    latest_sha="$(jq -r '.headRefOid // empty' <<< "$latest_info")"
    if [[ "$latest_sha" != "$EXPECTED_SHA" ]]; then
      echo "::notice::PR #$PR_NUMBER head moved from $EXPECTED_SHA to ${latest_sha:-missing}; no hold-release added for checks on the superseded head. The new head will be gated by its run."
      exit 0
    fi
    if has_hold_label "$latest_info"; then
      disable_auto_merge_if_armed "$latest_info"
      fail "Refusing to merge hq-core PR #$PR_NUMBER; failing or non-accepted checks on $EXPECTED_SHA: ${failed//$'\n'/; }. hold-release was already present."
    fi
    gh pr edit "$PR_NUMBER" --repo "$TARGET_REPO" --add-label hold-release
    latest_info="$(gh pr view "$PR_NUMBER" --repo "$TARGET_REPO" --json headRefOid,autoMergeRequest,labels)"
    latest_sha="$(jq -r '.headRefOid // empty' <<< "$latest_info")"
    if [[ "$latest_sha" != "$EXPECTED_SHA" ]]; then
      if has_hold_label "$latest_info"; then
        gh pr edit "$PR_NUMBER" --repo "$TARGET_REPO" --remove-label hold-release
      fi
      echo "::notice::PR #$PR_NUMBER head moved from $EXPECTED_SHA to ${latest_sha:-missing} after hold-release was applied; removed the hold so the new head's checks can gate the release."
      exit 0
    fi
    fail "Refusing to merge hq-core PR #$PR_NUMBER; failing or non-accepted checks on $EXPECTED_SHA: ${failed//$'\n'/; }. Added hold-release."
  fi

  if [[ -n "$retryable" ]]; then
    latest_info="$(gh pr view "$PR_NUMBER" --repo "$TARGET_REPO" --json headRefOid,autoMergeRequest,labels)"
    latest_sha="$(jq -r '.headRefOid // empty' <<< "$latest_info")"
    if [[ "$latest_sha" != "$EXPECTED_SHA" ]]; then
      echo "::notice::PR #$PR_NUMBER head moved from $EXPECTED_SHA to ${latest_sha:-missing}; no hold-release added for cancelled or stale checks on the superseded head. The new head will be gated by its run."
      exit 0
    fi
    fail "Retrying hq-core PR #$PR_NUMBER checks on current head $EXPECTED_SHA; cancelled or stale checks are retryable and do not add hold-release: ${retryable//$'\n'/; }. The scheduled recheck will retry."
  fi

  pending="$(jq -r '.pending | join(", ")' <<< "$report")"
  check_count="$(jq -r '.check_count' <<< "$report")"
  status_count="$(jq -r '.status_count' <<< "$report")"
  if (( check_count + status_count > 0 )) && [[ -z "$pending" ]]; then
    latest_info="$(gh pr view "$PR_NUMBER" --repo "$TARGET_REPO" --json headRefOid,autoMergeRequest,labels)"
    latest_sha="$(jq -r '.headRefOid // empty' <<< "$latest_info")"
    [[ "$latest_sha" == "$EXPECTED_SHA" ]] || fail "PR #$PR_NUMBER head changed during check polling; refusing to merge stale SHA $EXPECTED_SHA."
    if has_hold_label "$latest_info"; then
      disable_auto_merge_if_armed "$latest_info"
      echo "::notice::hold-release was added while checks ran for hq-core PR #$PR_NUMBER; not merging."
      exit 0
    fi
    disable_auto_merge_if_armed "$latest_info"
    gh pr merge "$PR_NUMBER" --repo "$TARGET_REPO" --squash --match-head-commit "$EXPECTED_SHA"
    echo "::notice::Merged hq-core PR #$PR_NUMBER after every check and status on $EXPECTED_SHA completed successfully."
    exit 0
  fi

  elapsed=$((SECONDS - started_at))
  if (( elapsed >= MAX_WAIT_SECONDS )); then
    # Still-pending checks are retryable; terminal timed_out conclusions are
    # classified as failures above. The scheduled workflow checks again.
    fail "Timed out waiting for hq-core PR #$PR_NUMBER checks on $EXPECTED_SHA; still pending: ${pending:-no checks/statuses observed}. Scheduled recheck will retry."
  fi
  sleep "$POLL_SECONDS"
done
