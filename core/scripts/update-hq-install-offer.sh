#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
STATE_DIR="${HOME:?HOME must be set}/.hq/anywhere"
STATE_FILE="$STATE_DIR/update-hq-install-offer.json"
FLAG_READER="$ROOT/core/scripts/hq-anywhere-runtime-flag.cjs"
HQ_ROOT="${HQ_ROOT:-$ROOT}"
TEMP_FILE=""

cleanup() {
  if [[ -n "$TEMP_FILE" ]]; then
    rm -f "$TEMP_FILE"
  fi
}
trap cleanup EXIT

usage() {
  echo "usage: update-hq-install-offer.sh --check|--accept|--decline" >&2
  exit 2
}

[[ $# -eq 1 ]] || usage
ACTION="$1"
case "$ACTION" in
  --check|--accept|--decline) ;;
  *) usage ;;
esac

result_for_current_state() {
  if [[ -e "$STATE_FILE" || -L "$STATE_FILE" ]]; then
    printf '%s\n' answered
    return
  fi
  if [[ -f "$STATE_DIR/claude-install.json" || -f "$STATE_DIR/codex-install.json" ]]; then
    printf '%s\n' installed
    return
  fi
  if [[ ! -f "$FLAG_READER" ]] || ! command -v node >/dev/null 2>&1 || ! command -v hq >/dev/null 2>&1; then
    printf '%s\n' off
    return
  fi
  local cli_bin flag endpoint company_slug company_uid
  cli_bin="$(command -v hq)"
  endpoint="${HQ_FLAGS_API_URL:-}"
  if [[ -z "${endpoint//[[:space:]]/}" ]]; then
    if ! endpoint="$(resolve_flag_endpoint "$cli_bin")"; then
      printf '%s\n' off
      return
    fi
  fi
  company_uid="${HQ_COMPANY_UID:-}"
  company_slug="${HQ_COMPANY_SLUG:-}"
  if [[ ! "$company_uid" =~ ^cmp_[A-Za-z0-9]{3,128}$ ]]; then
    company_slug="$(resolve_bound_company_slug)"
    company_uid="$(resolve_company_uid "$company_slug")"
  fi
  if [[ ! "$company_uid" =~ ^cmp_[A-Za-z0-9]{3,128}$ ]]; then
    printf '%s\n' off
    return
  fi
  if ! flag="$(HQ_FLAG_CLI_BIN="$cli_bin" HQ_FLAGS_API_URL="$endpoint" \
    HQ_COMPANY_UID="$company_uid" HQ_COMPANY_SLUG="$company_slug" node "$FLAG_READER")"; then
    printf '%s\n' off
    return
  fi
  if [[ "$flag" != true ]]; then
    printf '%s\n' off
    return
  fi
  printf '%s\n' offer
}

resolve_flag_endpoint() {
  local cli_bin="$1"
  node - "$cli_bin" <<'NODE'
const fs = require("node:fs");
const path = require("node:path");
const { pathToFileURL } = require("node:url");
(async () => {
  let current = fs.realpathSync(process.argv[2]);
  if (!fs.statSync(current).isDirectory()) current = path.dirname(current);
  for (let depth = 0; depth < 16; depth += 1) {
    const manifest = path.join(current, "package.json");
    if (fs.existsSync(manifest) && JSON.parse(fs.readFileSync(manifest, "utf8")).name === "@indigoai-us/hq-cli") {
      const endpointFile = path.join(current, "dist/lib/flag-registry-endpoint.js");
      const { FLAG_REGISTRY_DEFAULT_ENDPOINT } = await import(pathToFileURL(endpointFile).href);
      if (typeof FLAG_REGISTRY_DEFAULT_ENDPOINT === "string" && FLAG_REGISTRY_DEFAULT_ENDPOINT.trim()) {
        process.stdout.write(FLAG_REGISTRY_DEFAULT_ENDPOINT.trim());
        return;
      }
      break;
    }
    const parent = path.dirname(current);
    if (parent === current) break;
    current = parent;
  }
  process.exitCode = 1;
})().catch(() => { process.exitCode = 1; });
NODE
}

resolve_bound_company_slug() {
  local slug
  [[ -f "$HQ_ROOT/core/scripts/hq-session.sh" ]] || return 0
  slug="$(env HQ_ROOT="$HQ_ROOT" HQ_HQ_SESSION_NO_CLI=1 \
    bash "$HQ_ROOT/core/scripts/hq-session.sh" get company_slug 2>/dev/null || true)"
  if [[ "$slug" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]]; then
    printf '%s\n' "$slug"
  fi
  return 0
}

resolve_company_uid() {
  local slug="$1" uid_file="$HQ_ROOT/companies/$1/.company-uid" manifest
  [[ -n "$slug" ]] || return 0
  if [[ -f "$uid_file" ]]; then
    cat "$uid_file"
    return
  fi
  manifest="$HQ_ROOT/companies/manifest.yaml"
  [[ -f "$manifest" ]] || return 0
  awk -v company="$slug" '
    /^companies:[[:space:]]*$/ { in_companies=1; next }
    in_companies && /^[^[:space:]]/ { in_companies=0 }
    in_companies && /^  [^ #][^:]*:/ {
      current=$1; sub(/[[:space:]]+$/, "", current); sub(/:$/, "", current); in_company=(current == company); next
    }
    in_company && /^  [^[:space:]#]/ { exit }
    in_company && $1 == "cloud_uid:" { gsub(/["\047\r]/, "", $2); print $2; exit }
  ' "$manifest"
}

write_answer() {
  local answer="$1"
  umask 077
  mkdir -p "$STATE_DIR"
  chmod 700 "$STATE_DIR"
  TEMP_FILE="$(mktemp "$STATE_DIR/.update-hq-install-offer.XXXXXX")"
  printf '{"version":1,"answer":"%s","answeredAt":"%s"}\n' \
    "$answer" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" > "$TEMP_FILE"
  chmod 600 "$TEMP_FILE"
  if ! mv -n "$TEMP_FILE" "$STATE_FILE" 2>/dev/null; then
    if [[ -e "$STATE_FILE" || -L "$STATE_FILE" ]]; then
      rm -f "$TEMP_FILE"
      TEMP_FILE=""
      printf '%s\n' answered
      return
    fi
    echo "update-hq-install-offer: could not persist the answer" >&2
    return 1
  fi
  if [[ -e "$TEMP_FILE" ]]; then
    if [[ -e "$STATE_FILE" || -L "$STATE_FILE" ]]; then
      rm -f "$TEMP_FILE"
      TEMP_FILE=""
      printf '%s\n' answered
      return
    fi
    echo "update-hq-install-offer: answer was not persisted" >&2
    return 1
  fi
  if [[ -f "$STATE_FILE" ]]; then
    rm -f "$TEMP_FILE"
    TEMP_FILE=""
    printf '%s\n' "$answer"
  else
    echo "update-hq-install-offer: answer was not persisted" >&2
    return 1
  fi
}

if [[ "$ACTION" == --check ]]; then
  result_for_current_state
  exit 0
fi

state="$(result_for_current_state)"
if [[ "$state" != offer ]]; then
  printf '%s\n' "$state"
  exit 0
fi

if [[ "$ACTION" == --accept ]]; then
  write_answer accepted
else
  write_answer declined
fi
