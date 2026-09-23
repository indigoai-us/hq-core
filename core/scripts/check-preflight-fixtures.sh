#!/usr/bin/env bash
# hq-core: public
# Diff the vendored offline-preflight fixtures against an installed hq-cli
# when one is present. No installed copy is a skip, not a pass-by-absence
# of the pin (the pin lives in preflight-contract-fixtures.test.sh).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
VENDORED="$ROOT/core/hooks/SessionStart/preflight-fixtures.json"
[ -f "$VENDORED" ] || { echo "missing $VENDORED" >&2; exit 1; }

candidates=()
if [ -n "${HQ_CLI_ROOT:-}" ]; then
  candidates+=("$HQ_CLI_ROOT")
fi
if command -v node >/dev/null 2>&1; then
  resolved="$(node -p "try{require('path').dirname(require.resolve('@indigoai-us/hq-cli/package.json'))}catch(e){''}" 2>/dev/null || true)"
  if [ -n "$resolved" ]; then
    candidates+=("$resolved")
  fi
fi

found=0
for root in "${candidates[@]}"; do
  src="$root/contracts/preflight/v1/fixtures.json"
  if [ -f "$src" ]; then
    found=1
    echo "diff $src"
    diff -u "$src" "$VENDORED"
  fi
done

if [ "$found" -eq 0 ]; then
  echo "no installed hq-cli fixtures; vendored copy not diffed"
fi
