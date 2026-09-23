#!/usr/bin/env bash
# ontology-candidate.sh — write one signal or entity candidate for the ontology
# worker to garden. Deterministic, no model call. Spec:
# core/knowledge/public/hq-core/ontology-local-spec.md
#
# Usage:
#   ontology-candidate.sh write --company <co> --kind signal|entity --type <t> \
#     --audience <company|email[,email...]> --source-ref <ref> \
#     (--body-file <path> | --body <text>) [--created-by <email>]
#   ontology-candidate.sh key <company|email[,email...]>   # print the audience key
#
# Exit 0: written, already present (no-op), or capture disabled for the company.
# Exit 2: bad usage, unknown type, or empty body.
set -euo pipefail

root="${HQ_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
here="$(cd "$(dirname "$0")" && pwd)"

SIGNAL_TYPES="action_item commitment decision risk question key_point participant_contribution summary"
ENTITY_TYPES="person project company concept"

die() { echo "ontology-candidate: $*" >&2; exit 2; }

sha() { if command -v sha256sum >/dev/null 2>&1; then sha256sum | awk '{print $1}'; else shasum -a 256 | awk '{print $1}'; fi; }

normalize_audience() { # stdout: sorted, lowercased, trimmed, comma-joined
  # Emails are lowercased; person/agent uids (prs_…, agt_…) keep their case.
  printf '%s' "$1" | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' \
    | awk '/@/ { print tolower($0); next } { print }' \
    | grep -v '^$' | LC_ALL=C sort -u | paste -sd, -
}

audience_key() {
  local a; a="$(printf '%s' "$1" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  [ -n "$a" ] || die "empty audience"
  if [ "$(printf '%s' "$a" | tr '[:upper:]' '[:lower:]')" = "company" ]; then echo company; return; fi
  printf '%s' "$(normalize_audience "$a")" | sha | cut -c1-16
}

cmd="${1:-}"; shift || true
case "$cmd" in
  key) audience_key "${1:-}"; exit 0 ;;
  write) ;;
  *) die "usage: ontology-candidate.sh write|key ..." ;;
esac

co="" kind="" type="" audience="" ref="" body="" body_file="" by="${HQ_USER_EMAIL:-}"
while [ $# -gt 0 ]; do
  case "$1" in
    --company) co="$2"; shift 2 ;;
    --kind) kind="$2"; shift 2 ;;
    --type) type="$2"; shift 2 ;;
    --audience) audience="$2"; shift 2 ;;
    --source-ref) ref="$2"; shift 2 ;;
    --body) body="$2"; shift 2 ;;
    --body-file) body_file="$2"; shift 2 ;;
    --created-by) by="$2"; shift 2 ;;
    *) die "unknown flag $1" ;;
  esac
done
[ -n "$co" ] && [ -n "$kind" ] && [ -n "$type" ] && [ -n "$audience" ] && [ -n "$ref" ] || die "missing required flag"
[ -n "$body_file" ] && { [ -f "$body_file" ] || die "no body file $body_file"; body="$(cat "$body_file")"; }
body="$(printf '%s' "$body" | tr '\n' ' ' | sed 's/[[:space:]]\{1,\}/ /g;s/^ //;s/ $//')"
[ -n "$body" ] || die "empty body"

case "$kind" in
  signal) allowed="$SIGNAL_TYPES"; flag=signals_capture; store=signals ;;
  entity) allowed="$ENTITY_TYPES"; flag=ontology_capture; store=ontology ;;
  *) die "kind must be signal or entity" ;;
esac
case " $allowed " in *" $type "*) ;; *) die "unknown $kind type '$type' (allowed: $allowed)" ;; esac

enabled="$(HQ_ROOT="$root" bash "$here/knowledge-prefs.sh" get "$co" "$flag")" || exit 2
if [ "$enabled" != "true" ]; then echo "disabled for $co ($flag=false)"; exit 0; fi

key="$(audience_key "$audience")"
norm_body="$(printf '%s' "$body" | tr '[:upper:]' '[:lower:]')"
id="$(printf '%s\n%s\n%s\n%s' "$kind" "$type" "$key" "$norm_body" | sha)"

dir="$root/companies/$co/$store/_candidates/$(date -u +%Y-%m-%d)"
# Idempotent across days: the same candidate already written (pending or done) is a no-op.
if find "$root/companies/$co/$store/_candidates" -name "$id.md" 2>/dev/null | grep -q .; then
  echo "exists $id"; exit 0
fi
mkdir -p "$dir"
{
  echo "---"
  echo "kind: $kind"
  echo "type: $type"
  echo "audience_key: $key"
  if [ "$key" != "company" ]; then
    echo "audience: [$(normalize_audience "$audience" | sed 's/,/, /g')]"
  fi
  echo "source_ref: \"$ref\""
  [ -n "$by" ] && echo "created_by: $by"
  echo "created_at: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "---"
  echo "$body"
} > "$dir/$id.md.tmp" && mv "$dir/$id.md.tmp" "$dir/$id.md"
echo "wrote $store/_candidates/$(basename "$dir")/$id.md"
