#!/usr/bin/env bash
set -euo pipefail

PACK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${1:-$HOME/Downloads/hq-pack-cowork.plugin}"
BUILD_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/hq-pack-cowork-build.XXXXXX")"
STAGE="$BUILD_ROOT/hq-pack-cowork"

cleanup() {
  rm -rf "$BUILD_ROOT"
}
trap cleanup EXIT

mkdir -p "$STAGE"
rsync -a \
  --exclude 'mcp-server/node_modules' \
  --exclude 'mcp-server/.pnpm-store' \
  --exclude '.git' \
  --exclude '.DS_Store' \
  "$PACK_ROOT/" "$STAGE/"

(
  cd "$STAGE/mcp-server"
  rm -f .npmrc package-lock.json
  npm install --ignore-scripts --omit=dev --package-lock=false
  npm exec --package=esbuild -- esbuild index.mjs \
    --bundle \
    --platform=node \
    --format=esm \
    --target=node18 \
    --outfile="$STAGE/mcp-server/index.bundle.mjs"
) >&2

mv "$STAGE/mcp-server/index.bundle.mjs" "$STAGE/mcp-server/index.mjs"
rm -rf "$STAGE/mcp-server/node_modules" "$STAGE/mcp-server/package-lock.json"

mkdir -p "$(dirname "$OUT")"
rm -f "$OUT"
(
  cd "$STAGE"
  zip -r -q "$OUT" .
) >&2

echo "$OUT"
