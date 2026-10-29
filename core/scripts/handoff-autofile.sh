#!/usr/bin/env bash
# hq-core: public
# handoff-autofile.sh — file one HQ feedback report per /handoff listing the
# thread's hq-core deficiencies plus its system_info block.
#
# Usage: handoff-autofile.sh --thread <thread.json> [--root <hq-root>]
#
# Prints exactly one result line on stdout and exits 0 unless arguments are bad:
#   filed: <feedback id>
#   skipped: <reason>
#   aborted: <reason>          (secret scan matched; nothing submitted)
#   failed: <reason>           (hq feedback bug returned non-zero)
#
# Rules:
#   - Builder machines (repos/private/hq-core-staging present) never file.
#   - HQ_HANDOFF_AUTOFILE=0 disables filing.
#   - Only kind == "hq-core" items are filed.
#   - Dedupe: sha256(lever + "\n" + summary) per item is recorded in
#     workspace/handoff-autofile/filed.json; hashes filed in the last 7 days
#     are omitted. If every item is omitted, nothing is filed.
#   - The body is scanned with core/scripts/lib/secret-patterns.sh before
#     submit; a match aborts the submit.
# bash 3.2 safe.
set -euo pipefail

THREAD=""
ROOT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --thread) THREAD="${2:-}"; shift 2 ;;
    --root) ROOT="${2:-}"; shift 2 ;;
    *) echo "handoff-autofile: unknown argument: $1" >&2; exit 2 ;;
  esac
done
[ -n "$THREAD" ] || { echo "handoff-autofile: --thread is required" >&2; exit 2; }
[ -f "$THREAD" ] || { echo "handoff-autofile: thread not found: $THREAD" >&2; exit 2; }
if [ -z "$ROOT" ]; then
  ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
WINDOW_SECONDS=604800

if [ "${HQ_HANDOFF_AUTOFILE:-1}" = "0" ]; then
  echo "skipped: auto-filing disabled (HQ_HANDOFF_AUTOFILE=0)"
  exit 0
fi
if [ -d "$ROOT/repos/private/hq-core-staging" ]; then
  # Same builder test as the builder route: the staging repo must also accept
  # a push, otherwise this machine files feedback like a public install.
  route_line="$(bash "$SCRIPT_DIR/handoff-builder-route.sh" --root "$ROOT" 2>/dev/null || true)"
  if [ "$route_line" = "route: builder" ]; then
    echo "skipped: builder machine"
    exit 0
  fi
fi

ITEMS="$(jq -c '[(.deficiencies // [])[] | select(.kind == "hq-core")]' "$THREAD")"
if [ "$(jq 'length' <<<"$ITEMS")" -eq 0 ]; then
  echo "skipped: no hq-core deficiencies"
  exit 0
fi

hash_of() {
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$1" | shasum -a 256 | awk '{print $1}'
  else
    printf '%s' "$1" | sha256sum | awk '{print $1}'
  fi
}

STATE_DIR="$ROOT/workspace/handoff-autofile"
LEDGER="$STATE_DIR/filed.json"
mkdir -p "$STATE_DIR"
if [ ! -f "$LEDGER" ] || ! jq -e 'type == "object"' "$LEDGER" >/dev/null 2>&1; then
  printf '{}\n' > "$LEDGER"
fi
NOW="$(date +%s)"

# Attach a hash to each item and drop ones filed inside the window.
WITH_HASH="[]"
n="$(jq 'length' <<<"$ITEMS")"
i=0
while [ "$i" -lt "$n" ]; do
  item="$(jq -c ".[$i]" <<<"$ITEMS")"
  key="$(jq -r '(.lever // "") + "\n" + (.summary // "")' <<<"$item")"
  h="$(hash_of "$key")"
  WITH_HASH="$(jq -c --argjson it "$item" --arg h "$h" '. + [$it + {hash: $h}]' <<<"$WITH_HASH")"
  i=$((i + 1))
