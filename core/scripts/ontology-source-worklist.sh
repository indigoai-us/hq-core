#!/usr/bin/env bash
# ontology-source-worklist.sh — list a declared source's unprocessed items with
# each item's resolved audience. The ontology worker's process-source skill
# reads this list, extracts candidates from each item, and marks it done.
# Specs: source-yaml-spec.md, ontology-local-spec.md (core/knowledge/public/hq-core/)
#
# Usage:
#   ontology-source-worklist.sh --company <co> --channel <ch> [--limit N] [--force]
#   ontology-source-worklist.sh --company <co> --channel <ch> --mark-done <item-file>
#
# Output: one JSON object per line:
#   {"file":"sources/meetings/x.md","audience_key":"…","audience":["prs_…","a@x.com"]}
#   {"file":"sources/meetings/y.md","skip":"no-audience"}
# Audience by audience_rule:
#   attendees / thread / channel — the item's `audience:` or `attendees:` list if
#     it has one, else the direct read grants on the item's vault key
#     (hq files acl), which is how cloud ingestion records who was privy.
#   explicit — the item's own `audience:` frontmatter only.
#   company  — "company".
# An item with no resolvable audience is emitted as a skip, never as company.
# Exit 0; 2 bad usage / invalid source.yaml; 4 run: cloud source without --force.
set -uo pipefail
HQ="${HQ_BIN:-hq}"
root="${HQ_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
here="$(cd "$(dirname "$0")" && pwd)"
co="" ch="" limit=50 force=0 done_item=""
while [ $# -gt 0 ]; do
  case "$1" in
    --company) co="$2"; shift 2 ;; --channel) ch="$2"; shift 2 ;; --limit) limit="$2"; shift 2 ;;
    --force) force=1; shift ;; --mark-done) done_item="$2"; shift 2 ;;
    *) echo "unknown flag $1" >&2; exit 2 ;;
  esac
done
[ -n "$co" ] && [ -n "$ch" ] || { echo "usage: ontology-source-worklist.sh --company <co> --channel <ch> [--limit N] [--force] [--mark-done <file>]" >&2; exit 2; }
D="$root/companies/$co/sources/$ch"; Y="$D/source.yaml"; ledger="$D/.processed"
bash "$here/source-yaml-validate.sh" "$Y" >/dev/null || { bash "$here/source-yaml-validate.sh" "$Y" >&2; exit 2; }

if [ -n "$done_item" ]; then echo "$(basename "$done_item")" >> "$ledger"; exit 0; fi

get() { awk -v k="$1" '$0 ~ "^"k":" { sub("^"k":[[:space:]]*", ""); gsub(/^["\x27]|["\x27]$/, ""); print; exit }' "$Y"; }
run="$(get run)"; rule="$(get audience_rule)"
if [ "$run" = cloud ] && [ "$force" = 0 ]; then echo "assigned to cloud agent (run: cloud); pass --force to run locally" >&2; exit 4; fi

item_list() { # frontmatter list field: inline [a, b] or block "- a"
  awk -v k="$2" '
    BEGIN{fm=0}
    /^---$/ { fm++; if (fm==2) exit; next }
    fm==1 && $0 ~ "^"k":" { v=$0; sub("^"k":[[:space:]]*", "", v)
      if (v ~ /^\[/) { gsub(/[\[\]"\x27]/, "", v); n=split(v, a, ","); for(i=1;i<=n;i++){gsub(/^[ \t]+|[ \t]+$/, "", a[i]); if(a[i]!="") print a[i]}; exit }
      inlist=1; next }
    fm==1 && inlist && /^[[:space:]]*-[[:space:]]/ { v=$0; sub(/^[[:space:]]*-[[:space:]]*/, "", v); gsub(/["\x27]/, "", v); print v; next }
    fm==1 && inlist { exit }
  ' "$1"
}

n=0
for f in "$D"/*.md; do
  [ -f "$f" ] || continue
  b="$(basename "$f")"
  [ -f "$ledger" ] && grep -qxF "$b" "$ledger" && continue
  [ "$n" -ge "$limit" ] && break
  n=$((n+1))
  rel="sources/$ch/$b"
  aud=""
  case "$rule" in
    company) aud="company" ;;
    explicit) aud="$(item_list "$f" audience | paste -sd, -)" ;;
    *)
      aud="$(item_list "$f" audience | paste -sd, -)"
      [ -n "$aud" ] || aud="$(item_list "$f" attendees | grep -E '@|^(prs|agt)_' | paste -sd, -)"
      if [ -z "$aud" ]; then
        aud="$("$HQ" files --company "$co" acl "$rel" --json 2>/dev/null \
          | jq -r '[.direct[]? | select(.granteeType=="person" or .granteeType=="email" or .granteeType=="agent") | select(.permission=="read" or .permission=="write" or .permission=="admin") | .granteeId] | unique | join(",")' 2>/dev/null)"
      fi ;;
  esac
  if [ -z "$aud" ]; then jq -cn --arg f "$rel" '{file:$f, skip:"no-audience"}'; continue; fi
  key="$(HQ_ROOT="$root" bash "$here/ontology-candidate.sh" key "$aud")"
  jq -cn --arg f "$rel" --arg k "$key" --arg a "$aud" '{file:$f, audience_key:$k, audience:($a|split(","))}'
done
