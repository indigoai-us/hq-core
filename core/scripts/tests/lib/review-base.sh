#!/usr/bin/env bash
# Test-only baseline resolver. Never trust an arbitrary local main over the PR base.
hq_test_review_base() {
  local root="$1" ref="${GITHUB_BASE_REF:-main}" candidate='' base=''
  if [ "${GITHUB_EVENT_NAME:-}" = pull_request ] || [ "${GITHUB_EVENT_NAME:-}" = pull_request_target ]; then
    candidate="$(jq -er '.pull_request.base.sha | select(type == "string")' "${GITHUB_EVENT_PATH:-/nonexistent}" 2>/dev/null)" || {
      echo 'review base: pull-request event has no base SHA' >&2; return 1;
    }
    case "$candidate" in *[!0-9a-fA-F]*|'') echo 'review base: invalid pull-request base SHA' >&2; return 1 ;; esac
    [ "${#candidate}" -eq 40 ] || { echo 'review base: invalid pull-request base SHA length' >&2; return 1; }
  elif git -C "$root" rev-parse --verify "refs/remotes/origin/$ref^{commit}" >/dev/null 2>&1; then
    candidate="refs/remotes/origin/$ref"
  else
    candidate="refs/heads/$ref"
  fi
  base="$(git -C "$root" merge-base HEAD "$candidate")" || {
    echo "review base: cannot find common ancestor for HEAD and $candidate; fetch the exact review history" >&2
    return 1
  }
  [ -n "$base" ] || return 1
  printf '%s\n' "$base"
}
