#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
source "$ROOT/core/scripts/tests/hq-anywhere-flag-fixture.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
hq_anywhere_flag_fixture "$TMP/cli"
flag() { env -u HQ_FLAG_HQ_ANYWHERE_RUNTIME HQ_FLAG_CLI_BIN="$TMP/cli/bin/hq" HQ_FLAGS_API_URL=https://flags.test HQ_COMPANY_UID=cmp_123456 HQ_TEST_FLAG="$1" node "$ROOT/core/scripts/hq-anywhere-runtime-flag.cjs"; }
missing_endpoint() { env -u HQ_FLAGS_API_URL -u HQ_COMPANY_UID -u HQ_FLAG_HQ_ANYWHERE_RUNTIME HQ_FLAG_CLI_BIN="$TMP/cli/bin/hq" node "$ROOT/core/scripts/hq-anywhere-runtime-flag.cjs"; }
missing_uid() { env -u HQ_COMPANY_UID -u HQ_FLAG_HQ_ANYWHERE_RUNTIME HQ_FLAG_CLI_BIN="$TMP/cli/bin/hq" HQ_FLAGS_API_URL=https://flags.test HQ_TEST_FLAG=true node "$ROOT/core/scripts/hq-anywhere-runtime-flag.cjs"; }
override() { env -u HQ_TEST_FLAG HQ_FLAG_CLI_BIN="$TMP/cli/bin/hq" HQ_FLAGS_API_URL=https://flags.test HQ_COMPANY_UID=cmp_123456 HQ_FLAG_HQ_ANYWHERE_RUNTIME="$1" node "$ROOT/core/scripts/hq-anywhere-runtime-flag.cjs"; }
count=0
failed=0
assert_value() {
  local name="$1" expected="$2" actual
  shift 2
  if ! actual="$("$@" 2>"$TMP/stderr")"; then
    printf 'FAIL %s: command failed\n' "$name"
    failed=$((failed + 1))
  elif [ "$actual" != "$expected" ]; then
    printf 'FAIL %s: expected %s, got %s\n' "$name" "$expected" "$actual"
    failed=$((failed + 1))
  else
    printf 'PASS %s: %s\n' "$name" "$actual"
  fi
  count=$((count + 1))
}
assert_value 'missing endpoint defaults on' true missing_endpoint
assert_value 'missing company UID defaults on' true missing_uid
assert_value 'row true stays on' true flag true
assert_value 'row false stays off' false flag false
assert_value 'row absent defaults on' true flag absent
assert_value 'archived row defaults on' true flag archived
assert_value 'reader throw defaults on' true flag unreadable
grep -q 'using default-on behavior' "$TMP/stderr"
assert_value 'cached explicit false survives a read failure' false flag stale-false
assert_value 'cached explicit false survives a thrown read' false flag stale-false-throw
assert_value 'reader timeout defaults on' true flag timeout
assert_value 'local override false stays off' false override false
assert_value 'local override zero stays off' false override 0
printf 'Assertions: %s; failures: %s\n' "$count" "$failed"
[ "$failed" -eq 0 ]
