#!/usr/bin/env bash
# ontology-source-worklist.sh — list a declared source's unprocessed items with
# each item's resolved audience. The ontology worker's process-source skill
# reads this list, extracts candidates from each item, and marks it done.
# Specs: source-yaml-spec.md, ontology-local-spec.md (core/knowledge/public/hq-core/)
#
# Usage:
#   ontology-source-worklist.sh --company <co> --channel <ch> [--limit N] [--force]
#   ontology-source-worklist.sh --company <co> --channel <ch> --mark-done <item-file>
#   ontology-source-worklist.sh --company <co> --channel <ch> --redo <item-file> [--redo <item-file>...]
#
# Order: unprocessed items are listed newest first by the item's own date,
# before --limit applies. The date is the first frontmatter key present out of
# scheduled_start_time, meeting_start, when, created_at, date (ISO 8601, with
# or without an offset); an item with none of them uses its file mtime. Equal
# dates order by filename. Ingest stamps (ingested_at, updated_at) are not
# used, because a mirror refresh rewrites them for every item.
#
# --redo removes an item from .processed and .skipped so the next run lists it
# again. <item-file> is the item's basename, its path relative to the company
# dir (sources/<ch>/x.md) or HQ root, or an absolute path; it must name an
# existing .md item directly inside the channel dir (no . or .. segments).
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
# Exit 0; 2 bad usage / invalid source.yaml / --redo outside the channel;
# 4 run: cloud source without --force.
set -uo pipefail
HQ="${HQ_BIN:-hq}"
root="${HQ_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
here="$(cd "$(dirname "$0")" && pwd)"
co="" ch="" limit=50 force=0 done_item="" redo_items=()
usage="usage: ontology-source-worklist.sh --company <co> --channel <ch> [--limit N] [--force] [--mark-done <file> | --redo <file>...]"
while [ $# -gt 0 ]; do
  case "$1" in
    --company) co="$2"; shift 2 ;; --channel) ch="$2"; shift 2 ;; --limit) limit="$2"; shift 2 ;;
    --force) force=1; shift ;; --mark-done) done_item="$2"; shift 2 ;;
    --redo) [ $# -ge 2 ] || { echo "$usage" >&2; exit 2; }; redo_items+=("$2"); shift 2 ;;
    *) echo "unknown flag $1" >&2; exit 2 ;;
  esac
done
[ -n "$co" ] && [ -n "$ch" ] || { echo "$usage" >&2; exit 2; }
if [ -n "$done_item" ] && [ "${#redo_items[@]}" -gt 0 ]; then echo "--mark-done and --redo cannot be combined" >&2; exit 2; fi
D="$root/companies/$co/sources/$ch"; Y="$D/source.yaml"; ledger="$D/.processed"; skip_ledger="$D/.skipped"
# Bumped when the audience parser gains new recognisable frontmatter fields; items
# previously skipped as no-audience under an older PARSER_VERSION get re-evaluated
# on the next run instead of staying stuck forever (see feedback_b8d61e28).
PARSER_VERSION=2
bash "$here/source-yaml-validate.sh" "$Y" >/dev/null || { bash "$here/source-yaml-validate.sh" "$Y" >&2; exit 2; }

if [ -n "$done_item" ]; then printf '%s\t%s\n' "$(basename "$done_item")" "$PARSER_VERSION" >> "$ledger"; exit 0; fi

