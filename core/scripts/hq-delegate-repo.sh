#!/usr/bin/env bash
# hq-core: public
# hq-delegate-repo.sh — code/branch handover for a delegation: make sure the
# project's branch exists on the remote, record uncommitted work as NOT
# transferred, and verify the recipient's repository access read-only.
#
# Usage:
#   core/scripts/hq-delegate-repo.sh --manifest <path> [--yes] [--github-user <login>]
#
# Behavior (driven by the manifest's repo{} block; no-op when repo is null):
#   - records remote URL and the branch's headSha into the manifest
#   - a branch that exists only locally requires confirmation: without --yes
#     the helper prints the plan and exits 2; with --yes it pushes via an
#     explicitly anchored `git -C <abs path> push -u origin <branch>`
#   - dirty/untracked files are captured into repo.dirtyFiles[] and appended
#     to BRIEF.md as work NOT transferred — never silently dropped
#   - recipient access is checked read-only via gh when --github-user is
#     given; otherwise (or on a gh failure) repo.accessVerified stays false
#     and the brief says so plainly — the helper never claims unverified access
#   - never touches vaultPrefixes[] and never pushes repo content to the vault
#
# Env: HQ_ROOT — HQ root override (default: resolved from script location)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HQ_ROOT="${HQ_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"

usage() { sed -n '3,22p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }
die()   { echo "hq-delegate-repo: $*" >&2; exit 1; }

command -v jq >/dev/null 2>&1 || die "jq is required but not installed"

MANIFEST="" YES=0 GH_USER=""
while [ $# -gt 0 ]; do
  case "$1" in
    --manifest)    MANIFEST="${2:-}"; shift 2 ;;
    --yes)         YES=1; shift ;;
    --github-user) GH_USER="${2:-}"; shift 2 ;;
    -h|--help)     usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[ -n "$MANIFEST" ] || die "--manifest is required"
[ -f "$MANIFEST" ] || die "manifest not found: $MANIFEST"
jq -e . "$MANIFEST" >/dev/null 2>&1 || die "manifest is not valid JSON: $MANIFEST"

BUNDLE_DIR="$(cd "$(dirname "$MANIFEST")" && pwd)"
BRIEF="$BUNDLE_DIR/BRIEF.md"

# --- no-repo projects skip cleanly -------------------------------------------

if jq -e '.repo == null' "$MANIFEST" >/dev/null; then
  echo "hq-delegate-repo: project has no repoPath — nothing to hand over"
  exit 0
fi

REPO_REL="$(jq -r '.repo.path // empty' "$MANIFEST")"
BRANCH="$(jq -r '.repo.branch // empty' "$MANIFEST")"
[ -n "$REPO_REL" ] || die "manifest repo block has no path"

REPO_DIR="$HQ_ROOT/$REPO_REL"
[ -d "$REPO_DIR/.git" ] || git -C "$REPO_DIR" rev-parse --git-dir >/dev/null 2>&1 \
  || die "not a git repository: $REPO_DIR"

REMOTE_URL="$(git -C "$REPO_DIR" remote get-url origin 2>/dev/null || true)"

# --- dirty / untracked work is recorded, never dropped -----------------------

DIRTY_JSON="$(git -C "$REPO_DIR" status --porcelain | sed 's/^...//' | jq -R . | jq -cs .)"

# --- branch state -------------------------------------------------------------

