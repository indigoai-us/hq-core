#!/usr/bin/env bash
# /import-context credential redactor.
#
# Scrubs likely-credential patterns before content is shown or written. The
# scanner sends file previews through this script, and settings imports use it
# field by field.
#
# Usage:
#   redact.sh [--json-fields] [<input_file>|-]  → stdout redacted text
#   redact.sh [--list-fields] [<input_file>|-]  → prints fields redacted (one/line)
#   With no input path or with `-`, reads stdin. `--list-fields` is text-only.

set -euo pipefail

MODE="text"
LIST=false
INPUT=""
INPUT_SET=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --list-fields) LIST=true ;;
    --json-fields) MODE="json-fields" ;;
    -)
      if $INPUT_SET; then echo "redact.sh: only one input path is allowed" >&2; exit 2; fi
      INPUT="-"; INPUT_SET=true
      ;;
    --*) echo "redact.sh: unknown option: $1" >&2; exit 2 ;;
    *)
      if $INPUT_SET; then echo "redact.sh: only one input path is allowed" >&2; exit 2; fi
      INPUT="$1"; INPUT_SET=true
      ;;
  esac
  shift
done

if $LIST && [[ "$MODE" == "json-fields" ]]; then
  echo "redact.sh: --list-fields cannot be combined with --json-fields" >&2
  exit 2
fi

[[ "$INPUT_SET" == true ]] || INPUT="-"
if [[ "$INPUT" != "-" && ! -f "$INPUT" ]]; then
  echo "redact.sh: input file required and must exist" >&2
  exit 2
fi

read_input() {
  if [[ "$INPUT" == "-" ]]; then cat; else cat "$INPUT"; fi
}

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

ci_regex() {
  local value="$1"
  printf '%s\n' "$value" | awk '
    {
      for (i = 1; i <= length($0); i++) {
        char = substr($0, i, 1)
        if (char ~ /[a-zA-Z]/) printf "[%s%s]", tolower(char), toupper(char)
        else printf "%s", char
      }
    }
  '
}

redact_pem_text() {
  awk '
    function header(kind) { return "-----" "BEGIN " kind " KEY" "-----" }
    function footer(kind) { return "-----" "END " kind " KEY" "-----" }
    function key_kind(line) {
      if (line == header("RSA PRIVATE")) return "RSA PRIVATE"
      if (line == header("PRIVATE")) return "PRIVATE"
      if (line == header("OPENSSH PRIVATE")) return "OPENSSH PRIVATE"
      return ""
    }
    function redact_escaped(line, kind, h, f, start, rest, rel, end_start, end_pos) {
      for (kind_index = 1; kind_index <= 3; kind_index++) {
        if (kind_index == 1) kind = "RSA PRIVATE"
        else if (kind_index == 2) kind = "PRIVATE"
        else kind = "OPENSSH PRIVATE"
        h = header(kind); f = footer(kind)
        start = index(line, h)
        while (start > 0) {
          rest = substr(line, start + length(h))
          rel = index(rest, "\\n" f)
          if (rel == 0) break
          end_start = start + length(h) + rel - 1
          end_pos = end_start + 2 + length(f) - 1
          line = substr(line, 1, start - 1) "<REDACTED:private_key>" substr(line, end_pos + 1)
          start = index(line, h)
        }
      }
      return line
    }
    {
      if (active_kind != "") {
        if ($0 == footer(active_kind)) active_kind = ""
        next
      }
      kind = key_kind($0)
      if (kind != "") {
        print "<REDACTED:private_key>"
        active_kind = kind
        next
      }
      print redact_escaped($0)
    }
  '
}

