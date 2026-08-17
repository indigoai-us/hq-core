#!/usr/bin/env bash
# hq-core: public
# worktree-gc.sh — safe garbage collector for stale HQ git worktrees.
#
# HQ worktrees accumulate forever. Nothing GCs them, and a busy machine can
# reach hundreds of worktrees / hundreds of GB. This script enumerates the
# linked worktrees HQ creates under:
#   <hqRoot>/workspace/worktrees/                (flat <name>/ and nested <repo>/<name>/)
#   <hqRoot>/.claude/worktrees/                  (agent-* local-only worktrees)
# and removes ONLY the ones that are provably safe to lose.
#
# DATA SAFETY IS PARAMOUNT. A worktree is removed only when EVERY guard holds:
#   1. Working tree is clean            — `git status --porcelain` is empty.
#   2. Old enough                       — creation stamp (or dir mtime) is older
#                                         than the retention window (default 7d).
#   3. Branch work is preserved         — for a pushable (github) repo the tip is
#                                         reachable from origin (or the branch is
#                                         on origin at the same tip); for an
#                                         HQ-root local-only worktree the branch
#                                         is already merged into the HQ root's
#                                         local `main`. Fetch is best-effort; a
#                                         failed fetch makes the worktree UNSAFE.
#   4. Not in use                       — no active session references its path,
#                                         and it was not touched in the last 2h.
#
# Removal mechanics are the gentle git verbs only — never `rm -rf`, never
# `--force`, never `branch -D`:
#   git -C <main-repo> worktree remove <abs>   (HQ_ALLOW_HQ_ROOT_GIT=1 for HQ root)
#   git -C <main-repo> worktree prune
#   git -C <main-repo> branch -d <branch>
#
# DRY-RUN IS THE DEFAULT. Nothing is removed unless `--apply` is passed. A single
# worktree error is logged and skipped — it never aborts the run.
#
# Usage:
#   worktree-gc.sh [--days N] [--apply] [--dry-run] [--gated] [--json]
#
# Flags:
#   --days N     retention window in days (default 7; env HQ_WORKTREE_GC_DAYS)
#   --apply      actually remove safe worktrees (default: dry-run, no changes)
#   --dry-run    classify only, make no changes (the default; explicit for clarity)
#   --gated      no-op if a GC run already happened in the last 24h (for cadence
#                callers like handoff-post.sh); writes a marker on each real run
#   --json       emit a machine-readable summary + per-worktree records on stdout
#
# Exit code is 0 whenever the scan completed (even with per-worktree skips).

set -euo pipefail

HQ_ROOT="${HQ_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

# ------------------------------- args ---------------------------------------
DAYS="${HQ_WORKTREE_GC_DAYS:-7}"
APPLY=0
JSON=0
GATED=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --days) DAYS="${2:-}"; shift 2 ;;
    --days=*) DAYS="${1#*=}"; shift ;;
    --apply) APPLY=1; shift ;;
    --dry-run) APPLY=0; shift ;;
    --gated) GATED=1; shift ;;
    --json) JSON=1; shift ;;
    -h|--help)
      sed -n '2,45p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) echo "worktree-gc: unknown arg: $1" >&2; exit 2 ;;
  esac
done

case "$DAYS" in
  ''|*[!0-9]*) echo "worktree-gc: --days must be a non-negative integer (got: $DAYS)" >&2; exit 2 ;;
esac

NOW=$(date -u +%s)
CUTOFF_EPOCH=$((NOW - DAYS * 86400))
RECENT_EPOCH=$((NOW - 2 * 60 * 60))     # 2h in-use guard

GC_META_DIR="$HQ_ROOT/workspace/worktrees/.gc-meta"
GATE_MARKER="$GC_META_DIR/.last-gc-run"

# ------------------------------- gating -------------------------------------
# --gated callers (handoff-post) get a once-per-24h ceiling so the opportunistic
# cadence never storms. The marker is written at the START of a real run so two
# near-simultaneous handoffs cannot both do the work.
if [[ "$GATED" -eq 1 ]]; then
  if [[ -f "$GATE_MARKER" ]]; then
    marker_mtime=$(stat -c %Y "$GATE_MARKER" 2>/dev/null || stat -f %m "$GATE_MARKER" 2>/dev/null || echo 0)
    if (( NOW - marker_mtime < 86400 )); then
      [[ "$JSON" -eq 1 ]] && echo '{"skipped":"gated","reason":"ran within 24h"}' || echo "worktree-gc: skipped (gated — ran within 24h)"
      exit 0
    fi
  fi
  mkdir -p "$GC_META_DIR" 2>/dev/null || true
  touch "$GATE_MARKER" 2>/dev/null || true
