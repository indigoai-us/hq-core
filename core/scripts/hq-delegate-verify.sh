#!/usr/bin/env bash
# hq-core: public
# hq-delegate-verify.sh — prove a delegation can actually be picked up
# before anyone is told it is theirs, or print the full plan without
# touching anything.
#
# Usage (probe mode — after grants, before the DM):
#   core/scripts/hq-delegate-verify.sh --manifest <path>
#
# Probes every manifest vaultPrefix with `hq files browse` and requires it
# reachable AND non-empty. All pass -> manifest advances granted -> verified
# (send is gated on this). Any failure -> non-zero, the failing prefix and
# likely cause named, status left at its last successful value so a re-run
# resumes without re-granting.
#
# Usage (dry-run mode — full plan, zero mutation):
#   core/scripts/hq-delegate-verify.sh --dry-run \
#     --company <slug> --project <name> --to <principal> [--mode transfer|share]
#
# Prints recipient, mode, every prefix with its permission, the secret
# names an .env.schema would grant, repo + branch, and the DM headline that
# would be sent. Exits 0. Creates nothing under workspace/delegations/ and
# invokes no mutating command.
#
# Env: HQ_ROOT — HQ root override (default: resolved from script location)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HQ_ROOT="${HQ_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"

usage() { sed -n '3,25p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }
die()   { echo "hq-delegate-verify: $*" >&2; exit 1; }

command -v jq >/dev/null 2>&1 || die "jq is required but not installed"

MANIFEST="" DRY_RUN=0 COMPANY="" PROJECT="" TO="" MODE="transfer"
while [ $# -gt 0 ]; do
  case "$1" in
    --manifest) MANIFEST="${2:-}"; shift 2 ;;
    --dry-run)  DRY_RUN=1; shift ;;
    --company)  COMPANY="${2:-}"; shift 2 ;;
    --project)  PROJECT="${2:-}"; shift 2 ;;
    --to)       TO="${2:-}"; shift 2 ;;
    --mode)     MODE="${2:-}"; shift 2 ;;
    -h|--help)  usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

# =============================================================================
# Dry-run mode: full plan from the builder's own derivation, zero mutation
# =============================================================================

if [ "$DRY_RUN" -eq 1 ]; then
  [ -n "$COMPANY" ] || die "--dry-run requires --company"
  [ -n "$PROJECT" ] || die "--dry-run requires --project"
  [ -n "$TO" ]      || die "--dry-run requires --to"

  # The builder's --dry-run prints the manifest it WOULD write — single
  # derivation source, nothing lands on disk.
  PLAN_JSON="$(HQ_ROOT="$HQ_ROOT" bash "$SCRIPT_DIR/hq-delegate-bundle.sh" build \
    --company "$COMPANY" --project "$PROJECT" --to "$TO" --mode "$MODE" --dry-run)" \
    || die "could not derive the delegation plan (see builder error above)"

  # Secret names the US-005 step would grant (same .env.schema derivation).
  REPO_REL="$(printf '%s' "$PLAN_JSON" | jq -r '.repo.path // empty')"
  SCHEMA=""
  for candidate in \
    "$HQ_ROOT/companies/$COMPANY/projects/$PROJECT/.env.schema" \
    "${REPO_REL:+$HQ_ROOT/$REPO_REL/.env.schema}"; do
    [ -n "$candidate" ] && [ -f "$candidate" ] && { SCHEMA="$candidate"; break; }
  done
  SECRET_NAMES="(none — no .env.schema found)"
  if [ -n "$SCHEMA" ]; then
    SECRET_NAMES="$(grep -E '^[A-Za-z_][A-Za-z0-9_]*=' "$SCHEMA" | cut -d= -f1 | sort -u | tr '\n' ' ')"
    [ -n "$SECRET_NAMES" ] || SECRET_NAMES="(none declared)"
  fi

  echo "Delegation dry run — nothing will be pushed, granted, transferred, or sent."
  echo
  echo "  Recipient:  $TO"
  echo "  Mode:       $MODE"
  echo "  Company:    $COMPANY"
  echo "  Project:    $PROJECT"
  echo
  echo "  Vault grants that would be written:"
  printf '%s' "$PLAN_JSON" | jq -r '.vaultPrefixes[] | "    \(.permission)\ton \(.prefix)\t(\(.reason // ""))"'
  echo
  echo "  Secret names that would be granted (read): $SECRET_NAMES"
  echo
  if printf '%s' "$PLAN_JSON" | jq -e '.repo != null' >/dev/null; then
    printf '%s' "$PLAN_JSON" | jq -r '"  Repo handover: \(.repo.path) — branch \(.repo.branch // "(none)") (base \(.repo.baseBranch))"'
  else
    echo "  Repo handover: none (project has no repoPath)"
  fi
  echo
  echo "  DM that would be sent to $TO:"
  echo "    \"Project handoff: $PROJECT is yours now — open details for the brief, paste the prompt into your agent to pick it up\""
  echo "    (prompt: generated pickup prompt; details: the delegation brief)"
  exit 0
