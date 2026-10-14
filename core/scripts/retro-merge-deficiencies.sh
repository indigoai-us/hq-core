#!/usr/bin/env bash
# hq-core: public
# retro-merge-deficiencies.sh — merge environment deficiencies for /retro
# SESSION mode: thread files' deficiencies[] from the last 24h plus the items
# the retro found itself, deduped by lever + summary.
#
# Usage: retro-merge-deficiencies.sh [--root <hq-root>] [--retro-json <path>]
#                                    [--hours <n>] [--company <slug>]
#                                    [--out <thread.json>]
#
# --retro-json  file holding the retro's own deficiencies array (same item
#               fields as the /handoff array). Missing flag means [].
# --hours       look-back window for thread files (default 24).
# --company     only read threads whose metadata.company lists this slug, so
#               one company's deficiencies never reach another's retro.
# --out         where to write a synthetic thread file
#               ({thread_id, deficiencies, system_info}) that
#               handoff-autofile.sh and handoff-builder-route.sh accept via
#               --thread. system_info is taken from the newest thread that
#               has one. Without --out the merged array goes to stdout.
#
# Items without evidence are dropped. On a duplicate lever + summary the
# retro's own item wins, then the newest thread's. Each merged item carries
# a "source" field: "retro" or the thread file name.
# bash 3.2 safe.
set -euo pipefail

ROOT=""
RETRO_JSON=""
HOURS=24
OUT=""
COMPANY=""
while [ $# -gt 0 ]; do
  case "$1" in
    --root) ROOT="${2:-}"; shift 2 ;;
    --retro-json) RETRO_JSON="${2:-}"; shift 2 ;;
    --hours) HOURS="${2:-}"; shift 2 ;;
    --out) OUT="${2:-}"; shift 2 ;;
    --company) COMPANY="${2:-}"; shift 2 ;;
    *) echo "retro-merge-deficiencies: unknown argument: $1" >&2; exit 2 ;;
  esac
done
case "$HOURS" in ''|*[!0-9]*) echo "retro-merge-deficiencies: --hours must be a whole number" >&2; exit 2 ;; esac
if [ -z "$ROOT" ]; then
  ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
fi

RETRO_ITEMS='[]'
if [ -n "$RETRO_JSON" ]; then
  [ -f "$RETRO_JSON" ] || { echo "retro-merge-deficiencies: retro json not found: $RETRO_JSON" >&2; exit 3; }
  RETRO_ITEMS="$(jq -c 'if type == "array" then [.[] | . + {source: "retro"}] else error("not an array") end' "$RETRO_JSON" 2>/dev/null)" \
    || { echo "retro-merge-deficiencies: retro json is not an array: $RETRO_JSON" >&2; exit 3; }
fi

THREADS_DIR="$ROOT/workspace/threads"
THREAD_ITEMS='[]'
SYSTEM_INFO='{}'
if [ -d "$THREADS_DIR" ]; then
  minutes=$((HOURS * 60))
  # Newest first so the newest thread wins duplicates and supplies system_info.
  list="$(find "$THREADS_DIR" -maxdepth 1 -type f -name '*.json' -mmin "-$minutes" -print 2>/dev/null \
    | while IFS= read -r f; do printf '%s\t%s\n' "$(stat -f %m "$f" 2>/dev/null || stat -c %Y "$f")" "$f"; done \
    | sort -rn | cut -f2-)"
  if [ -n "$list" ]; then
    while IFS= read -r f; do
      jq -e 'type == "object"' "$f" >/dev/null 2>&1 || continue
      if [ -n "$COMPANY" ]; then
        jq -e --arg co "$COMPANY" '[.metadata.company // [] | if type == "array" then .[] else . end] | index($co) != null' "$f" >/dev/null 2>&1 || continue
      fi
      name="$(basename "$f")"
      items="$(jq -c --arg src "$name" '[(.deficiencies // [])[] | select(type == "object") | . + {source: $src}]' "$f")"
      THREAD_ITEMS="$(jq -c --argjson add "$items" '. + $add' <<<"$THREAD_ITEMS")"
      if [ "$SYSTEM_INFO" = '{}' ]; then
        SYSTEM_INFO="$(jq -c '.system_info // {}' "$f")"
      fi
    done <<<"$list"
  fi
fi

MERGED="$(jq -c -n --argjson r "$RETRO_ITEMS" --argjson t "$THREAD_ITEMS" '
  ($r + $t)
  | map(select(((.evidence // "") | tostring | length) > 0))
  | reduce .[] as $it ({seen: {}, out: []};
      (($it.lever // "") + "\n" + ($it.summary // "")) as $k
      | if .seen[$k] then . else .seen[$k] = true | .out += [$it] end)
  | .out')"

if [ -n "$OUT" ]; then
  jq -n --argjson d "$MERGED" --argjson s "$SYSTEM_INFO" \
    '{thread_id: "retro-session", deficiencies: $d, system_info: $s}' > "$OUT"
  echo "merged: $(jq 'length' <<<"$MERGED") item(s) -> $OUT"
else
  printf '%s\n' "$MERGED"
fi
