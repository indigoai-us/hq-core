#!/usr/bin/env bash
# FORWARDER — hq core derive-trigger-facts; shared runtime lives in lib/forwarder.sh.
set -euo pipefail
FORWARDER_PATH="${BASH_SOURCE[0]}"
FORWARDER_DIR="${FORWARDER_PATH%/*}"
[ "$FORWARDER_DIR" != "$FORWARDER_PATH" ] || FORWARDER_DIR=.
SCRIPT_DIR="$(cd "$FORWARDER_DIR" && pwd)"
# shellcheck disable=SC2034
PATH_OPERANDS=none
if [ ! -f "$SCRIPT_DIR/lib/forwarder.sh" ]; then
  printf '%s: required forwarder library is missing: %s\n' 'derive-trigger-facts.sh' "$SCRIPT_DIR/lib/forwarder.sh" >&2
  exit 1
fi
# shellcheck source=lib/forwarder.sh
. "$SCRIPT_DIR/lib/forwarder.sh"
export HQ_NO_UPDATE_CHECK=1
forwarder_exec "derive-trigger-facts.sh" "5.342.5" "live-project" "derive-trigger-facts" "true" "$@"