fi

# =============================================================================
# Probe mode: reachability of every granted prefix
# =============================================================================

[ -n "$MANIFEST" ] || die "--manifest is required (or --dry-run with --company/--project/--to)"
[ -f "$MANIFEST" ] || die "manifest not found: $MANIFEST"
jq -e . "$MANIFEST" >/dev/null 2>&1 || die "manifest is not valid JSON: $MANIFEST"

COMPANY="$(jq -r '.company // empty' "$MANIFEST")"
STATUS="$(jq -r '.status // empty' "$MANIFEST")"
[ -n "$COMPANY" ] || die "manifest has no company"

case "$STATUS" in
  granted|verified) ;;
  building) die "manifest status is 'building' — run hq-delegate-grant.sh first (probe verifies grants, it cannot create them)" ;;
  *) die "manifest status is '$STATUS' — probe runs from 'granted' (or re-runs from 'verified')" ;;
esac

PREFIX_COUNT="$(jq '.vaultPrefixes | length' "$MANIFEST")"
[ "$PREFIX_COUNT" -gt 0 ] || die "manifest has no vaultPrefixes to probe"

echo "hq-delegate-verify: probing $PREFIX_COUNT prefix(es) in company '$COMPANY'"
FAILED=0
i=0
while [ "$i" -lt "$PREFIX_COUNT" ]; do
  PFX="$(jq -r ".vaultPrefixes[$i].prefix" "$MANIFEST")"
  BROWSE_OUT="$(hq files browse "$PFX" --company "$COMPANY" 2>&1)" && BROWSE_RC=0 || BROWSE_RC=$?
  if [ "$BROWSE_RC" -ne 0 ]; then
    echo "  FAIL  $PFX — browse errored (likely cause: the grant did not land, or the caller's session expired — re-run /hq-login and hq-delegate-grant.sh)"
    FAILED=1
  elif [ -z "$(printf '%s' "$BROWSE_OUT" | tr -d '[:space:]')" ]; then
    echo "  FAIL  $PFX — reachable but EMPTY (likely cause: the dossier was never pushed to the vault — hq sync push companies/$COMPANY/... and re-run)"
    FAILED=1
  else
    echo "  pass  $PFX"
  fi
  i=$((i + 1))
done

# --- referenced files: prefix reachability is not enough ---------------------
# (Live finding: a knowledge prefix can be reachable and non-empty while the
# SPECIFIC referenced file is absent — the recipient then pulls a folder that
# silently misses the note the brief points at. Probe each referenced file.)

REF_COUNT="$(jq -r --arg co "$COMPANY" \
  '[((.knowledge // []) + (.policies // []))[] | select(startswith("companies/" + $co + "/"))] | length' "$MANIFEST")"
if [ "$REF_COUNT" -gt 0 ]; then
  echo "hq-delegate-verify: probing $REF_COUNT referenced knowledge/policy file(s)"
  while IFS= read -r kpath; do
    [ -n "$kpath" ] || continue
    REL="${kpath#companies/$COMPANY/}"
    PARENT="$(dirname "$REL")/"
    BASE="$(basename "$REL")"
    LISTING="$(hq files browse "$PARENT" --company "$COMPANY" 2>/dev/null || true)"
    if printf '%s\n' "$LISTING" | grep -qF "$BASE"; then
      echo "  pass  $REL"
    else
      echo "  FAIL  $REL — granted prefix is reachable but this referenced file is NOT in the vault (likely cause: it was never pushed — hq sync push $kpath --company $COMPANY and re-run)"
      FAILED=1
    fi
  done <<EOF
$(jq -r --arg co "$COMPANY" '((.knowledge // []) + (.policies // []))[] | select(startswith("companies/" + $co + "/"))' "$MANIFEST")
EOF
fi

if [ "$FAILED" -ne 0 ]; then
  echo "hq-delegate-verify: probe FAILED — the DM must not be sent; fix the failing prefix(es) above and re-run (manifest status left at '$STATUS')" >&2
  exit 1
fi

NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
TMP_MANIFEST="$(mktemp)"
jq --arg now "$NOW" '.status = "verified" | .verifiedAt = $now' \
  "$MANIFEST" > "$TMP_MANIFEST" && mv "$TMP_MANIFEST" "$MANIFEST"

echo "hq-delegate-verify: all $PREFIX_COUNT prefix(es) reachable — manifest status advanced to 'verified'"
