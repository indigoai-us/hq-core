#!/usr/bin/env bash
# tag-inventory.sh — Show frequency-ranked tag vocabulary from the knowledge base
# Usage: ./tools/tag-inventory.sh [-c <company-slug>]
set -euo pipefail

COMPANY="personal"
while [[ $# -gt 0 ]]; do
  case "$1" in
    -c) COMPANY="$2"; shift 2 ;;
    *) shift ;;
  esac
done

cd "$(git rev-parse --show-toplevel)"

grep -rh "^tags:" "companies/$COMPANY/knowledge/" --include="*.md" \
  | sed 's/^tags: //' \
  | tr -d '[]"' \
  | tr ',' '\n' \
  | sed 's/^ *//;s/ *$//' \
  | sort | uniq -c | sort -rn
