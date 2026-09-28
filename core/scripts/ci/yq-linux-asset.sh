#!/usr/bin/env bash
set -euo pipefail

machine="${1:-$(uname -m)}"
case "$machine" in
  x86_64|amd64) printf '%s\n' 'yq_linux_amd64' ;;
  aarch64|arm64) printf '%s\n' 'yq_linux_arm64' ;;
  *)
    echo "unsupported Linux architecture for yq: $machine" >&2
    exit 1
    ;;
esac
