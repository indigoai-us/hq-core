#!/usr/bin/env bash
# hq-core: public
# twig-soak-summary.sh — write a daily summary of the twig worktree soak log.
#
# Reads workspace/reports/twig-soak/events.jsonl (written by
# worktree-backend.sh when the backend is twig) and writes
# workspace/reports/twig-soak/<date>.md for one UTC day.
#
# Usage: twig-soak-summary.sh [--date YYYY-MM-DD] [--dir <soak-dir>] [--stdout]
set -euo pipefail

HQ_ROOT="${HQ_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
DIR="${HQ_TWIG_SOAK_DIR:-$HQ_ROOT/workspace/reports/twig-soak}"
DAY="$(date -u +%Y-%m-%d)"
TO_STDOUT=0
while [ $# -gt 0 ]; do
  case "$1" in
    --date) DAY="$2"; shift 2 ;;
    --dir) DIR="$2"; shift 2 ;;
    --stdout) TO_STDOUT=1; shift ;;
    -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
    *) echo "twig-soak-summary: unknown arg $1" >&2; exit 2 ;;
  esac
done
command -v jq >/dev/null 2>&1 || { echo "twig-soak-summary: needs jq" >&2; exit 2; }
LOG="$DIR/events.jsonl"

report() {
  echo "# Twig worktree soak: $DAY"
  echo
  if [ ! -s "$LOG" ]; then
    echo "No soak events logged yet ($LOG is missing or empty)."
    return
  fi
  jq -rs --arg day "$DAY" '
    def pct(a; b): if b == 0 then "n/a" else ((a * 100 / b) | floor | tostring) + "%" end;
    def med: sort | if length == 0 then null elif length % 2 == 1 then .[length/2|floor] else ((.[length/2-1] + .[length/2]) / 2) end;
    [ .[] | select((.ts // "") | startswith($day)) ] as $d
    | ($d | length) as $n
    | ($d | map(select(.backend | startswith("twig-cow")))) as $cow
    | ($d | map(select(.backend == "twig-stock"))) as $stock
    | ($d | map(select(.backend == "git"))) as $fb
    | ($d | map(select(.rc != 0))) as $err
    | [
        "Events: \($n). CoW: \($cow|length) (\(pct($cow|length; $n))). Twig delegated to stock Git: \($stock|length). Fell back to plain git: \($fb|length). Failed creates: \($err|length).",
        "",
        "Median create time: CoW \(($cow|map(.duration_ms)|med) // "n/a") ms; stock/fallback \((($stock+$fb)|map(.duration_ms)|med) // "n/a") ms.",
        "Median disk delta: CoW \(($cow|map(.disk_delta_kb|numbers)|med) // "n/a") KB; stock/fallback \((($stock+$fb)|map(.disk_delta_kb|numbers)|med) // "n/a") KB.",
        "",
        "## Fallback reasons",
        ( $fb | group_by(.fallback) | map("- \(.[0].fallback): \(length)") | if length == 0 then ["- none"] else . end | .[] ),
        "",
        "## Errors",
        ( ($d | map(select((.error // "") != "" or .rc != 0)) | map("- \(.ts) \(.repo): rc=\(.rc) \(.error)")) | if length == 0 then ["- none"] else . end | .[] ),
        "",
        "## By repo",
        ( $d | group_by(.repo) | map("- \(.[0].repo | split("/") | last): \(length) creates, \(map(select(.backend|startswith("twig-cow")))|length) CoW") | .[] ),
        "",
        "## Events",
        "| time (UTC) | repo | backend | ms | disk KB | fallback |",
        "|---|---|---|---|---|---|",
        ( $d[] | "| \(.ts[11:19]) | \(.repo | split("/") | last) | \(.backend) | \(.duration_ms) | \(.disk_delta_kb // "") | \(.fallback // "") |" )
      ] | .[]
  ' "$LOG"
  echo
  echo "## Watch list"
  echo
  echo "Check by hand and note findings here: builds in twig worktrees (twig copies tracked files only, so node_modules and target/ still need an install or a warm copy), git hooks firing in twig worktrees, worktree-preserve.sh and /clean-worktree on twig worktrees, and HQ sync staying out of workspace/worktrees/."
}

if [ "$TO_STDOUT" -eq 1 ]; then report; exit 0; fi
mkdir -p "$DIR"
report > "$DIR/$DAY.md"
echo "$DIR/$DAY.md"
