#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
source "$ROOT/core/scripts/tests/hq-anywhere-flag-fixture.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
hq_anywhere_flag_fixture "$TMP/cli"
flag() { HQ_FLAG_CLI_BIN="$TMP/cli/bin/hq" HQ_FLAGS_API_URL=https://flags.test HQ_COMPANY_UID=cmp_123456 HQ_TEST_FLAG="$1" node "$ROOT/core/scripts/hq-anywhere-runtime-flag.cjs"; }
[ "$(env -u HQ_FLAGS_API_URL -u HQ_COMPANY_UID HQ_FLAG_CLI_BIN="$TMP/cli/bin/hq" node "$ROOT/core/scripts/hq-anywhere-runtime-flag.cjs")" = false ]
[ "$(flag false)" = false ]
[ "$(flag true)" = true ]
printf '%s\n' 'hq-anywhere-runtime-flag: missing, false, and true snapshots passed'
