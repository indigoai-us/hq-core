#!/usr/bin/env bash
# hq-core: public
# hq-adapter-contract-version.sh — on-box reader for the provider adapter contract version.
#
# Prints the installed HQ_ADAPTER_CONTRACT_VERSION to stdout.
# Exits 3 with 'adapter contract not installed' when the version stamp is absent
# (the signal US-059 / US-507 fallbacks consume).
#
# Usage:
#   hq-adapter-contract-version.sh [HQ_ROOT]
#   HQ_ROOT=/path/to/hq hq-adapter-contract-version.sh

set -euo pipefail

_hq_adapter_reader_root() {
  if [[ -n "${1:-}" ]]; then
    printf '%s\n' "$1"
    return 0
  fi
  if [[ -n "${HQ_ROOT:-}" ]]; then
    printf '%s\n' "$HQ_ROOT"
    return 0
  fi
  # Script lives at <root>/core/scripts/hq-adapter-contract-version.sh
  local here
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  printf '%s\n' "$(cd "$here/../.." && pwd)"
}

ROOT="$(_hq_adapter_reader_root "${1:-}")"
VER_FILE="$ROOT/core/scripts/lib/provider-adapter-version.sh"

if [[ ! -f "$VER_FILE" ]]; then
  echo "adapter contract not installed" >&2
  exit 3
fi

# shellcheck disable=SC1090
# shellcheck source=lib/provider-adapter-version.sh
. "$VER_FILE"

if [[ -z "${HQ_ADAPTER_CONTRACT_VERSION:-}" ]]; then
  echo "adapter contract not installed" >&2
  exit 3
fi

printf '%s\n' "$HQ_ADAPTER_CONTRACT_VERSION"