# --redo: validate every item first, then drop each from both ledgers.
redo_basename() { # print the item's basename if $1 names an existing item directly in $D, else fail
  local arg="$1" b parent dpath cand
  case "/$arg/" in */../*|*/./*) echo "--redo: refusing path with . or .. segment: $arg" >&2; return 1 ;; esac
  b="${arg##*/}"
  case "$b" in ""|.*) echo "--redo: not an item file: $arg" >&2; return 1 ;; *.md) ;; *) echo "--redo: not an item file: $arg" >&2; return 1 ;; esac
  if [ "$b" != "$arg" ]; then
    parent="${arg%/*}"; [ -n "$parent" ] || parent=/
    dpath="$(cd "$D" 2>/dev/null && pwd -P)" || { echo "--redo: channel dir missing: $D" >&2; return 1; }
    for cand in "$parent" "$root/companies/$co/$parent" "$root/$parent"; do
      case "$parent" in /*) [ "$cand" = "$parent" ] || continue ;; esac
      if [ -d "$cand" ] && [ "$(cd "$cand" && pwd -P)" = "$dpath" ]; then parent=""; break; fi
    done
    [ -z "$parent" ] || { echo "--redo: item is outside sources/$ch: $arg" >&2; return 1; }
  fi
  [ -f "$D/$b" ] || { echo "--redo: no such item in sources/$ch: $b" >&2; return 1; }
  printf '%s\n' "$b"
}
if [ "${#redo_items[@]}" -gt 0 ]; then
  redo_names=""
  for r in "${redo_items[@]}"; do
    rb="$(redo_basename "$r")" || exit 2
    redo_names="$redo_names$rb"$'\n'
  done
  for lf in "$ledger" "$skip_ledger"; do
    [ -f "$lf" ] || continue
    if printf '%s' "$redo_names" | awk -F '\t' 'NR==FNR { if ($0 != "") drop[$0]=1; next } { k=$1; sub(/\r$/, "", k) } !(k in drop)' - "$lf" > "$lf.redo.$$"; then
      mv "$lf.redo.$$" "$lf"
    else
      rm -f "$lf.redo.$$"; echo "--redo: could not rewrite $lf" >&2; exit 1
    fi
  done
  exit 0
fi

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

# ordered_items: print the paths of unprocessed, not-skipped items, newest first
# (see Order in the header). An item counts as processed when .processed
# records it unstamped or at >= PARSER_VERSION, and as skipped when .skipped
# records it at PARSER_VERSION. One awk pass per xargs batch reads both ledgers
# and each item's frontmatter only; one stat per batch covers items with no
# date. Portable to bash 3.2 and BSD userland.
work="$(mktemp -d "${TMPDIR:-/tmp}/ontology-worklist.XXXXXX")" || exit 1
trap 'rm -rf "$work"' EXIT
ordered_items() {
  local pl=/dev/null sl=/dev/null f
  [ -f "$ledger" ] && pl="$ledger"
  [ -f "$skip_ledger" ] && sl="$skip_ledger"
  for f in "$D"/*.md; do [ -f "$f" ] && printf '%s\0' "$f"; done > "$work/items"
  : > "$work/dated"
  [ -s "$work/items" ] || return 0
  xargs -0 awk -v P="$pl" -v S="$sl" -v v="$PARSER_VERSION" '
    function base(p) { sub(/.*\//, "", p); return p }
    function epoch(s,   y, mo, d, h, mi, se, off, rest, tz, yy, era, yoe, mp, doy, doe) {
      gsub(/^[ \t"\047]+|[ \t"\047]+$/, "", s)
      if (s !~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]/) return ""
      y = substr(s, 1, 4) + 0; mo = substr(s, 6, 2) + 0; d = substr(s, 9, 2) + 0
      if (mo < 1 || mo > 12 || d < 1 || d > 31) return ""
      h = 0; mi = 0; se = 0; off = 0; rest = substr(s, 11)
      if (rest ~ /^[Tt ][0-9][0-9]:[0-9][0-9]/) {
        h = substr(rest, 2, 2) + 0; mi = substr(rest, 5, 2) + 0
        if (rest ~ /^[Tt ][0-9][0-9]:[0-9][0-9]:[0-9][0-9]/) se = substr(rest, 8, 2) + 0
        if (match(rest, /[+-][0-9][0-9]:?[0-9][0-9]$/)) {
          tz = substr(rest, RSTART, RLENGTH); gsub(/:/, "", tz)
          off = (substr(tz, 2, 2) * 3600 + substr(tz, 4, 2) * 60) * (substr(tz, 1, 1) == "-" ? -1 : 1)
        }
      }
      yy = (mo <= 2) ? y - 1 : y; era = int(yy / 400); yoe = yy - era * 400
      mp = (mo + 9) % 12; doy = int((153 * mp + 2) / 5) + d - 1
      doe = yoe * 365 + int(yoe / 4) - int(yoe / 100) + doy
      return (era * 146097 + doe - 719468) * 86400 + h * 3600 + mi * 60 + se - off
    }
    function emit(   i, k, e) {
      if (cur == "") return
      e = ""
      for (i = 1; i <= nk; i++) { k = keys[i]; if (k in val) { e = epoch(val[k]); if (e != "") break } }
      if (e == "") printf "-\t%s\n", cur; else printf "%.0f\t%s\n", e, cur
      cur = ""
      for (k in val) delete val[k]
    }
    BEGIN { nk = split("scheduled_start_time meeting_start when created_at date", keys, " ") }
    FILENAME == P || FILENAME == S {
      line = $0; sub(/\r$/, "", line); n = split(line, a, "\t")
      if (a[1] == "") next
      if (FILENAME == P) { if (n < 2 || a[2] == "" || (a[2] + 0) >= v) done[a[1]] = 1 }
      else if (n >= 3 && a[3] == v) done[a[1]] = 1
      next
    }
    FNR == 1 {
      emit(); seen[FILENAME] = 1
      if (base(FILENAME) in done) nextfile
      cur = FILENAME; fm = 0
    }
    { line = $0; sub(/\r$/, "", line) }
    line == "---" { fm++; if (fm == 2 || FNR > 1) { emit(); nextfile } next }
    fm == 0 || FNR > 400 { emit(); nextfile }
    match(line, /^[A-Za-z_]+:/) { k = substr(line, 1, RLENGTH - 1); if (!(k in val)) val[k] = substr(line, RLENGTH + 1) }
    END {
      emit()
      for (i = 1; i < ARGC; i++) {
        f = ARGV[i]
        if (f == P || f == S || (f in seen) || (base(f) in done)) continue
        printf "-\t%s\n", f
      }
    }
  ' "$pl" "$sl" < "$work/items" > "$work/dated" || return 1
  awk -F '\t' '$1 == "-" { print $2 }' "$work/dated" | tr '\n' '\0' > "$work/undated"
  if [ -s "$work/undated" ]; then
    if stat -c %Y / >/dev/null 2>&1; then
      xargs -0 stat --printf='%Y\t%n\n' < "$work/undated" >> "$work/dated" || return 1
    else
      xargs -0 stat -f '%m%t%N' < "$work/undated" >> "$work/dated" || return 1
    fi
  fi
  awk -F '\t' '$1 != "-"' "$work/dated" | LC_ALL=C sort -t "$(printf '\t')" -k1,1nr -k2,2 | cut -f2-
}
ordered_items > "$work/order" || { echo "could not list items in sources/$ch" >&2; exit 1; }

n=0
while IFS= read -r f <&3; do
  [ -f "$f" ] || continue
  b="$(basename "$f")"
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
done 3< "$work/order"
