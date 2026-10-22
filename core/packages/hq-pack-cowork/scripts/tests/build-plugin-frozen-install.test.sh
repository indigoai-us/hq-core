#!/usr/bin/env bash
# The Cowork plugin build installs the MCP server's dependencies from the
# committed pnpm-lock.yaml with a frozen install, and pins its build tools to
# exact versions. Security audit 2026-10-21, item M3.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_SCRIPT="${BUILD_PLUGIN_SCRIPT:-$SCRIPT_DIR/../build-plugin.sh}"
LOCKFILE="$SCRIPT_DIR/../../mcp-server/pnpm-lock.yaml"

checks=0
failures=0
check() {
  label="$1"
  shift
  checks=$((checks + 1))
  if "$@"; then
    printf 'ok %s\n' "$label"
  else
    failures=$((failures + 1))
    printf 'not ok %s\n' "$label" >&2
  fi
}

lacks() {
  ! grep -Eq -e "$1" "$BUILD_SCRIPT"
}

check "MCP server lockfile is committed" test -f "$LOCKFILE"
check "dependencies install with a frozen pnpm lockfile" \
  grep -Eq 'pnpm install --frozen-lockfile --prod --ignore-scripts' "$BUILD_SCRIPT"
check "no lockfile-free npm dependency install" lacks '(^|[^p])npm (install|i)( |$)|--package-lock=false'
check "pnpm is pinned to an exact version" grep -Eq '^PNPM_VERSION="[0-9]+\.[0-9]+\.[0-9]+"$' "$BUILD_SCRIPT"
check "esbuild is pinned to an exact version" grep -Eq '^ESBUILD_VERSION="[0-9]+\.[0-9]+\.[0-9]+"$' "$BUILD_SCRIPT"
check "pnpm runs at the pinned version" grep -Fq -- '--package="pnpm@$PNPM_VERSION"' "$BUILD_SCRIPT"
check "esbuild runs at the pinned version" grep -Fq -- '--package="esbuild@$ESBUILD_VERSION"' "$BUILD_SCRIPT"
check "no unpinned esbuild" lacks '--package=esbuild( |$)'

if [ "$failures" -eq 0 ]; then
  printf 'PASS build-plugin frozen install (%s/%s assertions)\n' "$checks" "$checks"
  exit 0
fi
printf 'FAIL build-plugin frozen install (%s/%s assertions failed)\n' "$failures" "$checks" >&2
exit 1
