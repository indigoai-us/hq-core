#!/usr/bin/env bash
# FORWARDER — hq core job notify; shared runtime lives in lib/forwarder.sh.
set -euo pipefail
FORWARDER_PATH="${BASH_SOURCE[0]}"
FORWARDER_DIR="${FORWARDER_PATH%/*}"
[ "$FORWARDER_DIR" != "$FORWARDER_PATH" ] || FORWARDER_DIR=.
SCRIPT_DIR="$(cd "$FORWARDER_DIR" && pwd)"
# shellcheck disable=SC2034
PATH_OPERANDS=options:--hq-root\,--log-path
if [ ! -f "$SCRIPT_DIR/lib/forwarder.sh" ]; then
  printf '%s: required forwarder library is missing: %s\n' 'hq-job-notify.sh' "$SCRIPT_DIR/lib/forwarder.sh" >&2
  exit 1
fi
# shellcheck source=lib/forwarder.sh
. "$SCRIPT_DIR/lib/forwarder.sh"
forwarder_exec "hq-job-notify.sh" "5.342.14" "live" "job notify" "false" "$@"
