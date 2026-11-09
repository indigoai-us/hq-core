#!/usr/bin/env bash
# shrink-check.sh — stop a redeploy that would replace a live site with a much
# smaller or incomplete one (feedback 09bf5e25: a 52 KB older copy of a page
# replaced the full live app). hq-deploy replaces the whole site on completion,
# so this runs BEFORE the upload to an app that already exists.
#
#   shrink-check.sh --new-dir <dir> (--live-dir <dir> | --live-index-file <file>)
#                   [--confirm-shrink]
#
#   --new-dir          the build output about to be uploaded
#   --live-dir         what is live now (the local route-host.sh snapshot)
#   --live-index-file  a downloaded copy of the live index.html, when there is
#                      no snapshot (compares the entry file only)
#   --confirm-shrink   the operator has seen the warning and wants to go on
#
# Flags a shrink when index.html or the total size drops by more than half, or
# when non-hashed top-level HTML/data files (*.html, *.json, *.xml, *.txt,
# *.webmanifest, *.csv) that are live are missing from the new build
# (--live-dir only). Hashed bundles (assets/index-abc123.js) are never counted:
# every ordinary Vite/webpack/Next redeploy renames them.
# A legitimate trim (for example big media removed on purpose) trips the total
# size check and needs --confirm-shrink.
# Prints one JSON line:
#   {"ok":true,"shrink":false}
#   {"ok":true,"shrink":true,"confirmed":bool,"reasons":[...],"message":"..."}
# Exit 0 when nothing shrank or --confirm-shrink was given; exit 3 when a
# shrink is unconfirmed (the caller must stop and ask); exit 64 on bad args.
# Never prints file contents.
# No -e on purpose: the checks below use failing tests and pipelines as values
# and must reach the JSON/exit-code logic at the end.
set -uo pipefail

NEW=""; LIVE=""; LIVE_INDEX=""; CONFIRM=0
while [ $# -gt 0 ]; do
  case "$1" in
    --new-dir) NEW="${2:-}"; shift 2 ;;
    --live-dir) LIVE="${2:-}"; shift 2 ;;
    --live-index-file) LIVE_INDEX="${2:-}"; shift 2 ;;
    --confirm-shrink) CONFIRM=1; shift ;;
    *) echo '{"ok":false,"reason":"bad_args"}'; exit 64 ;;
  esac
done
if [ ! -d "$NEW" ] || { [ ! -d "$LIVE" ] && [ ! -f "$LIVE_INDEX" ]; }; then
  echo '{"ok":false,"reason":"bad_args"}'; exit 64
fi

fsize() { wc -c < "$1" | tr -d ' '; }
dirsize() { # total bytes of regular files under $1
  local t=0 f
  while IFS= read -r -d '' f; do t=$((t + $(fsize "$f"))); done < <(find "$1" -type f -print0)
  echo "$t"
}
human() { awk -v b="$1" 'BEGIN{ if (b>=1048576) printf "%.1f MB", b/1048576; else printf "%.0f KB", b/1024 }'; }

reasons=(); msgs=()
live_index=0
if [ -f "$LIVE_INDEX" ]; then live_index=$(fsize "$LIVE_INDEX")
elif [ -f "$LIVE/index.html" ]; then live_index=$(fsize "$LIVE/index.html"); fi
new_index=0; [ -f "$NEW/index.html" ] && new_index=$(fsize "$NEW/index.html")

if [ "$live_index" -gt 0 ] && [ $((new_index * 2)) -lt "$live_index" ]; then
  reasons+=("index_shrunk")
  msgs+=("index.html goes from $(human "$live_index") live to $(human "$new_index")")
fi

if [ -d "$LIVE" ]; then
  live_total=$(dirsize "$LIVE"); new_total=$(dirsize "$NEW")
  if [ "$live_total" -gt 0 ] && [ $((new_total * 2)) -lt "$live_total" ]; then
    reasons+=("total_shrunk")
    msgs+=("the site goes from $(human "$live_total") live to $(human "$new_total") in total")
  fi
  missing=$(cd "$LIVE" && find . -maxdepth 1 -type f \( -name '*.html' -o -name '*.htm' -o -name '*.json' \
    -o -name '*.xml' -o -name '*.txt' -o -name '*.webmanifest' -o -name '*.csv' \) | sed 's|^\./||' \
    | grep -Ev '[.-][0-9a-fA-F]{8,}\.[A-Za-z0-9]+$' | LC_ALL=C sort | while IFS= read -r p; do
    [ -e "$NEW/$p" ] || printf '%s\n' "$p"; done)
  if [ -n "$missing" ]; then
    n=$(printf '%s\n' "$missing" | wc -l | tr -d ' ')
    sample=$(printf '%s\n' "$missing" | head -3 | paste -sd, - | sed 's/,/, /g')
    reasons+=("files_missing")
    msgs+=("$n top-level file(s) that are live are not in the new build (for example $sample)")
  fi
fi

if [ "${#reasons[@]}" -eq 0 ]; then
  echo '{"ok":true,"shrink":false}'; exit 0
fi

msg="Warning: this deploy would replace the live site with a smaller one. $(printf '%s; ' "${msgs[@]}")This can happen when an older copy is deployed over a newer one. Confirm that this is intended, or stop and deploy from the current folder."
reasons_json=$(printf '%s\n' "${reasons[@]}" | jq -R . | jq -sc .)
confirmed=false; [ "$CONFIRM" = 1 ] && confirmed=true
jq -cn --argjson r "$reasons_json" --arg m "$msg" --argjson c "$confirmed" \
  '{ok:true,shrink:true,confirmed:$c,reasons:$r,message:$m}'
[ "$CONFIRM" = 1 ] && exit 0
exit 3
