#!/usr/bin/env bash
set -euo pipefail

required_build_tools=(dirname mktemp mkdir rm rsync node npm mv zip)
missing_build_tools=()
for tool in "${required_build_tools[@]}"; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    missing_build_tools+=("$tool")
  fi
done

if [ "${#missing_build_tools[@]}" -gt 0 ]; then
  printf 'Missing required Cowork plugin build tools: %s\n' "${missing_build_tools[*]}" >&2
  printf 'Install the missing tools and ensure they are on PATH:\n' >&2
  for tool in "${missing_build_tools[@]}"; do
    case "$tool" in
      rsync)
        printf '  rsync: MSYS2: pacman -S rsync; macOS: brew install rsync; Debian/Ubuntu: sudo apt install rsync\n' >&2
        ;;
      zip)
        printf '  zip: MSYS2: pacman -S zip; macOS: brew install zip; Debian/Ubuntu: sudo apt install zip\n' >&2
        ;;
      node|npm)
        printf '  %s: install Node.js; its installer includes npm\n' "$tool" >&2
        ;;
      dirname|mktemp|mkdir|rm|mv)
        printf '  %s: install the standard shell utilities (MSYS2: pacman -S coreutils)\n' "$tool" >&2
        ;;
    esac
  done
  exit 1
fi

PACK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${1:-$HOME/Downloads/hq-pack-cowork.plugin}"
BUILD_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/hq-pack-cowork-build.XXXXXX")"
STAGE="$BUILD_ROOT/hq-pack-cowork"
PNPM_VERSION="10.32.1"
ESBUILD_VERSION="0.28.2"

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
  # Install from the committed pnpm-lock.yaml, so the plugin bundles the
  # versions CI tests. A lockfile that is out of sync with package.json fails
  # the build instead of resolving a fresh tree. pnpm and esbuild are pinned
  # to exact versions; pnpm matches the pr-checks.yml cowork job.
  npm exec --yes --package="pnpm@$PNPM_VERSION" -- \
    pnpm install --frozen-lockfile --prod --ignore-scripts --ignore-workspace
  npm exec --yes --package="esbuild@$ESBUILD_VERSION" -- esbuild index.mjs \
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
