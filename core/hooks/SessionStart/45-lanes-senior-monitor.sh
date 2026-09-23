#!/usr/bin/env bash
# hq-core: public
# SessionStart: inject the hq-cli-owned senior Monitor reminder. Implementation:
# core/scripts/lib/lanes-senior-monitor.sh
set -euo pipefail
_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec bash "$_here/../../scripts/lib/lanes-senior-monitor.sh" "${1:-SessionStart}"
