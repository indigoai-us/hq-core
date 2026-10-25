#!/usr/bin/env bash
set -euo pipefail
ROOT="${HQ_TEST_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
python3 -I "$ROOT/core/scripts/tests/decision-queue.test.py"
