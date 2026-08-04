#!/usr/bin/env bash
# hq-core: public
# refresh-vault-access.sh — build/refresh the local vault-access manifest that
# enforce-vault-write-access.sh (PreToolUse hook) reads.
#
# Output: <hqRoot>/.hq/vault-access.json
#
#   {
#     "version": 1,
#     "generatedAt": "2026-01-01T00:00:00Z",
#     "companies": {
#       "<slug>": {
#         "role": "owner|admin|member|guest|unknown",
#         "grants": [ { "path": "reports/*", "permission": "read|write" } ]
#       }
#     }
#   }
#
# Sources (best-effort, all via the hq CLI):
#   - grants: `hq files shared-with-me` (explicit per-prefix grants)
#   - role:   `hq members --company <slug> list` matched against the caller's
#             email (from `hq whoami`, override with HQ_VAULT_ACCESS_EMAIL)
#
# Fail-open by design: anything this script cannot determine is recorded as
# role "unknown" (the hook does not enforce unknown roles), and a company it
# cannot query at all is left out of the manifest entirely (the hook allows
# companies absent from the manifest). The server-side STS/ACL layer remains
# the authoritative security boundary — this manifest only powers the local
# early-warning block for read-only shares.
#
# Usage:
#   bash core/scripts/refresh-vault-access.sh [--company <slug>]... [--root <hqRoot>]
#
# With no --company, refreshes every company that appears in the
# `hq files shared-with-me` cross-company roll-up.

set -uo pipefail

log() { printf 'refresh-vault-access: %s\n' "$*" >&2; }

ROOT=""
SLUGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --root)
      ROOT="${2:-}"
      shift 2 || { log "--root requires a value"; exit 1; }
      ;;
    --company)
      SLUGS[${#SLUGS[@]}]="${2:-}"
      shift 2 || { log "--company requires a value"; exit 1; }
      ;;
    -h|--help)
      sed -n '2,33p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      log "unknown argument: $1"
      exit 1
      ;;
  esac
done

is_hq_root() { [ -n "${1:-}" ] && [ -d "$1/core" ] && [ -d "$1/.claude" ]; }

if [ -z "$ROOT" ]; then
  if is_hq_root "${CLAUDE_PROJECT_DIR:-}"; then
    ROOT="$CLAUDE_PROJECT_DIR"
  else
    dir="$PWD"
    while [ -n "$dir" ] && [ "$dir" != "/" ]; do
      if is_hq_root "$dir"; then ROOT="$dir"; break; fi
      dir="$(dirname "$dir")"
    done
  fi
fi
if ! is_hq_root "$ROOT"; then
  log "could not resolve the HQ root (pass --root <hqRoot>)"
  exit 1
fi

command -v jq >/dev/null 2>&1 || { log "jq is required"; exit 1; }
if ! command -v hq >/dev/null 2>&1; then
  log "hq CLI not found — nothing refreshed (the write-access hook stays fail-open without a manifest)"
  exit 0
fi

strip_ansi() { sed -e 's/\x1b\[[0-9;]*m//g'; }

# ── caller email (for role lookup) ─────────────────────────────────────────
EMAIL="${HQ_VAULT_ACCESS_EMAIL:-}"
if [ -z "$EMAIL" ]; then
  EMAIL="$(hq whoami 2>/dev/null | strip_ansi \
    | grep -Eo '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}' \
    | grep -v '@outposts\.' | head -1 || true)"
fi
[ -n "$EMAIL" ] || log "could not determine caller email — roles will be 'unknown' (hook will not enforce)"

# ── explicit grants via shared-with-me ─────────────────────────────────────
# Table columns: COMPANY  PATH  PERMISSION  SOURCE (header + ─── separator).
fetch_grants_tsv() {
  # $1 = optional slug filter; prints "slug<TAB>path<TAB>permission" rows.
  local slug="${1:-}" out
  if [ -n "$slug" ]; then
    out="$(hq files shared-with-me --company "$slug" 2>/dev/null | strip_ansi)" || return 1
  else
    out="$(hq files shared-with-me 2>/dev/null | strip_ansi)" || return 1
  fi
  printf '%s\n' "$out" | awk '
    /^COMPANY[[:space:]]/ { next }
    /^─/ { next }
    /^[[:space:]]*$/ { next }
    /^Nothing is explicitly shared/ { next }
    NF >= 3 {
      perm = ""
      if ($3 == "read" || $3 == "write" || $3 == "admin") perm = $3
      else if (NF >= 4 && ($4 == "read" || $4 == "write" || $4 == "admin")) perm = $4
      if (perm != "") printf "%s\t%s\t%s\n", $1, $2, perm
    }'
}

# ── role lookup ────────────────────────────────────────────────────────────
fetch_role() {
  # $1 = slug; prints role or "unknown". Never fails.
  local slug="$1" out role=""
  if [ -n "$EMAIL" ]; then
    # --company is declared on the parent `members` group, so it goes first.
    out="$(hq members --company "$slug" list 2>/dev/null | strip_ansi)" || out=""
    if [ -n "$out" ]; then
      role="$(printf '%s\n' "$out" | awk -v email="$EMAIL" '$1 == email { print $2; exit }')"
    fi
  fi
  case "$role" in
    owner|admin|member|guest) printf '%s' "$role" ;;
    *) printf 'unknown' ;;
  esac
}

