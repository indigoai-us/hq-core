#!/usr/bin/env bash
# Thin wrapper so the hook-local tests directory also runs the DEF-026 suite.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
exec bash "$ROOT/core/scripts/tests/block-env-dump.test.sh"
