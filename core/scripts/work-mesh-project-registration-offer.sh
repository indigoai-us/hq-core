#!/usr/bin/env bash
set -euo pipefail

ROOT="${HQ_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
FLAG_READER="$ROOT/.claude/hooks/work-mesh-project-registration-offer-flag.cjs"

die() { echo "$*" >&2; exit 1; }

resolve_cloud_uid() {
  local company="$1" manifest="$ROOT/companies/manifest.yaml"
  [ -f "$manifest" ] || return 0
  awk -v company="$company" '
    /^companies:[[:space:]]*$/ { in_companies=1; next }
    in_companies && /^[^[:space:]]/ { in_companies=0 }
    in_companies && /^  [^ #][^:]*:/ {
      slug=$1; sub(/[[:space:]]+$/, "", slug); sub(/:$/, "", slug); in_company=(slug == company); next
    }
    in_company && /^  [^[:space:]#]/ { exit }
    in_company && $1 == "cloud_uid:" { gsub(/["\047]/, "", $2); sub(/[[:space:]]+$/, "", $2); print $2; exit }
  ' "$manifest"
}

valid_names() {
  case "$1" in *[!A-Za-z0-9_-]*|"") return 1 ;; esac
  case "$2" in *[!A-Za-z0-9._-]*|"") return 1 ;; esac
}

board_path() { printf '%s\n' "$ROOT/companies/$1/board.json"; }

update_prompt_state() {
  local company="$1" project="$2" state="$3" board tmp
  board="$(board_path "$company")"
  [ -f "$board" ] || die "no company board for $company"
  jq -e --arg id "$project" 'any(.projects[]?; .id == $id or .mesh_project_id == $id)' "$board" >/dev/null \
    || die "no local Board project $project for $company"
  tmp="$(mktemp)"
  jq --arg id "$project" --arg state "$state" '
    .projects |= map(if .id == $id or .mesh_project_id == $id then . + {mesh_registration_prompt_state:$state} else . end)
  ' "$board" > "$tmp"
  mv "$tmp" "$board"
}

check_offer() {
  local company="$1" project="$2" uid board row_state enabled
  valid_names "$company" "$project" || die "invalid company or project id"
  uid="$(resolve_cloud_uid "$company")"
  [ -n "$uid" ] || { printf 'local\n'; return 0; }
  [[ "$uid" =~ ^cmp_[A-Za-z0-9]{3,128}$ ]] || { printf 'local\n'; return 0; }
  board="$(board_path "$company")"
  [ -f "$board" ] || { printf 'missing\n'; return 0; }
  row_state="$(jq -r --arg id "$project" '
    [.projects[]? | select(.id == $id or .mesh_project_id == $id)] | first |
    if . == null then "missing"
    elif (.threadId // "") != "" and (.channelId // "") != "" then "registered"
    else (.mesh_registration_prompt_state // "offer") end
  ' "$board" 2>/dev/null || printf 'missing')"
  case "$row_state" in
    accepted|deferred|registered|missing) printf '%s\n' "$row_state"; return 0 ;;
  esac

  [ -f "$FLAG_READER" ] && command -v node >/dev/null 2>&1 || { printf 'off\n'; return 0; }
  enabled="$(HQ_COMPANY_UID="$uid" HQ_COMPANY_SLUG="$company" \
    HQ_CLI_BIN="$(command -v hq 2>/dev/null || true)" node "$FLAG_READER" 2>/dev/null || printf 'false')"
  [ "$enabled" = "true" ] && printf 'offer\n' || printf 'off\n'
}

if [ "${1:-}" = "--check" ] && [ "$#" -eq 3 ]; then
  check_offer "$2" "$3"
elif [ "${1:-}" = "--accept" ] && [ "$#" -eq 3 ]; then
  valid_names "$2" "$3" || die "invalid company or project id"
  update_prompt_state "$2" "$3" accepted
elif [ "${1:-}" = "--defer" ] && [ "$#" -eq 3 ]; then
  valid_names "$2" "$3" || die "invalid company or project id"
  update_prompt_state "$2" "$3" deferred
else
  die "usage: work-mesh-project-registration-offer.sh --check <company> <project-id> | --accept <company> <project-id> | --defer <company> <project-id>"
fi