GRANTS_TSV=""
if [ "${#SLUGS[@]}" -gt 0 ]; then
  for slug in "${SLUGS[@]}"; do
    rows="$(fetch_grants_tsv "$slug")" || { log "skipping $slug — shared-with-me query failed"; continue; }
    GRANTS_TSV="${GRANTS_TSV}${rows}
"
  done
else
  GRANTS_TSV="$(fetch_grants_tsv)" || { log "shared-with-me roll-up failed — nothing refreshed"; exit 0; }
fi

# Companies to include = every slug present in the grant rows (plus any
# explicitly requested slugs, so a company with zero explicit grants still
# gets a role entry when asked for by name).
ALL_SLUGS="$(printf '%s\n' "$GRANTS_TSV" | awk -F'\t' 'NF { print $1 }' | sort -u)"
if [ "${#SLUGS[@]}" -gt 0 ]; then
  ALL_SLUGS="$(printf '%s\n%s\n' "$ALL_SLUGS" "$(printf '%s\n' "${SLUGS[@]}")" | awk 'NF' | sort -u)"
fi

if [ -z "$ALL_SLUGS" ]; then
  log "no explicit grants found — writing an empty manifest (hook stays fail-open everywhere)"
fi

COMPANIES_JSON="{}"
while IFS= read -r slug; do
  [ -n "$slug" ] || continue
  role="$(fetch_role "$slug")"
  grants_json="$(printf '%s\n' "$GRANTS_TSV" \
    | awk -F'\t' -v s="$slug" '$1 == s { printf "%s\t%s\n", $2, $3 }' \
    | jq -Rn '[inputs | split("\t") | select(length == 2) | {path: .[0], permission: .[1]}]')"
  COMPANIES_JSON="$(printf '%s' "$COMPANIES_JSON" \
    | jq --arg slug "$slug" --arg role "$role" --argjson grants "$grants_json" \
        '. + {($slug): {role: $role, grants: $grants}}')"
done <<EOF
$ALL_SLUGS
EOF

mkdir -p "$ROOT/.hq"
TMP_OUT="$(mktemp "$ROOT/.hq/vault-access.json.XXXXXX")"
jq -n --argjson companies "$COMPANIES_JSON" \
  --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{version: 1, generatedAt: $ts, companies: $companies}' > "$TMP_OUT"
mv "$TMP_OUT" "$ROOT/.hq/vault-access.json"

N_COMPANIES="$(printf '%s\n' "$ALL_SLUGS" | awk 'NF' | wc -l | tr -d ' ')"
log "wrote .hq/vault-access.json ($N_COMPANIES companies, identity: ${EMAIL:-unknown})"
exit 0
