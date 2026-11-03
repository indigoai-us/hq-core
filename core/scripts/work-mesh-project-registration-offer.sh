#!/usr/bin/env bash
# Report whether a local Board project needs a Work Mesh registration.
# Registration is always-on for cloud-backed companies: /brainstorm and /prd
# call this right after the Board entry is written, then run
# register-project.sh when it prints `register`. There is no flag and no
# prompt. The filename is kept so existing allowed-tools lists keep working.
set -euo pipefail

ROOT="${HQ_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

die() { echo "$*" >&2; exit 1; }

# The named company's own record decides its uid: companies/<co>/.company-uid,
# then the manifest cloud_uid. HQ_COMPANY_UID alone is used only when no uid is
# recorded and the active company is the named company: a session or agent
# runtime may export it for a different company, and using it then would
# register company B's project in company A's Work Mesh.
resolve_cloud_uid() {
  local company="$1" manifest="$ROOT/companies/manifest.yaml" file uid=""
  file="$ROOT/companies/$company/.company-uid"
  if [ -f "$file" ]; then
    uid="$(tr -d '[:space:]' < "$file")"
  elif [ -f "$manifest" ]; then
    uid="$(manifest_uid "$company" "$manifest")"
  fi
  if [ -z "$uid" ]; then
    # No recorded uid: accept HQ_COMPANY_UID only for the active company.
    active_company_env_uid "$company"
    return 0
  fi
  if [ -n "${HQ_COMPANY_UID:-}" ] && [ "$HQ_COMPANY_UID" != "$uid" ]; then
    echo "work-mesh-project-registration-offer: HQ_COMPANY_UID does not match $company's recorded uid; using $company's uid" >&2
  fi
  printf '%s\n' "$uid"
}

# --- active-company HQ_COMPANY_UID check (shared shape with
# work-mesh-project-registration-offer.sh) ---
active_company_slug() {
  local slug="${HQ_COMPANY_SLUG:-}"
  if [ -z "$slug" ] && [ -f "$ROOT/core/scripts/hq-session.sh" ]; then
    slug="$(env HQ_ROOT="$ROOT" HQ_HQ_SESSION_NO_CLI=1 \
      bash "$ROOT/core/scripts/hq-session.sh" get company_slug 2>/dev/null | tr -d '[:space:]' || true)"
  fi
  printf '%s\n' "$slug"
}

# Prints HQ_COMPANY_UID only when it is well formed, the active company is the
# named company, and no other company records that uid. Prints nothing
# otherwise.
active_company_env_uid() {
  local company="$1" env_uid="${HQ_COMPANY_UID:-}" active
  [[ "$env_uid" =~ ^cmp_[A-Za-z0-9]{3,128}$ ]] || return 0
  active="$(active_company_slug)"
  [ -n "$active" ] && [ "$active" = "$company" ] || return 0
  if uid_recorded_elsewhere "$company" "$env_uid"; then
    return 0
  fi
  printf '%s\n' "$env_uid"
}

uid_recorded_elsewhere() {
  local company="$1" uid="$2" f manifest="$ROOT/companies/manifest.yaml"
  for f in "$ROOT"/companies/*/.company-uid; do
    [ -f "$f" ] || continue
    [ "$(basename "$(dirname "$f")")" = "$company" ] && continue
    [ "$(tr -d '[:space:]' < "$f")" = "$uid" ] && return 0
  done
  [ -f "$manifest" ] || return 1
  tr -d '\r' < "$manifest" | awk -v uid="$uid" '
    $1 == "cloud_uid:" { v=$2; gsub(/["\047]/, "", v); if (v == uid) found=1 }
    END { exit !found }'
}

manifest_uid() {
  local company="$1" manifest="$2"
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

# Prints exactly one word:
#   local      - company is not cloud-backed; nothing to register
#   missing    - no local Board entry with this id
#   registered - Board entry already carries threadId and channelId
#   deferred   - the user declined registration for this entry under the
#                earlier prompt flow; do not register it automatically
#   register   - cloud-backed, entry present, not yet registered
check_registration() {
  local company="$1" project="$2" uid board
  valid_names "$company" "$project" || die "invalid company or project id"
  uid="$(resolve_cloud_uid "$company" | tr -d '\r')"
  [ -n "$uid" ] || { printf 'local\n'; return 0; }
  [[ "$uid" =~ ^cmp_[A-Za-z0-9]{3,128}$ ]] || { printf 'local\n'; return 0; }
  board="$(board_path "$company")"
  [ -f "$board" ] || { printf 'missing\n'; return 0; }
  jq -r --arg id "$project" '
    [.projects[]? | select(.id == $id or .mesh_project_id == $id)] | first |
    if . == null then "missing"
    elif (.threadId // "") != "" and (.channelId // "") != "" then "registered"
    elif (.mesh_registration_prompt_state // "") == "deferred" then "deferred"
    else "register" end
  ' "$board" 2>/dev/null || printf 'missing\n'
}

if [ "${1:-}" = "--check" ] && [ "$#" -eq 3 ]; then
  check_registration "$2" "$3"
else
  die "usage: work-mesh-project-registration-offer.sh --check <company> <project-id>"
fi
