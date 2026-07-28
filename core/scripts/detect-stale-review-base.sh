#!/usr/bin/env bash
# detect-stale-review-base.sh — find remote-tracking refs in the HQ root that
# have fallen so far behind local HEAD that a diff/review tool will pick one as
# its comparison base and try to review the entire tree.
#
# Background: HQ autosaves one commit per edited file (.claude/hooks/hq-autocommit.sh)
# and is never pushed to a remote (policy hq-root-never-push-remote). An HQ root
# that is itself a git repo with a remote attached therefore accumulates local
# commits the remote-tracking ref never receives. The gap only grows.
#
# Review tools that auto-select a base branch resolve it from refs/remotes/*.
# Once the gap is large enough that base is effectively "the empty tree", so the
# review payload becomes the whole repository instead of the working delta. The
# observed failure (2026-07-28) was a Codex desktop git worker taking SIGTRAP on
# a 108,434-path / 29.2 MB payload built against a remote-tracking ref 22,881
# commits behind local main, retried until the app reached 5.5 GB RSS.
#
# Codex exposes no configuration for the review base — `review_model` only picks
# the reviewing model, and `auto_review` governs the approval-reviewer subagent,
# not code review. `codex review --base` is per-invocation and does not reach the
# desktop app's automatic review. Removing the stale ref is therefore the only
# lever available on the HQ side: with nothing stale to resolve, there is no
# whole-tree base to pick.
#
# Modes:
#   (default)  human-readable report; exit 0.
#   --json     machine-readable JSON array; exit 0.
#   --check    exit 0 if clean, 1 if any stale base exists (advisory gate).
#   --fix      delete the offending remote-tracking refs; print each action.
#
# --fix deletes ONLY refs under refs/remotes/. It never touches refs/heads/,
# never removes a configured remote, never fetches, and never pushes. The
# deletion is recoverable: `git fetch <remote>` recreates the ref (and, on an HQ
# root, recreates this condition — HQ roots are not meant to be fetched).
#
# Thresholds (override with flags or env):
#   --max-paths N    changed paths tolerated vs. a base   (default 5000)
#   --max-commits N  commits ahead tolerated vs. a base   (default 1000)
# A ref is stale when EITHER threshold is exceeded. Path count is the primary
# signal: it is what determines the review payload size.

set -euo pipefail

MODE="report"
MAX_PATHS="${HQ_REVIEW_BASE_MAX_PATHS:-5000}"
MAX_COMMITS="${HQ_REVIEW_BASE_MAX_COMMITS:-1000}"
ROOT_OVERRIDE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --json)        MODE="json"; shift ;;
    --check)       MODE="check"; shift ;;
    --fix)         MODE="fix"; shift ;;
    --max-paths)   MAX_PATHS="${2:?--max-paths needs a value}"; shift 2 ;;
    --max-commits) MAX_COMMITS="${2:?--max-commits needs a value}"; shift 2 ;;
    --root)        ROOT_OVERRIDE="${2:?--root needs a value}"; shift 2 ;;
    -h|--help)     sed -n '2,41p' "$0"; exit 0 ;;
    *)
      printf 'detect-stale-review-base: unknown argument: %s\n' "$1" >&2
      printf 'usage: %s [--json|--check|--fix] [--max-paths N] [--max-commits N] [--root PATH]\n' "$0" >&2
      exit 2 ;;
  esac
done

case "$MAX_PATHS" in ''|*[!0-9]*)
  echo "detect-stale-review-base: --max-paths must be a non-negative integer" >&2; exit 2 ;;
esac
case "$MAX_COMMITS" in ''|*[!0-9]*)
  echo "detect-stale-review-base: --max-commits must be a non-negative integer" >&2; exit 2 ;;
esac

# Resolve HQ root: explicit flag wins, then env, then the tree this script ships in.
# Physical paths (pwd -P) so the nesting guard below cannot be dodged through a
# symlink to a clone.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
HQ_ROOT="${ROOT_OVERRIDE:-${HQ_ROOT:-${CLAUDE_PROJECT_DIR:-$(cd "$SCRIPT_DIR/../.." && pwd -P)}}}"

if [ ! -d "$HQ_ROOT" ]; then
  echo "detect-stale-review-base: no such directory: $HQ_ROOT" >&2
  exit 2
fi
HQ_ROOT="$(cd "$HQ_ROOT" && pwd -P)"

emit_clean() {
  case "$MODE" in
    json)  echo "[]" ;;
    check) : ;;
    fix)   printf 'detect-stale-review-base: nothing to fix (%s)\n' "$1" ;;
    *)     printf 'detect-stale-review-base: clean (%s)\n' "$1" ;;
  esac
  exit 0
}

# Only ever operate on an HQ root. This guard is what keeps the tool away from
# repos/ working clones, where a remote-tracking ref far behind local HEAD is
# ordinary and its refs must never be deleted.
if [ ! -f "$HQ_ROOT/core/core.yaml" ]; then
  echo "detect-stale-review-base: $HQ_ROOT is not an HQ root (no core/core.yaml)" >&2
  exit 2
fi

