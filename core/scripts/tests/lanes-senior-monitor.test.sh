#!/usr/bin/env bash
# hq-core: public
# Compatibility entrypoint for the hq-cli-backed lane reminder/Stop shim suite.
#
# The former test exercised lane-store logic that now lives in hq-cli. Keep the
# established test path while routing it to the thin shell-wiring coverage.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
exec bash "$ROOT/core/scripts/tests/lanes-senior-monitor-stop-gate.test.sh"
