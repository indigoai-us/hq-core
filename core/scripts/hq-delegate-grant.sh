#!/usr/bin/env bash
# hq-core: public
# hq-delegate-grant.sh — materialize a delegation's dossier in the vault and
# write the ACL grants its manifest declares, verifying each one landed.
#
# Usage:
#   core/scripts/hq-delegate-grant.sh --manifest <path> [--yes]
#
# Without --yes: prints the full grant plan (prefix, principal, permission —
# the write grant is a privilege escalation and needs explicit confirmation)
# and exits 2 without mutating anything. The caller (the /delegate skill)
# confirms with the user, then re-invokes with --yes.
#
# With --yes:
#   1. hq sync push the project directory so the vault prefix exists
#   2. hq files share each manifest vaultPrefix to the recipient
#   3. read each grant back with hq files acl and match grantee + permission
#   4. advance manifest status building -> granted, stamping verifiedAt
#
# Direct ACL grants ONLY — this helper never mints a share-session URL
# (policy hq-delegate-never-inlines-secrets-or-share-urls).
#
# Idempotent: a prefix whose grant already exists is reported, not an error.
# A failed read-back exits non-zero and leaves manifest status unchanged.
#
# Env: HQ_ROOT — HQ root override (default: resolved from script location)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HQ_ROOT="${HQ_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"

usage() { sed -n '3,25p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }
die()   { echo "hq-delegate-grant: $*" >&2; exit 1; }

command -v jq >/dev/null 2>&1 || die "jq is required but not installed"

MANIFEST="" YES=0
while [ $# -gt 0 ]; do
  case "$1" in
    --manifest) MANIFEST="${2:-}"; shift 2 ;;
    --yes)      YES=1; shift ;;
    -h|--help)  usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[ -n "$MANIFEST" ] || die "--manifest is required"
[ -f "$MANIFEST" ] || die "manifest not found: $MANIFEST"
jq -e . "$MANIFEST" >/dev/null 2>&1 || die "manifest is not valid JSON: $MANIFEST"

COMPANY="$(jq -r '.company // empty' "$MANIFEST")"
PROJECT="$(jq -r '.project.name // empty' "$MANIFEST")"
PRINCIPAL="$(jq -r '.to.principal // empty' "$MANIFEST")"
DISPLAY="$(jq -r '.to.displayName // .to.principal // empty' "$MANIFEST")"
STATUS="$(jq -r '.status // empty' "$MANIFEST")"
[ -n "$COMPANY" ]   || die "manifest has no company"
[ -n "$PROJECT" ]   || die "manifest has no project.name"
[ -n "$PRINCIPAL" ] || die "manifest has no to.principal"

# File-ACL principals must be an email, grp_<id>, or @all — an agentUid is
# NOT accepted by `hq files share`. For agent recipients, grants flow through
# a deterministic per-agent delegation group (the /new-agent pattern):
# grp_dlg-<uid tail>, containing exactly that agent.
GRANT_PRINCIPAL="$PRINCIPAL"
case "$PRINCIPAL" in
  agt_*)
    TAIL="$(printf '%s' "$PRINCIPAL" | tail -c 9 | tr '[:upper:]' '[:lower:]')"
    GRANT_PRINCIPAL="grp_dlg-$TAIL"
    ;;
esac

case "$STATUS" in
  building|granted) ;;
  *) die "manifest status is '$STATUS' — grants run from 'building' (or re-run from 'granted'), not from there" ;;
esac

PREFIX_COUNT="$(jq '.vaultPrefixes | length' "$MANIFEST")"
[ "$PREFIX_COUNT" -gt 0 ] || die "manifest has no vaultPrefixes"

# --- validate every prefix BEFORE touching anything --------------------------
# Company-relative, trailing-slash folder form. A bare prefix would degrade to
# a single literal key and grant nothing useful; company-anchored prefixes do
# not exist in the bucket. Either is a hard error, never a silent grant.

BAD="$(jq -r '.vaultPrefixes[] | .prefix
  | select((endswith("/") | not) or startswith("companies/") or startswith("/"))' "$MANIFEST")"
if [ -n "$BAD" ]; then
  die "prefix violates the hq-files prefix conventions (must be company-relative folder form ending in '/'): $BAD"
fi

# --- plan (always printed; the only output without --yes) --------------------

echo "Delegation grant plan — company '$COMPANY', recipient '$PRINCIPAL':"
if [ "$GRANT_PRINCIPAL" != "$PRINCIPAL" ]; then
  echo "  0. Agent recipient: grants flow through group $GRANT_PRINCIPAL (created if absent, containing exactly $DISPLAY)"
