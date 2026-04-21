#!/usr/bin/env bash
# archive-old-threads.sh — move thread JSONs older than CUTOFF_DAYS into
# workspace/threads/archive/YYYY-MM/.
#
# Default cutoff: 60 days. Idempotent — files already in archive/ are ignored.
# Safe to run repeatedly; gated to once-per-day via a touchfile when invoked
# with --gated.
#
# Usage:
#   scripts/archive-old-threads.sh              # run archive, 60-day cutoff
#   scripts/archive-old-threads.sh --days 90    # custom cutoff
#   scripts/archive-old-threads.sh --gated      # skip if ran within 24h
#   scripts/archive-old-threads.sh --dry-run    # preview without moving

set -euo pipefail

HQ_ROOT="${HQ_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
cd "$HQ_ROOT"

CUTOFF_DAYS=60
DRY_RUN="false"
GATED="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --days) CUTOFF_DAYS="$2"; shift 2 ;;
    --dry-run) DRY_RUN="true"; shift ;;
    --gated) GATED="true"; shift ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

TOUCHFILE="workspace/.last-archive-run"
if [[ "$GATED" == "true" && -f "$TOUCHFILE" ]]; then
  # macOS `stat -f %m` gives mtime epoch; GNU `stat -c %Y`. Try both.
  mtime=$(stat -f %m "$TOUCHFILE" 2>/dev/null || stat -c %Y "$TOUCHFILE" 2>/dev/null || echo 0)
  now=$(date +%s)
  if [[ $((now - mtime)) -lt 86400 ]]; then
    echo "archive-old-threads: gated (ran <24h ago, skipping)" >&2
    exit 0
  fi
fi

THREADS_DIR="workspace/threads"
ARCHIVE_ROOT="${THREADS_DIR}/archive"
mkdir -p "$ARCHIVE_ROOT"

# Thread files are named T-YYYYMMDD-HHMMSS-slug.json.
# Extract YYYYMMDD from name, compare to cutoff.
CUTOFF_EPOCH=$(date -v-"${CUTOFF_DAYS}"d +%Y%m%d 2>/dev/null || date -d "-${CUTOFF_DAYS} days" +%Y%m%d 2>/dev/null)
if [[ -z "$CUTOFF_EPOCH" ]]; then
  echo "archive-old-threads: could not compute cutoff date" >&2
  exit 1
fi

moved=0
skipped=0
while IFS= read -r f; do
  base=$(basename "$f")
  # Extract YYYYMMDD (after "T-")
  date_part=$(echo "$base" | sed -E 's/^T-([0-9]{8})-.*/\1/')
  if [[ ! "$date_part" =~ ^[0-9]{8}$ ]]; then
    skipped=$((skipped + 1))
    continue
  fi
  if [[ "$date_part" -lt "$CUTOFF_EPOCH" ]]; then
    # Archive bucket: YYYY-MM
    yyyy="${date_part:0:4}"
    mm="${date_part:4:2}"
    bucket="${ARCHIVE_ROOT}/${yyyy}-${mm}"
    if [[ "$DRY_RUN" == "true" ]]; then
      echo "WOULD MOVE: $f -> $bucket/" >&2
    else
      mkdir -p "$bucket"
      mv "$f" "$bucket/"
    fi
    moved=$((moved + 1))
  fi
done < <(ls "$THREADS_DIR"/T-*.json 2>/dev/null || true)

if [[ "$DRY_RUN" != "true" && "$GATED" == "true" ]]; then
  mkdir -p "$(dirname "$TOUCHFILE")"
  touch "$TOUCHFILE"
fi

echo "archive-old-threads: cutoff=${CUTOFF_DAYS}d (before ${CUTOFF_EPOCH}) moved=${moved} skipped=${skipped} dry_run=${DRY_RUN}" >&2
