#!/usr/bin/env bash
# Regression: .claude/skills/deploy/scripts/resolve-deploy-api.sh MUST always
# print a non-empty hq-deploy API base. The load-bearing case is a FRESH INSTALL
# (no companies/manifest.yaml, no $HQ_DEPLOY_API) — it must fall back to the
# public default https://api.indigo-hq.com, never the empty string. Without that
# fallback the /deploy skill stalls at Phase C on an empty upload host
# (Hassaan directive, task-3517155514).
set -euo pipefail
ROOT="$(git rev-parse --show-toplevel)"
SRC="$ROOT/.claude/skills/deploy/scripts/resolve-deploy-api.sh"
DEFAULT="https://api.indigo-hq.com"
fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "  ok: $*"; }
[ -f "$SRC" ] || fail "resolve-deploy-api.sh not found at $SRC"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

echo "[1] fresh install (no manifest, no \$HQ_DEPLOY_API) → public default, never empty"
out="$(cd "$TMP" && env -u HQ_DEPLOY_API bash "$SRC")"
[ -n "$out" ] || fail "resolver printed an EMPTY base (would stall /deploy at Phase C)"
[ "$out" = "$DEFAULT" ] || fail "fresh-install fallback was '$out', expected '$DEFAULT'"
pass "fresh install → $out"

echo "[2] \$HQ_DEPLOY_API set → explicit override wins"
out="$(cd "$TMP" && HQ_DEPLOY_API='https://override.example.com' bash "$SRC")"
[ "$out" = "https://override.example.com" ] || fail "env override not honored: got '$out'"
pass "env override → $out"

echo "[3] companies/manifest.yaml endpoint → tenant override wins over the default"
mkdir -p "$TMP/hqtree/companies/sub/proj"
printf 'services:\n  hq-deploy:\n    endpoint: https://tenant.example.com\n' > "$TMP/hqtree/companies/manifest.yaml"
# resolve from a nested cwd to prove the walk-up finds the nearest manifest
out="$(cd "$TMP/hqtree/companies/sub/proj" && env -u HQ_DEPLOY_API bash "$SRC")"
[ "$out" = "https://tenant.example.com" ] || fail "manifest endpoint not resolved: got '$out'"
pass "manifest endpoint → $out"

echo "[4] nounset-safe: runs under set -u with \$HQ_DEPLOY_API unset, no unbound abort"
out="$(cd "$TMP" && env -u HQ_DEPLOY_API bash -c "set -u; bash '$SRC'" 2>&1)"
printf '%s' "$out" | grep -qi 'unbound variable' && fail "aborts with unbound variable under set -u: $out"
[ "$out" = "$DEFAULT" ] || fail "set -u run did not resolve cleanly: got '$out'"
pass "nounset-safe → $out"

echo "[5] source-contract: the public default is present and is the exact reconciled value"
grep -qF 'API="${API:-https://api.indigo-hq.com}"' "$SRC" \
  || fail "the always-on public default https://api.indigo-hq.com is missing from the resolver"
grep -qF 'API="${HQ_DEPLOY_API:-}"' "$SRC" \
  || fail "\$HQ_DEPLOY_API is not read nounset-safe (\${HQ_DEPLOY_API:-})"
pass "public default + nounset-safe env read present"

echo "ALL PASS: resolve-deploy-api"
