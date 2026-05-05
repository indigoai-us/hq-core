---
description: Mark an HQ company directory as cloud-backed and run company sync
allowed-tools: Bash, Read
argument-hint: "<company-slug>"
visibility: public
---

# /designate-team

Designate one local `companies/{slug}/` directory as an HQ Pro team workspace by
setting `cloud: true` in `companies/{slug}/company.yaml` (an AppBar marker), then
delegating cloud provisioning to the canonical CLI subcommand
`hq cloud provision company <slug>`.

**Company slug:** `$ARGUMENTS`

## Rules

- Refuse `personal`; personal sync is auto-provisioned per-user.
- Validate the slug is non-empty and uses only `[A-Za-z0-9._-]`.
- Validate `companies/{slug}/` exists locally (deeper validation — manifest
  membership, archived status — happens inside the CLI subcommand).
- Write `cloud: true` to `companies/{slug}/company.yaml` idempotently. This is
  an **AppBar marker** that `provision.rs::provision_missing_companies()` reads
  to discover cloud-eligible companies. The CLI subcommand writes
  `.hq/config.json` + patches `manifest.yaml` but does NOT touch `company.yaml`.
- Delegate manifest patching, vault entity creation, S3 bucket provisioning, and
  initial sync to `hq cloud provision company <slug>`. The CLI emits one line of
  structured JSON to stdout on success (or partial success on exit code 3).
- If `hq` is not on `PATH`, print the exact subcommand for the user to run later
  and exit 0 (company.yaml has been written; remaining work is recoverable).
- Echo the active HQ environment (vault URL, Cognito pool domain, current
  operator) before calling the CLI. This catches "wrong userpool" / "wrong
  vault" surprises early and works for every HQ user — no owner-specific paths.
- After the CLI succeeds, run a `GET /membership/me` self-check against the
  vault API the CLI just used. If the new `cloud_uid` is present in the
  response, the company will appear in the HQ console for the current operator.
  This is the same endpoint the console calls, so a green check here is a
  deterministic guarantee of console visibility.
- Append one JSONL audit row to `workspace/learnings/designate-team-runs.jsonl`
  capturing the structured result from the CLI plus the `membership_visible`
  flag from the self-check.