BRANCH_PUSHED=false HEAD_SHA=""
if [ -n "$BRANCH" ]; then
  LOCAL_SHA="$(git -C "$REPO_DIR" rev-parse --verify --quiet "refs/heads/$BRANCH" || true)"
  REMOTE_SHA="$(git -C "$REPO_DIR" rev-parse --verify --quiet "refs/remotes/origin/$BRANCH" || true)"

  if [ -n "$REMOTE_SHA" ]; then
    BRANCH_PUSHED=true
    HEAD_SHA="$REMOTE_SHA"
  elif [ -n "$LOCAL_SHA" ]; then
    echo "Branch handover plan — repo '$REPO_REL':"
    echo "  branch '$BRANCH' exists only locally ($LOCAL_SHA)"
    echo "  action: git -C $REPO_DIR push -u origin $BRANCH"
    if [ "$YES" -ne 1 ]; then
      echo
      echo "hq-delegate-repo: confirmation required — re-run with --yes to push the branch" >&2
      exit 2
    fi
    git -C "$REPO_DIR" push -u origin "$BRANCH" \
      || die "failed to push branch '$BRANCH' to origin"
    BRANCH_PUSHED=true
    HEAD_SHA="$LOCAL_SHA"
  else
    echo "hq-delegate-repo: branch '$BRANCH' does not exist yet (declared in the PRD, not started) — recording as unpushed"
  fi
fi

# --- read-only recipient access check ----------------------------------------

ACCESS_VERIFIED=false ACCESS_NOTE=""
if [ -n "$GH_USER" ] && [ -n "$REMOTE_URL" ] && command -v gh >/dev/null 2>&1; then
  # owner/repo from ssh or https remote forms
  OWNER_REPO="$(printf '%s' "$REMOTE_URL" | sed -E 's#^(git@[^:]+:|https?://[^/]+/)##; s#\.git$##')"
  if gh api "repos/$OWNER_REPO/collaborators/$GH_USER" >/dev/null 2>&1; then
    ACCESS_VERIFIED=true
    ACCESS_NOTE="verified: $GH_USER is a collaborator on $OWNER_REPO"
  else
    ACCESS_NOTE="UNVERIFIED: could not confirm $GH_USER has access to $OWNER_REPO — the recipient may need to be invited before they can pull the branch"
  fi
else
  ACCESS_NOTE="UNVERIFIED: recipient repository access was not checked (no GitHub login supplied) — confirm they can reach the repo before assuming so"
fi

# --- manifest update (repo block only — vaultPrefixes are never touched) -----

TMP_MANIFEST="$(mktemp)"
jq \
  --arg remote "$REMOTE_URL" \
  --arg headSha "$HEAD_SHA" \
  --argjson dirty "$DIRTY_JSON" \
  --argjson pushed "$BRANCH_PUSHED" \
  --argjson access "$ACCESS_VERIFIED" \
  --arg accessNote "$ACCESS_NOTE" \
  '.repo.remote = (if $remote == "" then null else $remote end)
   | .repo.headSha = (if $headSha == "" then null else $headSha end)
   | .repo.dirtyFiles = $dirty
   | .repo.branchPushed = $pushed
   | .repo.accessVerified = $access
   | .repo.accessNote = $accessNote' \
  "$MANIFEST" > "$TMP_MANIFEST" && mv "$TMP_MANIFEST" "$MANIFEST"

# --- brief: call out untransferred work and unverified access ----------------

if [ -f "$BRIEF" ]; then
  DIRTY_COUNT="$(printf '%s' "$DIRTY_JSON" | jq 'length')"
  if [ "$DIRTY_COUNT" -gt 0 ] || [ "$ACCESS_VERIFIED" != "true" ]; then
    {
      echo
      echo "## Code handover notes"
      echo
      if [ "$DIRTY_COUNT" -gt 0 ]; then
        echo "The delegator's working tree had uncommitted changes that are **not transferred** with this delegation. If something seems missing, these files are why — ask the delegator to commit and push them:"
        echo
        printf '%s' "$DIRTY_JSON" | jq -r '.[] | "- `\(.)`"'
        echo
      fi
      if [ "$ACCESS_VERIFIED" != "true" ]; then
        echo "$ACCESS_NOTE"
      fi
    } >> "$BRIEF"
  fi
fi

echo "hq-delegate-repo: recorded branch state (pushed=$BRANCH_PUSHED, dirty=$(printf '%s' "$DIRTY_JSON" | jq 'length') files, accessVerified=$ACCESS_VERIFIED)"
