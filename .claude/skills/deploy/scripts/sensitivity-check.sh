#!/usr/bin/env bash
# sensitivity-check.sh — classify artifact sensitivity for hq-deploy.
# Inlined replacement for the former Sensitivity sub-agent.
#
# Args:
#   $1 — artifact path (defaults to $PWD)
#   $2 — latest user message excerpt (optional, used for stated-private rule)
#
# Output (one JSON line on stdout):
#   {"sensitive":true,"trigger":"companies-data-path|private-repo|pii-detected|financial-filename|user-stated-private"}
#   {"sensitive":false,"trigger":null}
#
# Rule precedence (stops on first match):
#   1. Path under companies/*/data/         → companies-data-path
#   2. Inside a private repo (/repos/private/) → private-repo
#   3. PII content (email/SSN/phone regex)  → pii-detected
#   4. Financial filename match             → financial-filename
#   5. Latest user message stated private   → user-stated-private

set -u

PATH_ARG="${1:-$PWD}"
USER_MSG="${2:-}"

emit() { printf '%s\n' "$1"; exit 0; }

# Normalize path
ABS_PATH=$(cd "$PATH_ARG" 2>/dev/null && pwd || echo "$PATH_ARG")

# Rule 1: companies/*/data/
case "$ABS_PATH" in
  */companies/*/data/*|*/companies/*/data)
    emit '{"sensitive":true,"trigger":"companies-data-path"}'
    ;;
esac

# Rule 2: private repo
case "$ABS_PATH" in
  */repos/private/*)
    emit '{"sensitive":true,"trigger":"private-repo"}'
    ;;
esac

# Rule 3: PII content (filename-only listing — never surfaces matched content)
# Email with TLD requirement avoids CSS @media false positives.
EMAIL_RE='[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}'
SSN_RE='[0-9]{3}-[0-9]{2}-[0-9]{4}'
PHONE_RE='\+?1?[-. ]?\(?[0-9]{3}\)?[-. ]?[0-9]{3}[-. ]?[0-9]{4}'

if [ -d "$ABS_PATH" ]; then
  HIT=$(grep -rlE "$EMAIL_RE|$SSN_RE|$PHONE_RE" \
    --include='*.html' --include='*.htm' --include='*.md' \
    --include='*.txt' --include='*.json' --include='*.csv' \
    "$ABS_PATH" 2>/dev/null | head -1)
elif [ -f "$ABS_PATH" ]; then
  HIT=$(grep -lE "$EMAIL_RE|$SSN_RE|$PHONE_RE" "$ABS_PATH" 2>/dev/null | head -1)
else
  HIT=""
fi

if [ -n "$HIT" ]; then
  emit '{"sensitive":true,"trigger":"pii-detected"}'
fi

# Rule 4: financial filename
FIN_RE='(revenue|mrr|arr|payroll|salary|pnl|forecast|runway|burn)'
if [ -d "$ABS_PATH" ]; then
  FIN_HIT=$(find "$ABS_PATH" -type f 2>/dev/null | grep -iE "$FIN_RE" | head -1)
else
  FIN_HIT=$(echo "$ABS_PATH" | grep -iE "$FIN_RE" || true)
fi
if [ -n "$FIN_HIT" ]; then
  emit '{"sensitive":true,"trigger":"financial-filename"}'
fi

# Rule 5: user message stated private
if [ -n "$USER_MSG" ]; then
  if echo "$USER_MSG" | grep -iqE '\b(private|confidential|sensitive|internal[- ]only)\b'; then
    emit '{"sensitive":true,"trigger":"user-stated-private"}'
  fi
fi

emit '{"sensitive":false,"trigger":null}'
