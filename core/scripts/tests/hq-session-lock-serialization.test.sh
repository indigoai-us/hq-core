#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/core/scripts/lib" "$TMP/core/scripts" "$TMP/.codex/hooks" \
  "$TMP/workspace/sessions/sid-lock" "$TMP/companies/acme" "$TMP/companies/beta" "$TMP/home"
cp "$ROOT/core/scripts/hq-session.sh" "$TMP/core/scripts/"
cp "$ROOT/core/scripts/lib/session-scope-capability.sh" "$ROOT/core/scripts/lib/session-id.sh" "$TMP/core/scripts/lib/"
cp "$ROOT/core/scripts/hqd-hook-flag-cache-lib.sh" "$TMP/core/scripts/"
printf '%s\n' 'process.stdout.write("true")' > "$TMP/.codex/hooks/codex-explicit-path-flag.cjs"
printf 'session_id: sid-lock\ncompany_slug: acme\n' > "$TMP/workspace/sessions/sid-lock/meta.yaml"
printf '{"session_id":"sid-lock","company_slug":"acme"}\n' > "$TMP/workspace/sessions/sid-lock/scope-capability.json"

lock="$TMP/workspace/sessions/sid-lock/.company-lock-set.lock"
mkdir "$lock"
printf '%s\n' "$$" > "$lock/pid"
HOME="$TMP/home" HQ_ROOT="$TMP" HQ_HQ_SESSION_NO_CLI=1 \
  "$TMP/core/scripts/hq-session.sh" --session-id sid-lock add company beta >/dev/null &
pid=$!
sleep 1.5
if ! kill -0 "$pid" 2>/dev/null; then
  echo "FAIL: add company ignored the held per-session lock" >&2
  exit 1
fi
rm -rf "$lock"
wait "$pid"
echo "PASS: hq-session-lock-serialization.test.sh (add waits under the per-session lock)"