done
FRESH="$(jq -c --slurpfile led "$LEDGER" --argjson now "$NOW" --argjson win "$WINDOW_SECONDS" \
  'map(select((($led[0][.hash] // 0) | tonumber) < ($now - $win)))' <<<"$WITH_HASH")"
if [ "$(jq 'length' <<<"$FRESH")" -eq 0 ]; then
  echo "skipped: all hq-core deficiencies already filed in the last 7 days"
  exit 0
fi

TITLE="$(jq -r '
  (map(. + {rank: ({"high": 0, "medium": 1, "low": 2}[.severity // "low"] // 3)})
   | sort_by(.rank) | .[0].summary) // "HQ handoff deficiencies"' <<<"$FRESH")"

# Source and impact tags (owner decision D4): an agent-filed row with no
# person-reported effect is an observation. It is degraded only when a
# high-severity deficiency's evidence names a blocked command or a failed
# write; then the title keeps no [observation] prefix.
IMPACT="$(jq -r '
  if any(.[]; (.severity // "") == "high"
      and ((.evidence // "") | test("\\bblocked\\b|\\bdenied\\b|fail(ed|s)? to write|failed write|write (failed|was blocked|was denied)|could not write|cannot write|unable to write"; "i")))
  then "degraded" else "inferred" end' <<<"$FRESH")"
if [ "$IMPACT" = "inferred" ]; then
  TITLE="[observation] $TITLE"
fi

BODY="$(mktemp "${TMPDIR:-/tmp}/handoff-autofile-body.XXXXXX")"
OUT="$(mktemp "${TMPDIR:-/tmp}/handoff-autofile-out.XXXXXX")"
trap 'rm -f "$BODY" "$OUT"' EXIT
jq -r --slurpfile t "$THREAD" --arg impact "$IMPACT" '
  "src=handoff impact=\($impact)",
  "Auto-filed by /handoff: hq-core deficiencies from one session.\n",
  (to_entries[] | .value as $d |
    "## \(.key + 1). \($d.summary // "")\n",
    "- lever: \($d.lever // "")",
    "- severity: \($d.severity // "")",
    "- summary: \($d.summary // "")",
    "- evidence: \($d.evidence // "")",
    "- proposed fix: \($d.proposed_fix // "")\n"),
  "## system_info\n",
  "```json",
  (($t[0].system_info // {}) | tojson),
  "```"' <<<"$FRESH" > "$BODY"

# shellcheck source=lib/secret-patterns.sh
. "$SCRIPT_DIR/lib/secret-patterns.sh"
if ! hq_scan_secrets "$BODY" 2>/dev/null; then
  echo "aborted: report body matched a secret pattern; nothing submitted"
  exit 0
fi

# --no-logs: the report carries only the deficiency sections and system_info;
# never attach this machine's ~/.hq log tails.
if ! hq feedback bug --reporter agent --title "$TITLE" --body-file "$BODY" --no-logs >"$OUT" 2>&1; then
  echo "failed: hq feedback bug exited non-zero"
  exit 0
fi

# Match "id: fb_123" / "ID=fb_123" as a standalone word, never the tail of a
# word such as "valid".
FEEDBACK_ID="$(grep -oE '(^|[^A-Za-z0-9_])[Ii][Dd][:= ]+[A-Za-z0-9_-]+' "$OUT" | head -n 1 | sed -E 's/^.*[Ii][Dd][:= ]+//' || true)"
[ -n "$FEEDBACK_ID" ] || FEEDBACK_ID="unknown"

TMP_LEDGER="$(mktemp "$STATE_DIR/filed.json.XXXXXX")"
jq --argjson fresh "$FRESH" --argjson now "$NOW" \
  'reduce $fresh[] as $f (.; .[$f.hash] = $now)' "$LEDGER" > "$TMP_LEDGER"
mv "$TMP_LEDGER" "$LEDGER"

echo "filed: $FEEDBACK_ID"