fi
echo "  1. Push companies/$COMPANY/projects/$PROJECT/ to the vault (on-conflict keep)"
jq -r '.vaultPrefixes[] | "  2. Grant \(.permission) on \(.prefix) — \(.reason // "")"' "$MANIFEST"
WRITE_PREFIXES="$(jq -r '.vaultPrefixes[] | select(.permission == "write") | .prefix' "$MANIFEST")"
if [ -n "$WRITE_PREFIXES" ]; then
  echo
  echo "NOTE: granting 'write' is a privilege escalation. The recipient will be able"
  echo "to upload, overwrite, and delete under: $(printf '%s ' "$WRITE_PREFIXES")"
fi

if [ "$YES" -ne 1 ]; then
  echo
  echo "hq-delegate-grant: confirmation required — re-run with --yes after the user approves" >&2
  exit 2
fi

# --- 1. materialize the dossier AND referenced knowledge in the vault --------
# (Live finding: granting read on a knowledge prefix is useless if the
# specific referenced file was never pushed — the recipient's pull succeeds
# on the prefix and silently misses the file. Push every referenced
# company-local knowledge/policy path alongside the dossier.)

hq sync push "companies/$COMPANY/projects/$PROJECT/" --company "$COMPANY" --on-conflict keep \
  || die "vault push failed for companies/$COMPANY/projects/$PROJECT/"

jq -r --arg co "$COMPANY" \
  '((.knowledge // []) + (.policies // []))[] | select(startswith("companies/" + $co + "/"))' \
  "$MANIFEST" | while IFS= read -r kpath; do
  if [ -e "$HQ_ROOT/$kpath" ]; then
    hq sync push "$kpath" --company "$COMPANY" --on-conflict keep \
      || die "vault push failed for referenced knowledge: $kpath"
  else
    echo "hq-delegate-grant: referenced path missing locally (cannot push): $kpath — the verify probe will fail if it is not already in the vault" >&2
  fi
done

# --- 1b. agent recipients: ensure the delegation group exists + contains them

if [ "$GRANT_PRINCIPAL" != "$PRINCIPAL" ]; then
  # Both calls are idempotent-tolerated: an existing group / existing member
  # is fine — the ACL read-back below is the arbiter of success.
  hq groups create "$GRANT_PRINCIPAL" --name "Delegation: $DISPLAY" --company "$COMPANY" \
    || echo "hq-delegate-grant: group create reported an error (may already exist) — continuing" >&2
  hq groups add "$GRANT_PRINCIPAL" "$PRINCIPAL" --company "$COMPANY" \
    || echo "hq-delegate-grant: group add reported an error (may already be a member) — continuing" >&2
fi

# --- 2+3. grant each prefix, then verify via ACL read-back -------------------

NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
i=0
while [ "$i" -lt "$PREFIX_COUNT" ]; do
  PFX="$(jq -r ".vaultPrefixes[$i].prefix" "$MANIFEST")"
  PERM="$(jq -r ".vaultPrefixes[$i].permission" "$MANIFEST")"

  if ! hq files share "$PFX" --with "$GRANT_PRINCIPAL" --permission "$PERM" --company "$COMPANY"; then
    # The share may fail because an identical grant already exists — the
    # read-back below is the arbiter either way.
    echo "hq-delegate-grant: share reported an error on $PFX — checking whether the grant already exists" >&2
  fi

  ACL_OUT="$(hq files acl "$PFX" --company "$COMPANY" 2>/dev/null || true)"
  MATCH="$(printf '%s\n' "$ACL_OUT" | grep -F "$GRANT_PRINCIPAL" | grep -c "$PERM" || true)"
  if [ "${MATCH:-0}" -eq 0 ]; then
    die "grant did not land: '$PRINCIPAL' with '$PERM' not visible in ACL for '$PFX' — manifest status left unchanged"
  fi
  echo "hq-delegate-grant: verified $PERM on $PFX for $PRINCIPAL"
  i=$((i + 1))
done

# --- 4. advance manifest status ----------------------------------------------

TMP_MANIFEST="$(mktemp)"
jq --arg now "$NOW" --arg gp "$GRANT_PRINCIPAL" '
  .status = "granted"
  | .grantPrincipal = $gp
  | .vaultPrefixes = [.vaultPrefixes[] | . + {verifiedAt: $now}]
' "$MANIFEST" > "$TMP_MANIFEST" && mv "$TMP_MANIFEST" "$MANIFEST"

echo "hq-delegate-grant: all $PREFIX_COUNT grants verified — manifest status advanced to 'granted'"
