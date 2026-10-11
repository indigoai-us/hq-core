#!/usr/bin/env bash
# FORWARDER — hq core rebuild-index company-knowledge; shared runtime lives in lib/forwarder.sh.
set -euo pipefail
FORWARDER_PATH="${BASH_SOURCE[0]}"
FORWARDER_DIR="${FORWARDER_PATH%/*}"
[ "$FORWARDER_DIR" != "$FORWARDER_PATH" ] || FORWARDER_DIR=.
SCRIPT_DIR="$(cd "$FORWARDER_DIR" && pwd)"
# shellcheck disable=SC2034
PATH_OPERANDS=none
if [ ! -f "$SCRIPT_DIR/lib/forwarder.sh" ]; then
  printf '%s: required forwarder library is missing: %s\n' 'rebuild-company-knowledge-index.sh' "$SCRIPT_DIR/lib/forwarder.sh" >&2
  exit 1
fi
# shellcheck source=lib/forwarder.sh
. "$SCRIPT_DIR/lib/forwarder.sh"
forwarder_exec "rebuild-company-knowledge-index.sh" "5.78.0" "live" "rebuild-index company-knowledge" "false" "$@"