fi

# --------------------------- helper functions -------------------------------
path_mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo 0; }

# Stable per-path key shared with worktree.sh's creation stamp. MUST match the
# hashing in worktree.sh so a stamp written at creation is found here.
path_key() { printf '%s' "$1" | cksum | cut -d' ' -f1; }

dir_size_kb() { du -sk "$1" 2>/dev/null | awk '{print $1; exit}'; }

# is_ancestor <repo> <ancestor-ish> <descendant-ref> — true iff ancestor.
# Used only in `if` conditions so `set -e` never trips on the non-zero "not an
# ancestor" (1) or the error (>1, treated as not-an-ancestor → unsafe) results.
is_ancestor() { git -C "$1" merge-base --is-ancestor "$2" "$3" >/dev/null 2>&1; }

# session_references <abs-worktree-path> — true if any active session / thread /
# state file names this worktree path. Best-effort and conservative: an
# unreadable tree simply yields no match (the 2h mtime guard still applies).
session_references() {
  local wt="$1" hay
  for hay in "$HQ_ROOT/workspace/sessions" "$HQ_ROOT/.claude/state" \
             "$HQ_ROOT/workspace/threads/handoff.json" "$HQ_ROOT/workspace/locks"; do
    [[ -e "$hay" ]] || continue
    if grep -rqF "$wt" "$hay" 2>/dev/null; then
      return 0
    fi
  done
  return 1
}

# Optional timeout wrapper for network fetches (macOS has no `timeout`).
_TIMEOUT_BIN=""
if command -v timeout >/dev/null 2>&1; then _TIMEOUT_BIN="timeout"
elif command -v gtimeout >/dev/null 2>&1; then _TIMEOUT_BIN="gtimeout"; fi
run_fetch() { # <repo>
  if [[ -n "$_TIMEOUT_BIN" ]]; then
    "$_TIMEOUT_BIN" 45 git -C "$1" fetch origin --quiet >/dev/null 2>&1
  else
    git -C "$1" fetch origin --quiet >/dev/null 2>&1
  fi
}

# ----------------------------- enumerate ------------------------------------
# Genuine LINKED worktrees have a `.git` FILE (a gitfile). Main checkouts have a
# `.git` DIRECTORY, and plain project subdirectories have no `.git` at all — so
# `-name .git -type f` selects exactly the linked worktrees and never a main
# repo. Depth covers flat (<name>/.git) and nested (<repo>/<name>/.git) layouts.
CANDIDATES=()
while IFS= read -r gitfile; do
  [[ -n "$gitfile" ]] || continue
  CANDIDATES+=("$(cd "$(dirname "$gitfile")" && pwd -P)")
done < <(
  {
    [[ -d "$HQ_ROOT/workspace/worktrees" ]] && find "$HQ_ROOT/workspace/worktrees" -maxdepth 4 -name .git -type f 2>/dev/null
    [[ -d "$HQ_ROOT/.claude/worktrees" ]] && find "$HQ_ROOT/.claude/worktrees" -maxdepth 3 -name .git -type f 2>/dev/null
  } | sort -u
)

# Never GC the worktree this script is executing from.
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

# --------------------------- results / counters -----------------------------
REC_NDJSON="$(mktemp 2>/dev/null || echo "/tmp/worktree-gc-rec.$$")"
: > "$REC_NDJSON"
cleanup_rec() { rm -f "$REC_NDJSON"; }
trap cleanup_rec EXIT

examined=0
removed=0
would=0
reclaimed_kb=0
declare -i skip_total=0

# wt_git <git-args...> — run git against the current worktree's main repo, adding
# the HQ_ALLOW_HQ_ROOT_GIT escape hatch only for HQ-root-class worktrees (whose
# mutations touch the HQ root object store and are otherwise hook-blocked).
# Reads $main_repo and $is_hq_root from the loop scope.
wt_git() {
  if [[ "${is_hq_root:-0}" -eq 1 ]]; then
    HQ_ALLOW_HQ_ROOT_GIT=1 git -C "$main_repo" "$@"
  else
    git -C "$main_repo" "$@"
  fi
}

record() { # <path> <repo> <branch> <hq_root 0|1> <age_days> <size_kb> <action> <reason>
  jq -nc \
    --arg path "$1" --arg repo "$2" --arg branch "$3" \
    --argjson hq_root "$4" --arg age_days "$5" --arg size_kb "$6" \
    --arg action "$7" --arg reason "$8" \
    '{path:$path,repo:$repo,branch:$branch,hq_root:($hq_root==1),
      age_days:($age_days|tonumber?),size_kb:($size_kb|tonumber?),
      action:$action,reason:$reason}' >> "$REC_NDJSON"
}

