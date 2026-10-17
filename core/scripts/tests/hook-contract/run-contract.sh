#!/usr/bin/env bash
# hq-core: public
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
exec node "$SCRIPT_DIR/run-contract.mjs" "$@"