- Exit codes: 0 success | 1 vault/auth | 2 invalid input | 3 sync failed
  (entity provisioned) | 4 provisioned but membership self-check failed
  (entity exists but operator can't see it — likely a userpool/token mismatch).

## Implementation

Run this from the HQ root:

```bash
set -euo pipefail

slug="${ARGUMENTS:-}"
if [ -z "$slug" ]; then
  echo "Usage: /designate-team <company-slug>" >&2
  exit 2
fi
if [ "$slug" = "personal" ]; then
  echo "ERROR: personal is out of scope for /designate-team" >&2
  exit 2
fi
case "$slug" in
  *[!A-Za-z0-9._-]*)
    echo "ERROR: invalid company slug '$slug'" >&2
    exit 2
    ;;
esac

company_dir="companies/$slug"
company_yaml="$company_dir/company.yaml"
audit_log="workspace/learnings/designate-team-runs.jsonl"

if [ ! -d "$company_dir" ]; then
  echo "ERROR: company directory not found: $company_dir" >&2
  exit 1
fi

# Idempotently write cloud: true to company.yaml.
# This is the AppBar marker (provision.rs walks companies/*/company.yaml looking
# for cloud:true). The CLI subcommand never writes this file — it writes
# .hq/config.json and patches manifest.yaml.
mkdir -p "$company_dir"
if [ ! -f "$company_yaml" ]; then
  printf "slug: %s\ncloud: true\n" "$slug" > "$company_yaml"
elif ! grep -Eq '^[[:space:]]*cloud:[[:space:]]*true[[:space:]]*$' "$company_yaml"; then
  tmp="$(mktemp)"
  awk '
    BEGIN { seen=0 }
    /^[[:space:]]*cloud:[[:space:]]*/ {
      if (!seen) { print "cloud: true"; seen=1 }
      next
    }
    { print }
    END { if (!seen) print "cloud: true" }
  ' "$company_yaml" > "$tmp"
  mv "$tmp" "$company_yaml"
fi

cloud_count="$(grep -Ec '^[[:space:]]*cloud:[[:space:]]*' "$company_yaml" || true)"
if [ "$cloud_count" != "1" ]; then
  echo "ERROR: expected exactly one cloud key in $company_yaml, found $cloud_count" >&2
  exit 1
fi

# Graceful path: hq not on PATH. Surface the exact CLI command for the user.
if ! command -v hq >/dev/null 2>&1; then
  echo "Updated $company_yaml"
  echo "hq binary not found on PATH. After installing the HQ CLI, run:"
  echo "  hq cloud provision company $slug"
  exit 0
fi

# Echo the active HQ environment so any user can sanity-check their target.
# Reads from env (HQ_VAULT_API_URL, HQ_COGNITO_DOMAIN) when set, otherwise
# falls back to the CLI defaults. Operator identity comes from `hq whoami`
# when available — this is informational only, never blocking.
hq_vault_api_url_env="${HQ_VAULT_API_URL:-}"
hq_cognito_domain_env="${HQ_COGNITO_DOMAIN:-vault-indigo-hq-prod}"
hq_whoami_line=""
if hq whoami >/dev/null 2>&1; then
  hq_whoami_line="$(hq whoami 2>/dev/null | head -1 || true)"
fi
echo "HQ environment for designation:"
echo "  Operator:          ${hq_whoami_line:-<unknown — run \`hq auth login\`>}"
echo "  Vault API URL:     ${hq_vault_api_url_env:-<CLI default>}"
echo "  Cognito domain:    ${hq_cognito_domain_env}"

# Delegate to the canonical CLI subcommand.
# Exit codes: 0 success | 1 vault/auth | 2 invalid input | 3 sync failed (entity provisioned)
provision_output="$(mktemp)"
set +e
hq cloud provision company "$slug" >"$provision_output"
provision_status=$?
set -e

# CLI emits one structured JSON line to stdout. Log lines go to stderr.
provision_json="$(grep -E '^\{' "$provision_output" | tail -1 || true)"
cat "$provision_output"
rm -f "$provision_output"

if [ "$provision_status" -ne 0 ] && [ "$provision_status" -ne 3 ]; then
  echo "ERROR: hq cloud provision company $slug failed (exit $provision_status)" >&2
  exit "$provision_status"
fi

# Parse fields for the audit row + summary. Defaults handle empty JSON.
if [ -n "$provision_json" ]; then
  cloud_uid="$(printf '%s' "$provision_json" | jq -r '.cloud_uid // ""')"
  bucket_name="$(printf '%s' "$provision_json" | jq -r '.bucket_name // ""')"
  vault_api_url="$(printf '%s' "$provision_json" | jq -r '.vault_api_url // ""')"
  manifest_patched="$(printf '%s' "$provision_json" | jq -r '.manifest_patched // false')"
  config_written="$(printf '%s' "$provision_json" | jq -r '.config_written // false')"
  sync_ok="$(printf '%s' "$provision_json" | jq -r '.initial_sync.ok // false')"
  files_uploaded="$(printf '%s' "$provision_json" | jq -r '.initial_sync.files_uploaded // 0')"
else
  cloud_uid=""; bucket_name=""; vault_api_url=""
  manifest_patched=false; config_written=false; sync_ok=false; files_uploaded=0
fi

# Membership self-check — confirms the new cloud_uid is visible to the
# operator's Cognito identity. If the CLI surfaced its own vault URL we use
# that; else fall back to the vault URL written into .hq/config.json (the
# CLI's source of truth); else env override; else skip silently. Token comes
# from the standard cache the CLI maintains at ~/.hq/cognito-tokens.json.
# Sets membership_visible=true|false|unknown — only `false` triggers exit 4.
membership_visible="unknown"
membership_check_url=""
if [ -n "$vault_api_url" ]; then
  membership_check_url="$vault_api_url"
elif [ -f .hq/config.json ]; then
  membership_check_url="$(jq -r '.vaultApiUrl // empty' .hq/config.json 2>/dev/null || true)"
fi
if [ -z "$membership_check_url" ] && [ -n "$hq_vault_api_url_env" ]; then
  membership_check_url="$hq_vault_api_url_env"
fi

token_file="${HOME}/.hq/cognito-tokens.json"
if [ -n "$cloud_uid" ] && [ -n "$membership_check_url" ] && [ -f "$token_file" ]; then
  access_token="$(jq -r '.accessToken // empty' "$token_file" 2>/dev/null || true)"
  if [ -n "$access_token" ]; then
    membership_body="$(mktemp)"
    membership_status="$(curl -sS -o "$membership_body" -w '%{http_code}' \
      -H "Authorization: Bearer ${access_token}" \
      -H "Accept: application/json" \
      "${membership_check_url%/}/membership/me" 2>/dev/null || echo "000")"
    if [ "$membership_status" = "200" ]; then
      if jq -e --arg u "$cloud_uid" '.memberships // [] | map(.companyUid) | index($u)' \
          "$membership_body" >/dev/null 2>&1; then
        membership_visible="true"
      else
        membership_visible="false"
      fi
    fi
    rm -f "$membership_body"
  fi
fi

# Audit row — structured JSONL (one record per run).
mkdir -p "$(dirname "$audit_log")"
printf '{"ts":"%s","company":"%s","company_yaml":"%s","cli":"hq cloud provision company","exit_status":%d,"cloud_uid":%s,"bucket_name":%s,"vault_api_url":%s,"manifest_patched":%s,"config_written":%s,"initial_sync_ok":%s,"files_uploaded":%s,"membership_visible":%s}\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  "$slug" \
  "$company_yaml" \
  "$provision_status" \
  "$(if [ -n "$cloud_uid" ]; then jq -Rn --arg v "$cloud_uid" '$v'; else printf 'null'; fi)" \
  "$(if [ -n "$bucket_name" ]; then jq -Rn --arg v "$bucket_name" '$v'; else printf 'null'; fi)" \
  "$(if [ -n "$vault_api_url" ]; then jq -Rn --arg v "$vault_api_url" '$v'; else printf 'null'; fi)" \
  "$manifest_patched" \
  "$config_written" \
  "$sync_ok" \
  "$files_uploaded" \
  "$(jq -Rn --arg v "$membership_visible" '$v')" \
  >> "$audit_log"

if [ "$provision_status" -eq 3 ]; then
  echo "PARTIAL: $slug entity provisioned but initial sync failed."
  echo "  Cloud UID: $cloud_uid"
  echo "  Bucket: $bucket_name"
  echo "  Re-run 'hq sync push companies/$slug --company $slug' to retry."
  exit 3
fi

echo "Designated $slug for cloud sync."
[ -n "$cloud_uid" ] && echo "Cloud UID: $cloud_uid"
[ -n "$bucket_name" ] && echo "Bucket: $bucket_name"
[ "$sync_ok" = "true" ] && echo "Initial sync: $files_uploaded files uploaded"

case "$membership_visible" in
  true)
    echo "Console visibility: confirmed via /membership/me"
    ;;
  false)
    echo "WARN: $slug provisioned but not visible via /membership/me." >&2
    echo "  This usually means the CLI authenticated against a different Cognito" >&2
    echo "  pool than the console. Check HQ_COGNITO_DOMAIN / HQ_VAULT_API_URL," >&2
    echo "  refresh tokens with \`hq auth login\`, and re-run the self-check:" >&2
    echo "    curl -H \"Authorization: Bearer \$(jq -r .accessToken ~/.hq/cognito-tokens.json)\" \\" >&2
    echo "      ${membership_check_url%/}/membership/me" >&2
    exit 4
    ;;
  unknown)
    echo "Console visibility: not checked (no cached token or vault URL)."
    ;;
esac
```
