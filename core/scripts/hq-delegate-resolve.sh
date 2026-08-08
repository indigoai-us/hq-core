#!/usr/bin/env bash
# hq-core: public
# hq-delegate-resolve.sh — resolve a delegation recipient to a confirmed
# principal (person email / prs_ uid, or fleet-agent agt_ uid). Read-only.
#
# Usage:
#   core/scripts/hq-delegate-resolve.sh --company <slug> --to <token>
#
# Output (stdout, JSON): {kind, principal, displayName, source}
#   kind      — "person" | "agent"
#   principal — confirmed email, prs_… or agt_… uid
#   source    — "verbatim" | "people-resolve" | "agents-list"
#
# Exit codes:
#   0 — resolved
#   1 — usage error (missing/invalid arguments)
#   3 — ambiguous: candidate list printed to stdout as JSON
#       {status:"ambiguous", matches:[…]} — caller must present a picker
#   4 — not found (or found with no email): plain message on stderr
#
# Tenancy: every lookup is scoped with an explicit --company. This helper
# never enumerates or falls back across companies — single-company by
# construction, matching the /dm skill's resolution contract.
#
# Fast path: a token containing "@" or starting with prs_ / agt_ passes
# through verbatim with NO lookup, preserving existing invocations exactly.

set -euo pipefail

usage() {
  sed -n '3,26p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

die_usage() {
  echo "hq-delegate-resolve: $*" >&2
  usage >&2
  exit 1
}

command -v jq >/dev/null 2>&1 || { echo "hq-delegate-resolve: jq is required" >&2; exit 1; }

COMPANY="" TOKEN=""
while [ $# -gt 0 ]; do
  case "$1" in
    --company) COMPANY="${2:-}"; shift 2 ;;
    --to)      TOKEN="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die_usage "unknown argument: $1" ;;
  esac
done

[ -n "$COMPANY" ] || die_usage "--company is required (single-company lookups only; never a multi-company scan)"
[ -n "$TOKEN" ]   || die_usage "--to is required"

emit() { # kind principal displayName source
  jq -cn --arg kind "$1" --arg principal "$2" --arg name "$3" --arg source "$4" \
    '{kind: $kind, principal: $principal,
      displayName: (if $name == "" then null else $name end), source: $source}'
}

# Strip CLI noise (version warnings, session-refresh notices) before the JSON
# payload: keep everything from the first line that starts a JSON value.
json_only() {
  awk 'started {print; next} /^[[:space:]]*[{[]/ {started=1; print}'
}

# --- fast path: already a principal — pass through verbatim, no lookup -------

case "$TOKEN" in
  agt_*)
    emit agent "$TOKEN" "" verbatim
    exit 0
    ;;
  prs_*|*@*)
    emit person "$TOKEN" "" verbatim
    exit 0
    ;;
esac

# --- name → people roster (single-company, read-only) ------------------------

PEOPLE_RAW="$(hq people resolve "$TOKEN" --json --company "$COMPANY" 2>/dev/null | json_only || true)"
PEOPLE_STATUS=""
if [ -n "$PEOPLE_RAW" ] && printf '%s' "$PEOPLE_RAW" | jq -e . >/dev/null 2>&1; then
  PEOPLE_STATUS="$(printf '%s' "$PEOPLE_RAW" | jq -r '.status // empty')"
fi

case "$PEOPLE_STATUS" in
  found)
    EMAIL="$(printf '%s' "$PEOPLE_RAW" | jq -r '.email // empty')"
    NAME="$(printf '%s' "$PEOPLE_RAW" | jq -r '.name // .displayName // empty')"
    [ -n "$EMAIL" ] || { echo "hq-delegate-resolve: resolver returned found but no email for '$TOKEN'" >&2; exit 4; }
    emit person "$EMAIL" "$NAME" people-resolve
    exit 0
    ;;
  ambiguous)
    printf '%s' "$PEOPLE_RAW" | jq -c '{status: "ambiguous", matches: (.matches // [])}'
    exit 3
    ;;
  no_email)
    # A person entry without an email is often a fleet agent's roster row —
    # fall through to the agent roster before treating this as terminal.
    PERSON_NO_EMAIL=1
    ;;
  not_found|"")
    : # fall through to the fleet-agent roster
    ;;
  *)
    echo "hq-delegate-resolve: unexpected resolver status '$PEOPLE_STATUS' for '$TOKEN'" >&2
    exit 4
    ;;
esac

# --- name → fleet-agent roster (same company, read-only) ---------------------

AGENTS_RAW="$(hq agents list --company "$COMPANY" --json 2>/dev/null | json_only || true)"
if [ -z "$AGENTS_RAW" ] || ! printf '%s' "$AGENTS_RAW" | jq -e . >/dev/null 2>&1; then
  AGENTS_RAW="[]"
fi

MATCHES="$(printf '%s' "$AGENTS_RAW" | jq -c --arg t "$TOKEN" '
  [ .[]
    | select((.name // .displayName // "") | ascii_downcase == ($t | ascii_downcase))
    | {agentUid: (.agentUid // .uid // empty), name: (.name // .displayName // "")}
    | select(.agentUid != "")
  ]')"
MATCH_COUNT="$(printf '%s' "$MATCHES" | jq 'length')"

if [ "$MATCH_COUNT" -eq 1 ]; then
  emit agent \
    "$(printf '%s' "$MATCHES" | jq -r '.[0].agentUid')" \
    "$(printf '%s' "$MATCHES" | jq -r '.[0].name')" \
    agents-list
  exit 0
elif [ "$MATCH_COUNT" -gt 1 ]; then
  printf '%s' "$MATCHES" | jq -c '{status: "ambiguous", matches: .}'
  exit 3
fi

if [ "${PERSON_NO_EMAIL:-0}" -eq 1 ]; then
  echo "hq-delegate-resolve: '$TOKEN' was found in company '$COMPANY' but has no email on record and matches no fleet agent — pass their exact email, personUid (prs_…), or agentUid (agt_…) instead" >&2
else
  echo "hq-delegate-resolve: no teammate or fleet agent named '$TOKEN' found in company '$COMPANY' — pass the exact email, personUid (prs_…), or agentUid (agt_…) instead" >&2
fi
exit 4
