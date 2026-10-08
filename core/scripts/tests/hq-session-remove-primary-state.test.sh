#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/core/scripts/lib" "$TMP/core/scripts" "$TMP/.codex/hooks" \
  "$TMP/workspace/sessions/sid-remove" "$TMP/companies/acme" "$TMP/companies/beta" "$TMP/home"
cp "$ROOT/core/scripts/hq-session.sh" "$TMP/core/scripts/"
cp "$ROOT/core/scripts/lib/session-scope-capability.sh" "$ROOT/core/scripts/lib/session-id.sh" "$TMP/core/scripts/lib/"
cp "$ROOT/core/scripts/hqd-hook-flag-cache-lib.sh" "$TMP/core/scripts/"
printf '%s\n' 'process.stdout.write("true")' > "$TMP/.codex/hooks/codex-explicit-path-flag.cjs"
printf 'session_id: sid-remove\ncompany_slug: acme\ncompany_slugs: acme,beta\nproject: old-project\ntask: old-task\n' \
  > "$TMP/workspace/sessions/sid-remove/meta.yaml"
printf '{"session_id":"sid-remove","company_slug":"acme","company_slugs":["acme","beta"]}\n' \
  > "$TMP/workspace/sessions/sid-remove/scope-capability.json"

HOME="$TMP/home" HQ_ROOT="$TMP" HQ_HQ_SESSION_NO_CLI=1 \
  "$TMP/core/scripts/hq-session.sh" --session-id sid-remove remove company acme >/dev/null
for key in project task; do
  value="$(HOME="$TMP/home" HQ_ROOT="$TMP" HQ_HQ_SESSION_NO_CLI=1 \
    "$TMP/core/scripts/hq-session.sh" --session-id sid-remove get "$key")"
  [ -z "$value" ] || { echo "FAIL: removing primary retained stale $key=$value" >&2; exit 1; }
done
echo "PASS: hq-session-remove-primary-state.test.sh (old tenant project/task cleared)"
