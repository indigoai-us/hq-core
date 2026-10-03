#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 6 ]]; then
  echo "usage: publish-hq-anywhere-runtime-assets.sh <true|false> <owner/repo> <release-tag> <plugin.tar.gz> <marketplace.tar.gz> <pack.tar.gz>" >&2
  exit 2
fi

publish_enabled="$1"
repository="$2"
release_tag="$3"
shift 3

case "$publish_enabled" in
  true) ;;
  false)
    echo "Runtime asset publish skipped: publish_runtime_assets is false"
    exit 0
    ;;
  *)
    echo "error: publish switch must be true or false" >&2
    exit 2
    ;;
esac

if [[ ! "$repository" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
  echo "error: repository must be an explicit owner/repo pair" >&2
  exit 2
fi

if [[ ! "$release_tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9.-]+)?$ ]]; then
  echo "error: refusing to upload runtime assets to non-release tag: $release_tag" >&2
  exit 2
fi

for asset in "$@"; do
  if [[ ! -f "$asset" ]]; then
    echo "error: runtime release asset does not exist: $asset" >&2
    exit 2
  fi
done

gh release upload --repo "$repository" --clobber "$release_tag" "$@"