# A repos/ clone of hq-core is itself HQ-root-shaped — core/core.yaml ships in
# the repo, so the check above cannot tell it from a real install. What does
# distinguish a working clone is position: clones and worktree checkouts live
# NESTED inside another HQ root (repos/, workspace/worktrees/), while a real HQ
# root never does. Refuse any candidate with an HQ-root-shaped ancestor rather
# than trusting the caller.
ANCESTOR="$(dirname "$HQ_ROOT")"
while [ -n "$ANCESTOR" ] && [ "$ANCESTOR" != "/" ] && [ "$ANCESTOR" != "." ]; do
  if [ -f "$ANCESTOR/core/core.yaml" ]; then
    echo "detect-stale-review-base: $HQ_ROOT is nested inside the HQ root $ANCESTOR — refusing. Working clones and worktree checkouts keep their remote-tracking refs; this tool only repairs a top-level HQ install." >&2
    exit 2
  fi
  ANCESTOR="$(dirname "$ANCESTOR")"
done

if [ "$(git -C "$HQ_ROOT" rev-parse --show-toplevel 2>/dev/null || true)" != "$HQ_ROOT" ]; then
  emit_clean "HQ root is not a git repository — no review base to go stale"
fi

if ! git -C "$HQ_ROOT" rev-parse --verify -q HEAD >/dev/null 2>&1; then
  emit_clean "HQ root has no commits yet"
fi

REFS="$(git -C "$HQ_ROOT" for-each-ref --format='%(refname)' refs/remotes 2>/dev/null || true)"
if [ -z "$REFS" ]; then
  emit_clean "no remote-tracking refs in the HQ root"
fi

STALE_REFS=""
STALE_JSON=""
STALE_COUNT=0

while IFS= read -r ref; do
  [ -n "$ref" ] || continue
  # Symbolic refs (refs/remotes/<remote>/HEAD) resolve to a ref already covered.
  if git -C "$HQ_ROOT" symbolic-ref -q "$ref" >/dev/null 2>&1; then
    continue
  fi

  commits="$(git -C "$HQ_ROOT" rev-list --count "$ref..HEAD" 2>/dev/null || true)"
  [ -n "$commits" ] || continue

  # Three-dot: paths changed since the merge base — what a review of
  # "HEAD against this base" would actually carry. This is the expensive probe
  # on exactly the repos this tool exists for (it IS the whole-tree diff), so
  # skip it when the commit gap alone already proves staleness and the mode
  # does not display counts. --json always measures both.
  paths=""
  if [ "$commits" -le "$MAX_COMMITS" ] || [ "$MODE" = "json" ]; then
    paths="$(git -C "$HQ_ROOT" diff --name-only "$ref...HEAD" 2>/dev/null | wc -l | tr -d ' ')"
    [ -n "$paths" ] || paths=0
  fi

  if [ "$commits" -le "$MAX_COMMITS" ] && [ "$paths" -le "$MAX_PATHS" ]; then
    continue
  fi

  STALE_COUNT=$((STALE_COUNT + 1))
  STALE_REFS="${STALE_REFS}${ref}"$'\n'
  if [ "$MODE" = "json" ]; then
    [ -z "$STALE_JSON" ] || STALE_JSON="${STALE_JSON},"
    STALE_JSON="${STALE_JSON}{\"ref\":\"${ref}\",\"commits_ahead\":${commits},\"changed_paths\":${paths}}"
  fi
done <<EOF
$REFS
EOF

if [ "$STALE_COUNT" -eq 0 ]; then
  emit_clean "every remote-tracking ref is within ${MAX_PATHS} paths / ${MAX_COMMITS} commits of HEAD"
fi

case "$MODE" in
  json)
    printf '[%s]\n' "$STALE_JSON"
    ;;
  check)
    printf 'detect-stale-review-base: %s stale review base(s) in %s\n' "$STALE_COUNT" "$HQ_ROOT" >&2
    exit 1
    ;;
  fix)
    printf '%s' "$STALE_REFS" | while IFS= read -r ref; do
      [ -n "$ref" ] || continue
      git -C "$HQ_ROOT" update-ref -d "$ref"
      printf 'detect-stale-review-base: deleted %s\n' "$ref"
    done
    printf 'detect-stale-review-base: removed %s stale review base(s). A later `git fetch` in the HQ root recreates them — HQ roots are not meant to be fetched (policy hq-root-never-push-remote).\n' "$STALE_COUNT"
    ;;
  *)
    printf 'detect-stale-review-base: %s stale review base(s) in %s\n\n' "$STALE_COUNT" "$HQ_ROOT"
    printf '%s' "$STALE_REFS" | while IFS= read -r ref; do
      [ -n "$ref" ] || continue
      c="$(git -C "$HQ_ROOT" rev-list --count "$ref..HEAD" 2>/dev/null || echo '?')"
      p="$(git -C "$HQ_ROOT" diff --name-only "$ref...HEAD" 2>/dev/null | wc -l | tr -d ' ')"
      printf '  %s — HEAD is %s commits ahead, %s changed paths\n' "$ref" "$c" "$p"
    done
    printf '\nA review tool that auto-selects a base will pick one of these and build a\nwhole-tree payload from it. Remove them with:\n\n  bash core/scripts/detect-stale-review-base.sh --fix\n'
    ;;
esac
