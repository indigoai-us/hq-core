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
D="$root/companies/$co/sources/$ch"; Y="$D/source.yaml"; ledger="$D/.processed"; skip_ledger="$D/.skipped"
# Bumped when the audience parser gains new recognisable frontmatter fields; items
# previously skipped as no-audience under an older PARSER_VERSION get re-evaluated
# on the next run instead of staying stuck forever (see feedback_b8d61e28).
PARSER_VERSION=2
bash "$here/source-yaml-validate.sh" "$Y" >/dev/null || { bash "$here/source-yaml-validate.sh" "$Y" >&2; exit 2; }

if [ -n "$done_item" ]; then printf '%s\t%s\n' "$(basename "$done_item")" "$PARSER_VERSION" >> "$ledger"; exit 0; fi

# Migrate `.processed` to parser-version stamps so a successfully processed item
# stays processed across runs. Entries are `basename\tversion`; new mark-done
# writes always include the stamp. Convergence rule for legacy UNSTAMPED
# entries from the pre-fix slack-dm bug (254 DMs recorded in `.processed` as
# plain basenames while no candidates were ever written): drop ones whose file
# carries `resolved_participants:` (the exact bug signature) so the main loop
# re-evaluates them exactly once; the next mark-done writes them back stamped
# at the current version. Any other unstamped entry is upgraded in place to a
# stamp — never re-stripped again. Stamped entries at a version below current
# PARSER_VERSION are also dropped so a parser upgrade re-evaluates them.
# ontology-candidate ids are content-addressed, so a true reprocess is idempotent.
if [ -f "$ledger" ]; then
  tmp="$ledger.heal.$$"
  : > "$tmp"
  changed=0
  while IFS=$'\t' read -r b ver || [ -n "$b" ]; do
    b="${b%$'\r'}"; ver="${ver%$'\r'}"
    [ -n "$b" ] || continue
    if [ -n "${ver:-}" ]; then
      if [ "$ver" -lt "$PARSER_VERSION" ] 2>/dev/null; then changed=1; continue; fi
      printf '%s\t%s\n' "$b" "$ver" >> "$tmp"
      continue
    fi
    item="$D/$b"
    if [ -f "$item" ] && awk '/^---$/{fm++; if(fm==2) exit} fm==1 && /^resolved_participants:/{found=1; exit} END{exit !found}' "$item" 2>/dev/null; then
      changed=1; continue
    fi
    printf '%s\t%s\n' "$b" "$PARSER_VERSION" >> "$tmp"
    changed=1
  done < "$ledger"
  if [ "$changed" = 1 ]; then mv "$tmp" "$ledger"; else rm -f "$tmp"; fi
fi
is_processed() { # 0 if $1 is recorded in .processed at >= current parser version (or unstamped — treated as current after migration)
  [ -f "$ledger" ] || return 1
  awk -F '\t' -v b="$1" -v v="$PARSER_VERSION" '
    { sub(/\r$/, "") }
    $1==b { if (NF < 2 || $2=="") { found=1; exit } if (($2+0) >= v) { found=1; exit } }
    END { exit !found }
  ' "$ledger"
}

# Walk `.skipped`: entries whose recorded version is < current PARSER_VERSION
# are dropped so the main loop re-evaluates them. Entries at the current
# version stay as the ignore set for this run.
declare_skipped=""
if [ -f "$skip_ledger" ]; then
  tmp="$skip_ledger.rev.$$"
  : > "$tmp"
  changed=0
  while IFS=$'\t' read -r b reason ver || [ -n "$b" ]; do
    [ -n "$b" ] || continue
    if [ -z "${ver:-}" ] || [ "$ver" -lt "$PARSER_VERSION" ] 2>/dev/null; then
      changed=1; continue
    fi
    printf '%s\t%s\t%s\n' "$b" "$reason" "$ver" >> "$tmp"
  done < "$skip_ledger"
  if [ "$changed" = 1 ]; then mv "$tmp" "$skip_ledger"; else rm -f "$tmp"; fi
fi
skipped_at_current() { # 0 if $1 is recorded as skipped at the current parser version
  [ -f "$skip_ledger" ] || return 1
  awk -F '\t' -v b="$1" -v v="$PARSER_VERSION" '$1==b && $3==v { found=1; exit } END { exit !found }' "$skip_ledger"
}

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

