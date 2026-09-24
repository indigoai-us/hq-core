#!/usr/bin/env bash
# hq-core: public
# parse-release-tag.sh — resolve a `v<semver>` tag from a push to hq-core main.
#
# Used by .github/workflows/auto-tag-release.yml. Squash-merge of a
# `release: v<semver>` PR keeps the existing head-subject path. Merge-commit
# merges (GitHub "Create a merge commit") put `Merge pull request #N from …`
# on HEAD, so this script then reads the second parent's subject or the
# associated PR title (`gh api repos/<repo>/commits/<sha>/pulls`).
#
# Usage:
#   parse-release-tag.sh [--subject MSG] [--sha SHA] [--repo OWNER/REPO]
#                        [--parent2-subject SUBJECT] [--pr-title TITLE]
#                        [--is-merge] [--no-fetch]
#
# Env (GitHub Actions defaults):
#   MSG / RELEASE_SUBJECT   head commit message (full; first line is the subject)
#   GITHUB_SHA              head commit SHA (needed for merge-commit fetch)
#   GITHUB_REPOSITORY       owner/repo
#   GITHUB_OUTPUT           if set, also appends match=/tag=/source= here
#   GH_TOKEN / GITHUB_TOKEN used by `gh api` on the merge-commit path
#
# Stdout (and GITHUB_OUTPUT):
#   match=true|false
#   tag=vX.Y.Z              (match=true only)
#   source=head|parent2|pr  (match=true only)
#
# Exit 0 always for parse outcomes (including "not a release"). Exit 2 on
# usage errors. Network failures on the merge fallback are treated as no-match,
# not a job failure — a missed tag is recoverable; a red workflow on every
# non-release push to main is not.

set -euo pipefail

SUBJECT="${MSG:-${RELEASE_SUBJECT:-}}"
SHA="${GITHUB_SHA:-}"
REPO="${GITHUB_REPOSITORY:-}"
PARENT2_SUBJECT=""
PR_TITLE=""
IS_MERGE=0
NO_FETCH=0

usage() {
  echo "usage: parse-release-tag.sh [--subject MSG] [--sha SHA] [--repo OWNER/REPO] [--parent2-subject SUBJECT] [--pr-title TITLE] [--is-merge] [--no-fetch]" >&2
  exit 2
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --subject)
      [ "$#" -ge 2 ] || usage
      SUBJECT="$2"
      shift 2
      ;;
    --sha)
      [ "$#" -ge 2 ] || usage
      SHA="$2"
      shift 2
      ;;
    --repo)
      [ "$#" -ge 2 ] || usage
      REPO="$2"
      shift 2
      ;;
    --parent2-subject)
      [ "$#" -ge 2 ] || usage
      PARENT2_SUBJECT="$2"
      IS_MERGE=1
      shift 2
      ;;
    --pr-title)
      [ "$#" -ge 2 ] || usage
      PR_TITLE="$2"
      shift 2
      ;;
    --is-merge)
      IS_MERGE=1
      shift
      ;;
    --no-fetch)
      NO_FETCH=1
      shift
      ;;
    -h|--help)
      usage
      ;;
    --)
      shift
      break
      ;;
    -*)
      echo "parse-release-tag: unknown flag: $1" >&2
      usage
      ;;
    *)
      echo "parse-release-tag: unexpected argument: $1" >&2
      usage
      ;;
  esac
done

# Same anchored pattern the workflow used inline: `release: v<semver>` with
# optional prerelease and optional squash-merge ` (#123)` suffix.
RELEASE_SUBJECT_RE='^release: v[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.]+)?( \(#[0-9]+\))?$'

first_line() {
  printf '%s' "$1" | awk 'NR==1 { sub(/\r$/, ""); print; exit }'
}

trim() {
  printf '%s' "$1" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}

# Prints the semver (no leading v) and returns 0, or returns 1.
version_from_subject() {
  local s
  s="$(trim "$(first_line "$1")")"
  if printf '%s' "$s" | grep -Eq "$RELEASE_SUBJECT_RE"; then
    printf '%s' "$s" | sed -E 's/^release: v([0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.]+)?).*/\1/'
    return 0
  fi
  return 1
}

emit_match() {
  local tag="$1" source="$2"
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    {
      echo "match=true"
      echo "tag=${tag}"
      echo "source=${source}"
    } >> "$GITHUB_OUTPUT"
  fi
  echo "match=true"
  echo "tag=${tag}"
  echo "source=${source}"
  echo "::notice::Release commit detected (${source}) → will tag ${tag}"
}

emit_nomatch() {
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    echo "match=false" >> "$GITHUB_OUTPUT"
  fi
  echo "match=false"
  echo "::notice::Head commit subject is not 'release: v<semver>'; no tag created."
}

gh_api() {
  # Swallow gh failures: a missing commit or preview-header 404 must not
  # fail the auto-tag job on ordinary (non-release) pushes.
  gh api "$@" 2>/dev/null || true
}

HEAD_SUBJECT="$(trim "$(first_line "$SUBJECT")")"
echo "head commit subject: ${HEAD_SUBJECT}"

VER=""
if VER="$(version_from_subject "$HEAD_SUBJECT")"; then
  emit_match "v${VER}" "head"
  exit 0
fi

# Merge-commit fallback. Squash / rebase / ordinary commits stop here unless
# the caller already marked this SHA as a merge (tests) or we can see two
# parents via the GitHub API.
if [ "$NO_FETCH" -eq 0 ] && [ "$IS_MERGE" -eq 0 ] && [ -n "$SHA" ] && [ -n "$REPO" ]; then
  parent_count="$(gh_api "repos/${REPO}/commits/${SHA}" --jq '.parents | length')"
  case "$parent_count" in
    ''|*[!0-9]*) parent_count=0 ;;
  esac
  if [ "$parent_count" -ge 2 ]; then
    IS_MERGE=1
    if [ -z "$PARENT2_SUBJECT" ]; then
      parent2_sha="$(gh_api "repos/${REPO}/commits/${SHA}" --jq '.parents[1].sha // empty')"
      if [ -n "$parent2_sha" ]; then
        PARENT2_SUBJECT="$(gh_api "repos/${REPO}/commits/${parent2_sha}" --jq '.commit.message' | awk 'NR==1 { sub(/\r$/, ""); print; exit }')"
      fi
    fi
  fi
fi

if [ "$IS_MERGE" -eq 1 ]; then
  if VER="$(version_from_subject "$PARENT2_SUBJECT")"; then
    emit_match "v${VER}" "parent2"
    exit 0
  fi
  if [ "$NO_FETCH" -eq 0 ] && [ -z "$PR_TITLE" ] && [ -n "$SHA" ] && [ -n "$REPO" ]; then
    # Prefer a merged PR when GitHub returns several associations.
    PR_TITLE="$(gh_api "repos/${REPO}/commits/${SHA}/pulls" --jq '([.[] | select(.merged_at != null) | .title] | .[0]) // (.[0].title // empty)')"
  fi
  if VER="$(version_from_subject "$PR_TITLE")"; then
    emit_match "v${VER}" "pr"
    exit 0
  fi
fi

emit_nomatch
exit 0
