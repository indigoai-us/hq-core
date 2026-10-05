#!/usr/bin/env bash
# FORWARDER — the implementation of this script now lives in the hq CLI.
#
# It ships at assets/scaffold/core/scripts/hq-dm-bind.sh inside @indigoai-us/hq-cli and
# runs as the hidden command `hq core dm-bind`. This file stays behind so every
# existing caller — skills, other scripts, CI, and muscle memory — keeps working
# against the path it already knows.
#
# Native dm-bind passed the current Windows and macOS parity matrix; core-native-utilities remains the rollback switch.
#
# The ABI is preserved exactly: arguments are forwarded unchanged, stdin is never
# read by this file, stdout and stderr are inherited untouched, and the child
# replaces this process so its exit code and signal disposition become the
# caller's.

set -euo pipefail

FORWARDER_PATH="${BASH_SOURCE[0]}"
FORWARDER_DIR="${FORWARDER_PATH%/*}"
[ "$FORWARDER_DIR" != "$FORWARDER_PATH" ] || FORWARDER_DIR=.
SCRIPT_DIR="$(cd "$FORWARDER_DIR" && pwd)"

# This forwarder sits in the tree it targets, so its own location IS the root.
HQ_ROOT="${HQ_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"

if ! command -v hq >/dev/null 2>&1; then
  echo "hq-dm-bind.sh: requires the hq CLI — this script's implementation now ships with it." >&2
  echo "Install it with: npm install -g @indigoai-us/hq-cli" >&2
  exit 127
fi

if [ -f "$SCRIPT_DIR/lib/hq-cli-floor.sh" ]; then
  # shellcheck source=lib/hq-cli-floor.sh
  . "$SCRIPT_DIR/lib/hq-cli-floor.sh"
  hq_cli_floor_check "hq-dm-bind.sh" "5.309.1"
fi

exec hq core --hq-root "$HQ_ROOT" dm-bind "$@"