# participant_ids: for a frontmatter block list of mappings under key $2 (e.g.
# resolved_participants:), emit one id per entry: the entry's `person_uid:` if
# present, otherwise its `email:`. Entries with only `slack_user_id:` (no
# person_uid, no email) are skipped — the audience must stay exactly the
# resolvable DM participants, never widened. Scope: ONLY the mapping list
# directly under $2 in frontmatter.
participant_ids() {
  awk -v k="$2" '
    { sub(/\r$/, "") }
    BEGIN{fm=0; inlist=0; have_pid=0; have_email=0; pid=""; em=""}
    function flush() {
      if (have_pid && pid != "") { print pid }
      else if (have_email && em != "") { print em }
      have_pid=0; have_email=0; pid=""; em=""
    }
    /^---$/ { fm++; if (fm==2) { if (inlist) flush(); exit } next }
    fm==1 && $0 ~ "^"k":" { inlist=1; next }
    fm==1 && inlist {
      # end of list = a line that is not indented beyond col 0 and not a bare "-"
      if ($0 ~ /^[^ \t-]/) { flush(); inlist=0; next }
      is_dash = ($0 ~ /^[[:space:]]*-[[:space:]]/)
      if (is_dash) {
        flush()
        s=$0; sub(/^[[:space:]]*-[[:space:]]*/, "", s)
        # inline mapping (JSON-style) on same line as the dash
        if (s ~ /^\{/) {
          gsub(/[{}"\x27]/, "", s); n=split(s, kv, ",")
          for (i=1;i<=n;i++) {
            gsub(/^[ \t]+|[ \t]+$/, "", kv[i])
            if (match(kv[i], /^person_uid[[:space:]]*:[[:space:]]*/)) { pid=substr(kv[i], RLENGTH+1); have_pid=1 }
            else if (match(kv[i], /^email[[:space:]]*:[[:space:]]*/)) { em=substr(kv[i], RLENGTH+1); have_email=1 }
          }
          flush()
          next
        }
        # First mapping key on same line as the dash, e.g.
        #   - person_uid: prs_01ALICE
        # Fall through to the key/value handlers below with the de-dashed line.
        line = s
      } else {
        line = $0; sub(/^[[:space:]]+/, "", line)
      }
      if (line ~ /^person_uid:/) {
        v=line; sub(/^person_uid:[[:space:]]*/, "", v); gsub(/["\x27]/, "", v); gsub(/^[ \t]+|[ \t]+$/, "", v)
        if (v != "") { pid=v; have_pid=1 }
        next
      }
      if (line ~ /^email:/) {
        v=line; sub(/^email:[[:space:]]*/, "", v); gsub(/["\x27]/, "", v); gsub(/^[ \t]+|[ \t]+$/, "", v)
        if (v != "") { em=v; have_email=1 }
        next
      }
    }
    END { if (inlist) flush() }
  ' "$1"
}

n=0
for f in "$D"/*.md; do
  [ -f "$f" ] || continue
  b="$(basename "$f")"
  is_processed "$b" && continue
  skipped_at_current "$b" && continue
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
      # Slack DM items (hq-pro inbound slack-personal-dm.ts) only carry
      # resolved_participants: a block list of mappings with person_uid /
      # slack_user_id / email. Derive audience from those, scoped exactly to
      # the DM's own participants (never widened to company). Only entries
      # whose person_uid or email resolves become audience ids; a slack_user_id
      # alone is not a usable audience key, so that entry is dropped — matching
      # the frontmatter contract exercised in hq-pro
      # test/sources/inbound/slack-personal-dm.test.ts.
      [ -n "$aud" ] || aud="$(participant_ids "$f" resolved_participants | grep -E '@|^(prs|agt)_' | paste -sd, -)"
      if [ -z "$aud" ]; then
        # A transient ACL or jq failure must not turn a source into a durable
        # no-audience skip. Retry once, while treating valid empty ACL output as
        # a completed lookup that needs no retry.
        for attempt in 1 2; do
          acl_output=""
          if acl_output="$("$HQ" files --company "$co" acl "$rel" --json 2>/dev/null \
            | jq -r '[.direct[]? | select(.granteeType=="person" or .granteeType=="email" or .granteeType=="agent") | select(.permission=="read" or .permission=="write" or .permission=="admin") | .granteeId] | unique | join(",")' 2>/dev/null)"; then
            aud="$acl_output"
            break
          fi
          aud=""
        done
      fi ;;
  esac
  if [ -z "$aud" ]; then
    printf '%s\t%s\t%s\n' "$b" "no-audience" "$PARSER_VERSION" >> "$skip_ledger"
    jq -cn --arg f "$rel" '{file:$f, skip:"no-audience"}'; continue
  fi
  key="$(HQ_ROOT="$root" bash "$here/ontology-candidate.sh" key "$aud")"
  jq -cn --arg f "$rel" --arg k "$key" --arg a "$aud" '{file:$f, audience_key:$k, audience:($a|split(","))}'
done
