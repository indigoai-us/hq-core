#!/usr/bin/env bash
# /import-claude credential redactor.
#
# Scrubs likely-credential patterns from a file before the content is written
# to any committed artifact (report.json, preview prompt, summary). Runs at
# two surfaces:
#   1. During scan preview generation (first 40 lines passed through this).
#   2. During import of settings fragments (field-by-field).
#
# Usage:
#   redact.sh <input_file> [--json-fields]     → stdout redacted text
#   redact.sh --list-fields <input_file>        → prints fields redacted (one/line)

set -euo pipefail

MODE="text"
LIST=false
if [[ "${1:-}" == "--list-fields" ]]; then
  LIST=true
  shift
fi
if [[ "${1:-}" == "--json-fields" ]]; then
  MODE="json-fields"
  shift
fi

INPUT="${1:-}"
if [[ -z "$INPUT" || ! -f "$INPUT" ]]; then
  echo "redact.sh: input file required and must exist" >&2
  exit 2
fi

# ──────────────────────── regex catalog ────────────────────────
# Each entry: NAME|PATTERN (extended regex). Replacement is <REDACTED:NAME>.
REDACTIONS=(
  'anthropic_key|sk-ant-[A-Za-z0-9_-]{20,}'
  'openai_key|sk-[A-Za-z0-9_-]{20,}'
  'github_pat|ghp_[A-Za-z0-9]{36}'
  'github_fine|github_pat_[A-Za-z0-9_]{20,}'
  'slack_bot|xoxb-[0-9]+-[0-9]+-[A-Za-z0-9]+'
  'slack_user|xoxp-[0-9]+-[0-9]+-[0-9]+-[A-Za-z0-9]+'
  'aws_key|AKIA[0-9A-Z]{16}'
  'bearer|Bearer[[:space:]]+[A-Za-z0-9._-]+'
  'google_api|AIza[0-9A-Za-z_-]{35}'
  'stripe_live|sk_live_[A-Za-z0-9]{24,}'
  'stripe_test|sk_test_[A-Za-z0-9]{24,}'
  'anthropic_legacy|sk-[A-Za-z0-9]{48,}'
)

# JSON value patterns (key-based; scrubs the value, keeps the key).
JSON_KEYS=(
  apiKey apiKeyHelper api_key apiToken authToken auth_token
  access_token refresh_token client_secret clientSecret
  private_key privateKey secret token password
)

ENV_SUFFIXES=(_KEY _TOKEN _SECRET _PASSWORD)

# ──────────────────────── redact text ────────────────────────
redact_text() {
  local out; out="$(cat "$INPUT")"
  local redacted_names=()
  for entry in "${REDACTIONS[@]}"; do
    local name="${entry%%|*}"
    local pat="${entry#*|}"
    if echo "$out" | grep -E -q -- "$pat" 2>/dev/null; then
      redacted_names+=("$name")
      out="$(echo "$out" | sed -E "s@${pat}@<REDACTED:${name}>@g")"
    fi
  done
  # JSON key-value redaction (handles "key": "value" with optional whitespace).
  for key in "${JSON_KEYS[@]}"; do
    if echo "$out" | grep -E -q "\"${key}\"[[:space:]]*:[[:space:]]*\"[^\"]+\""; then
      redacted_names+=("json:${key}")
      out="$(echo "$out" | sed -E "s@\"${key}\"[[:space:]]*:[[:space:]]*\"[^\"]+\"@\"${key}\":\"<REDACTED:json:${key}>\"@g")"
    fi
  done
  # Env-style KEY=VALUE redaction for common credential suffixes.
  for suf in "${ENV_SUFFIXES[@]}"; do
    if echo "$out" | grep -E -q "^[A-Z][A-Z0-9_]*${suf}=[^[:space:]]+"; then
      redacted_names+=("env${suf}")
      out="$(echo "$out" | sed -E "s@(^[A-Z][A-Z0-9_]*${suf})=[^[:space:]]+@\1=<REDACTED:env${suf}>@g")"
    fi
  done

  if $LIST; then
    printf "%s\n" "${redacted_names[@]:-}" | awk '!seen[$0]++ && NF'
  else
    printf "%s" "$out"
  fi
}

# Apply pattern-based regex redactions to stdin (used by json-fields mode to
# catch credential strings that live under non-standard JSON keys, e.g. shouty
# env vars like API_KEY / TOKEN in an mcpServers.*.env block).
apply_regex_patterns() {
  local data; data="$(cat)"
  for entry in "${REDACTIONS[@]}"; do
    local name="${entry%%|*}"
    local pat="${entry#*|}"
    if printf '%s' "$data" | grep -E -q -- "$pat" 2>/dev/null; then
      data="$(printf '%s' "$data" | sed -E "s@${pat}@<REDACTED:${name}>@g")"
    fi
  done
  printf '%s' "$data"
}

# ──────────────────────── redact JSON fields (structural) ────────────────────
redact_json_fields() {
  command -v jq >/dev/null 2>&1 || { redact_text; return; }
  # Structural pass: replace values at well-known key names.
  # Follow-up pass: regex-scrub remaining string values so credential patterns
  # under arbitrary keys (API_KEY, MY_TOKEN, etc.) don't leak.
  jq --argjson keys "$(printf '%s\n' "${JSON_KEYS[@]}" | jq -R . | jq -s .)" '
    walk(
      if type == "object" then
        with_entries(
          .key as $k |
          if ($keys | index($k)) and (.value | type == "string")
          then .value = ("<REDACTED:json:" + $k + ">")
          else . end
        )
      else . end
    )
  ' "$INPUT" | apply_regex_patterns
}

case "$MODE" in
  json-fields) redact_json_fields ;;
  *) redact_text ;;
esac
