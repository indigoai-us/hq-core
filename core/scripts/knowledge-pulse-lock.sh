#!/usr/bin/env bash
set -euo pipefail

if [[ "$#" -ne 4 || "$1" != "claim" ]]; then
  echo "Usage: knowledge-pulse-lock.sh claim <claim-root> <company-slug> <YYYY-MM-DD>" >&2
  exit 2
fi

claim_root="$2"
company_slug="$3"
claim_date="$4"

if [[ -z "$claim_root" || ! "$company_slug" =~ ^[a-z0-9][a-z0-9-]*$ || ! "$claim_date" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
  echo "knowledge-pulse-lock: invalid claim root, company slug, or date" >&2
  exit 2
fi

mkdir -p "$claim_root"
marker="$claim_root/$company_slug-$claim_date.claimed"
if mkdir "$marker" 2>/dev/null; then
  printf 'claimed\n'
elif [[ -d "$marker" ]]; then
  printf 'already-claimed\n'
else
  echo "knowledge-pulse-lock: could not create claim marker" >&2
  exit 1
fi
