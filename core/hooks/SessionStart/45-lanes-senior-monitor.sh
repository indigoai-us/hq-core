#!/usr/bin/env bash
# hq-core: public
# SessionStart: if this session is senior of a still-askable lane, instruct
# it to arm a 20-minute Monitor. Implementation:
# core/scripts/lib/lanes-senior-monitor.sh
set -euo pipefail
_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec bash "$_here/../../scripts/lib/lanes-senior-monitor.sh" "${1:-SessionStart}"
