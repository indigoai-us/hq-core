#!/usr/bin/env bash
# FORWARDER — the implementation of this script now lives in the hq CLI.
#
# It ships at assets/scaffold/core/scripts/eval-trigger.sh inside @indigoai-us/hq-cli and
# runs as the hidden command `hq core eval-trigger`. This file stays behind so every
# existing caller — skills, other scripts, CI, and muscle memory — keeps working
# against the path it already knows.
#
# This hook-time helper runs on the hq core fast path and retains its
# bundled shell fallback while the core-native-hook-helpers flag is off.
#
# The ABI is preserved exactly: arguments are forwarded unchanged, stdin is never
# read by this file, stdout and stderr are inherited untouched, and the child
# replaces this process so its exit code and signal disposition become the
# caller's.

set -euo pipefail

# Hook-time helpers must not run the CLI self-updater inside the hook deadline.
export HQ_NO_UPDATE_CHECK=1

FORWARDER_PATH="${BASH_SOURCE[0]}"
FORWARDER_DIR="${FORWARDER_PATH%/*}"
[ "$FORWARDER_DIR" != "$FORWARDER_PATH" ] || FORWARDER_DIR=.
SCRIPT_DIR="$(cd "$FORWARDER_DIR" && pwd)"

# No root is injected: this script derived its root from the CALLER's cwd
# before it moved (git top level, a cwd walk, or a positional argument), and the
# CLI preserves that. Anything the caller already exported still applies.

if ! command -v hq >/dev/null 2>&1; then
  echo "eval-trigger.sh: requires the hq CLI — this script's implementation now ships with it." >&2
  echo "Install it with: npm install -g @indigoai-us/hq-cli" >&2
  exit 127
fi

if [ -f "$SCRIPT_DIR/lib/hq-cli-floor.sh" ]; then
  # shellcheck source=lib/hq-cli-floor.sh
  . "$SCRIPT_DIR/lib/hq-cli-floor.sh"
  hq_cli_floor_check "eval-trigger.sh" "5.341.3"
fi

exec hq core eval-trigger "$@"