# ──────────────────────── redact text ────────────────────────
redact_text() {
  local out; out="$(read_input)"
  local redacted_names=()
  for entry in "${REDACTIONS[@]}"; do
    local name="${entry%%|*}"
    local pat="${entry#*|}"
    if grep -E -- "$pat" <<< "$out" >/dev/null 2>&1; then
      redacted_names+=("$name")
      out="$(printf '%s' "$out" | sed -E "s@${pat}@<REDACTED:${name}>@g")"
    fi
  done
  # Remove URL userinfo while retaining the scheme and host.
  local conn_pat='([[:alpha:]][[:alnum:]+.-]*://)[^/@[:space:]]+:[^/@[:space:]]+@'
  if grep -E -- "$conn_pat" <<< "$out" >/dev/null 2>&1; then
    redacted_names+=(connection_credentials)
    out="$(printf '%s' "$out" | sed -E "s#${conn_pat}#\\1<REDACTED:connection_credentials>@#g")"
  fi

  # Replace complete PEM blocks, including a JSON-escaped block on one line.
  local pem_out; pem_out="$(printf '%s' "$out" | redact_pem_text)"
  if [[ "$pem_out" != "$out" ]]; then redacted_names+=(private_key); out="$pem_out"; fi

  # JSON key-value redaction, case-insensitive, preserving key spelling.
  for key in "${JSON_KEYS[@]}"; do
    local key_pat; key_pat="$(ci_regex "$key")"
    local key_value_pat="(\"${key_pat}\"[[:space:]]*:[[:space:]]*\")[^\"]+(\")"
    if grep -E -- "$key_value_pat" <<< "$out" >/dev/null 2>&1; then
      redacted_names+=("json:${key}")
      out="$(printf '%s' "$out" | sed -E "s#${key_value_pat}#\\1<REDACTED:json:${key}>\\2#g")"
    fi
  done
  # Env-style KEY=VALUE redaction for common credential suffixes.
  for suf in "${ENV_SUFFIXES[@]}"; do
    local env_pat="(^[[:space:]]*(export[[:space:]]+)?[A-Z][A-Z0-9_]*${suf})=[^[:space:]]+"
    if grep -E -- "$env_pat" <<< "$out" >/dev/null 2>&1; then
      redacted_names+=("env${suf}")
      out="$(printf '%s' "$out" | sed -E "s#${env_pat}#\\1=<REDACTED:env${suf}>#g")"
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
    if grep -E -- "$pat" <<< "$data" >/dev/null 2>&1; then
      data="$(printf '%s' "$data" | sed -E "s@${pat}@<REDACTED:${name}>@g")"
    fi
  done
  printf '%s' "$data"
}

# ──────────────────────── redact JSON fields (structural) ────────────────────
redact_json_fields() {
  command -v jq >/dev/null 2>&1 || { redact_text; return; }
  local normalized_keys
  normalized_keys="$(printf '%s\n' "${JSON_KEYS[@]}" | jq -R 'ascii_downcase' | jq -s '.')"
  read_input | jq --argjson keys "$normalized_keys" '
    def redact_string:
      gsub("(?s)-----BEGIN (RSA PRIVATE|PRIVATE|OPENSSH PRIVATE) KEY-----.*?-----END \\1 KEY-----"; "<REDACTED:private_key>")
      | gsub("(?<scheme>[A-Za-z][A-Za-z0-9+.-]*://)[^/@[:space:]]+:[^/@[:space:]]+@"; "\\(.scheme)<REDACTED:connection_credentials>@")
      | gsub("(?m)(?<prefix>^[[:space:]]*(export[[:space:]]+)?[A-Z][A-Z0-9_]*(_KEY|_TOKEN|_SECRET|_PASSWORD))=[^[:space:]]+"; "\\(.prefix)=<REDACTED:env>");
    walk(
      if type == "object" then
        with_entries(
          .key as $key |
          .value |= if type == "string" and ($keys | index($key | ascii_downcase)) != null
            then "<REDACTED:json:\($key)>"
            elif type == "string" then redact_string
            else . end
        )
      elif type == "string" then redact_string
      else . end
    )
  ' | apply_regex_patterns
}

case "$MODE" in
  json-fields) redact_json_fields ;;
  *) redact_text ;;
esac
