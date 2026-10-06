#!/usr/bin/env bash
# Regression: macOS ships Bash 3.2, where expanding an empty array under
# nounset is an unbound-variable error. Relative PATH entries normalize away.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
RECON="${OUTPOST_RECONCILE_SOURCE:-$ROOT/core/scripts/outpost-jobs-reconcile.sh}"
fail() { echo "FAIL: $*" >&2; exit 1; }

normalizer="$(sed -n '/^normalize_service_path()/,/^}/p' "$RECON")"
[[ -n "$normalizer" ]] || fail "normalizer function is missing"
result="$(printf '%s\n' "$normalizer" | /bin/bash -c 'set -euo pipefail; source /dev/stdin; normalize_service_path "relative:also-relative"')" \
  || fail "relative-only PATH must not fail under nounset"
[[ -z "$result" ]] || fail "relative-only PATH should normalize to empty, got: $result"
echo "PASS: relative-only PATH normalizes under nounset"
