#!/usr/bin/env bash
# ontology-audience-grant.sh — grant each scoped audience folder to exactly the
# people in its audience, and prove every grant by readback.
# Spec: core/knowledge/public/hq-core/ontology-local-spec.md
#
# Usage: ontology-audience-grant.sh --company <co> [--dry-run]
#
# For every signals/@{key}/_audience.yaml under companies/<co>/:
#   - grants read on signals/@{key}/, ontology/facts/@{key}/, and each
#     sources/{channel}/@{key}/ that exists, to each principal that is an
#     active company member (non-members are skipped with a warning);
#   - one prefix grant per principal per folder, never per file;
#   - reads every grant back with `hq files acl --json`; a missing grant exits 3.
# Company-audience paths get @all read on signals/{type}/ and
# ontology/facts/@company/ only. Nothing else under ontology/, signals/,
# sources/ is granted to @all.
# Local-only companies (company.yaml cloud: false or absent cloud_uid) exit 0
# with "local-only, no grants".
set -uo pipefail
HQ="${HQ_BIN:-hq}"
root="${HQ_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
co="" dry=0
while [ $# -gt 0 ]; do
  case "$1" in --company) co="$2"; shift 2 ;; --dry-run) dry=1; shift ;; *) echo "unknown flag $1" >&2; exit 2 ;; esac
done
[ -n "$co" ] || { echo "usage: ontology-audience-grant.sh --company <co> [--dry-run]" >&2; exit 2; }
C="$root/companies/$co"; [ -d "$C" ] || { echo "no company $co" >&2; exit 2; }

cloud=no
grep -Eq '^cloud:[[:space:]]*true' "$C/company.yaml" 2>/dev/null && cloud=yes
if [ "$cloud" = no ] && [ -f "$root/companies/manifest.yaml" ]; then
  # manifest: companies:\n  <co>:\n    cloud_uid: ...  (two-space company keys)
  awk -v co="$co" '/^  [^ #][^:]*:/{inco=($1==co":")} inco && /^    cloud_uid:[[:space:]]*[^[:space:]]/{f=1} END{exit !f}' "$root/companies/manifest.yaml" && cloud=yes
fi
[ "$cloud" = yes ] || { echo "local-only, no grants"; exit 0; }

members="$("$HQ" members --company "$co" list 2>/dev/null | awk 'NR>1{print tolower($1)}')"
[ -n "$members" ] || { echo "could not list members of $co" >&2; exit 3; }

granted=0 skipped=0 failed=0
grant() { # <prefix> <principal>
  local p="$1" who="$2"
  if [ "$dry" = 1 ]; then echo "would grant read $p -> $who"; return 0; fi
  "$HQ" files --company "$co" share "$p" --with "$who" --permission read >/dev/null 2>&1 || true
  if "$HQ" files --company "$co" acl "$p" --json 2>/dev/null | jq -e --arg w "$who" \
      '.direct[]? | select((.granteeId==$w) or ($w=="@all" and .granteeType=="company-wide")) | select(.permission=="read" or .permission=="write" or .permission=="admin")' >/dev/null; then
    granted=$((granted+1)); echo "granted read $p -> $who"
  else
    failed=$((failed+1)); echo "READBACK FAILED: $p -> $who" >&2
  fi
}

for aud in "$C"/signals/@*/_audience.yaml; do
  [ -f "$aud" ] || continue
  key="$(basename "$(dirname "$aud")")"; key="${key#@}"
  principals="$(sed -n 's/^principals:[[:space:]]*\[\(.*\)\]/\1/p' "$aud" | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | awk '/@/ { print tolower($0); next } { print }' | grep -v '^$')"
  prefixes="signals/@$key/"
  [ -d "$C/ontology/facts/@$key" ] && prefixes="$prefixes ontology/facts/@$key/"
  for d in "$C"/sources/*/@"$key"; do [ -d "$d" ] && prefixes="$prefixes sources/$(basename "$(dirname "$d")")/@$key/"; done
  for who in $principals; do
    # prs_/agt_ principals come from the source's own vault ACL (e.g. meeting
    # attendees), so they are already company identities; emails must be members.
    case "$who" in
      prs_*|agt_*) ;;
      *) if ! printf '%s\n' "$members" | grep -qxF "$who"; then echo "skip $who (not a member of $co)" >&2; skipped=$((skipped+1)); continue; fi ;;
    esac
    for p in $prefixes; do grant "$p" "$who"; done
  done
done
[ -d "$C/ontology/facts/@company" ] && grant "ontology/facts/@company/" "@all"
for t in action_item commitment decision risk question key_point participant_contribution summary; do
  [ -d "$C/signals/$t" ] && grant "signals/$t/" "@all"
done

echo "audience grants for $co: $granted granted, $skipped skipped, $failed failed"
[ "$failed" -eq 0 ] || exit 3