log() { [[ "$JSON" -eq 1 ]] || echo "$*"; }

skip() { # <path> <repo> <branch> <hq_root> <age_days> <size_kb> <reason>
  skip_total+=1
  record "$1" "$2" "$3" "$4" "$5" "$6" "skipped" "$7"
  log "  skip  [$7] $1"
}

# ------------------------------- main loop ----------------------------------
for wt in "${CANDIDATES[@]:-}"; do
  [[ -n "$wt" ]] || continue
  examined=$((examined + 1))

  # Skip the worktree we are running inside.
  if [[ "$SELF_DIR" == "$wt"/* || "$SELF_DIR" == "$wt" ]]; then
    skip "$wt" "" "" 0 "" "" "self"; continue
  fi

  # Resolve the owning repo. A gitfile that no longer resolves is a git error.
  common_dir=$(git -C "$wt" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)
  if [[ -z "$common_dir" ]]; then
    skip "$wt" "" "" 0 "" "" "git-error"; continue
  fi
  main_repo=$(cd "$(dirname "$common_dir")" && pwd -P 2>/dev/null || echo "")
  if [[ -z "$main_repo" || ! -d "$main_repo" ]]; then
    skip "$wt" "" "" 0 "" "" "git-error"; continue
  fi

  is_hq_root=0
  [[ "$main_repo" -ef "$HQ_ROOT" ]] && is_hq_root=1

  branch=$(git -C "$wt" symbolic-ref --short HEAD 2>/dev/null || echo "")
  head_sha=$(git -C "$wt" rev-parse HEAD 2>/dev/null || echo "")

  # ---- guard 1: clean working tree ----
  porcelain=$(git -C "$wt" status --porcelain 2>/dev/null || echo "__ERR__")
  if [[ "$porcelain" == "__ERR__" ]]; then
    skip "$wt" "$main_repo" "$branch" "$is_hq_root" "" "" "git-error"; continue
  fi
  if [[ -n "$porcelain" ]]; then
    skip "$wt" "$main_repo" "$branch" "$is_hq_root" "" "" "dirty"; continue
  fi

  # ---- guard 4a: recent activity (in-use heuristic) ----
  wt_mtime=$(path_mtime "$wt")
  if (( wt_mtime > RECENT_EPOCH )); then
    skip "$wt" "$main_repo" "$branch" "$is_hq_root" "" "" "recent-activity"; continue
  fi

  # ---- guard 4b: active-session reference ----
  if session_references "$wt"; then
    skip "$wt" "$main_repo" "$branch" "$is_hq_root" "" "" "active-session"; continue
  fi

  # ---- guard 2: age (creation stamp, else dir mtime) ----
  created_epoch="$wt_mtime"
  stamp_file="$GC_META_DIR/$(path_key "$wt").json"
  if [[ -f "$stamp_file" ]]; then
    stamped=$(jq -r '.createdAtEpoch // empty' "$stamp_file" 2>/dev/null || echo "")
    [[ -n "$stamped" ]] && created_epoch="$stamped"
  fi
  age_days=$(( (NOW - created_epoch) / 86400 ))
  if (( created_epoch > CUTOFF_EPOCH )); then
    skip "$wt" "$main_repo" "$branch" "$is_hq_root" "$age_days" "" "too-recent"; continue
  fi

  # ---- guard 3: branch work is preserved somewhere ----
  preserved=0
  if [[ "$is_hq_root" -eq 1 ]]; then
    # HQ root is local-only; HQ never pushes. Safe only if the tip is already
    # merged into the HQ root's local `main`.
    if [[ -n "$head_sha" ]] && is_ancestor "$HQ_ROOT" "$head_sha" "main"; then
      preserved=1
    fi
    if [[ "$preserved" -ne 1 ]]; then
      skip "$wt" "$main_repo" "$branch" "$is_hq_root" "$age_days" "" "unmerged-local"; continue
    fi
  else
    # Pushable repo: require a github origin.
    origin_url=$(git -C "$main_repo" remote get-url origin 2>/dev/null || echo "")
    if [[ "$origin_url" != *github* ]]; then
      skip "$wt" "$main_repo" "$branch" "$is_hq_root" "$age_days" "" "non-github-remote"; continue
    fi
    # Best-effort fetch; a failed fetch means we cannot prove preservation → UNSAFE.
    if ! run_fetch "$main_repo"; then
      skip "$wt" "$main_repo" "$branch" "$is_hq_root" "$age_days" "" "fetch-failed"; continue
    fi
    # Reachable from origin's default branch (HEAD → main → master)?
    for ref in origin/HEAD origin/main origin/master; do
      if git -C "$main_repo" rev-parse --verify --quiet "$ref" >/dev/null 2>&1; then
        if [[ -n "$head_sha" ]] && is_ancestor "$main_repo" "$head_sha" "$ref"; then
          preserved=1; break
        fi
      fi
    done
    # Or the branch itself exists on origin at this exact tip.
    if [[ "$preserved" -ne 1 && -n "$branch" && -n "$head_sha" ]]; then
      remote_sha=$(git -C "$main_repo" rev-parse --verify --quiet "refs/remotes/origin/$branch" 2>/dev/null || echo "")
      [[ -z "$remote_sha" ]] && remote_sha=$(git -C "$main_repo" ls-remote --heads origin "$branch" 2>/dev/null | awk '{print $1; exit}')
      [[ -n "$remote_sha" && "$remote_sha" == "$head_sha" ]] && preserved=1
    fi
    if [[ "$preserved" -ne 1 ]]; then
      skip "$wt" "$main_repo" "$branch" "$is_hq_root" "$age_days" "" "unpushed"; continue
    fi
  fi

  # ---- SAFE TO REMOVE ----
  size_kb=$(dir_size_kb "$wt"); size_kb="${size_kb:-0}"

  if [[ "$APPLY" -ne 1 ]]; then
    would=$((would + 1))
    reclaimed_kb=$((reclaimed_kb + size_kb))
    record "$wt" "$main_repo" "$branch" "$is_hq_root" "$age_days" "$size_kb" "would-remove" "safe"
    log "  DRY   would remove ($((size_kb / 1024)) MB, ${age_days}d) $wt"
    continue
  fi

  # Apply: gentle verbs only, fail-soft per worktree.
  rm_rc=0
  wt_git worktree remove "$wt" >/dev/null 2>&1 || rm_rc=$?
  if [[ "$rm_rc" -ne 0 ]]; then
    skip "$wt" "$main_repo" "$branch" "$is_hq_root" "$age_days" "$size_kb" "remove-failed"; continue
  fi
  wt_git worktree prune >/dev/null 2>&1 || true
  if [[ -n "$branch" ]]; then
    # Safe -d only: git refuses if the branch is not merged. Never -D.
    wt_git branch -d "$branch" >/dev/null 2>&1 || true
  fi
  rm -f "$stamp_file" 2>/dev/null || true

  removed=$((removed + 1))
  reclaimed_kb=$((reclaimed_kb + size_kb))
  record "$wt" "$main_repo" "$branch" "$is_hq_root" "$age_days" "$size_kb" "removed" "safe"
  log "  GC    removed ($((size_kb / 1024)) MB, ${age_days}d) $wt"
done

# ------------------------------- summary ------------------------------------
reclaimed_gb=$(awk -v kb="$reclaimed_kb" 'BEGIN{printf "%.2f", kb/1024/1024}')
mode="dry-run"; [[ "$APPLY" -eq 1 ]] && mode="apply"

if [[ "$JSON" -eq 1 ]]; then
  jq -n \
    --arg mode "$mode" \
    --argjson examined "$examined" \
    --argjson removed "$removed" \
    --argjson reclaimed_kb "$reclaimed_kb" \
    --arg reclaimed_gb "$reclaimed_gb" \
    --argjson days "$DAYS" \
    --slurpfile records "$REC_NDJSON" \
    '{
      mode: $mode,
      retention_days: $days,
      examined: $examined,
      removed: $removed,
      reclaimed_gb: ($reclaimed_gb|tonumber),
      reclaimed_kb: $reclaimed_kb,
      skipped_by_reason: ([$records[] | select(.action=="skipped") | .reason]
                          | group_by(.) | map({(.[0]): length}) | add // {}),
      records: $records
    }'
else
  if [[ "$APPLY" -eq 1 ]]; then
    echo "worktree-gc [apply]: examined $examined · removed $removed · reclaimed ${reclaimed_gb} GB · skipped ${skip_total} (retention ${DAYS}d)"
  else
    echo "worktree-gc [dry-run]: examined $examined · would remove $would · would reclaim ${reclaimed_gb} GB · skipped ${skip_total} (retention ${DAYS}d)"
  fi
fi

exit 0
